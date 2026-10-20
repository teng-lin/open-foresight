#!/usr/bin/env python3
"""Resolve main-produced immutable tooling, or build only tooling on a real miss.

The key deliberately excludes application sources and dependency seed objects.
GitHub receipts bind the image digest to its original successful uploading job;
Docker verifies OCI content hashes while pulling the immutable reference.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.ci_app_build_transport import reference  # noqa: E402
from tools.ci_producer_trust import PRODUCERS  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RECIPE = "packaging/ci-tooling.Dockerfile"
CONSUMER = "linux-ci-tooling"
MAX_RECEIPT = 64 * 1024


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def identity(sdk_id, snapshot, root=ROOT):
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", sdk_id) or not re.fullmatch(
        r"\d{8}T\d{6}Z", snapshot
    ):
        raise ValueError("Tooling requires an exact SDK image and pinned snapshot")
    recipe = root / RECIPE
    if recipe.is_symlink() or not recipe.is_file():
        raise ValueError("Tooling recipe must be a regular source file")
    inputs = {
        "schema": 1,
        "platform": "linux/amd64",
        "sdk_image_id": sdk_id,
        "snapshot": snapshot,
        "recipe": {
            "sha256": artifacts.digest(recipe),
            "mode": recipe.stat().st_mode & 0o777,
        },
    }
    return {**inputs, "identity": hashlib.sha256(canonical(inputs)).hexdigest()}


def image_reference(repository, digest):
    # Reuse the existing explicit repository syntax check.
    reference(repository)
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        raise ValueError("Tooling image requires an immutable OCI digest")
    return f"ghcr.io/{repository.lower()}/linux-sdk@{digest}"


def verify_receipt(repository, expected, receipt, artifact, run, jobs, *, fetch=None):
    producer = PRODUCERS[CONSUMER]
    fetch = fetch or artifacts.api
    if (
        not isinstance(receipt, dict)
        or receipt.get("schema") != 1
        or type(receipt.get("schema")) is not int
        or receipt.get("component") != CONSUMER
        or receipt.get("inputs") != expected
        or receipt.get("repository") != repository
        or receipt.get("tier") != "tooling"
        or receipt.get("label") != ""
        or not producer.matches_receipt(receipt)
        or not producer.matches_run(run)
        or run.get("head_branch") != "main"
        or (run.get("repository") or {}).get("full_name") != repository
        or (run.get("head_repository") or {}).get("full_name") != repository
        or not re.fullmatch(r"[a-f0-9]{40}", str(run.get("head_sha", "")))
        or receipt.get("source_commit") != run.get("head_sha")
        or type(receipt.get("source_run_id")) is not int
        or receipt["source_run_id"] != run.get("id")
        or artifact.get("name") != "ci-tooling-" + expected["identity"]
        or artifact.get("expired") is not False
        or artifact.get("workflow_run", {}).get("id") != run.get("id")
        or type(receipt.get("source_run_attempt")) is not int
        or receipt["source_run_attempt"] < 1
        or type(receipt.get("source_job_id")) is not int
        or receipt["source_job_id"] < 1
    ):
        raise ValueError("Tooling receipt producer/source/input contract mismatch")
    matching = [
        job
        for job in jobs
        if job.get("id") == receipt["source_job_id"]
        and job.get("run_id") == run["id"]
        and producer.matches_job(job)
        and job.get("run_attempt") == receipt["source_run_attempt"]
        and job.get("conclusion") == "success"
        and artifacts.in_producer_attempt(artifact, job)
    ]
    if len(matching) != 1:
        raise ValueError("Tooling upload lacks its original successful job attempt")
    if fetch(repository, f"compare/{run['head_sha']}...main").get("status") not in (
        "ahead",
        "identical",
    ):
        raise ValueError("Tooling producer source is not reviewed main ancestry")
    return image_reference(repository, receipt.get("image_digest", ""))


def lookup(repository, expected, directory, *, fetch=None, download=None, jobs=None):
    fetch = fetch or artifacts.api
    download = download or artifacts.download_zip
    jobs = jobs or artifacts.dependency_jobs
    name = "ci-tooling-" + expected["identity"]
    candidates: list[dict] = []
    page = 1
    while True:
        result = fetch(
            repository, f"actions/artifacts?name={name}&per_page=100&page={page}"
        )
        rows = result["artifacts"]
        candidates.extend(row for row in rows if row.get("expired") is False)
        if len(rows) < 100:
            break
        page += 1
    if not candidates:
        return None
    # Pending/failed maintenance is not application validation failure. Consume
    # only a successful original upload; otherwise prepare local tooling. Never
    # treat a metadata/API failure or corrupt qualified receipt as a cache miss.
    selected = None
    for candidate in sorted(candidates, key=lambda item: item["id"], reverse=True):
        run = fetch(repository, f"actions/runs/{candidate['workflow_run']['id']}")
        producer = PRODUCERS[CONSUMER]
        if (
            not producer.matches_run(run)
            or run.get("head_branch") != "main"
            or (run.get("repository") or {}).get("full_name") != repository
            or (run.get("head_repository") or {}).get("full_name") != repository
        ):
            continue
        original_jobs = jobs(repository, run["id"])
        if any(
            producer.matches_job(job)
            and job.get("conclusion") == "success"
            and artifacts.in_producer_attempt(candidate, job)
            for job in original_jobs
        ):
            selected = candidate, run, original_jobs
            break
    if selected is None:
        print(
            "Tooling maintenance has no successful qualifying upload; prepare local tools without consuming its bytes",
            flush=True,
        )
        return None
    artifact, run, original_jobs = selected
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tooling-receipt-", dir=directory) as temp:
        archive = Path(temp) / "receipt.zip"
        download(repository, artifact, archive)
        with zipfile.ZipFile(archive) as stream:
            members = stream.infolist()
            if (
                len(members) != 1
                or members[0].filename != "tooling.json"
                or members[0].file_size > MAX_RECEIPT
            ):
                raise ValueError("Unexpected tooling receipt ZIP membership or size")
            receipt = json.loads(stream.read("tooling.json"))
    image = verify_receipt(
        repository,
        expected,
        receipt,
        artifact,
        run,
        original_jobs,
        fetch=fetch,
    )
    (directory / "producer.json").write_text(
        json.dumps({"artifact": artifact, "receipt": receipt}, indent=2) + "\n"
    )
    return image


def require_publisher(repository, *, fetch=None, environment=None, head=None):
    env = os.environ if environment is None else environment
    fetch = fetch or artifacts.api
    producer = PRODUCERS[CONSUMER]
    source = env.get("GITHUB_SHA", "")
    if (
        env.get("GITHUB_REF") != "refs/heads/main"
        or env.get("GITHUB_REPOSITORY") != repository
        or env.get("GITHUB_EVENT_NAME") not in producer.events
        or env.get("GITHUB_JOB") != "publish-linux-caches"
        or env.get("GITHUB_WORKFLOW_REF")
        != repository + "/" + producer.workflows[0] + "@refs/heads/main"
        or not re.fullmatch(r"[a-f0-9]{40}", source)
    ):
        raise ValueError("Tooling publication requires the dedicated reviewed-main job")
    if head is None:
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, timeout=30
        ).strip()
    if head != source or fetch(repository, "commits/main").get("sha") != source:
        raise ValueError("Main advanced; reconcile tooling for the current source")
    return source


def verify_abi(sdk_image, tooling_image, *, profile=None):
    from tools.ci_app_dependency_seed import sdk_profile

    profile = profile or sdk_profile

    # Inspect exact compiler/header/runtime bytes without starting either image.
    # Image IDs and their transport names are provenance, not ABI equivalence.
    def compatible(image):
        return {
            key: value
            for key, value in profile(image).items()
            if key not in ("image_id", "requested_image")
        }

    original = compatible(sdk_image)
    if compatible(tooling_image) != original:
        raise ValueError(
            "Tool installation changed the qualified SDK compiler ABI; preserve outputs and requalify"
        )
    return hashlib.sha256(canonical(original)).hexdigest()


def prepare(repository, sdk_image, snapshot, output, *, publish=False):
    sdk_id = subprocess.check_output(
        ["docker", "image", "inspect", "--format", "{{.Id}}", sdk_image],
        text=True,
        timeout=60,
    ).strip()
    expected = identity(sdk_id, snapshot)
    output.mkdir(parents=True, exist_ok=True)
    shared = None
    if publish:
        require_publisher(repository)
    if os.environ.get("GH_TOKEN"):
        shared = lookup(repository, expected, output)
    if shared:
        subprocess.run(["docker", "pull", shared], check=True, timeout=600)
        image = shared
    else:
        print(
            "Confirmed tooling miss/local scope: build OS tools only; reuse SDK and seed.",
            flush=True,
        )
        image = "foresight-tooling:" + expected["identity"]
        args = [
            "docker",
            "buildx",
            "build",
            "--platform",
            "linux/amd64",
            "--builder",
            subprocess.check_output(
                ["docker", "context", "show"], text=True, timeout=60
            ).strip(),
            "--file",
            RECIPE,
            "--target",
            "ci-tooling",
            "--build-arg",
            "SDK_IMAGE=" + sdk_image,
            "--build-arg",
            "SDK_IMAGE_ID=" + sdk_id,
            "--build-arg",
            "CI_TOOLING_ID=" + expected["identity"],
            "--build-arg",
            "UBUNTU_SNAPSHOT=" + snapshot,
            "--cache-from",
            "type=registry,ref=" + reference(repository, ci=True),
        ]
        if publish:
            require_publisher(repository)
            image = f"ghcr.io/{repository.lower()}/linux-sdk:ci-tooling-v1-{expected['identity']}"
            args += ["--push", "--metadata-file", str(output / "build.json")]
        else:
            args += ["--load"]
        subprocess.run([*args, "--tag", image, "."], check=True, timeout=1800)
        if publish:
            metadata = json.loads((output / "build.json").read_text())
            digest = metadata["containerimage.digest"]
            image = image_reference(repository, digest)
            source = require_publisher(repository)
            run_id, attempt = (
                int(os.environ["GITHUB_RUN_ID"]),
                int(os.environ["GITHUB_RUN_ATTEMPT"]),
            )
            current = [
                job
                for job in artifacts.dependency_jobs(repository, run_id)
                if job.get("name") == "publish-linux-caches"
                and job.get("run_attempt") == attempt
                and job.get("status") == "in_progress"
            ]
            if len(current) != 1:
                raise ValueError(
                    "Cannot bind tooling upload to this original publisher job"
                )
            receipt = {
                "schema": 1,
                "component": CONSUMER,
                "inputs": expected,
                "repository": repository,
                "tier": "tooling",
                "label": "",
                "source_commit": source,
                "source_run_id": run_id,
                "source_run_attempt": attempt,
                "source_job_id": current[0]["id"],
                "image_digest": digest,
            }
            (output / "tooling.json").write_text(json.dumps(receipt, indent=2) + "\n")
            subprocess.run(["docker", "pull", image], check=True, timeout=600)
    inspected = json.loads(
        subprocess.check_output(
            ["docker", "image", "inspect", image], text=True, timeout=60
        )
    )[0]
    labels = inspected.get("Config", {}).get("Labels") or {}
    if (
        inspected.get("Architecture") != "amd64"
        or inspected.get("Os") != "linux"
        or labels.get("org.openforesight.ci-tooling") != expected["identity"]
        or labels.get("org.openforesight.sdk-image-id") != sdk_id
        or labels.get("org.openforesight.ubuntu-snapshot") != snapshot
    ):
        raise ValueError(
            "Consumed tooling image labels/platform differ from qualified inputs"
        )
    result = {
        "inputs": expected,
        "image": image,
        "image_id": inspected["Id"],
        "reused": bool(shared),
        "abi_sha256": verify_abi(sdk_image, image),
    }
    (output / "inputs.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--sdk-image", required=True)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    result = prepare(
        args.repository,
        args.sdk_image,
        args.snapshot,
        args.output,
        publish=args.publish,
    )
    if destination := os.environ.get("GITHUB_OUTPUT"):
        with open(destination, "a") as stream:
            stream.write(
                f"tooling_image={result['image']}\ntooling_identity={result['inputs']['identity']}\ntooling_reused={str(result['reused']).lower()}\n"
            )
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
