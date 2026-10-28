#!/usr/bin/env python3
"""Check that local boundary gates and hosted workflows call the same entrypoints.

The boundary inventory names the checked-in script each command gate runs. A
workflow that never calls it means "run locally" and "hosted CI" can drift apart
without anyone noticing, so every command gate must either be referenced by a
workflow `run:` step or say why not (`local_only`). A `local_only` claim that a
workflow now contradicts is stale. Workflows are only read, never changed, and
anything that does not parse into the expected shape fails the check instead of
being skipped.

Inline test-runner invocations in workflows (`dart test`, `flutter test`, `ctest`,
`pytest`) are reported for information. They are not failures.
"""

from __future__ import annotations

import argparse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys
from typing import Any

import yaml

from tools import boundary_inventory

ROOT = Path(__file__).resolve().parents[1]
_SCRIPT = re.compile(r"(?<![\w./-])((?:tools|packaging)/[A-Za-z0-9_./-]+\.(?:py|sh))\b")
_MODULE = re.compile(r"python[\d.]*\s+-m\s+(tools\.[A-Za-z0-9_]+)")
_INLINE = re.compile(r"(?<![\w./-])(dart test|flutter test|ctest|pytest|python[\d.]* -m pytest)\b")


@dataclass(frozen=True)
class Run:
    file: str
    job: str
    step: str
    text: str


def _steps(document: Any, where: str, problems: list[str], runs: list[Run], file: str) -> None:
    if not isinstance(document, list):
        problems.append(f"{where}: steps must be a list")
        return
    for index, step in enumerate(document):
        if not isinstance(step, dict):
            problems.append(f"{where}: step {index} is not a mapping")
            continue
        if "run" in step:
            if not isinstance(step["run"], str):
                problems.append(f"{where}: step {index} has a run that is not text")
                continue
            runs.append(Run(file, where, str(step.get("name", f"step {index}")), step["run"]))


def workflow_runs(root: Path = ROOT) -> tuple[list[Run], list[str]]:
    """Every `run:` step of every workflow and composite action, and parse problems."""
    runs: list[Run] = []
    problems: list[str] = []
    files = sorted((root / ".github/workflows").glob("*.y*ml")) + sorted((root / ".github/actions").glob("**/action.y*ml"))
    if not (root / ".github/workflows").is_dir() or not files:
        return runs, ["no workflow files were found; the parity check cannot pass vacuously"]
    for path in files:
        name = path.relative_to(root).as_posix()
        try:
            document = yaml.safe_load(path.read_text())
        except yaml.YAMLError as error:
            problems.append(f"{name}: not valid YAML ({type(error).__name__})")
            continue
        if not isinstance(document, dict):
            problems.append(f"{name}: top level is not a mapping")
        elif "jobs" in document:
            if not isinstance(document["jobs"], dict):
                problems.append(f"{name}: jobs is not a mapping")
                continue
            for job, body in document["jobs"].items():
                if isinstance(body, dict) and "uses" in body and "steps" not in body:
                    continue  # a reusable-workflow call has no steps of its own
                if not isinstance(body, dict) or "steps" not in body:
                    problems.append(f"{name}: job {job} has no steps")
                    continue
                _steps(body["steps"], f"{name}:{job}", problems, runs, name)
        elif isinstance(document.get("runs"), dict):
            _steps(document["runs"].get("steps", []), f"{name}:(action)", problems, runs, name)
        else:
            problems.append(f"{name}: neither a workflow with jobs nor a composite action")
    return runs, problems


def referenced_scripts(text: str) -> set[str]:
    """Repository scripts a `run:` text calls, by path or `python -m tools.x`."""
    scripts = set(_SCRIPT.findall(text))
    scripts.update(module.replace(".", "/") + ".py" for module in _MODULE.findall(text))
    return scripts


def inline_runners(runs: Sequence[Run]) -> list[dict[str, str]]:
    return [
        {"where": run.job, "step": run.step, "runner": match}
        for run in runs
        for match in sorted(set(_INLINE.findall(run.text)))
    ]


def check(root: Path = ROOT, inventory: Mapping[str, Any] | None = None) -> dict[str, Any]:
    inventory = boundary_inventory.load(root) if inventory is None else inventory
    runs, problems = workflow_runs(root)
    referenced: dict[str, list[str]] = {}
    for run in runs:
        for script in referenced_scripts(run.text):
            referenced.setdefault(script, []).append(run.job)
            if not (root / script).is_file():
                problems.append(f"{run.job}: step {run.step!r} calls {script}, which does not exist")
    gates: dict[str, Any] = {}
    for name, gate in sorted(inventory["gates"].items()):
        if gate["kind"] != "command":
            continue
        scripts = boundary_inventory._argv_entrypoints(gate["argv"])
        called_by = sorted({job for script in scripts for job in referenced.get(script, ())})
        local_only = gate.get("local_only")
        gates[name] = {"scripts": scripts, "called_by": called_by, "local_only": local_only}
        if local_only is not None and (not isinstance(local_only, str) or not local_only.strip()):
            problems.append(f"gate {name}: local_only needs a reason")
        elif local_only is not None and called_by:
            problems.append(f"gate {name}: declared local_only but {called_by[0]} calls it; remove the stale declaration")
        elif local_only is None and not called_by:
            problems.append(f"gate {name}: no workflow calls {', '.join(scripts)}; wire it or declare local_only with a reason")
    return {"problems": problems, "gates": gates, "inline_runners": inline_runners(runs), "runs": len(runs)}


def main(argv: Sequence[str] | None = None, root: Path = ROOT) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    report = check(root)
    if arguments.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Checked {report['runs']} workflow run steps against {len(report['gates'])} command gates.")
        for problem in report["problems"]:
            print(f"- {problem}", file=sys.stderr)
    return 1 if report["problems"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
