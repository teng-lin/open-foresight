#!/usr/bin/env python3
"""Restore this run's successful application or fork SDK without recompiling it.

Acceptance retries retain the original successful job, attempt and byte receipts.
These PR artifacts are not promoted into the trusted main/release candidate pool.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from tools import ci_artifacts as artifacts
from tools.ci_stage_cache import read_zip
from tools import linux_sdk_artifacts as sdk
from tools.ci_producer_trust import PRODUCERS


def original_producer(
    repository,
    source,
    run_id,
    attempt,
    artifact,
    *,
    wait=60,
    consumer="inrun-application",
):
    """Refresh a uniquely identified pending producer without relaxing its proof."""
    deadline = time.monotonic() + wait

    def matches(job):
        return (
            PRODUCERS[consumer].matches_job(job)
            and job.get("run_id") == run_id
            and job.get("head_sha") == source
            and job.get("run_attempt") == attempt
        )

    def reject(reason):
        raise ValueError(
            "Application requires one successful original producer attempt: " + reason
        )

    while True:
        listed = artifacts.dependency_jobs(repository, run_id)
        jobs = [job for job in listed if matches(job)]
        if len(jobs) == 1:
            break
        if len(jobs) > 1 or any(PRODUCERS[consumer].matches_job(job) for job in listed):
            reject(
                f"found {len(jobs)} matching producer jobs; identity is ambiguous or mismatched"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            reject(f"found 0 matching producer jobs after {wait}s")
        print(
            "Wait for original producer to appear in the job list",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(min(5, remaining))
    job = jobs[0]
    job_id = job.get("id")
    if type(job_id) is not int or job_id < 1:
        reject("producer job ID is invalid")
    completion_refreshed = False
    while True:
        if not matches(job) or job.get("id") != job_id:
            reject(f"refreshed job {job_id} changed producer identity")
        if job.get("status") == "completed":
            if job.get("conclusion") != "success":
                reject(
                    f"producer job {job_id} completed with {job.get('conclusion')!r}"
                )
            if job.get("completed_at") in (None, ""):
                if completion_refreshed or time.monotonic() >= deadline:
                    reject(f"producer job {job_id} has no completion timestamp")
                completion_refreshed = True
                job = artifacts.api(repository, f"actions/jobs/{job_id}")
                continue
            if not artifacts.in_producer_attempt(artifact, job):
                reject(f"artifact was not created during producer job {job_id}")
            return job
        if (
            job.get("status") not in ("queued", "in_progress", "waiting")
            or job.get("conclusion") is not None
        ):
            reject(f"producer job {job_id} has invalid status {job.get('status')!r}")
        if time.monotonic() >= deadline:
            reject(f"producer job {job_id} is still {job['status']} after {wait}s")
        print(
            f"Refresh original producer job {job_id}: list/API status is {job['status']}",
            file=sys.stderr,
            flush=True,
        )
        job = artifacts.api(repository, f"actions/jobs/{job_id}")
        # A direct lookup commonly resolves lagging list metadata immediately.
        # If it remains pending, wait only within this bounded visibility window.
        if (
            matches(job)
            and job.get("id") == job_id
            and job.get("status") in ("queued", "in_progress", "waiting")
            and job.get("conclusion") is None
        ):
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(5, remaining))


def save_sdk(
    source, image, output, *, shadow=True, source_prefix=None, reuse_archive=False
):
    """Retain a fork's already-built SDK for this workflow, never compile it twice."""
    actual = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=artifacts.ROOT, text=True, timeout=30
    ).strip()
    if actual != source or not re.fullmatch(r"[a-f0-9]{40}", source):
        raise ValueError("SDK source must match the actual built checkout")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="foresight-integration-sdk-", dir=output.parent
    ) as directory:
        prefix = Path(directory)
        image_id = sdk.inspect(image)
        archive = prefix / "image.tar"
        if reuse_archive:
            if not shadow or source_prefix is None:
                raise ValueError("Archive reuse requires a verified shadow SDK prefix")
            metadata = sdk.record(source_prefix, "linux-sdk")
            if (
                metadata.get("transport") != "docker-archive"
                or metadata.get("image_id") != image_id
            ):
                raise ValueError(
                    "Retained archive differs from the inspected SDK image"
                )
            # The validated payload and output share a task filesystem. A hardlink
            # preserves its exact bytes without a second multi-GB docker save/copy.
            os.link(source_prefix / "image.tar", archive)
        else:
            sdk.run(["docker", "image", "save", "--output", str(archive), image_id])
        (prefix / "image.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "transport": "docker-archive",
                    "component": "linux-sdk",
                    "identity": artifacts.fingerprint("linux-sdk"),
                    "image_id": image_id,
                    "platform": "linux/amd64",
                    "archive_sha256": artifacts.digest(archive),
                    "source_scope": source,
                    "local_recipe_sha256": artifacts.digest(
                        artifacts.ROOT
                        / (
                            "tools/linux_sdk_artifacts.py"
                            if shadow
                            else "tools/build_linux_sdk_local.sh"
                        )
                    ),
                }
            )
            + "\n"
        )
        if source_prefix is not None:
            for name in ("source-qualification.json", "approved-source.json"):
                previous = source_prefix / name
                if previous.is_symlink():
                    raise ValueError("SDK source qualification must be regular")
                if previous.is_file():
                    (prefix / name).write_bytes(previous.read_bytes())
        if shadow:
            artifacts.pack(
                "linux-sdk",
                artifacts.fingerprint("linux-sdk"),
                prefix,
                output,
                tier="pr",
            )
        else:
            artifacts.pack(
                "linux-sdk", artifacts.fingerprint("linux-sdk"), prefix, output
            )


def retrieve(
    repository,
    head_repository,
    source,
    run_id,
    artifact_id,
    attempt,
    checksum,
    destination,
    *,
    component="linux-app",
    producer_wait=60,
    shadow=False,
    main_candidate=False,
    label="",
    purpose="acceptance",
):
    if (
        purpose not in ("acceptance", "package-contract", "weekly-audit")
        or component not in ("linux-app", "linux-sdk")
        or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
        or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", head_repository)
        or not re.fullmatch(r"[a-f0-9]{40}", source)
        or not re.fullmatch(r"[a-f0-9]{64}", checksum)
        or any(
            type(value) is not int or value < 1
            for value in (run_id, artifact_id, attempt)
        )
    ):
        raise ValueError("Invalid application producer identity")
    identity = source if component == "linux-app" else artifacts.fingerprint(component)
    if purpose == "weekly-audit" and component != "linux-app":
        raise ValueError("Weekly audit consumes only the preview application")
    if main_candidate and (
        component != "linux-app" or label or purpose != "acceptance"
    ):
        raise ValueError("Legacy main candidates require an unlabelled application")
    if shadow and component != "linux-sdk":
        raise ValueError("Fork handoff restores only its source-scoped SDK")
    consumer = (
        "weekly-preview-audit"
        if purpose == "weekly-audit" and component == "linux-app"
        else "main-acceptance"
        if main_candidate
        else "inrun-package-contract"
        if component == "linux-app" and purpose == "package-contract"
        else "inrun-application"
        if component == "linux-app"
        else "shadow-fork-sdk"
    )
    run = artifacts.api(repository, f"actions/runs/{run_id}")
    release = run.get("path") == ".github/workflows/release.yml"
    if release and (
        component != "linux-app" or main_candidate or purpose == "weekly-audit"
    ):
        raise ValueError("Release consumers require their exact in-run application")
    if release:
        consumer = "release-inrun-application"
    name = (
        artifacts.name(component, identity)
        if release
        else f"main-linux-bundle-{source}"
        if main_candidate
        else f"linux-bundle-{run_id}-{attempt}"
        if component == "linux-app"
        else f"shadow-sdk-{source}-{attempt}"
    )
    run_head = run.get("head_sha", "")
    if (
        run.get("id") != run_id
        or not PRODUCERS[consumer].matches_run(run)
        or not re.fullmatch(r"[a-f0-9]{40}", run_head)
        or (run.get("repository") or {}).get("full_name") != repository
        or (run.get("head_repository") or {}).get("full_name") != head_repository
        or (
            (run.get("event") == "pull_request" or purpose == "weekly-audit")
            and run_head != source
        )
        or (main_candidate and run.get("head_branch") != "main")
    ):
        raise ValueError("Application producer repository, workflow or source mismatch")
    if (
        run.get("event") == "workflow_dispatch"
        and run.get("path") == ".github/workflows/macos.yml"
        and isinstance(run.get("head_branch"), str)
        and run["head_branch"]
        and run["head_branch"] != "main"
    ):
        if head_repository != repository or run_head != source:
            raise ValueError("Application source is not this run's exact source")
    elif run.get("event") != "pull_request" and (
        head_repository != repository
        or run.get("head_branch") != "main"
        or (
            source != run_head
            and artifacts.api(repository, f"compare/{source}...{run_head}").get(
                "status"
            )
            not in ("ahead", "identical")
        )
    ):
        raise ValueError("Application source is not reviewed main ancestry")
    artifact = artifacts.api(repository, f"actions/artifacts/{artifact_id}")
    if (
        artifact.get("id") != artifact_id
        or artifact.get("expired") is not False
        or artifact.get("name") != name
        or artifact.get("digest") != "sha256:" + checksum
        or (artifact.get("workflow_run") or {}).get("id") != run_id
        or (artifact.get("workflow_run") or {}).get("head_sha") != run_head
    ):
        raise ValueError("Application artifact differs from its producer output")
    job = original_producer(
        repository,
        run_head,
        run_id,
        attempt,
        artifact,
        wait=producer_wait,
        consumer=consumer,
    )
    with tempfile.TemporaryDirectory(
        prefix="foresight-integration-application-"
    ) as temporary:
        root = Path(temporary)
        archive = root / "application.zip"
        artifacts.download_zip(repository, artifact, archive)
        receipt = read_zip(archive, root / "receipt")
        if purpose == "weekly-audit":
            label = receipt.get("label")
            if not isinstance(label, str) or not re.fullmatch(
                r"nightly\.\d{8}\.[1-9]\d*", label
            ):
                raise ValueError(
                    "Weekly audit requires the actual stamped preview label"
                )
        expected_tier = (
            "release"
            if release
            else "pr"
            if run["event"] == "pull_request"
            else "preview"
            if run["path"] == ".github/workflows/preview-packages.yml"
            else "sweep"
        )
        if (
            not artifacts.valid_receipt(receipt, component, identity)
            or not PRODUCERS[consumer].matches_receipt(receipt)
            or receipt["source_commit"] != source
            or receipt["source_run_attempt"] != attempt
            or receipt.get("tier") != expected_tier
            or receipt.get("label") != label
            or (expected_tier != "preview" and label)
        ):
            raise ValueError(
                "Application receipt source, tier, label or original attempt mismatch"
            )
        artifacts.unpack(component, identity, root / "receipt", destination)
    if component == "linux-app":
        distribution = artifacts.application_distribution(
            destination, component, source
        )
        if distribution != receipt.get("distribution"):
            raise ValueError(
                "Application distribution differs from the original receipt"
            )
        if expected_tier == "preview":
            stamp = destination / "distribution-stamp.json"
            if (
                stamp.is_symlink()
                or not stamp.is_file()
                or json.loads(stamp.read_text())
                != {**distribution, "label": label, "source_commit": source}
            ):
                raise ValueError(
                    "Preview stamp does not bind the actual package identity"
                )
    else:
        descriptor = sdk.record(destination, component)
        if descriptor.get("source_scope") != source or descriptor.get(
            "local_recipe_sha256"
        ) != artifacts.digest(artifacts.ROOT / "tools/linux_sdk_artifacts.py"):
            raise ValueError("Fork SDK transport differs from its source-scoped recipe")
    qualification = {
        "schema": 1,
        "source_receipt": receipt,
        "producer_repository": repository,
        "source_repository": head_repository,
        "producer_workflow": run["path"],
        "producer_run": run_id,
        "producer_job": job["id"],
        "producer_attempt": attempt,
        "artifact_id": artifact_id,
        "artifact_digest": artifact["digest"],
    }
    (destination / "source-qualification.json").write_text(
        json.dumps(qualification, indent=2) + "\n"
    )
    return qualification


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--head-repository")
    parser.add_argument("--artifact-id", type=int)
    parser.add_argument("--artifact-digest")
    parser.add_argument("--attempt", type=int)
    parser.add_argument(
        "--component", choices=("linux-app", "linux-sdk"), default="linux-app"
    )
    parser.add_argument("--save-sdk", action="store_true")
    parser.add_argument("--shadow", action="store_true")
    parser.add_argument("--main-candidate", action="store_true")
    parser.add_argument("--label", default="")
    parser.add_argument(
        "--purpose", choices=("acceptance", "package-contract"), default="acceptance"
    )
    parser.add_argument("--image", default="foresight-sdk:pr")
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.save_sdk:
        if args.shadow:
            save_sdk(args.source, args.image, args.directory, shadow=True)
        else:
            save_sdk(args.source, args.image, args.directory)
        return
    if any(
        value is None
        for value in (
            args.head_repository,
            args.artifact_id,
            args.artifact_digest,
            args.attempt,
        )
    ):
        parser.error(
            "restore requires --head-repository, --artifact-id, --artifact-digest and --attempt"
        )
    print(
        json.dumps(
            retrieve(
                os.environ["GITHUB_REPOSITORY"],
                args.head_repository,
                args.source,
                int(os.environ["GITHUB_RUN_ID"]),
                args.artifact_id,
                args.attempt,
                args.artifact_digest,
                args.directory,
                component=args.component,
                **({"shadow": True} if args.shadow else {}),
                **({"main_candidate": True} if args.main_candidate else {}),
                **({"label": args.label} if args.label else {}),
                **({"purpose": args.purpose} if args.purpose != "acceptance" else {}),
            ),
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
