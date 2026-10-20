#!/usr/bin/env python3
"""Reuse verified dependencies; fork validation may explicitly build pinned sources."""

import argparse
import json
from functools import lru_cache
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import (
    ROOT,
    api,
    dependency_jobs,
    fingerprint,
    pull,
    trusted_run,
    FILES,
    PARENTS,
    report_unavailable,
)  # noqa: E402
from tools.ci_verify_dependency import verify  # noqa: E402
from tools.sdk_producer_trust import compatible_producers, source_fingerprint  # noqa: E402


@lru_cache(maxsize=256)
def producer_identity(repository, commit, component, loader, recipe, request):
    # Immutable source proofs need fetching only once during a long producer
    # wait. Job/run status must still be refreshed on every poll.
    return loader(
        repository,
        commit,
        component,
        api=request,
        fingerprint=recipe,
        files=FILES,
        parents=PARENTS,
    )


def waiting_producers(repository, component, own_head, own_pr):
    if not own_head:
        return []
    runs: dict[int, dict] = {}
    for scope in (f"head_sha={own_head}", "branch=main"):
        page = 1
        while True:
            batch = api(
                repository,
                f"actions/workflows/ci-dependencies.yml/runs?{scope}&per_page=100&page={page}",
            )["workflow_runs"]
            runs.update(
                (run["id"], run)
                for run in batch
                if run.get("status")
                in ("in_progress", "queued", "waiting", "pending", "requested")
                and (
                    run.get("head_sha") == own_head
                    if scope.startswith("head_sha=")
                    else run.get("head_branch") == "main"
                    and run.get("event") != "pull_request"
                )
            )
            if len(batch) < 100:
                break
            page += 1

    def fingerprint_at(repo, commit, name):
        try:
            return producer_identity(
                repo,
                commit,
                name,
                source_fingerprint,
                fingerprint,
                api,
            )
        except json.JSONDecodeError:
            raise
        except ValueError:
            # An older source may predate the consumer's supported recipe.
            # API/network failures still propagate rather than authorize builds.
            return None

    return compatible_producers(
        repository,
        runs.values(),
        component,
        fingerprint(component),
        eligible=lambda run: trusted_run(run, component, own_head, repository, own_pr),
        # Mutually exclusive registry/archive jobs share producer names. GitHub
        # can list the skipped alternative before the real job is materialized.
        jobs=lambda repo, run_id: [
            job
            for job in dependency_jobs(repo, run_id)
            if job.get("conclusion") != "skipped"
        ],
        fingerprint_at=fingerprint_at,
    )


def ensure(
    component,
    prefix,
    repository,
    own_head="",
    own_pr=0,
    wait=1800,
    *,
    allow_local_build=False,
):
    deadline = time.monotonic() + max(0, min(wait, 1800))

    def restore_original():
        if not pull(
            repository,
            component,
            fingerprint(component),
            prefix,
            own_head=own_head,
            own_pr=own_pr,
        ):
            return False
        verify(component, prefix)
        return True

    while True:
        if restore_original():
            return "artifact"
        waiting = waiting_producers(repository, component, own_head, own_pr)
        if not waiting:
            # Upload and successful-job metadata can become eligible between
            # the first pull and the producer-status lookup, even on poll one.
            if restore_original():
                return "artifact"
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(report_unavailable(component, fingerprint(component)))
        # Bound GitHub API traffic while a long-running dependency compiles.
        time.sleep(min(60, max(0, deadline - time.monotonic())))
    if not allow_local_build or os.environ.get("GITHUB_ACTOR", "").startswith(
        "dependabot"
    ):
        raise RuntimeError(report_unavailable(component, fingerprint(component)))
    if component == "macos-runtime":
        vendor = prefix.parent / "macos-vendor"
        ensure(
            "macos-vendor",
            vendor,
            repository,
            own_head,
            own_pr,
            wait,
            allow_local_build=allow_local_build,
        )
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
    parser.add_argument("--wait", type=int, default=1800)
    parser.add_argument(
        "--allow-local-build",
        action="store_true",
        help="Allow pinned local source builds for explicit fork validation only",
    )
    args = parser.parse_args()
    print(
        ensure(
            args.component,
            args.prefix,
            args.repository,
            args.own_head,
            args.own_pr,
            args.wait,
            allow_local_build=args.allow_local_build,
        )
    )


if __name__ == "__main__":
    main()
