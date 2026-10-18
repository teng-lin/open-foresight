#!/usr/bin/env python3
"""Use trusted dependency artifacts, or build the pinned sources locally."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import (
    ROOT,
    JOBS,
    api,
    dependency_jobs,
    fingerprint,
    pull,
    trusted_run,
)  # noqa: E402
from tools.ci_verify_dependency import verify  # noqa: E402


def waiting_producers(repository, component, own_head, own_pr):
    if not own_head:
        return []
    runs = api(
        repository,
        f"actions/workflows/ci-dependencies.yml/runs?head_sha={own_head}&per_page=100",
    )["workflow_runs"]
    waiting = []
    for run in runs:
        if (
            run.get("head_sha") != own_head
            or run.get("status") == "completed"
            or not trusted_run(run, component, own_head, repository, own_pr)
        ):
            continue
        jobs = dependency_jobs(repository, run["id"])
        component_jobs = [job for job in jobs if job["name"] == JOBS[component]]
        if any(
            job.get("conclusion") in ("failure", "cancelled", "timed_out", "skipped")
            for job in component_jobs
        ):
            continue
        waiting.append(run["id"])
    return waiting


def ensure(component, prefix, repository, own_head="", own_pr=0, wait=5400):
    deadline = time.monotonic() + wait
    while True:
        if pull(
            repository,
            component,
            fingerprint(component),
            prefix,
            own_head=own_head,
            own_pr=own_pr,
        ):
            verify(component, prefix)
            return "artifact"
        if time.monotonic() >= deadline or not waiting_producers(
            repository, component, own_head, own_pr
        ):
            break
        time.sleep(min(20, max(0, deadline - time.monotonic())))
    if component == "macos-runtime":
        vendor = prefix.parent / "macos-vendor"
        ensure("macos-vendor", vendor, repository, own_head, own_pr, wait)
        command = [
            sys.executable,
            str(ROOT / "tools/build_macos_runtimes.py"),
            "--prefix",
            str(prefix),
            "--vendor-prefix",
            str(vendor),
        ]
    else:
        script = (
            "build_macos_sdk.py"
            if component == "macos-sdk"
            else "build_macos_vendor.py"
        )
        command = [
            sys.executable,
            str(ROOT / "tools" / script),
            "--prefix",
            str(prefix),
        ]
    subprocess.run(command, check=True, timeout=10800)
    verify(component, prefix)
    return "local"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--component", choices=("macos-sdk", "macos-runtime"), required=True
    )
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-head", default="")
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--wait", type=int, default=5400)
    args = parser.parse_args()
    print(
        ensure(
            args.component,
            args.prefix,
            args.repository,
            args.own_head,
            args.own_pr,
            args.wait,
        )
    )


if __name__ == "__main__":
    main()
