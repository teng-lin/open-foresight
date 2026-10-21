#!/usr/bin/env python3
"""Observe conservative acceptance selection without authorizing any test skips."""

import argparse
from datetime import datetime
import hashlib
import json
import os
import sys
from pathlib import Path, PurePosixPath
import subprocess
import re

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
PHASES = ("cpu-models", "software-gpu", "virtual-audio")
FAILURE_BASELINE = "tests/fixtures/ci-acceptance-failures-20261020.json"
# These are suite entry points, not a claim that their production dependencies
# are disjoint. Shared runtime/application inputs and unknown paths select all.
SUITE_INPUTS = {
    "cpu-models": {
        "apps/desktop/test/integration_test.dart",
        "apps/desktop/test/native_load_test.dart",
        "apps/desktop/test/meeting_citation_test.dart",
        "apps/desktop/test/google_real_helper_test.dart",
        "apps/desktop/test/gemma_native_test.dart",
        "packages/foresight_core/test/web_model_test.dart",
    },
    "software-gpu": {"tools/accept_software_gpu.py"},
    "virtual-audio": {
        "apps/desktop/test/live_recording_test.dart",
        "apps/desktop/test/live_gap_recording_test.dart",
        "apps/desktop/integration_test/meeting_workflow_test.dart",
        "packages/foresight_core/test/recording_pipewire_test.dart",
    },
}
EDITORIAL_FILES = {"README.md", "CHANGELOG.md", "AGENTS.md"}
QUALITY_FILES = {
    ".coveragerc",
    "pytest.ini",
    "pytest-exclusions.json",
    "pyproject.toml",
    "requirements-format.lock",
    ".github/workflows/quality.yml",
}


def plan(paths, event="pull_request", fallback=None):
    """Explain a proposal; executed phases always remain the full current set."""
    reasons: dict[str, list[str]] = {phase: [] for phase in PHASES}
    if event != "pull_request" or fallback:
        reason = fallback or f"{event}: full acceptance backstop"
        reasons = {phase: [reason] for phase in PHASES}
    else:
        for name in sorted(set(paths)):
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or not name:
                for entries in reasons.values():
                    entries.append(f"{name!r}: unrecognized path; select all")
                continue
            if name in EDITORIAL_FILES | QUALITY_FILES or name.startswith(
                ("docs/", ".github/ISSUE_TEMPLATE/")
            ):
                continue
            suites = [phase for phase, inputs in SUITE_INPUTS.items() if name in inputs]
            for phase in suites or PHASES:
                reasons[phase].append(
                    f"{name}: suite entry point"
                    if suites
                    else f"{name}: shared or unaudited dependency; select all"
                )
    return {
        "schema": 1,
        "mode": "observe-only",
        "event": event,
        "changed_paths": sorted(set(paths)),
        "proposed": {phase: bool(entries) for phase, entries in reasons.items()},
        "reasons": reasons,
        "execution_policy": "Run every existing phase whenever acceptance is selected",
        "permits_skipping": False,
    }


def changed_paths(root, base):
    """Keep both sides of renames/deletions; fail safe when history is absent."""
    result = subprocess.check_output(
        ["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...HEAD"],
        cwd=root,
        timeout=30,
    )
    return [name for name in result.decode().split("\0") if name]


def activate(result, *, source, repository, force=False, capability=None, activation=None):
    """Only PR observations may narrow after actual four-week hosted proof."""
    if result["event"] != "pull_request" or force:
        result["executed"] = dict.fromkeys(PHASES, True)
        return result
    reason = "Verified selection report unavailable"
    qualified = False
    if activation is not None:
        decision = activation.get("acceptance_narrowing", {})
        qualified = decision.get("active") is True
        reason = decision.get("reason", "Acceptance narrowing is not qualified")
    elif capability is not None:
        try:
            capability("acceptance_narrowing", source, repository=repository)
        except (ValueError, KeyError, TypeError, subprocess.SubprocessError, RuntimeError, OSError) as error:
            reason = f"{type(error).__name__}: {error}"
        else:
            qualified = True
    if qualified:
        result.update(mode="qualified", permits_skipping=True, executed=result["proposed"], execution_policy="Execute qualified selected phases; packaging acceptance remains required")
    else:
        result["activation_reason"] = reason
        result["executed"] = dict.fromkeys(PHASES, True)
    return result


def failure_baseline(root=ROOT):
    """The reviewed source pins historical observations independently of output."""
    path = root / FAILURE_BASELINE
    raw = path.read_bytes()
    expected = path.with_suffix(".sha256").read_text().split()[0]
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("Frozen acceptance failure baseline checksum mismatch")
    value = json.loads(raw)
    if (
        value.get("schema") != 1
        or value.get("repository") != "teng-lin/open-foresight"
        or value.get("since") != "2026-10-12T00:00:00Z"
        or value.get("complete") is not True
        or not value.get("failures")
    ):
        raise ValueError("Incomplete frozen acceptance failure baseline")
    return value, expected


def startup_guard(failure):
    """A proven workflow-startup failure executed no narrowable phase."""
    from tools.ci_acceptance_history import WORKFLOWS

    proof = failure.get("startup_proof", {})
    return (
        isinstance(proof, dict)
        and proof.get("workflow") in WORKFLOWS
        and failure.get("classification") == "workflow-startup-no-jobs"
        and failure.get("job") == 0
        and failure.get("conclusion") == "startup_failure"
        and failure.get("failed_steps") == []
        and failure.get("paths") == []
        and failure.get("required_phases") == []
        and failure.get("source") == failure.get("head")
        and failure.get("range") == {"kind": "workflow-startup-no-jobs"}
        and failure.get("startup_proof") == {
            "run": failure.get("run"), "attempt": failure.get("attempt"),
            "conclusion": "startup_failure", "status": "completed",
            "job_count": 0, "workflow": proof.get("workflow"),
        }
    )


def replay(inventory, *, inventory_sha256, root=ROOT):
    """Replay independently observed failures, never proposed phase labels."""
    baseline, expected = failure_baseline(root)
    if (
        inventory.get("schema") != 1
        or inventory.get("repository") != baseline["repository"]
        or inventory.get("since") != baseline["since"]
        or inventory.get("complete") is not True
        or inventory.get("baseline_sha256") != expected
        or inventory.get("baseline_count") != len(baseline["failures"])
    ):
        raise ValueError(
            "Acceptance failure inventory is incomplete or has another baseline"
        )
    ending = datetime.fromisoformat(inventory["until"].replace("Z", "+00:00"))
    if ending.tzinfo is None or ending < datetime.fromisoformat(
        baseline["until"].replace("Z", "+00:00")
    ):
        raise ValueError("Acceptance failure inventory cutoff predates its baseline")
    entries = inventory.get("failures", [])
    indexed = {row["id"]: row for row in entries}
    if len(indexed) != len(entries) or any(
        indexed.get(row["id"]) != row for row in baseline["failures"]
    ):
        raise ValueError(
            "Original acceptance failure observations were removed or changed"
        )
    rows = []
    for failure in entries:
        required = failure.get("required_phases")
        paths = failure.get("paths")
        evidence = failure.get("range", {})
        unresolved = bool(failure.get("unresolved"))
        outer_guard = startup_guard(failure)
        if (
            not isinstance(required, list)
            or (not required and not outer_guard)
            or len(set(required)) != len(required)
            or not set(required).issubset(PHASES)
            or not isinstance(paths, list)
            or any(not isinstance(path, str) for path in paths)
        ):
            unresolved = True
        if failure.get("event") == "pull_request" and not outer_guard and (
            any(
                not re.fullmatch(r"[a-f0-9]{40}", str(evidence.get(key, "")))
                for key in ("base", "head", "merge_base")
            )
            or type(evidence.get("proof_job")) is not int
            or evidence.get("proof_job", 0) < 1
        ):
            unresolved = True
        if any(
            type(failure.get(key)) is not int or failure[key] < minimum
            for key, minimum in (("run", 1), ("attempt", 1), ("job", 0))
        ) or any(
            not re.fullmatch(r"[a-f0-9]{40}", str(failure.get(key, "")))
            for key in ("head", "source")
        ):
            unresolved = True
        if failure.get("event") == "pull_request" and not outer_guard and (
            evidence.get("head") != failure.get("source")
            or type(evidence.get("proof_attempt")) is not int
            or evidence.get("proof_attempt") != failure.get("attempt")
        ):
            unresolved = True
        if failure.get("event") not in (
            "pull_request",
            "push",
            "schedule",
            "workflow_dispatch",
            "workflow_run",
            "release",
        ):
            unresolved = True
        proposed = plan(paths or [], failure.get("event", "pull_request"))["proposed"]
        misses = (
            [
                phase
                for phase in required
                if phase not in proposed or not proposed[phase]
            ]
            if isinstance(required, list)
            else list(PHASES)
        )
        rows.append(
            {
                "id": failure["id"],
                "source": failure.get("source"),
                "required_phases": required,
                "proposed": proposed,
                "misses": misses,
                "unresolved": unresolved,
                "outer_guard": outer_guard,
            }
        )
    return {
        "schema": 2,
        "repository": baseline["repository"],
        "baseline_sha256": expected,
        "baseline_count": len(baseline["failures"]),
        "inventory_sha256": inventory_sha256,
        "count": len(rows),
        "outer_guard_count": sum(row["outer_guard"] for row in rows),
        "phase_failure_count": sum(not row["outer_guard"] for row in rows),
        "miss_count": sum(len(row["misses"]) for row in rows),
        "unresolved_count": sum(row["unresolved"] for row in rows),
        "coverage": {
            "since": inventory["since"],
            "until": inventory["until"],
            "complete": True,
        },
        "failures": rows,
    }


def verify_replay_summary(value, *, root=ROOT, run_started=None, uploaded=None):
    baseline, expected = failure_baseline(root)
    if (
        not isinstance(value, dict)
        or value.get("schema") != 2
        or value.get("baseline_sha256") != expected
        or value.get("baseline_count") != len(baseline["failures"])
        or type(value.get("count")) is not int
        or value["count"] < len(baseline["failures"])
        or any(type(value.get(key)) is not int or value[key] < sum(startup_guard(row) if key == "outer_guard_count" else not startup_guard(row) for row in baseline["failures"]) for key in ("outer_guard_count", "phase_failure_count"))
        or value.get("outer_guard_count", -1) + value.get("phase_failure_count", -1) != value.get("count")
        or any(
            type(value.get(key)) is not int or value[key] != 0
            for key in ("miss_count", "unresolved_count")
        )
        or any(
            not re.fullmatch(r"[a-f0-9]{64}", str(value.get(key, "")))
            for key in ("inventory_sha256", "sha256")
        )
    ):
        raise ValueError("Acceptance replay lacks zero-miss original failure evidence")
    coverage = value.get("coverage", {})
    if (
        not isinstance(coverage, dict)
        or coverage.get("complete") is not True
        or coverage.get("since") != baseline["since"]
    ):
        raise ValueError("Acceptance replay lacks complete historical coverage")
    ending = datetime.fromisoformat(coverage["until"].replace("Z", "+00:00"))
    beginning = datetime.fromisoformat(baseline["until"].replace("Z", "+00:00"))
    if (
        ending.tzinfo is None
        or ending < beginning
        or (
            run_started
            and ending < datetime.fromisoformat(run_started.replace("Z", "+00:00"))
        )
        or (
            uploaded
            and ending > datetime.fromisoformat(uploaded.replace("Z", "+00:00"))
        )
    ):
        raise ValueError(
            "Acceptance replay does not cover the actual qualification cutoff"
        )
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--event", default="pull_request")
    parser.add_argument("--activate", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--replay", type=Path)
    parser.add_argument("--sha256")
    parser.add_argument("--selection-report", type=Path)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.replay:
        raw = args.replay.read_bytes()
        if hashlib.sha256(raw).hexdigest() != args.sha256:
            raise ValueError("Acceptance replay checksum mismatch")
        result = replay(json.loads(raw), inventory_sha256=args.sha256, root=args.root)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, sort_keys=True) + "\n")
        if result["miss_count"] or result["unresolved_count"]:
            raise ValueError(
                "Acceptance replay found missed phases or unresolved evidence; retain its diagnostics"
            )
        return
    paths, fallback = [], None
    if args.event == "pull_request":
        if not args.base or not args.base.strip("0"):
            fallback = "Missing PR base: select all"
        else:
            try:
                paths = changed_paths(args.root, args.base)
            except (
                OSError,
                subprocess.CalledProcessError,
                subprocess.TimeoutExpired,
                UnicodeError,
            ):
                fallback = "Cannot read complete PR diff: select all"
    result = plan(paths, args.event, fallback)
    activation = {}
    if args.selection_report:
        verified = json.loads(args.selection_report.read_text())
        args.force = args.force or verified["force"]
        if verified.get("activation_source") == os.environ.get(
            "GITHUB_SHA"
        ) and verified.get("activation_repository") == os.environ.get(
            "GITHUB_REPOSITORY"
        ):
            activation = verified.get("activation", {})
    if args.activate:
        result = activate(
            result,
            source=os.environ["GITHUB_SHA"],
            repository=os.environ["GITHUB_REPOSITORY"],
            force=args.force,
            activation=activation,
        )
    if args.selection_report:
        selection = json.loads(args.selection_report.read_text())
        selection["acceptance_phases"] = result.get(
            "executed", dict.fromkeys(PHASES, True)
        )
        args.selection_report.write_text(
            json.dumps(selection, sort_keys=True, indent=2) + "\n"
        )
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for phase, selected in result.get(
                "executed", dict.fromkeys(PHASES, True)
            ).items():
                stream.write(
                    phase.replace("-", "_") + "=" + str(selected).lower() + "\n"
                )
            stream.write(
                "acceptance_phases="
                + json.dumps(
                    result.get("executed", dict.fromkeys(PHASES, True)),
                    separators=(",", ":"),
                )
                + "\n"
            )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
