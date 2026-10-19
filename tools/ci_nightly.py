#!/usr/bin/env python3
"""Require in-run nightly evidence, retry failed jobs once, and track failures."""

import argparse
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.build_sequence import request


def pages(repository, route, key, *, request=request):
    result = []
    page = 1
    while True:
        separator = "&" if "?" in route else "?"
        response = request(repository, f"{route}{separator}per_page=100&page={page}")
        batch = response[key] if key else response
        result.extend(batch)
        if len(batch) < 100:
            return result
        page += 1


def jobs(repository, run, *, request=request):
    return pages(
        repository, f"actions/runs/{run}/jobs?filter=latest", "jobs", request=request
    )


def green(repository, run, *, request=request):
    return any(
        job["name"] == "nightly-checks" and job["conclusion"] == "success"
        for job in jobs(repository, run["id"], request=request)
    )


def previous_nightly(repository, commit, force, *, request=request):
    """A retry retains original bytes and returns immediately, without polling."""
    if force:
        return None
    runs = pages(
        repository,
        f"actions/workflows/preview-packages.yml/runs?branch=main&head_sha={commit}",
        "workflow_runs",
        request=request,
    )
    matching = sorted(
        (
            run
            for run in runs
            if run["head_sha"] == commit
            and run["id"] < int(os.environ["GITHUB_RUN_ID"])
            and not run.get("display_title", "").startswith("Nightly exercise")
        ),
        key=lambda run: run["id"],
        reverse=True,
    )
    # Skip-only trigger runs cannot hide the original failed producer.
    planning_failure = None
    for run in matching:
        if run["status"] != "completed":
            return {
                "summary": f"Original nightly {run['id']} is still active; preserving it."
            }
        run_jobs = jobs(repository, run["id"], request=request)
        if not any(job["name"] == "nightly-checks" for job in run_jobs):
            # Pre-rollout producers have no aggregate/issue job to report a retry.
            continue
        if any(
            job["name"] == "nightly-checks" and job["conclusion"] == "success"
            for job in run_jobs
        ):
            return {
                "summary": f"No changes since green nightly-checks for `{commit}` in run {run['id']}."
            }
        if run["conclusion"] in {"failure", "timed_out", "cancelled"}:
            if not any(
                job["name"] == "build" or job["name"].startswith("build / ")
                for job in run_jobs
            ):
                planning_failure = run["id"]
                continue
            if run["run_attempt"] != 1:
                raise ValueError(
                    f"Nightly {run['id']} failed after its retry; inspect the failed jobs. "
                    "Compatible SDKs and successful jobs remain reusable."
                )
            request(repository, f"actions/runs/{run['id']}/rerun-failed-jobs", "POST")
            return {
                "summary": f"Retry requested for failed jobs of original nightly {run['id']}; its aggregate and issue job report the result."
            }
    if planning_failure:
        raise ValueError(
            f"Nightly planning failed in run {planning_failure}; inspect its plan output before requesting a new build."
        )
    return None


def aggregate(results, exercise=False):
    expected = (
        ("plan", "exercise")
        if exercise
        else ("plan", "build", "linux", "macos", "publish")
    )
    failed = [
        name for name in expected if results.get(name, {}).get("result") != "success"
    ]
    scope = (
        "Synthetic exercise only; no build or publication."
        if exercise
        else "In-run platform suites and installer lifecycle checks. Main model/audio acceptance remains a separate per-candidate workflow until WS2b."
    )
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write(
                f"Nightly scope: {scope}\n\nFailed or missing: {', '.join(failed) or 'none'}.\n"
            )
    if failed:
        raise ValueError("Nightly jobs did not succeed: " + ", ".join(failed))


def issue(repository, run_id, source, success, exercise=False, *, request=request):
    """Exercise failures use their own issue and never modify real-night status."""
    label = "ci-nightly-exercise" if exercise else "ci-nightly"
    runs = pages(
        repository,
        "actions/workflows/preview-packages.yml/runs?branch=main",
        "workflow_runs",
        request=request,
    )
    for run in runs:
        is_exercise = run.get("display_title", "").startswith("Nightly exercise")
        if (
            run["id"] > run_id
            and is_exercise == exercise
            and run["status"] == "completed"
        ):
            if any(
                job["name"] == "nightly-checks"
                and job.get("conclusion")
                in {"success", "failure", "cancelled", "timed_out"}
                for job in jobs(repository, run["id"], request=request)
            ):
                return
    issues = [
        item
        for item in pages(
            repository, f"issues?state=open&labels={label}", None, request=request
        )
        if "pull_request" not in item
    ]
    url = f"https://github.com/{repository}/actions/runs/{run_id}"
    if success:
        for item in issues:
            request(
                repository,
                f"issues/{item['number']}/comments",
                "POST",
                {"body": f"Recovered: [green nightly-checks]({url}) for `{source}`."},
            )
            request(
                repository, f"issues/{item['number']}", "PATCH", {"state": "closed"}
            )
        return
    failures = [
        job["name"]
        for job in jobs(repository, run_id, request=request)
        if job.get("conclusion") in {"failure", "cancelled", "timed_out"}
    ]
    body = f"[Nightly run]({url}) for `{source}` failed.\n\nFailing jobs: {', '.join(failures) or 'missing aggregate evidence'}.\n"
    if not exercise:
        previous = next(
            (
                run
                for run in sorted(runs, key=lambda run: run["id"], reverse=True)
                if run["id"] < run_id
                and run["status"] == "completed"
                and not run.get("display_title", "").startswith("Nightly exercise")
                and green(repository, run, request=request)
            ),
            None,
        )
        if previous:
            base = previous["head_sha"]
            body += f"\nCommit range since last green: `{base}...{source}`.\n"
            try:
                commits = pages(
                    repository, f"compare/{base}...{source}", "commits", request=request
                )
                pull_requests = {}
                for commit in commits:
                    for pr in pages(
                        repository,
                        f"commits/{commit['sha']}/pulls",
                        None,
                        request=request,
                    ):
                        pull_requests[pr["number"]] = pr
                body += "\n".join(
                    f"- #{pr['number']}: {pr['title']}" for pr in pull_requests.values()
                )
            except RuntimeError as error:
                print(f"Commit-range metadata unavailable: {error}", file=sys.stderr)
                body += "\nCommit-range metadata unavailable; inspect the compare/PR API and commit reachability. The failing jobs above still require investigation.\n"

        else:
            body += "\nNo earlier green nightly-checks exists; this is the initial baseline.\n"
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
                "title": f"{label}: failing nightly checks",
                "labels": [label],
                "body": body,
            },
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("aggregate", "issue"))
    args = parser.parse_args()
    exercise = os.environ.get("EXERCISE") == "true"
    if args.command == "aggregate":
        aggregate(json.loads(os.environ["RESULTS"]), exercise)
    else:
        issue(
            os.environ["GITHUB_REPOSITORY"],
            int(os.environ["GITHUB_RUN_ID"]),
            os.environ["GITHUB_SHA"],
            os.environ["RESULT"] == "success",
            exercise,
        )


if __name__ == "__main__":
    main()
