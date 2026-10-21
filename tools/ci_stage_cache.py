#!/usr/bin/env python3
"""Reuse successful PR stages only after independently verifying their producer.

Input roles are deliberately conservative: all tracked/new nonignored paths are
common inputs unless explicitly assigned below. Tools, workflows/actions, pins,
requirements, packaging, CMake, native/services/proto, and native/helper/inference/
integration tests therefore invalidate every stage. Native excludes only the
known Dart application and service-test trees; core additionally consumes all
core/test-support inputs, desktop consumes core and desktop, service consumes
all application and service tests. Parent identities and complete caller-supplied
compiler/runtime/system-package/SDK identity are mandatory cache inputs.

No producer Python, shell script, or workflow is executed by this verifier. Git
objects are read with this checkout's recipe, including this module itself.
"""

import argparse
import importlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

artifacts = importlib.import_module(
    "tools.ci_artifacts" if __package__ else "ci_artifacts"
)

timing = importlib.import_module("tools.ci_timing" if __package__ else "ci_timing")

ci_git = importlib.import_module("tools.ci_git" if __package__ else "ci_git")
git = ci_git.git
ensure_commit = ci_git.ensure_commit
read_zip = ci_git.read_zip

retained = importlib.import_module("tools.ci_native_cache" if __package__ else "ci_native_cache")
lookup_api = retained.lookup_api
lookup_download = retained.lookup_download
lookup_jobs = retained.lookup_jobs
selected_v1 = retained.selected_v1
selected = retained.selected
version_input = retained.version_input
source_inputs = retained.source_inputs
fingerprint = retained.fingerprint
name = retained.name
reusable = retained.reusable
reusable_native_work = retained.reusable_native_work
trusted_run = retained.trusted_run
trusted_native_work_run = retained.trusted_native_work_run
validate_receipt = retained.validate_receipt
compilation_environment = retained.compilation_environment
changed_configuration = retained.changed_configuration
native_work_candidates = retained.native_work_candidates
native_work_metadata = retained.native_work_metadata
native_work_producers = retained.native_work_producers
find_native_work = retained.find_native_work

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ("linux", "macos")
STAGES = ("native", "core", "desktop", "service")
WORKFLOW = ".github/workflows/macos.yml"
HEX = r"[a-f0-9]{64}"
COMMIT = r"[a-f0-9]{40}"
# These are known editorial inputs. Unknown/new paths always enter the common
# input set rather than silently missing a newly introduced build dependency.
EDITORIAL = {"README.md", "CHANGELOG.md", "LICENSE", "AGENTS.md"}
IDENTITY_RECIPE = 2
MAX_NATIVE_WORK_DOWNLOADS = 3
MAX_NATIVE_WORK_PRODUCER_ERRORS = 3
MAX_STAGE_RECEIPT_BYTES = 16 * 1024 * 1024


@timing.phase("stage result lookup")
def find(
    repository,
    platform,
    stage,
    identity,
    environment,
    parents,
    root=ROOT,
    own_pr=0,
    event="",
    branch="",
    release=False,
    output=None,
):
    """Return verified download/receipt metadata; an ineligible consumer misses."""
    result = {
        "hit": False,
        "identity": identity,
        "artifact_name": name(platform, stage, identity),
    }
    if not reusable(event, own_pr, branch, release):
        return result
    candidates = lookup_api(
        repository, f"actions/artifacts?name={result['artifact_name']}&per_page=100"
    )["artifacts"]
    for artifact in candidates:
        if artifact.get("expired") or artifact.get("name") != result["artifact_name"]:
            continue
        run = lookup_api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
        if not trusted_run(run, repository, own_pr):
            continue
        jobs = lookup_jobs(repository, run["id"])
        # Reject bad job provenance before transferring a potentially large ZIP.
        candidates_jobs = [
            job
            for job in jobs
            if job.get("name", "").split(" / ")[-1] == f"{stage}-{platform}"
            and job.get("conclusion") == "success"
            and artifacts.in_producer_attempt(artifact, job)
        ]
        if not candidates_jobs:
            continue
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "stage.zip"
            try:
                lookup_download(repository, artifact, archive)
                receipt = read_zip(archive)
                validate_receipt(
                    receipt, platform, stage, identity, run, environment, parents, root
                )
                if not any(
                    job.get("run_attempt", 1) == receipt["source_run_attempt"]
                    for job in candidates_jobs
                ):
                    raise ValueError(
                        "Stage payload not from successful producer attempt"
                    )
                if output:
                    read_zip(archive, Path(output))
            except (
                ValueError,
                KeyError,
                zipfile.BadZipFile,
                subprocess.CalledProcessError,
            ):
                continue
        return {
            **result,
            "hit": True,
            "artifact_id": artifact["id"],
            "run_id": run["id"],
            "receipt": receipt,
            **({"download_dir": str(output)} if output else {}),
        }
    return result


def publish(
    platform,
    stage,
    root,
    environment,
    parents,
    archive,
    output,
    content=None,
    reusable_result=True,
    payload_kind=None,
):
    payload_kind = stage if payload_kind is None else payload_kind
    if payload_kind != stage and (stage, payload_kind) != ("native", "native-runtime"):
        raise ValueError("Unexpected stage payload kind")
    artifact_suffix = "-runtime" if payload_kind == "native-runtime" else ""
    identity = fingerprint(
        platform, stage, root, environment=environment, parents=parents
    )
    commit = git(root, "rev-parse", "HEAD").decode().strip()
    # Only a clean committed input tree has a verifiable producer counterpart.
    if (
        reusable_result
        and fingerprint(platform, stage, root, commit, environment, parents) != identity
    ):
        raise ValueError("Cannot publish outputs with uncommitted stage inputs")
    receipt = {
        "schema": 1,
        "identity_recipe": IDENTITY_RECIPE,
        "platform": platform,
        "stage": stage,
        "identity": identity,
        "source_commit": commit,
        "source_run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
        "reusable": reusable_result,
        "payload_kind": payload_kind,
        "environment": environment,
        "parents": parents,
        "sha256": artifacts.digest(archive),
    }
    if content is not None:
        receipt["content"] = content
    output.mkdir(parents=True, exist_ok=True)
    (output / "identity.json").write_text(
        json.dumps(receipt, sort_keys=True, indent=2) + "\n"
    )
    return {
        "identity": identity,
        "artifact_name": name(platform, stage, identity) + artifact_suffix,
        "receipt": receipt,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("key", "probe", "restore", "publish"))
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    parser.add_argument("--stage", choices=STAGES, required=True)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--ref")
    parser.add_argument("--environment-json", type=json.loads, required=True)
    parser.add_argument("--parents-json", type=json.loads, default={})
    parser.add_argument("--content-json", type=json.loads)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument(
        "--branch",
        default=os.environ.get(
            "GITHUB_HEAD_REF", os.environ.get("GITHUB_REF_NAME", "")
        ),
    )
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    identity = fingerprint(
        args.platform,
        args.stage,
        args.root,
        args.ref,
        args.environment_json,
        args.parents_json,
    )
    result = {
        "identity": identity,
        "artifact_name": name(args.platform, args.stage, identity),
    }
    if args.command in ("probe", "restore"):
        if args.command == "restore" and not args.output:
            parser.error("restore requires --output")
        result = find(
            args.repository,
            args.platform,
            args.stage,
            identity,
            args.environment_json,
            args.parents_json,
            args.root,
            args.own_pr,
            args.event,
            args.branch,
            args.release,
            args.output if args.command == "restore" else None,
        )
    elif args.command == "publish":
        if not args.archive or not args.output:
            parser.error("publish requires --archive and --output")
        result = publish(
            args.platform,
            args.stage,
            args.root,
            args.environment_json,
            args.parents_json,
            args.archive,
            args.output,
            args.content_json,
        )
    print(json.dumps(result, sort_keys=True))
    if destination := os.environ.get("GITHUB_OUTPUT"):
        with open(destination, "a") as stream:
            for key in (
                "identity",
                "artifact_name",
                "hit",
                "artifact_id",
                "run_id",
                "download_dir",
            ):
                if key in result:
                    value = (
                        str(result[key]).lower()
                        if isinstance(result[key], bool)
                        else result[key]
                    )
                    stream.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
