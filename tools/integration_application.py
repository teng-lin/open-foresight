#!/usr/bin/env python3
"""Restore this run's successful PR application without recompiling it.

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


def original_producer(repository, source, run_id, attempt, artifact, *, wait=60):
    """Refresh a uniquely identified pending producer without relaxing its proof."""
    deadline = time.monotonic() + wait

    def matches(job):
        return (
            job.get("name") == "ubuntu-application"
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
        if len(jobs) > 1 or any(
            job.get("name") == "ubuntu-application" for job in listed
        ):
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


def save_sdk(source, image, output):
    """Retain a fork's already-built SDK for this workflow, never compile it twice."""
    actual = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=artifacts.ROOT, text=True, timeout=30
    ).strip()
    if actual != source or not re.fullmatch(r"[a-f0-9]{40}", source):
        raise ValueError("SDK source must match the actual built checkout")
    with tempfile.TemporaryDirectory(prefix="foresight-integration-sdk-") as directory:
        prefix = Path(directory)
        image_id = sdk.inspect(image)
        archive = prefix / "image.tar"
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
                        artifacts.ROOT / "tools/build_linux_sdk_local.sh"
                    ),
                }
            )
            + "\n"
        )
        artifacts.pack("linux-sdk", artifacts.fingerprint("linux-sdk"), prefix, output)


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
):
    if (
        component not in ("linux-app", "linux-sdk")
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
    name = (
        artifacts.name(component, identity)
        if component == "linux-app"
        else f"integration-sdk-{source}-{attempt}"
    )
    run = artifacts.api(repository, f"actions/runs/{run_id}")
    if (
        run.get("id") != run_id
        or run.get("path") != ".github/workflows/integration-acceptance.yml"
        or run.get("event") != "pull_request"
        or run.get("head_sha") != source
        or (run.get("repository") or {}).get("full_name") != repository
        or (run.get("head_repository") or {}).get("full_name") != head_repository
    ):
        raise ValueError("Application producer repository, workflow or source mismatch")
    artifact = artifacts.api(repository, f"actions/artifacts/{artifact_id}")
    if (
        artifact.get("id") != artifact_id
        or artifact.get("expired") is not False
        or artifact.get("name") != name
        or artifact.get("digest") != "sha256:" + checksum
        or (artifact.get("workflow_run") or {}).get("id") != run_id
        or (artifact.get("workflow_run") or {}).get("head_sha") != source
    ):
        raise ValueError("Application artifact differs from its producer output")
    job = original_producer(
        repository, source, run_id, attempt, artifact, wait=producer_wait
    )
    with tempfile.TemporaryDirectory(
        prefix="foresight-integration-application-"
    ) as temporary:
        root = Path(temporary)
        archive = root / "application.zip"
        artifacts.download_zip(repository, artifact, archive)
        receipt = read_zip(archive, root / "receipt")
        if (
            not artifacts.valid_receipt(receipt, component, identity)
            or receipt["source_commit"] != source
            or receipt["source_run_attempt"] != attempt
        ):
            raise ValueError("Application receipt source or original attempt mismatch")
        artifacts.unpack(component, identity, root / "receipt", destination)
    if component == "linux-app":
        distribution = artifacts.application_distribution(
            destination, component, source
        )
        if distribution != receipt.get("distribution"):
            raise ValueError(
                "Application distribution differs from the original receipt"
            )
    else:
        descriptor = sdk.record(destination, component)
        if descriptor.get("source_scope") != source or descriptor.get(
            "local_recipe_sha256"
        ) != artifacts.digest(artifacts.ROOT / "tools/build_linux_sdk_local.sh"):
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
    parser.add_argument("--image", default="foresight-sdk:pr")
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.save_sdk:
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
            ),
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
