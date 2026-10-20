#!/usr/bin/env python3
"""Reuse successful installer acceptance, bound to unchanged draft asset bytes."""

import argparse
import json
import os
from pathlib import Path

from tools.ci_artifacts import api
from tools.ci_release_evidence import acceptance_proof
from tools.github_release import release_for_tag
from tools.release_acceptance_report import gpu_status, SUITE_VERSION
from tools.release_asset_acceptance import select_asset


def restore(repository, tag, run_id, evidence=""):
    if str(run_id) == os.environ.get("GITHUB_RUN_ID"):
        raise ValueError(
            "Reuse acceptance from a distinct original run; preserve this run's successful proof"
        )
    locator, report = acceptance_proof(repository, run_id)
    if report.get("tag") != tag or report.get("suite_version") != SUITE_VERSION:
        raise ValueError(
            "Original automated acceptance is incomplete or for another release"
        )
    release = release_for_tag(repository, tag)
    source = api(repository, f"commits/{tag}")["sha"]
    if (
        report.get("source_commit") != source
        or release.get("target_commitish") != source
    ):
        raise ValueError(
            "Acceptance source binding is unavailable or changed; rerun installer acceptance without rebuilding the packages"
        )
    expected = {
        (select_asset(release, kind)["name"], select_asset(release, kind).get("digest"))
        for kind in ("deb", "rpm", "arch", "dmg")
    }
    actual = {
        (record["asset"], "sha256:" + record["sha256"])
        for record in report["installers"]
    }
    if actual != expected or len(report["installers"]) != 4:
        raise ValueError(
            "Installer bytes changed after acceptance; rerun only affected validation"
        )
    if evidence:
        report["gpu_inference"] = gpu_status(report["installers"], evidence)
        report["status"] = "passed"
    report["reused_validation_from"] = locator
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--run", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = restore(
        os.environ["GITHUB_REPOSITORY"],
        args.tag,
        args.run,
        os.environ.get("GPU_EVIDENCE", ""),
    )
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
