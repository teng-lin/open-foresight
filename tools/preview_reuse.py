#!/usr/bin/env python3
"""Restore retained preview installers without changing their build identity."""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import zipfile

from tools import ci_artifacts


WORKFLOW = ".github/workflows/preview-packages.yml"


def has_applications(repository, run, request=ci_artifacts.api):
    """Inspect retained successful application jobs before selecting recovery."""
    if (
        run.get("status") != "completed"
        or run.get("path") != WORKFLOW
        or run.get("head_branch") != "main"
        or run.get("event") not in ("workflow_dispatch", "schedule")
        or run.get("head_repository", {}).get("full_name") != repository
    ):
        return False
    items = request(repository, f"actions/runs/{run['id']}/artifacts?per_page=100")[
        "artifacts"
    ]
    bindings = []
    for artifact_name, job_name in (
        ("preview-linux-portable", "build / linux-bundle"),
        ("preview-macos-application", "build / macos"),
    ):
        matches = [
            item
            for item in items
            if item.get("name") == artifact_name
            and not item.get("expired")
            and re.fullmatch(r"sha256:[a-f0-9]{64}", item.get("digest", ""))
        ]
        if len(matches) != 1:
            return False
        bindings.append((matches[0], job_name))
    jobs = ci_artifacts.dependency_jobs(repository, run["id"])
    return all(
        any(
            job.get("name") == name
            and job.get("conclusion") == "success"
            and ci_artifacts.in_producer_attempt(artifact, job)
            for job in jobs
        )
        for artifact, name in bindings
    )


def retained(repository, run, request=ci_artifacts.api):
    if (
        run.get("path") != WORKFLOW
        or run.get("head_branch") != "main"
        or run.get("event") not in ("workflow_dispatch", "schedule")
        or run.get("head_repository", {}).get("full_name") != repository
        or run.get("conclusion") != "success"
    ):
        return False
    items = request(repository, f"actions/runs/{run['id']}/artifacts?per_page=100")[
        "artifacts"
    ]
    available = {
        item["name"]
        for item in items
        if not item["expired"]
        and re.fullmatch(r"sha256:[a-f0-9]{64}", item.get("digest", ""))
    }
    individual = {
        "tested-preview-linux-deb",
        "tested-preview-linux-rpm",
        "tested-preview-linux-arch",
        "tested-preview-macos",
    }
    current = {
        name.replace("tested-preview-", "preview-installer-") for name in individual
    }
    return (
        individual <= available
        or current <= available
        or any(
            name.startswith("Open-Foresight-") and name.endswith(run["head_sha"])
            for name in available
        )
    )


def restore(repository, run_id, source, kind, destination):
    from tools.preview_packages import receipt, EXTENSIONS

    run = ci_artifacts.api(repository, f"actions/runs/{run_id}")
    if (
        run.get("head_sha") != source
        or run.get("path") != WORKFLOW
        or run.get("head_branch") != "main"
        or run.get("event") not in ("workflow_dispatch", "schedule")
        or run.get("head_repository", {}).get("full_name") != repository
    ):
        raise ValueError(
            "Preview producer/source or retained installers are not qualified"
        )
    items = ci_artifacts.api(
        repository, f"actions/runs/{run_id}/artifacts?per_page=100"
    )["artifacts"]
    desired = (
        "tested-preview-macos" if kind == "dmg" else "tested-preview-linux-" + kind
    )
    desired_names = (desired.replace("tested-preview-", "preview-installer-"), desired)
    eligible = [
        item
        for item in items
        if not item["expired"]
        and (
            item["name"] in desired_names
            or (
                item["name"].startswith("Open-Foresight-")
                and item["name"].endswith(source)
            )
        )
    ]
    eligible.sort(key=lambda item: item["name"] not in desired_names)
    if not eligible:
        return None
    artifact = eligible[0]
    jobs = ci_artifacts.dependency_jobs(repository, run_id)

    def producer(job):
        name = job.get("name", "")
        expected = (
            name == "publish"
            if artifact["name"] not in desired_names
            else name == "macos"
            if kind == "dmg"
            else name.startswith(f"linux ({kind},")
        )
        return (
            expected
            and job.get("conclusion") == "success"
            and ci_artifacts.in_producer_attempt(artifact, job)
        )

    if not any(producer(job) for job in jobs):
        print(
            "Retain the unvalidated format artifact for diagnosis; its producer job did not pass",
            flush=True,
        )
        return None
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / "preview.zip"
        ci_artifacts.download_zip(repository, artifact, archive)
        with zipfile.ZipFile(archive) as bundle:
            names = [
                name for name in bundle.namelist() if name.endswith(EXTENSIONS[kind])
            ]
            if len(names) != 1:
                raise ValueError(
                    "Preview archive contains missing or duplicate installers"
                )
            name = names[0]
            for member in (name, name + ".sha256", name + ".build.json"):
                target = destination / Path(member).name
                if target.exists() or not re.fullmatch(
                    r"[A-Za-z0-9._+~-]+", target.name
                ):
                    raise ValueError("Unsafe or existing preview installer path")
                target.write_bytes(bundle.read(member))
    result = receipt(destination, kind, source)
    result.update(
        producer_run=run_id,
        producer_attempt=next(
            job.get("run_attempt", 1) for job in jobs if producer(job)
        ),
        artifact_id=artifact["id"],
        artifact_digest=artifact["digest"],
    )
    (destination / "original-producer.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    return result


def restore_application(repository, run_id, source, platform, destination):
    run = ci_artifacts.api(repository, f"actions/runs/{run_id}")
    if (
        run.get("head_sha") != source
        or run.get("path") != WORKFLOW
        or run.get("head_branch") != "main"
        or run.get("event") not in ("workflow_dispatch", "schedule")
        or run.get("head_repository", {}).get("full_name") != repository
    ):
        raise ValueError("Untrusted preview application producer/source")
    name = {"linux": "preview-linux-portable", "macos": "preview-macos-application"}[
        platform
    ]
    items = ci_artifacts.api(
        repository, f"actions/runs/{run_id}/artifacts?per_page=100"
    )["artifacts"]
    matches = [item for item in items if item["name"] == name and not item["expired"]]
    if len(matches) != 1:
        raise ValueError(
            f"Retained {platform} application candidate is unavailable; preserve other platforms and inspect compatible producers before rebuilding"
        )
    artifact = matches[0]
    expected = "build / " + ("linux-bundle" if platform == "linux" else "macos")
    if not any(
        job.get("name") == expected
        and job.get("conclusion") == "success"
        and ci_artifacts.in_producer_attempt(artifact, job)
        for job in ci_artifacts.dependency_jobs(repository, run_id)
    ):
        raise ValueError("Preview application has no successful producer job/attempt")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / "application.zip"
        ci_artifacts.download_zip(repository, artifact, archive)
        with zipfile.ZipFile(archive) as bundle:
            for name in bundle.namelist():
                if (
                    not (destination / name)
                    .resolve()
                    .is_relative_to(destination.resolve())
                ):
                    raise ValueError("Unsafe preview application archive path")
            bundle.extractall(destination)  # noqa: S202 - Every path and the trusted producer's ZIP digest are verified above.
    pattern = "*.build.json" if platform == "linux" else "*.manifest.json"
    records = list(destination.glob(pattern))
    if len(records) != 1:
        raise ValueError("Ambiguous preview application identity")
    metadata = json.loads(records[0].read_text())
    if metadata.get("revision") != source:
        raise ValueError("Preview application describes another product source")
    return metadata


def recovery_identity(repository, run_id, source):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        linux = restore_application(repository, run_id, source, "linux", root / "linux")
        macos = restore_application(repository, run_id, source, "macos", root / "macos")
    match = re.fullmatch(
        r"(\d+\.\d+\.\d+)~(nightly\.\d{8}\.([1-9]\d*))", linux.get("version", "")
    )
    if (
        not match
        or macos.get("version") != match[1]
        or linux.get("build_number") != macos.get("build_number")
        or linux.get("build_number") != int(match[3])
    ):
        raise ValueError(
            "Surviving preview application identities disagree; do not relabel them"
        )
    return {
        "source": source,
        "version": match[1],
        "label": match[2],
        "package_version": linux["version"],
        "build_number": match[3],
        "build": "false",
        "recovery_run": str(run_id),
        "reuse_run": "0",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, type=int)
    parser.add_argument("--source", required=True)
    parser.add_argument(
        "--format", default="deb", choices=("deb", "rpm", "arch", "dmg")
    )
    parser.add_argument("--application", choices=("linux", "macos"))
    parser.add_argument("--optional", action="store_true")
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.application:
        restore_application(
            os.environ["GITHUB_REPOSITORY"],
            args.run,
            args.source,
            args.application,
            args.directory,
        )
        return
    result = restore(
        os.environ["GITHUB_REPOSITORY"],
        args.run,
        args.source,
        args.format,
        args.directory,
    )

    if result is None:
        if args.optional:
            raise SystemExit(4)
        raise ValueError(
            "Requested validated preview installer is unavailable; preserve other formats"
        )


if __name__ == "__main__":
    main()
