#!/usr/bin/env python3
"""Report CI latency/cost from frozen GitHub REST snapshots; never dispatch CI.

Input directory: runs.jsonl, jobs/<run-id>.jsonl (all attempts), prs.json
(gh pr list --state all --json number,state,headRefName,headRefOid,mergeCommit,mergedAt),
trees.txt (SHA TREE [PARENTS]), and logs/<run-id>.txt for workflow_run jobs.
Use --current-since to separate removed job shapes from current configuration.
"""

import argparse
import ast
from collections import defaultdict
from datetime import datetime
import io
import json
from pathlib import Path
import re
import statistics
import tokenize

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {"python", "format", "contracts", "platform-checks", "acceptance-checks"}


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
    runs = {run["id"]: run for run in jsonlines(directory / "runs.jsonl")}
    seen = set()
    for run in runs.values():
        path = directory / "jobs" / f"{run['id']}.jsonl"
        run["jobs"] = []
        for job in sorted(
            jsonlines(path) if path.exists() else [],
            key=lambda job: (job["run_attempt"], job["id"]),
        ):
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
            branches[pull["headRefName"]].append(pull["number"])
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
                assignments = branches.get(run.get("head_branch"), [])
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
        per_push.append(
            {
                "pr": number,
                "state": pull.get("state"),
                "sha": sha,
                "final": sha == pull.get("headRefOid"),
                "green_minutes": (end - start).total_seconds() / 60 if green else None,
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
        if not pull.get("mergedAt") or not pull.get("mergeCommit"):
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
        "integration_application",
        "package_contract_candidate",
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
    args = parser.parse_args()
    if args.lines:
        result = line_inventory(args.root)
    elif args.directory:
        runs, prs, trees = load(args.directory)
        result = report(runs, prs, trees, args.current_since)
    else:
        parser.error("supply a snapshot directory or --lines")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
