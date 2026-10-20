#!/usr/bin/env python3
"""Gate prepared main coordination on independently verified hosted qualification."""

import argparse
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_main_evidence import (  # noqa: E402
    APPLICATION,
    PLATFORM,
    REQUIRED,
    Reader,
    job_proof,
    require_source,
    scoped_run,
    selected_on_push,
)
from tools.ci_main_sweep import dispatch, matches_sweep, qualify  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / "docs/platforms/ci-rollout-index.json"


def authorize(reader, source, *, index=None, root=None):
    """No environment variable or command flag can waive retained-closure proof."""
    if index is None:
        if not INDEX.is_file():
            raise ValueError(
                "Production main evidence disabled: hosted rollout index absent"
            )
        index = json.loads(INDEX.read_text())
    from tools.ci_rollout import authorize as qualify_rollout

    return qualify_rollout(
        index,
        root=root or ROOT,
        source=source,
        capabilities=("main_receipts",),
        repository=reader.repository,
        api=reader.api,
    )


def activation(reader, source):
    try:
        authorize(reader, source)
    except (ValueError, ImportError, KeyError, TypeError) as error:
        return {"active": False, "reason": str(error)}
    return {"active": True, "reason": "Hosted retained-closure qualification verified"}


def sweep_receipt(reader, run, before):
    upload = qualify(reader, run)
    source = run["head_sha"]
    jobs = reader.jobs(run)
    origins = {}
    for name in APPLICATION:
        proof = job_proof(jobs, name)
        origins[name] = {
            "kind": "sweep",
            "name": name,
            "source": source,
            "head": source,
            "run": run["id"],
            "selection_upload": upload,
            "executions": {
                child: {"job": job["id"], "attempt": job["run_attempt"]}
                for child, job in proof.items()
            },
        }
    return {
        "schema": 1,
        "mode": "production",
        "repository": reader.repository,
        "source": source,
        "before": before,
        "required": REQUIRED,
        "tree": reader.get(f"git/commits/{source}")["tree"]["sha"],
        "input_identity": reader.input_identity(source),
        "jobs": origins,
        "decision": "validated",
        "reason": "Fresh qualified application sweep",
    }


def reconcile(reader, source, before, *, root=ROOT, index=None):
    """Called only inside the dedicated main-only coordinator job.

    Current-head checks bracket decisions. A completion for an old source must
    reconcile today's HEAD instead of leaving it dependent on another push.
    """
    source = require_source(source)
    authorize(reader, source, index=index, root=root)
    current = require_source(reader.get("commits/main")["sha"])
    if current != source:
        return {"source": source, "decision": "superseded", "current": current}
    proposal = reader.proposal(source, before, selected_on_push(root, before, source))
    if proposal["decision"] == "validated":
        return proposal
    sweeps = sorted(
        (
            run
            for run in reader.runs(PLATFORM, source)
            if matches_sweep(reader, run, source, "production")
        ),
        key=lambda run: run["id"],
        reverse=True,
    )
    if (
        sweeps
        and sweeps[0].get("status") == "completed"
        and sweeps[0].get("conclusion") == "cancelled"
    ):
        # A cancelled newest validation cannot promote an older green run.
        # Dispatch will also ignore active runs predating this cancellation.
        sweeps = []
    if sweeps:
        run = sweeps[0]
        scoped_run(run, reader.repository, PLATFORM, source, ("workflow_dispatch",))
        if run.get("status") != "completed":
            return {"source": source, "decision": "waiting", "run": run["id"]}
        try:
            return sweep_receipt(reader, run, before)
        except ValueError as error:
            # Retry only failed jobs, once, preserving original successful bytes.
            if (
                run.get("conclusion") in ("failure", "timed_out")
                and run.get("run_attempt") == 1
            ):
                reader.api(
                    reader.repository,
                    f"actions/runs/{run['id']}/rerun-failed-jobs",
                    "POST",
                )
                return {
                    "source": source,
                    "decision": "retry-requested",
                    "run": run["id"],
                    "reason": str(error),
                }
            return {
                "source": source,
                "decision": "failed",
                "run": run["id"],
                "reason": str(error),
            }
    dispatched = dispatch(reader, source=source, index=index, root=root)
    return {"decision": "sweep-requested", **dispatched}


def track(reader, result):
    """Stale completions cannot close or overwrite the current main's issue."""
    if result["source"] != reader.get("commits/main")["sha"]:
        return
    if result["decision"] not in ("validated", "failed", "retry-requested"):
        return
    issues = [
        row
        for row in reader.rows("issues?state=open&labels=ci-main", None)
        if "pull_request" not in row
    ]
    if result["decision"] == "validated":
        for issue in issues:
            reader.api(
                reader.repository,
                f"issues/{issue['number']}",
                "PATCH",
                {"state": "closed"},
            )
        return
    body = f"Main `{result['source']}` requires attention.\n\n" + json.dumps(
        result, indent=2
    )
    if issues:
        reader.api(
            reader.repository, f"issues/{issues[0]['number']}", "PATCH", {"body": body}
        )
    else:
        if not reader.api(reader.repository, "labels/ci-main", optional=True):
            reader.api(
                reader.repository,
                "labels",
                "POST",
                {"name": "ci-main", "color": "d73a4a"},
            )
        reader.api(
            reader.repository,
            "issues",
            "POST",
            {
                "title": "ci-main: application validation failed",
                "labels": ["ci-main"],
                "body": body,
            },
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "reconcile"))
    parser.add_argument("--source", required=True)
    parser.add_argument(
        "--output", type=Path, default=Path("main-evidence/receipt.json")
    )
    args = parser.parse_args()
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get(
        "GITHUB_EVENT_NAME"
    ) not in ("push", "workflow_run", "workflow_dispatch", "schedule"):
        raise ValueError("Coordinator requires a main-only trusted event")
    reader = Reader(os.environ["GITHUB_REPOSITORY"], mode="production")
    if args.command == "status":
        result = activation(reader, args.source)
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a") as stream:
                stream.write(f"active={str(result['active']).lower()}\n")
    else:
        # Reconcile HEAD even when an old sweep completion woke this job.
        source = require_source(reader.get("commits/main")["sha"])
        before = reader.get(f"git/commits/{source}")["parents"][0]["sha"]
        result = reconcile(reader, source, before)
        track(reader, result)
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a") as stream:
                stream.write(f"source={result['source']}\n")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
