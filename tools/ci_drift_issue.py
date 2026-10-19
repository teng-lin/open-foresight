#!/usr/bin/env python3
"""Track daily drift independently of SHA and ignore stale rerun results."""

import argparse
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.build_sequence import request  # noqa: E402
from tools.ci_nightly import jobs, pages  # noqa: E402

WORKFLOWS = {
    "native-sanitizers.yml": (
        "ci-sanitizers",
        ("native-sanitizers", "thread-policy", "native-thread-sanitizer"),
    ),
    "arch-drift.yml": ("ci-arch-drift", ("arch",)),
}


def result(repository, run_id, expected, *, allow_missing=False, request=request):
    """Read actual job conclusions, including failures hidden by probation."""
    selected = [
        job
        for job in jobs(repository, run_id, request=request)
        if job.get("name") in expected
    ]
    if any(job.get("status") != "completed" for job in selected):
        return None
    found = {job["name"] for job in selected}
    if not allow_missing and set(expected).difference(found):
        return None
    failures = sorted(
        set(expected).difference(found)
        | {job["name"] for job in selected if job.get("conclusion") != "success"}
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
    for candidate in runs:
        if (
            candidate["id"] > run_id
            and qualified(candidate, repository, workflow)
            and result(
                repository,
                candidate["id"],
                expected,
                allow_missing=candidate.get("status") == "completed",
                request=request,
            )
            is not None
        ):
            print(
                f"Ignore stale drift result {run_id}; newer run {candidate['id']} reports it."
            )
            return
    failures = result(repository, run_id, expected, allow_missing=True, request=request)
    if failures is None:
        raise ValueError("Drift issue ran before its selected suites completed")
    issues = pages(
        repository, f"issues?state=open&labels={label}", None, request=request
    )
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
            {"title": f"{label}: daily checks failed", "labels": [label], "body": body},
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workflow", choices=WORKFLOWS)
    args = parser.parse_args()
    reconcile(
        os.environ["GITHUB_REPOSITORY"],
        args.workflow,
        int(os.environ["GITHUB_RUN_ID"]),
        os.environ["GITHUB_SHA"],
    )


if __name__ == "__main__":
    main()
