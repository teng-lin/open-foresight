#!/usr/bin/env python3
"""Track daily drift independently of SHA and ignore stale rerun results."""

import argparse
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_producer_trust import evidence_job_name  # noqa: E402
from tools.build_sequence import request  # noqa: E402
from tools.ci_nightly import jobs, pages  # noqa: E402

WORKFLOWS = {
    "native-sanitizers.yml": (
        "ci-sanitizers",
        ("native-sanitizers", "thread-policy", "native-thread-sanitizer"),
    ),
    "arch-drift.yml": ("ci-arch-drift", ("arch",)),
    "preview-packages.yml": ("ci-preview-external-drift", ("weekly-external-audit",)),
}


def result(
    repository,
    run_id,
    expected,
    *,
    allow_missing=False,
    cancelled=False,
    ignore_skipped=False,
    request=request,
):
    """Read actual job conclusions, including failures hidden by probation."""
    selected = [
        job
        for job in jobs(repository, run_id, request=request)
        if evidence_job_name(job) in expected
    ]
    if not selected or any(
        job.get("status") != "completed" or job.get("conclusion") in (None, "cancelled")
        for job in selected
    ):
        return None
    if (cancelled or ignore_skipped) and all(
        job.get("conclusion") == "skipped" for job in selected
    ):
        return None
    found = {evidence_job_name(job) for job in selected}
    if not allow_missing and set(expected).difference(found):
        return None
    failures = sorted(
        set(expected).difference(found)
        | {evidence_job_name(job) for job in selected if job.get("conclusion") != "success"}
    )
    return failures


def qualified(run, repository, workflow):
    return (
        run.get("path") == ".github/workflows/" + workflow
        and run.get("head_branch") == "main"
        and (run.get("head_repository") or {}).get("full_name") == repository
        and run.get("event") in ("schedule", "push", "workflow_dispatch")
    )


def reconcile(repository, workflow, run_id, source, *, request=request):
    label, expected = WORKFLOWS[workflow]
    current = request(repository, f"actions/runs/{run_id}")
    if (
        current.get("id") != run_id
        or current.get("head_sha") != source
        or not qualified(current, repository, workflow)
    ):
        raise ValueError("Drift issue requires this repository's reviewed main run")
    runs = pages(
        repository,
        f"actions/workflows/{workflow}/runs?branch=main",
        "workflow_runs",
        request=request,
    )
    # Concurrency may replace a pending issue job, including that of a newer
    # run. The invocation that survives must report the newest actual suites,
    # rather than assume another issue job will eventually report them.
    candidates = {candidate["id"]: candidate for candidate in runs}
    candidates[run_id] = current
    for candidate in sorted(
        candidates.values(), key=lambda item: item["id"], reverse=True
    ):
        if not qualified(candidate, repository, workflow) or candidate.get(
            "status"
        ) not in ("completed", "in_progress"):
            continue
        failures = result(
            repository,
            candidate["id"],
            expected,
            allow_missing=candidate.get("status") == "completed",
            cancelled=candidate.get("conclusion") == "cancelled",
            ignore_skipped=workflow == "preview-packages.yml",
            request=request,
        )
        if failures is not None:
            run_id, source = candidate["id"], candidate["head_sha"]
            break
    else:
        print(
            "No completed drift suites to report; pending or cancelled runs are not evidence."
        )
        return
    issues = [
        item
        for item in pages(
            repository, f"issues?state=open&labels={label}", None, request=request
        )
        if "pull_request" not in item
    ]
    url = f"https://github.com/{repository}/actions/runs/{run_id}"
    if not failures:
        for issue in issues:
            request(
                repository,
                f"issues/{issue['number']}/comments",
                "POST",
                {
                    "body": f"Recovered: [all drift suites passed]({url}) for `{source}`."
                },
            )
            request(
                repository, f"issues/{issue['number']}", "PATCH", {"state": "closed"}
            )
        return
    body = (
        f"[Drift run]({url}) for `{source}` failed.\n\n"
        f"Failing or missing suites: {', '.join(failures)}.\n\n"
        "Preserve successful dependency producers and inspect their verified outputs; "
        "a test failure does not authorize an SDK rebuild."
    )
    if issues:
        request(repository, f"issues/{issues[0]['number']}", "PATCH", {"body": body})
    else:
        if not request(repository, f"labels/{label}", optional=True):
            request(repository, "labels", "POST", {"name": label, "color": "d73a4a"})
        request(
            repository,
            "issues",
            "POST",
            {
                "title": f"{label}: {'weekly external audit' if workflow == 'preview-packages.yml' else 'daily checks'} failed",
                "labels": [label],
                "body": body,
            },
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workflow", choices=WORKFLOWS)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--source")
    args = parser.parse_args()
    if (args.run_id is None) != (args.source is None):
        parser.error("--run-id and --source must identify the same original run")
    reconcile(
        os.environ["GITHUB_REPOSITORY"],
        args.workflow,
        args.run_id if args.run_id is not None else int(os.environ["GITHUB_RUN_ID"]),
        args.source if args.source is not None else os.environ["GITHUB_SHA"],
    )


if __name__ == "__main__":
    main()
