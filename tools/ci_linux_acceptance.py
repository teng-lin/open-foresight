#!/usr/bin/env python3
"""Prepare one already-qualified portable bundle for independent Linux consumers."""

import argparse
import json
import os
import re
from pathlib import Path, PurePosixPath
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import application_distribution, valid_receipt, digest  # noqa: E402
from tools.release_asset_acceptance import verify_checksum  # noqa: E402
from tools.ci_linux_handoff import portable_input  # noqa: E402


def prepare(packages, destination, source, label=""):
    distribution = application_distribution(packages, "linux-app", source)
    if label and not re.fullmatch(r"nightly\.\d{8}\.[1-9]\d*", label):
        raise ValueError("Invalid preview package label")
    matches = list(packages.glob("*.tar.gz"))
    if len(matches) != 1 or matches[0].is_symlink():
        raise ValueError("Expected one regular portable package")
    package = matches[0]
    verify_checksum(package, package.with_name(package.name + ".sha256"))
    if destination.exists() or destination.is_symlink():
        raise ValueError("Choose an absent portable output; preserve existing outputs")
    with tarfile.open(package) as archive:
        members = archive.getmembers()
        names = [member.name.rstrip("/") for member in members]
        if (
            not members
            or len(names) != len(set(names))
            or any(
                not PurePosixPath(name).parts
                or PurePosixPath(name).is_absolute()
                or ".." in PurePosixPath(name).parts
                or PurePosixPath(name).parts[0] != "open-foresight"
                for name in names
            )
        ):
            raise ValueError("Unsafe or ambiguous portable package inventory")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix="verified-portable-", dir=destination.parent
        ) as temporary:
            archive.extractall(temporary, filter="data")
            Path(temporary).rename(destination)
    result = {
        "version": distribution["version"] + ("~" + label if label else ""),
        "source": source,
        "release": "1",
    }
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for name, value in result.items():
                stream.write(f"{name}={value}\n")
    return result


def check_gates(needs, selected):
    if (
        type(selected) is not bool
        or needs.get("changes", {}).get("result") != "success"
    ):
        raise ValueError("Acceptance classification did not succeed")
    expected = "success" if selected else "skipped"
    for job in ("linux-build", "acceptance-cpu", "acceptance-audio", "acceptance-deb"):
        if needs.get(job, {}).get("result") != expected:
            raise ValueError(
                f"{job}: expected {expected}, got {needs.get(job, {}).get('result')}"
            )
    allowed = ("success", "skipped") if selected else ("skipped",)
    if needs.get("linux-bundle", {}).get("result") not in allowed:
        raise ValueError("The stamped main candidate failed or was cancelled")


GATES = ("linux-test", "acceptance-cpu", "acceptance-audio", "acceptance-deb")


def record_input(
    packages,
    source,
    output,
    gate,
    handoff=None,
    *,
    handoff_manifest_sha256="",
    handoff_producer_job=0,
):
    """Relay the actual qualified release input after that consumer succeeds."""
    qualification = packages / "source-qualification.json"
    if qualification.is_symlink() or not qualification.is_file():
        raise ValueError(
            "Consumption evidence requires a regular verified qualification"
        )
    verified = json.loads(qualification.read_text())
    receipt = verified.get("source_receipt", {})
    run = int(os.environ["GITHUB_RUN_ID"])
    attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
    if (
        gate not in GATES
        or run < 1
        or attempt < 1
        or not valid_receipt(receipt, "linux-app", source)
        or receipt["source_commit"] != source
        or receipt.get("tier") != "release"
        or receipt.get("label") != ""
        or verified.get("producer_repository") != os.environ["GITHUB_REPOSITORY"]
        or verified.get("source_repository") != os.environ["GITHUB_REPOSITORY"]
        or type(verified.get("producer_run")) is not int
        or verified.get("producer_run") != run
        or type(verified.get("producer_attempt")) is not int
        or verified.get("producer_attempt") != receipt["source_run_attempt"]
        or type(verified.get("artifact_id")) is not int
        or verified["artifact_id"] < 1
        or not isinstance(verified.get("artifact_digest"), str)
        or not re.fullmatch(r"sha256:[a-f0-9]{64}", verified["artifact_digest"])
    ):
        raise ValueError(
            "Consumption evidence differs from the verified own-run release input"
        )
    packages_found = list(packages.glob("*.tar.gz"))
    if len(packages_found) != 1 or packages_found[0].is_symlink():
        raise ValueError("Consumption evidence requires one regular portable package")
    package = packages_found[0]
    verify_checksum(package, package.with_name(package.name + ".sha256"))
    if gate == "linux-test":
        if handoff is None:
            raise ValueError(
                "Linux test evidence requires its verified source/build handoff"
            )
        manifest_path = handoff / "source-build.json"
        archive_path = handoff / "source-build.tar.gz"
        if (
            not isinstance(handoff_manifest_sha256, str)
            or not re.fullmatch(r"[a-f0-9]{64}", handoff_manifest_sha256)
            or type(handoff_producer_job) is not int
            or handoff_producer_job < 1
            or type(verified.get("producer_job")) is not int
            or handoff_producer_job != verified.get("producer_job")
            or any(
                path.is_symlink() or not path.is_file()
                for path in (manifest_path, archive_path)
            )
            or digest(manifest_path) != handoff_manifest_sha256
        ):
            raise ValueError(
                "Linux test requires the exact API-qualified handoff manifest/job"
            )
        manifest = json.loads(manifest_path.read_text())
        producer = manifest.get("producer", {})
        if (
            manifest.get("source") != source
            or manifest.get("tier") != "release"
            or manifest.get("label") != ""
            or producer.get("GITHUB_REPOSITORY") != verified["producer_repository"]
            or producer.get("GITHUB_RUN_ID") != str(verified["producer_run"])
            or producer.get("GITHUB_RUN_ATTEMPT") != str(verified["producer_attempt"])
            or manifest.get("portable_package")
            != portable_input(packages, source, required=True)
            or manifest.get("archive_sha256") != digest(archive_path)
        ):
            raise ValueError(
                "Tested handoff package differs from the qualified release bundle"
            )
    result = {
        "schema": 1,
        "source": source,
        "component": "linux-app",
        "artifact_id": verified["artifact_id"],
        "artifact_digest": verified["artifact_digest"],
        "payload_sha256": receipt["sha256"],
        "source_run_attempt": receipt["source_run_attempt"],
        "consumer_run_id": run,
        "consumer_run_attempt": attempt,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check-gates", action="store_true")
    mode.add_argument("--record-input", action="store_true")
    parser.add_argument("--gate", choices=GATES)
    parser.add_argument("--handoff", type=Path)
    parser.add_argument("--handoff-manifest-sha256", default="")
    parser.add_argument("--handoff-producer-job", type=int, default=0)
    parser.add_argument(
        "--output", type=Path, default=Path("test-results/consumption/consumption.json")
    )
    parser.add_argument("--label", default="")
    parser.add_argument("--packages", type=Path, default=Path("artifacts"))
    parser.add_argument("--destination", type=Path, default=Path("build/portable/dist"))
    args = parser.parse_args()
    if args.check_gates:
        selected = os.environ["SELECTED"]
        if selected not in ("true", "false"):
            raise ValueError("Malformed acceptance selection")
        check_gates(json.loads(os.environ["NEEDS"]), selected == "true")
    else:
        if not args.source:
            parser.error("--source is required to prepare or record a bundle")
        if args.record_input:
            if not args.gate:
                parser.error("--gate is required for consumption evidence")
            record_input(
                args.packages,
                args.source,
                args.output,
                args.gate,
                args.handoff,
                handoff_manifest_sha256=args.handoff_manifest_sha256,
                handoff_producer_job=args.handoff_producer_job,
            )
        else:
            prepare(args.packages, args.destination, args.source, args.label)


if __name__ == "__main__":
    main()
