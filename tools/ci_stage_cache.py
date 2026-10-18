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
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

artifacts = importlib.import_module(
    "tools.ci_artifacts" if __package__ else "ci_artifacts"
)

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ("linux", "macos")
STAGES = ("native", "core", "desktop", "service")
WORKFLOW = ".github/workflows/macos.yml"
HEX = r"[a-f0-9]{64}"
COMMIT = r"[a-f0-9]{40}"
# These are known editorial inputs. Unknown/new paths always enter the common
# input set rather than silently missing a newly introduced build dependency.
EDITORIAL = {"README.md", "CHANGELOG.md", "LICENSE", "AGENTS.md"}


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, timeout=120)


def selected(path, stage):
    if path in EDITORIAL or path.startswith("docs/"):
        return False
    if path == "apps/desktop/pubspec.yaml":
        return True  # Native build and helper identity consume application version.
    if path == "packages/foresight_core/lib/src/model_pins.dart":
        return True  # Shared native/runtime fixtures consume these model pins.
    if path.startswith("apps/desktop/"):
        # Core's registry guard validates desktop command literals as well.
        return stage in ("desktop", "service") or (
            stage == "core" and path.startswith("apps/desktop/lib/")
        )
    if path.startswith("packages/foresight_core/"):
        return stage != "native"
    if path.startswith("tests/service/"):
        return stage in ("core", "service")
    return True


def source_inputs(root, stage, ref=None):
    """Mode and Git blob identities, including modified/new working files."""
    if ref is not None:
        if not re.fullmatch(COMMIT, ref):
            raise ValueError("Source ref must be a full commit SHA")
        rows = git(root, "ls-tree", "-r", "-z", ref).split(b"\0")
        result = {}
        for row in filter(None, rows):
            metadata, path = row.split(b"\t", 1)
            mode, kind, identity = metadata.decode().split()
            name = os.fsdecode(path)
            if selected(name, stage):
                result[name] = [mode, kind, identity]
        return result
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    result = {}
    object_format = git(root, "rev-parse", "--show-object-format").decode().strip()
    for raw in filter(None, paths.split(b"\0")):
        name = os.fsdecode(raw)
        if not selected(name, stage):
            continue
        path = root / name
        if not path.exists() and not path.is_symlink():
            continue  # Deletion is represented by removing the inventory entry.
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            data, mode = os.fsencode(os.readlink(path)), "120000"
        elif path.is_dir():
            # Gitlinks bind their checked-out commit, never recurse into them.
            identity = git(path, "rev-parse", "HEAD").decode().strip()
            result[name] = ["160000", "commit", identity]
            continue
        else:
            data = path.read_bytes()
            mode = "100755" if info.st_mode & 0o111 else "100644"
        blob = b"blob " + str(len(data)).encode() + b"\0" + data
        result[name] = [mode, "blob", hashlib.new(object_format, blob).hexdigest()]
    return result


def fingerprint(platform, stage, root=ROOT, ref=None, environment=None, parents=None):
    if platform not in PLATFORMS or stage not in STAGES:
        raise ValueError("Invalid platform or stage")
    if not isinstance(environment, dict) or not environment:
        raise ValueError("Explicit compiler/runtime/system/SDK environment is required")
    parents = {} if parents is None else parents
    if not isinstance(parents, dict) or any(
        not isinstance(key, str)
        or not isinstance(value, str)
        or not re.fullmatch(HEX, value)
        for key, value in parents.items()
    ):
        raise ValueError("Parent identities must be a mapping of SHA256 identities")
    if stage != "native" and "native" not in parents:
        raise ValueError("Dart stages require a native parent identity")
    record = {
        "schema": 1,
        "platform": platform,
        "stage": stage,
        "environment": environment,
        "parents": parents,
        "inputs": source_inputs(Path(root), stage, ref),
    }
    return hashlib.sha256(
        json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def name(platform, stage, identity):
    if (
        platform not in PLATFORMS
        or stage not in STAGES
        or not isinstance(identity, str)
        or not re.fullmatch(HEX, identity)
    ):
        raise ValueError("Invalid stage artifact identity")
    return f"ci-stage-{platform}-{stage}-{identity}"


def reusable(event, own_pr, branch="", release=False):
    return (
        event == "pull_request"
        and type(own_pr) is int
        and own_pr > 0
        and branch != "main"
        and not release
    )


def trusted_run(run, repository, own_pr):
    if (
        run.get("path") != WORKFLOW
        or (run.get("head_repository") or {}).get("full_name") != repository
    ):
        return False
    if run.get("event") == "push" and run.get("head_branch") == "main":
        return True
    return run.get("event") == "pull_request" and any(
        pr.get("number") == own_pr for pr in run.get("pull_requests", [])
    )


def ensure_commit(root, commit):
    if not re.fullmatch(COMMIT, commit):
        raise ValueError("Invalid producer source commit")
    try:
        git(root, "cat-file", "-e", commit + "^{commit}")
    except subprocess.CalledProcessError:
        subprocess.run(
            ["git", "fetch", "--no-tags", "origin", commit],
            cwd=root,
            check=True,
            timeout=300,
        )
        git(root, "cat-file", "-e", commit + "^{commit}")


def validate_receipt(
    receipt, platform, stage, identity, run, environment, parents, root
):
    if not isinstance(receipt, dict) or type(receipt.get("schema")) is not int:
        raise ValueError("Invalid receipt schema")
    if (
        receipt.get("schema"),
        receipt.get("platform"),
        receipt.get("stage"),
        receipt.get("identity"),
    ) != (1, platform, stage, identity):
        raise ValueError("Stage receipt identity mismatch")
    if receipt.get("payload_kind", stage) != stage:
        raise ValueError("Runtime-only outputs are not a native compilation cache")
    if receipt.get("environment") != environment or receipt.get("parents") != parents:
        raise ValueError("Stage environment or parent mismatch")
    if not isinstance(receipt.get("sha256"), str) or not re.fullmatch(
        HEX, receipt["sha256"]
    ):
        raise ValueError("Invalid payload checksum")
    if (
        type(receipt.get("source_run_attempt")) is not int
        or receipt["source_run_attempt"] < 1
    ):
        raise ValueError("Invalid producer attempt")
    if receipt.get("reusable", True) is not True:
        raise ValueError("Derived distribution outputs are not reusable stage proofs")
    commit = receipt.get("source_commit")
    if not isinstance(commit, str) or commit != run.get("head_sha"):
        raise ValueError("Receipt source differs from actual workflow producer")
    ensure_commit(root, commit)
    if fingerprint(platform, stage, root, commit, environment, parents) != identity:
        raise ValueError("Producer source fingerprint differs from current recipe")


def read_zip(path, destination=None):
    """Read exactly the expected two flat regular files, with bounded receipt."""
    with zipfile.ZipFile(path) as stream:
        if sorted(stream.namelist()) != ["identity.json", "payload.tar.gz"]:
            raise ValueError("Unexpected stage artifact members")
        receipt_info = stream.getinfo("identity.json")
        if receipt_info.file_size > 16 * 1024 * 1024:
            raise ValueError("Stage receipt too large")
        for entry in stream.infolist():
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG) or entry.is_dir():
                raise ValueError("Stage artifact members must be regular files")
        receipt = json.loads(stream.read(receipt_info))
        # Do not trust a receipt's checksum without reading the actual payload.
        with stream.open("payload.tar.gz") as payload:
            digest = hashlib.sha256()
            while block := payload.read(1024 * 1024):
                digest.update(block)
            checksum = digest.hexdigest()
        if not isinstance(receipt, dict) or receipt.get("sha256") != checksum:
            raise ValueError("Stage payload checksum mismatch")
        if destination:
            destination.mkdir(parents=True, exist_ok=False)
            for member in ("identity.json", "payload.tar.gz"):
                with (
                    stream.open(member) as source,
                    (destination / member).open("wb") as target,
                ):
                    shutil.copyfileobj(source, target)
        return receipt


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
    candidates = artifacts.api(
        repository, f"actions/artifacts?name={result['artifact_name']}&per_page=100"
    )["artifacts"]
    for artifact in candidates:
        if artifact.get("expired") or artifact.get("name") != result["artifact_name"]:
            continue
        run = artifacts.api(
            repository, f"actions/runs/{artifact['workflow_run']['id']}"
        )
        if not trusted_run(run, repository, own_pr):
            continue
        jobs = artifacts.dependency_jobs(repository, run["id"])
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
                artifacts.download_zip(repository, artifact, archive)
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
