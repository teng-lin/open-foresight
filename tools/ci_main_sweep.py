#!/usr/bin/env python3
"""Prepare isolated main sweep exercises without enabling production skipping."""

import argparse
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_main_evidence import (
    PLATFORM,
    Reader,
    require_ready,
    require_source,
    scoped_run,
)  # noqa: E402


def application_selection():
    from tools.ci_selection import application_selection as application

    return application()


def sweep_title(source, namespace):
    if namespace not in ("exercise", "production"):
        raise ValueError("Unknown sweep evidence namespace")
    return f"Main sweep {source} [{namespace}]"


def matches_sweep(reader, run, source, namespace):
    """A display title alone cannot turn another event/ref into a sweep."""
    if run.get("display_title") != sweep_title(source, namespace):
        return False
    try:
        scoped_run(run, reader.repository, PLATFORM, source, ("workflow_dispatch",))
    except ValueError:
        return False
    return True


def latest_invalidated(runs):
    return max(
        (
            run["id"]
            for run in runs
            if run.get("status") == "completed" and run.get("conclusion") != "success"
        ),
        default=0,
    )


def validation_runs(reader, source, namespace="production"):
    """Keep latest real readiness, excluding only verified successful no-op runs."""
    result = []
    for run in reader.runs(PLATFORM, source):
        if not matches_sweep(reader, run, source, namespace):
            continue
        superseded = False
        if run.get("status") == "completed" and run.get("conclusion") == "success":
            try:
                selection, _ = reader.artifact(
                    run, "ci-selection-platform", "ci-selection.json", "changes"
                )
                superseded = (
                    selection.get("superseded") is True
                    and selection.get("sweep") is True
                    and selection.get("sweep_namespace") == namespace
                    and selection.get("selection")
                    == dict.fromkeys(application_selection(), False)
                    and all(type(value) is bool for value in selection["selection"].values())
                )
            except ValueError:
                # An unverifiable newer run remains authoritative and fails
                # qualification; it must never uncover older green evidence.
                pass
        if not superseded:
            result.append(run)
    return sorted(result, key=lambda run: run["id"], reverse=True)


def guard(reader, source, current_run, *, namespace="exercise"):
    """Only already executing earlier sweeps can supersede this execution.

    Queued duplicates must not mutually skip. A completed title alone is not
    evidence: the original selection artifact and every application gate must
    qualify before it can eliminate fresh work.
    """
    require_source(source)
    if reader.get("commits/main")["sha"] != source:
        return "Source is no longer main HEAD"
    current = reader.run(current_run)
    scoped_run(current, reader.repository, PLATFORM, source, ("workflow_dispatch",))
    previous = [
        run
        for run in reader.runs(PLATFORM, source)
        if run["id"] < current_run and matches_sweep(reader, run, source, namespace)
    ]
    invalidated = latest_invalidated(previous)
    for run in previous:
        if run["id"] <= invalidated:
            continue
        if run.get("status") == "in_progress":
            try:
                selection, _ = reader.selection(run)
            except ValueError:
                continue
            if (
                selection.get("sweep") is True
                and selection.get("superseded") is False
                and selection.get("sweep_namespace") == namespace
            ):
                return "An earlier qualified sweep is executing"
        elif run.get("status") == "completed":
            try:
                qualify(reader, run, namespace=namespace)
            except ValueError:
                continue
            return "An earlier sweep already validated this source"
    return ""


def qualify(reader, run, *, namespace="production"):
    from tools import ci_release_candidates as candidate
    from tools.ci_main_evidence import job_proof, selection_jobs

    scoped_run(
        run, reader.repository, PLATFORM, run["head_sha"], ("workflow_dispatch",)
    )
    require_ready(run)
    selection, proof = reader.selection(run)
    if (
        selection.get("sweep") is not True
        or selection.get("sweep_namespace") != namespace
        or run.get("display_title") != sweep_title(run["head_sha"], namespace)
        or selection.get("selection") != application_selection()
    ):
        raise ValueError("Sweep must execute the complete application owner closure")
    jobs = reader.jobs(run)
    for name in ("platform-checks", "acceptance-checks", "workflow-lint"):
        candidate.latest(jobs, name)
    for name, required in selection_jobs(selection).items():
        if required:
            job_proof(jobs, name)
    return proof


def dispatch(reader, *, source, exercise=False, index=None, root=None):
    require_source(source)
    if not exercise:
        from tools.ci_main_coordinator import authorize

        authorize(reader, source, index=index, root=root)
    namespace = "exercise" if exercise else "production"
    if reader.get("commits/main")["sha"] != source:
        return {"source": source, "status": "superseded"}
    # This entrypoint is also used by scheduled reconciliation. The workflow's
    # repository-wide coordinator group serializes decisions, not SDK producers.
    previous = [
        run
        for run in reader.runs(PLATFORM, source)
        if matches_sweep(reader, run, source, namespace)
    ]
    invalidated = latest_invalidated(previous)
    for run in previous:
        if run["id"] > invalidated and run.get("status") in (
            "queued",
            "in_progress",
            "waiting",
            "pending",
        ):
            return {"source": source, "status": "already-active", "run": run["id"]}
    reader.api(
        reader.repository,
        "actions/workflows/macos.yml/dispatches",
        "POST",
        {
            "ref": "main",
            "inputs": {"source": source, "sweep": True, "sweep_namespace": namespace},
        },
    )
    return {
        "source": source,
        "status": "exercise-dispatched" if exercise else "dispatched",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("guard", "exercise"))
    parser.add_argument("--source", required=True)
    parser.add_argument(
        "--namespace", choices=("exercise", "production"), default="exercise"
    )
    parser.add_argument("--output", type=Path, default=Path("ci-selection.json"))
    args = parser.parse_args()
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get(
        "GITHUB_EVENT_NAME"
    ) not in ("workflow_dispatch", "schedule", "push", "workflow_run"):
        raise ValueError("Sweep control requires reviewed main controls")
    reader = Reader(os.environ["GITHUB_REPOSITORY"])
    if args.command == "exercise":
        result = dispatch(reader, source=args.source, exercise=True)
    else:
        if args.namespace == "production":
            from tools.ci_main_coordinator import authorize

            authorize(reader, args.source)
        reason = guard(
            reader,
            args.source,
            int(os.environ["GITHUB_RUN_ID"]),
            namespace=args.namespace,
        )
        selected = application_selection()
        if reason:
            selected = dict.fromkeys(selected, False)
        result = {
            "range": args.source,
            "selection": selected,
            "superseded": bool(reason),
            "sweep": True,
            "sweep_namespace": args.namespace,
            "reason": reason,
            "paths": [],
            "force": False,
        }
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a") as stream:
                stream.write(
                    "selection=" + json.dumps(selected, separators=(",", ":")) + "\n"
                )
                for name, value in selected.items():
                    stream.write(f"{name.replace('-', '_')}={str(value).lower()}\n")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
