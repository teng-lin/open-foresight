#!/usr/bin/env python3
"""Observe conservative acceptance selection without authorizing any test skips."""

import argparse
import json
import os
import sys
from pathlib import Path, PurePosixPath
import subprocess

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
PHASES = ("cpu-models", "software-gpu", "virtual-audio")
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


def activate(result, *, source, repository, force=False, capability=None):
    """Only PR observations may narrow after actual four-week hosted proof."""
    if result["event"] != "pull_request" or force:
        result["executed"] = dict.fromkeys(PHASES, True)
        return result
    if capability is None:
        from tools.ci_qualification_index import capability
    try:
        capability("acceptance_narrowing", source, repository=repository)
    except (ValueError, KeyError, TypeError) as error:
        result["activation_reason"] = str(error)
        result["executed"] = dict.fromkeys(PHASES, True)
    else:
        result.update(mode="qualified", permits_skipping=True, executed=result["proposed"], execution_policy="Execute qualified selected phases; packaging acceptance remains required")
    return result


def replay(inventory):
    """Freeze the complete changed-path inventory behind acceptance qualification."""
    from tools import ci_selection
    selected = ci_selection.replay(inventory)
    rows = [{"number": pr["number"], "plan": plan(pr["paths"])} for pr in selected["prs"]]
    return {"count": len(rows), "known_escapes": sorted(ci_selection.KNOWN_ESCAPES), "prs": rows}


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
        import hashlib
        if hashlib.sha256(args.replay.read_bytes()).hexdigest() != args.sha256:
            raise ValueError("Acceptance replay checksum mismatch")
        result = replay(json.loads(args.replay.read_text()))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, sort_keys=True) + "\n")
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
    if args.selection_report:
        args.force = args.force or json.loads(args.selection_report.read_text())["force"]
    if args.activate:
        result = activate(result, source=os.environ["GITHUB_SHA"], repository=os.environ["GITHUB_REPOSITORY"], force=args.force)
    if args.selection_report:
        selection = json.loads(args.selection_report.read_text())
        selection["acceptance_phases"] = result.get("executed", dict.fromkeys(PHASES, True))
        args.selection_report.write_text(json.dumps(selection, sort_keys=True, indent=2) + "\n")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for phase, selected in result.get("executed", dict.fromkeys(PHASES, True)).items():
                stream.write(phase.replace("-", "_") + "=" + str(selected).lower() + "\n")
            stream.write("acceptance_phases=" + json.dumps(result.get("executed", dict.fromkeys(PHASES, True)), separators=(",", ":")) + "\n")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
