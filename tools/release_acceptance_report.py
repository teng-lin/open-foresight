#!/usr/bin/env python3
"""Bind automated installer acceptance and release-day GPU evidence for publication."""

import argparse
import json
from pathlib import Path
import re


def aggregate(directory, tag, evidence):
    installers = []
    suffixes = set()
    validation_artifacts = []
    identities: dict[str, dict[str, str]] = {}
    sources = set()
    for receipt in sorted(directory.glob("*/assets/installer.json")):
        identity = json.loads(receipt.read_text())
        artifact = receipt.parents[1]
        functional = list(artifact.glob("reports/**/functional.json"))
        if identity.get("tag") != tag or identity.get("status") != "verified_download":
            raise ValueError(
                "Acceptance receipt does not identify the requested verified release"
            )
        source = identity.get("source_commit", "")
        if (
            not re.fullmatch(r"[a-f0-9]{40}", source)
            or identity.get("release_tag_commit") != source
        ):
            raise ValueError(
                "Acceptance requires an immutable source bound to the release tag"
            )
        sources.add(source)
        if len(functional) != 1:
            raise ValueError(
                "Every installer needs exactly one functional acceptance report"
            )
        report = json.loads(functional[0].read_text())
        if (
            report.get("status") != "automated_passed_manual_pending"
            or report.get("gpu_inference", {}).get("status") != "manual_pending"
        ):
            raise ValueError("Installer functional acceptance is incomplete")
        asset = identity["asset"]
        kind = next(
            (
                suffix
                for suffix in (".deb", ".rpm", ".pkg.tar.zst", ".dmg")
                if asset.endswith(suffix)
            ),
            None,
        )
        if kind is None:
            raise ValueError("Unexpected installer kind")
        binding = {
            "asset": asset,
            "sha256": identity["sha256"],
            "platform": "macos" if kind == ".dmg" else "linux",
        }
        validation_artifacts.append(
            {"artifact": artifact.name, **binding, "status": report["status"]}
        )
        if kind in identities:
            if binding != identities[kind]:
                raise ValueError(
                    "Repeated installer kind has conflicting asset or digest"
                )
            continue
        identities[kind] = binding
        suffixes.add(kind)
        installers.append(binding)
    if suffixes != {".deb", ".rpm", ".pkg.tar.zst", ".dmg"}:
        raise ValueError(
            "Acceptance must include DEB, RPM, Arch and DMG installer evidence"
        )
    if len(sources) != 1:
        raise ValueError("Accepted installers have conflicting product sources")
    gpu = gpu_status(installers, evidence)
    return {
        "tag": tag,
        "source_commit": sources.pop(),
        "status": "passed"
        if gpu["status"] == "manual_passed"
        else "automated_passed_manual_pending",
        "installers": installers,
        "validation_artifacts": validation_artifacts,
        "gpu_inference": gpu,
    }


def gpu_status(installers, evidence):
    gpu = {"status": "manual_pending", "evidence": []}
    if evidence:
        records = json.loads(evidence)
        if not isinstance(records, list) or len(records) != 2:
            raise ValueError("GPU evidence needs one Linux and one macOS record")
        platforms = set()
        for record in records:
            if not isinstance(record, dict):
                raise ValueError("Invalid GPU evidence record")
            for key in (
                "platform",
                "installer_sha256",
                "gpu",
                "backend",
                "tester",
                "tested_at_utc",
                "evidence",
            ):
                if not isinstance(record.get(key), str) or not record[key].strip():
                    raise ValueError("GPU evidence missing " + key)
            if record["platform"] in platforms or not any(
                item["platform"] == record["platform"]
                and item["sha256"] == record["installer_sha256"]
                for item in installers
            ):
                raise ValueError(
                    "GPU evidence does not match an accepted installer/platform"
                )
            if not re.fullmatch(
                r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", record["tested_at_utc"]
            ):
                raise ValueError("GPU evidence timestamp must use UTC RFC3339 seconds")
            platforms.add(record["platform"])
        if platforms != {"linux", "macos"}:
            raise ValueError("Both supported platforms need release-day GPU evidence")
        gpu = {"status": "manual_passed", "evidence": records}
    return gpu


def require_publication(report, tag):
    if (
        report.get("tag") != tag
        or report.get("status") != "passed"
        or report.get("gpu_inference", {}).get("status") != "manual_passed"
    ):
        raise ValueError(
            "Release remains unpublished: automated_passed_manual_pending requires the release-day GPU check and installer-bound gpu_evidence for Linux and macOS"
        )
    # Revalidate persisted evidence rather than accepting only a status string.
    records = report["gpu_inference"].get("evidence", [])
    installers = report.get("installers", [])
    if {record.get("platform") for record in records} != {"linux", "macos"} or any(
        not any(
            item.get("platform") == record.get("platform")
            and item.get("sha256") == record.get("installer_sha256")
            for item in installers
        )
        for record in records
    ):
        raise ValueError(
            "Publication GPU evidence is not bound to accepted installer bytes"
        )


def require_coordinator(results, ref, publish_only):
    if ref != "refs/heads/main":
        raise ValueError("Publication requires reviewed main")
    expected = "skipped" if publish_only else "success"
    if results.get("acceptance", {}).get("result") != "success" or any(
        results.get(job, {}).get("result") != expected
        for job in ("prepare", "linux", "macos")
    ):
        raise ValueError("Release remains unpublished: " + str(results))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--require-publication", type=Path)
    args = parser.parse_args()
    if args.require_publication:
        require_publication(json.loads(args.require_publication.read_text()), args.tag)
    else:
        import os

        if args.directory is None or args.output is None:
            parser.error("--directory and --output are required for aggregation")
        report = aggregate(args.directory, args.tag, os.environ.get("GPU_EVIDENCE", ""))
        args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
