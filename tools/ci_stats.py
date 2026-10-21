#!/usr/bin/env python3
"""Report CI latency/cost from frozen GitHub REST snapshots; never dispatch CI.

Input directory: runs.jsonl, jobs/<run-id>.jsonl (all attempts), prs.json
(gh pr list --state all --json number,state,headRefName,headRefOid,mergeCommit,mergedAt),
trees.txt (SHA TREE [PARENTS]), and logs/<run-id>.txt for workflow_run jobs.
Use --current-since to separate removed job shapes from current configuration.
"""

import argparse
import ast
from collections import Counter
from collections import defaultdict
from datetime import datetime
import io
import importlib
import json
from pathlib import Path
import re
import statistics
import tokenize

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {"python", "format", "contracts", "platform-checks", "acceptance-checks"}
FAILURES = {"failure", "timed_out", "startup_failure", "action_required", "stale"}


def outcome(jobs):
    """Derive an attempt from its jobs, never the run's later rerun conclusion."""
    values = [
        job.get("conclusion") if job.get("status") == "completed" else "incomplete"
        for job in jobs
    ]
    if not values:
        return "unknown"
    if any(value in FAILURES for value in values):
        return "failure"
    if "incomplete" in values:
        return "incomplete"
    if "cancelled" in values:
        return "cancelled"
    if all(value in {"skipped", "neutral"} for value in values):
        return "skipped"
    return (
        "success"
        if all(value in {"success", "skipped", "neutral"} for value in values)
        else "unknown"
    )


def failure_rate(values):
    counts = Counter(values)
    denominator = counts["success"] + counts["failure"]
    return {
        "failed": counts["failure"],
        "eligible": denominator,
        "rate": counts["failure"] / denominator if denominator else None,
        "outcomes": dict(sorted(counts.items())),
    }


def first_attempt_state(run):
    if run.get("run_attempt", 1) == 1 and run.get("status") not in (None, "completed"):
        return "incomplete"
    if run.get("run_attempt", 1) == 1:
        if run.get("conclusion") == "cancelled":
            return "cancelled"
        if run.get("conclusion") in FAILURES:
            return "failure"
    first = [job for job in run["jobs"] if job.get("run_attempt", 1) == 1]
    return outcome(first)


def failure_class(job):
    """Only validated diagnostic observations can establish a root cause."""
    observation = job.get("failure_evidence", {})
    allowed = {
        "package-network",
        "test-assertion",
        "provenance-abi",
        "maintenance-publication",
    }
    if (
        observation.get("class") in allowed
        and observation.get("command")
        and observation.get("diagnostic")
        and observation.get("source")
    ):
        return observation["class"]
    return "unknown"


def run_category(run):
    path = run["path"]
    if "cache-publish" in path:
        if Path(path).name == "linux-cache-publish.yml":
            publishers = []
            for job in run.get("jobs", []):
                name = job.get("name", "").split(" / ")[-1].split(" (")[0]
                if not name.startswith("publish-") or job.get("conclusion") == "skipped":
                    continue
                if name == "publish-linux-caches" and job.get("conclusion") == "success":
                    publication = [step for step in job.get("steps", []) if step.get("name") == "Publish only isolated secret-free dependency and acceptance caches"]
                    if publication and all(step.get("conclusion") == "skipped" for step in publication):
                        continue
                publishers.append(job)
            if not publishers:
                return "cache-reconcile"
        return "cache-publisher"
    if "dependencies" in path:
        return "sdk-producer"
    if "release" in path:
        return "release"
    if run["event"] == "schedule":
        return "nightly-or-drift"
    return (
        "pr"
        if run["event"] == "pull_request"
        else "main"
        if run["event"] == "push"
        else "dispatch-or-other"
    )


def operational_report(runs):
    """Report comparable raw cohorts without discarding failures or cold runs."""
    snapshot = importlib.import_module(
        "tools.ci_stats_snapshot" if __package__ else "ci_stats_snapshot"
    )
    categories: dict[str, float] = defaultdict(float)
    category_workflows: dict[str, list] = defaultdict(list)
    workflows, jobs, commits, failures, cohorts = (
        [],
        [],
        defaultdict(list),
        [],
        defaultdict(list),
    )
    queue, start_latency = [], []
    for run in runs:
        snapshot.validate_qualification(run)
        category = run_category(run)
        categories[category] += run["minutes"]
        state = first_attempt_state(run)
        ordinary = run.get("qualification") is not True
        if ordinary:
            workflows.append(state)
            category_workflows[category].append(state)
        if ordinary and run["event"] == "pull_request":
            commits[run["source"]].append(state)
        for job in run["jobs"]:
            if ordinary and job.get("run_attempt", 1) == 1:
                jobs.append(outcome([job]))
            if job.get("created_at") and job.get("started_at"):
                queue.append(
                    max(
                        0,
                        (
                            stamp(job["started_at"]) - stamp(job["created_at"])
                        ).total_seconds()
                        / 60,
                    )
                )
            if job.get("conclusion") in FAILURES:
                failures.append(
                    {
                        "run": run["id"],
                        "job": job["id"],
                        "attempt": job["run_attempt"],
                        "conclusion": job["conclusion"],
                        "class": failure_class(job),
                        "qualification": not ordinary,
                        "evidence": job.get("failure_evidence"),
                    }
                )
        if run.get("run_started_at"):
            start_latency.append(
                max(
                    0,
                    (
                        stamp(run["run_started_at"]) - stamp(run["created_at"])
                    ).total_seconds()
                    / 60,
                )
            )
        key = json.dumps(
            {
                "configuration": run.get("configuration", "unknown"),
                "scope": run.get("scope", "unknown"),
                "workflow": run["path"],
                "category": category,
                "cache_state": run.get("cache_state", "unknown"),
                "selection": run.get("selection", "unknown"),
                "qualification": not ordinary,
            },
            sort_keys=True,
        )
        cohorts[key].append(
            {
                "run": run["id"],
                "outcome": state,
                "minutes": run["minutes"],
                "jobs": [
                    {
                        "name": job["name"],
                        "attempt": job["run_attempt"],
                        "minutes": job["minutes"],
                        "outcome": job.get("conclusion"),
                        "platform": job.get("platform", "unknown"),
                        "runner_labels": job.get("labels", []),
                        "cache_state": job.get("cache_state", "unknown"),
                    }
                    for job in run["jobs"]
                ],
            }
        )
    commit_states = [
        "failure"
        if "failure" in states
        else "success"
        if all(state == "success" for state in states)
        else "cancelled"
        if "cancelled" in states
        else "incomplete"
        if "incomplete" in states
        else "unknown"
        for states in commits.values()
    ]
    return {
        "first_attempt_workflows": failure_rate(workflows),
        "first_attempt_jobs": failure_rate(jobs),
        "first_attempt_pr_commits": failure_rate(commit_states),
        "first_attempt_pr_workflows": failure_rate(
            [
                first_attempt_state(run)
                for run in runs
                if run["event"] == "pull_request"
                and run.get("qualification") is not True
            ]
        ),
        "qualification_first_attempts": failure_rate(
            [
                first_attempt_state(run)
                for run in runs
                if run.get("qualification") is True
            ]
        ),
        "first_attempt_job_conclusions": dict(
            Counter(
                job.get("conclusion") or "incomplete"
                for run in runs
                for job in run["jobs"]
                if job.get("run_attempt", 1) == 1
            )
        ),
        "job_queue_minutes": summary(queue),
        "workflow_start_latency_minutes": summary(start_latency),
        "runner_minutes_by_category": dict(sorted(categories.items())),
        "first_attempt_workflows_by_category": {
            category: failure_rate(states)
            for category, states in sorted(category_workflows.items())
        },
        "failures": failures,
        "cohorts": [
            {"identity": json.loads(key), "observations": values}
            for key, values in sorted(cohorts.items())
        ],
        "cache_observations": [
            {"run": run["id"], "observations": run.get("cache_observations", [])}
            for run in runs
        ],
        "manual_qualification_runs": [
            run["id"] for run in runs if run.get("qualification") is True
        ],
        "run_sources": [
            {
                "run": run["id"],
                "event": run["event"],
                "trigger_source": run["head_sha"],
                "workflow_source": run.get("workflow_source"),
                "checked_out_source": run.get("checked_out_source"),
                "bundle_source": run.get("bundle_source"),
            }
            for run in runs
        ],
    }


def stamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def percentile(values, fraction):
    if not values:
        return None
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lo = int(position)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (position - lo)


def summary(values):
    return {
        "n": len(values),
        "p50": percentile(values, 0.5),
        "p90": percentile(values, 0.9),
        "mean": statistics.mean(values) if values else None,
    }


def jsonlines(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def candidate_source(log):
    """workflow_run's head_sha is not the candidate tested by recovery jobs."""
    sources = set(
        re.findall(
            r'(?:source|candidate_source|SOURCE)(?:=|":\s*")([0-9a-f]{40})\b', log
        )
    )
    if len(sources) != 1:
        return None
    return sources.pop()


def load(directory):
    snapshot = importlib.import_module(
        "tools.ci_stats_snapshot" if __package__ else "ci_stats_snapshot"
    )
    snapshot.verify(directory)
    observations_path = directory / "observations.json"
    observations = (
        json.loads(observations_path.read_text()) if observations_path.exists() else {}
    )
    snapshot.validate_observations(observations)
    runs = {run["id"]: run for run in jsonlines(directory / "runs.jsonl")}
    seen = set()
    for run in runs.values():
        run.update(observations.get("runs", {}).get(str(run["id"]), {}))
        snapshot.validate_qualification(run)
        path = directory / "jobs" / f"{run['id']}.jsonl"
        run["jobs"] = []
        for job in sorted(
            jsonlines(path) if path.exists() else [],
            key=lambda job: (job["run_attempt"], job["id"]),
        ):
            job.update(observations.get("jobs", {}).get(str(job["id"]), {}))
            # GitHub repeats unchanged successful jobs on a failed-jobs rerun.
            key = (job.get("runner_id") or job["id"], job["started_at"])
            if key in seen:
                continue
            seen.add(key)
            job["minutes"] = 0.0
            if (
                job.get("runner_id")
                and job.get("status") == "completed"
                and job.get("started_at")
                and job.get("completed_at")
            ):
                job["minutes"] = max(
                    0,
                    (
                        stamp(job["completed_at"]) - stamp(job["started_at"])
                    ).total_seconds()
                    / 60,
                )
            run["jobs"].append(job)
        run["minutes"] = sum(job["minutes"] for job in run["jobs"])
        run["source"] = run["head_sha"]
        if run["event"] == "workflow_run":
            log = directory / "logs" / f"{run['id']}.txt"
            run["source"] = candidate_source(log.read_text()) if log.exists() else None
    prs = json.loads((directory / "prs.json").read_text())
    trees = {
        parts[0]: parts[1]
        for line in (directory / "trees.txt").read_text().splitlines()
        if len(parts := line.split()) >= 2
    }
    return list(runs.values()), prs, trees


def merge_attribution(run):
    """Identify merge-triggered work without treating a shared SHA as causality.

    Dispatch inputs/selection receipts are absent from the REST snapshots. A
    future ``Main sweep`` display title is only a filter, so dispatches remain
    independent spend until their actual sweep selection can be verified.
    """
    if run.get("head_branch") != "main":
        return "not-main"
    if run["event"] == "push":
        return None if run["source"] else "missing-push-source"
    if run["event"] == "workflow_run":
        if run["path"] != ".github/workflows/integration-acceptance.yml":
            return "unverified-downstream-workflow"
        return None if run["source"] else "missing-candidate-source"
    if run["event"] == "workflow_dispatch":
        return "dispatch-without-verified-sweep-evidence"
    return "independent-event"


def report(runs, prs, trees, current_since):
    pulls = {pull["number"]: pull for pull in prs}
    branches = defaultdict(list)
    for pull in prs:
        if pull.get("headRefName"):
            branches[pull["headRefName"]].append(pull)
    pushes = defaultdict(list)
    main = defaultdict(list)
    shapes: dict[str, dict[str, float]] = defaultdict(
        lambda: {"current": 0.0, "removed": 0.0}
    )
    current_shapes = {
        (run["path"], job["name"])
        for run in runs
        if run["created_at"] >= current_since
        for job in run["jobs"]
    }
    unattributed = []
    non_merge = []
    for run in runs:
        for job in run["jobs"]:
            shape = (run["path"], job["name"])
            shapes[" / ".join(shape)][
                "current" if shape in current_shapes else "removed"
            ] += job["minutes"]
        if run["event"] == "pull_request":
            assignments = run.get("pull_requests", [])
            if not assignments:
                # REST drops PR associations after merge; resolve only unique
                # snapshot branch names, never guess between reused branches.
                assignments = [
                    pull["number"]
                    for pull in branches.get(run.get("head_branch"), [])
                    if (
                        not pull.get("createdAt")
                        or pull["createdAt"] <= run["created_at"]
                    )
                    and (
                        not pull.get("closedAt")
                        or run["created_at"] <= pull["closedAt"]
                    )
                ]
                if len(assignments) != 1:
                    assignments = []
            for pull in assignments:
                number = pull["number"] if isinstance(pull, dict) else pull
                pushes[number, run["head_sha"]].append(run)
        else:
            reason = merge_attribution(run)
            if reason is None:
                main[run["source"]].append(run)
            else:
                non_merge.append(
                    {
                        "id": run["id"],
                        "event": run["event"],
                        "workflow": run["path"],
                        "head_sha": run["head_sha"],
                        "runner_minutes": run["minutes"],
                        "reason": reason,
                    }
                )
                if run["event"] == "workflow_run" and not run["source"]:
                    unattributed.append(run["id"])
    per_push = []
    for (number, sha), group in sorted(pushes.items()):
        pull = pulls.get(number, {})
        checks = {}
        for run in sorted(group, key=lambda item: (item["created_at"], item["id"])):
            for job in sorted(
                run["jobs"], key=lambda item: (item["run_attempt"], item["id"])
            ):
                if job["name"] in REQUIRED:
                    checks[job["name"]] = job
        # Abandoned PRs still consume runner time, but are not delivery samples.
        green = (
            pull.get("state") in {"OPEN", "MERGED"}
            and len(checks) == len(REQUIRED)
            and all(
                job.get("conclusion") == "success" and job.get("completed_at")
                for job in checks.values()
            )
        )
        end = max(
            (
                stamp(job["completed_at"])
                for job in checks.values()
                if job.get("completed_at")
            ),
            default=None,
        )
        start = min(stamp(run["created_at"]) for run in group)
        readiness = {}
        readiness_attempts = {}
        readiness_runs = {}
        earliest_runs: dict[str, int] = {}
        for run in sorted(group, key=lambda row: (row["created_at"], row["id"])):
            earliest_runs.setdefault(run["path"], run["id"])
        first_green = None
        first_green_attempt = None
        first_green_runs = {}
        first_attempt_green = False
        events = sorted(
            (
                (run, job)
                for run in group
                for job in run["jobs"]
                if job["name"] in REQUIRED and job.get("completed_at")
            ),
            key=lambda pair: (pair[1]["completed_at"], pair[0]["id"], pair[1]["id"]),
        )
        for run, job in events:
            readiness[job["name"]] = job.get("conclusion")
            readiness_attempts[job["name"]] = job["run_attempt"]
            readiness_runs[job["name"]] = {
                "run": run["id"],
                "workflow": run["path"],
                "qualification": run.get("qualification") is True,
            }
            if set(readiness) == REQUIRED and all(
                value == "success" for value in readiness.values()
            ):
                first_green = (stamp(job["completed_at"]) - start).total_seconds() / 60
                first_green_attempt = max(readiness_attempts.values())
                first_green_runs = dict(readiness_runs)
                first_attempt_green = first_green_attempt == 1 and all(
                    value["run"] == earliest_runs[value["workflow"]]
                    and not value["qualification"]
                    for value in readiness_runs.values()
                )
                break
        per_push.append(
            {
                "pr": number,
                "state": pull.get("state"),
                "sha": sha,
                "final": sha == pull.get("headRefOid"),
                "green_minutes": (end - start).total_seconds() / 60 if green else None,
                "first_green_minutes": first_green,
                "first_green_attempt": first_green_attempt,
                "first_green_runs": first_green_runs,
                "first_attempt_green": first_attempt_green,
                "runner_minutes": sum(run["minutes"] for run in group),
                "missing_or_red": sorted(
                    REQUIRED
                    - {
                        name
                        for name, job in checks.items()
                        if job.get("conclusion") == "success"
                    }
                ),
            }
        )
    per_merge = []
    for pull in prs:
        if (
            not pull.get("mergedAt")
            or not pull.get("mergeCommit")
            or not pull.get("measurement_window", True)
        ):
            continue
        sha, head = pull["mergeCommit"]["oid"], pull["headRefOid"]
        identity = (
            (trees[sha] == trees[head]) if sha in trees and head in trees else None
        )
        group = main.get(sha, [])
        per_merge.append(
            {
                "pr": pull["number"],
                "sha": sha,
                "identical_tree": identity,
                "observed": bool(group),
                "runner_minutes": sum(run["minutes"] for run in group)
                if group
                else None,
            }
        )
    known = [merge for merge in per_merge if merge["identical_tree"] is not None]
    observed = [merge for merge in per_merge if merge["observed"]]
    identical = [merge for merge in observed if merge["identical_tree"] is True]
    divergent = [merge for merge in observed if merge["identical_tree"] is False]
    return {
        "schema": 2,
        "operational": operational_report(runs),
        "push_to_first_green": summary(
            [
                push["first_green_minutes"]
                for push in per_push
                if push["first_green_minutes"] is not None
            ]
        ),
        "push_to_first_attempt_green": summary(
            [
                push["first_green_minutes"]
                for push in per_push
                if push["first_attempt_green"]
            ]
        ),
        "push_to_green": summary(
            [
                push["green_minutes"]
                for push in per_push
                if push["green_minutes"] is not None
            ]
        ),
        "final_push_to_green": summary(
            [
                push["green_minutes"]
                for push in per_push
                if push["final"] and push["green_minutes"] is not None
            ]
        ),
        "runner_minutes_per_push": summary(
            [push["runner_minutes"] for push in per_push]
        ),
        "identical_tree_share": sum(merge["identical_tree"] for merge in known)
        / len(known)
        if known
        else None,
        "identical_tree_merge_minutes": summary(
            [merge["runner_minutes"] for merge in identical]
        ),
        "divergent_count": sum(merge["identical_tree"] is False for merge in known),
        "divergent_sweep_minutes": summary(
            [merge["runner_minutes"] for merge in divergent]
        ),
        "mean_per_merge": summary([merge["runner_minutes"] for merge in observed])[
            "mean"
        ],
        "unobserved_merge_count": len(per_merge) - len(observed),
        "unknown_tree_count": len(per_merge) - len(known),
        "unattributed_workflow_run_ids": unattributed,
        "non_merge_runner_minutes": sum(run["runner_minutes"] for run in non_merge),
        "non_merge_runs": non_merge,
        "job_shapes": dict(sorted(shapes.items())),
        "pushes": per_push,
        "merges": per_merge,
    }


def code_lines(path):
    source = path.read_text()
    if path.suffix != ".py":
        return sum(
            bool(line.strip()) and not line.lstrip().startswith("#")
            for line in source.splitlines()
        )
    # Count physical code lines, excluding comments, whitespace and docstrings.
    docs: set[int] = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(
            node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
        ):
            if node.body and isinstance(node.body[0], ast.Expr):
                value = node.body[0].value
                if isinstance(value, ast.Constant) and isinstance(value.value, str):
                    docs.update(
                        range(
                            node.body[0].lineno,
                            (node.body[0].end_lineno or node.body[0].lineno) + 1,
                        )
                    )
    lines: set[int] = set()
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type not in {
            tokenize.COMMENT,
            tokenize.NL,
            tokenize.NEWLINE,
            tokenize.INDENT,
            tokenize.DEDENT,
            tokenize.ENDMARKER,
        }:
            lines.update(range(token.start[0], token.end[0] + 1))
    return len(lines - docs)


def line_inventory(root):
    # Explicitly include CI helpers whose historic names predate the ci_ prefix.
    paths = set(root.glob(".github/workflows/*.yml"))
    helpers = {
        "platform_python_tests",
        "release_upgrade",
        "integration_application",
        "preview_reuse",
        "preview_packages",
        "sdk_approval_bridge",
        "sdk_final_approval",
        "create_sdk_approval",
        "linux_sdk_artifacts",
        "run_ci_stage",
    }
    paths.update(
        path
        for path in (root / "tools").glob("*")
        if path.is_file() and (path.stem.startswith("ci_") or path.stem in helpers)
    )
    paths.update(
        path
        for path in (root / "tests").glob("test_*")
        if path.is_file()
        and (
            path.stem.startswith("test_ci_")
            or path.stem.removeprefix("test_") in helpers
        )
    )
    counts = {
        path.relative_to(root).as_posix(): code_lines(path) for path in sorted(paths)
    }
    return {"total": sum(counts.values()), "files": counts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path)
    parser.add_argument("--current-since", default="2026-10-19T13:57:00Z")
    parser.add_argument("--lines", action="store_true")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--report-output",
        type=Path,
        help="Write report.json and report.md alongside frozen inputs",
    )
    args = parser.parse_args()
    if args.lines:
        result = line_inventory(args.root)
    elif args.directory:
        runs, prs, trees = load(args.directory)
        result = report(runs, prs, trees, args.current_since)
        snapshot = importlib.import_module(
            "tools.ci_stats_snapshot" if __package__ else "ci_stats_snapshot"
        )
        manifest = snapshot.verify(args.directory)
        result["snapshot"] = {
            "verified": manifest is not None,
            "retrieved_at": manifest.get("retrieved_at") if manifest else None,
        }
    else:
        parser.error("supply a snapshot directory or --lines")
    if args.report_output:
        args.report_output.mkdir(parents=True, exist_ok=True)
        (args.report_output / "report.json").write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n"
        )
        rates = result.get("operational", {})
        lines = [
            "# Frozen CI observations",
            "",
            "| First-attempt cohort | Failures | Eligible | Rate |",
            "| --- | ---: | ---: | ---: |",
        ]
        for name in (
            "first_attempt_workflows",
            "first_attempt_jobs",
            "first_attempt_pr_commits",
        ):
            value = rates.get(name, {})
            rate = (
                f"{value['rate']:.1%}" if value.get("rate") is not None else "unknown"
            )
            lines.append(
                f"| {name} | {value.get('failed', 0)} | {value.get('eligible', 0)} | {rate} |"
            )
        for category, value in rates.get("first_attempt_workflows_by_category", {}).items():
            rate = f"{value['rate']:.1%}" if value.get("rate") is not None else "unknown"
            lines.append(f"| workflows: {category} | {value['failed']} | {value['eligible']} | {rate} |")
        lines.extend(
            [
                "",
                "Cancellation, incomplete, skipped and unknown observations remain explicit in report.json. Cohorts are observational; small samples do not establish causality.",
                "",
            ]
        )
        (args.report_output / "report.md").write_text("\n".join(lines))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
