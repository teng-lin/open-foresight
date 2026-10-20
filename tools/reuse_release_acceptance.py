#!/usr/bin/env python3
"""Reuse successful installer acceptance, bound to unchanged draft asset bytes."""

import argparse
import json
import os
from pathlib import Path
import tempfile
import zipfile

from tools.ci_artifacts import api, dependency_jobs, download_zip, in_producer_attempt
from tools.github_release import release_for_tag
from tools.release_acceptance_report import gpu_status
from tools.release_asset_acceptance import select_asset
from tools.ci_producer_trust import PRODUCERS


def restore(repository, tag, run_id, evidence=""):
    run = api(repository, f"actions/runs/{run_id}")
    if (
        not PRODUCERS["release-acceptance"].matches_run(run)
        or run.get("head_branch") != "main"
        or run.get("head_repository", {}).get("full_name") != repository
    ):
        raise ValueError("Acceptance must come from a trusted reviewed main workflow")
    items = api(repository, f"actions/runs/{run_id}/artifacts?per_page=100")[
        "artifacts"
    ]
    matches = [
        item
        for item in items
        if item["name"] == "release-acceptance-summary" and not item["expired"]
    ]
    if len(matches) != 1:
        raise ValueError(
            "Original acceptance summary is missing or ambiguous; preserve the installers"
        )
    item = matches[0]
    jobs = [
        job
        for job in dependency_jobs(repository, run_id)
        if PRODUCERS["release-acceptance"].matches_job(job)
        and job.get("conclusion") == "success"
        and in_producer_attempt(item, job)
    ]
    if len(jobs) != 1:
        raise ValueError("Acceptance summary has no successful producer job/attempt")
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / "summary.zip"
        download_zip(repository, item, archive)
        with zipfile.ZipFile(archive) as bundle:
            if (
                bundle.namelist() != ["release-acceptance.json"]
                or bundle.getinfo("release-acceptance.json").file_size > 1024 * 1024
            ):
                raise ValueError("Invalid acceptance archive")
            report = json.loads(bundle.read("release-acceptance.json"))
    if (
        not PRODUCERS["release-acceptance"].matches_receipt(report)
        or report.get("tag") != tag
        or report.get("status")
        not in (
            "passed",
            "automated_passed_manual_pending",
        )
    ):
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
    report["reused_validation_from"] = {
        "run": run_id,
        "attempt": jobs[0].get("run_attempt", 1),
        "artifact": item["id"],
        "digest": item["digest"],
    }
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
