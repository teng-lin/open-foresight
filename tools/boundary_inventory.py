#!/usr/bin/env python3
"""Machine-readable boundary inventory, reconciled against the existing inventories.

`tools/boundary_inventory.json` records each critical producer/consumer boundary,
its tests by kind, owning gate and honest gaps. This module loads it and fails on
drift against `integration_probes.json`, `integration_skips.json`,
`pytest-exclusions.json`, the registered tests it cites and the real entrypoints
its gates name. It adds no second selector: `tools.validate_change` consumes it
together with `ci_changes` and `ci_selection`.
"""

from __future__ import annotations

import argparse
import ast
from collections.abc import Sequence
from dataclasses import dataclass
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = "tools/boundary_inventory.json"
SCHEMA = 1
PLATFORMS = ("linux", "macos")
COVERAGE_KINDS = ("production-both-sides", "fixture", "static-guard", "manual")
EXECUTION_MODES = ("source-jit", "compiled", "installed", "ctest", "static")
GATE_KINDS = ("command", "ci-only", "manual")
REQUIREMENT_KINDS = ("executable", "path", "python")
LIFECYCLE_STATUSES = ("closed-production", "fixture-only", "partial", "open")
# Every class the issue names must keep at least one closure rule; removing the
# last rule of a class would silently narrow downstream selection.
REQUIRED_RULE_KINDS = (
    "schema-bindings",
    "shared-test-support",
    "native-abi",
    "runtime-config",
    "package-layout",
    "toolchain",
    "orchestration",
)
# Text that names something a closed cell does not prove. A closed cell lists no
# missing coverage, so its note must not either.
GAP_LANGUAGE = re.compile(
    r"\bnot (?:covered|exercised|tested|proven)\b|\bnever (?:exercised|covered|tested)\b"
    r"|\buntested\b|\bunproven\b|\buncovered\b|\bno tests?\b|\b(?:does|do) not cover\b"
    r"|\bnot yet (?:covered|tested|proven|exercised)\b"
    r"|\bno coverage\b|\b(?:lack|lacks|lacking) (?:any )?coverage\b|\bwithout (?:any )?coverage\b",
    re.I,
)
_PRUNE = {".git", ".venv", "build", "dist", "coverage", "test-results", ".dart_tool", "node_modules"}


def load(root: Path = ROOT) -> dict[str, Any]:
    inventory = json.loads((root / INVENTORY).read_text())
    if not isinstance(inventory, dict) or inventory.get("schema") != SCHEMA:
        raise ValueError("Unsupported boundary inventory schema")
    return inventory


def glob_match(path: str, pattern: str) -> bool:
    """Glob with `*` crossing directories; `**` is the same, kept for readability."""
    return fnmatchcase(path, pattern.replace("**", "*"))


def repo_files(root: Path = ROOT) -> list[str]:
    """Every source file, without requiring Git metadata (exports have none)."""
    found: list[str] = []
    for directory, names, files in os.walk(root):
        names[:] = [name for name in names if name not in _PRUNE]
        base = Path(directory).relative_to(root)
        found.extend((base / name).as_posix() for name in files)
    return sorted(found)


@dataclass(frozen=True)
class Registered:
    """A registered Dart test name; interpolated names match as templates."""

    text: str
    pattern: re.Pattern[str] | None

    def matches(self, name: str) -> bool:
        if self.pattern is None:
            return self.text == name
        return self.pattern.fullmatch(name) is not None


_ESCAPES = {"n": "\n", "t": "\t", "r": "\r"}
_WORD = re.compile(r"[A-Za-z_$][\w$]*")
_SKIP_NAMES = {"skip", "skipif", "skipIf", "skipUnless", "skipTest", "importorskip", "SkipTest"}


def _skip_quoted(text: str, index: int) -> int:
    """Index after a nested quoted string that starts at `index`."""
    quote = text[index]
    index += 1
    while index < len(text) and text[index] != quote:
        index += 2 if text[index] == "\\" else 1
    return index + 1


def _literal(text: str, index: int) -> tuple[str, re.Pattern[str] | None, int] | None:
    """Parse one Dart string literal; return plain text, template regex and end."""
    raw = text.startswith("r", index) and index + 1 < len(text) and text[index + 1] in "'\""
    if raw:
        index += 1
    if index >= len(text) or text[index] not in "'\"":
        return None
    quote = text[index]
    terminator = quote * 3 if text.startswith(quote * 3, index) else quote
    index += len(terminator)
    plain: list[str] = []
    regex: list[str] = []
    interpolated = False
    while index < len(text) and not text.startswith(terminator, index):
        char = text[index]
        if char == "\\" and not raw and index + 1 < len(text):
            literal = _ESCAPES.get(text[index + 1], text[index + 1])
            plain.append(literal)
            regex.append(re.escape(literal))
            index += 2
        elif char == "$" and not raw and index + 1 < len(text) and text[index + 1] == "{":
            depth = 1
            index += 2
            while index < len(text) and depth:
                if text[index] in "'\"":
                    index = _skip_quoted(text, index)
                    continue
                depth += {"{": 1, "}": -1}.get(text[index], 0)
                index += 1
            interpolated = True
            regex.append(".+?")
        elif char == "$" and not raw and index + 1 < len(text) and (text[index + 1].isalpha() or text[index + 1] == "_"):
            index += 1
            while index < len(text) and (text[index].isalnum() or text[index] == "_"):
                index += 1
            interpolated = True
            regex.append(".+?")
        else:
            plain.append(char)
            regex.append(re.escape(char))
            index += 1
    return "".join(plain), (re.compile("".join(regex), re.S) if interpolated else None), index + len(terminator)


def _name_at(text: str, index: int) -> tuple[Registered, int] | None:
    """The test name whose adjacent string literals begin at `index`."""
    plain = ""
    regex = ""
    interpolated = False
    parsed = _literal(text, index)
    if parsed is None:
        return None
    while parsed is not None:
        part, pattern, index = parsed
        plain += part
        regex += pattern.pattern if pattern else re.escape(part)
        interpolated = interpolated or pattern is not None
        while index < len(text) and text[index].isspace():
            index += 1
        parsed = _literal(text, index)
    return Registered(plain, re.compile(regex, re.S) if interpolated else None), index


def scan_dart(text: str) -> tuple[list[Registered], bool]:
    """Registered test names and whether any skip marker exists, outside comments and strings."""
    found: list[Registered] = []
    skippable = False
    index = 0
    size = len(text)
    while index < size:
        char = text[index]
        if text.startswith("//", index):
            end = text.find("\n", index)
            index = size if end < 0 else end
        elif text.startswith("/*", index):
            depth = 1
            index += 2
            while index < size and depth:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        elif char in "'\"":
            parsed = _literal(text, index)
            index = parsed[2] if parsed else index + 1
        elif char == "@" and text.startswith("@Skip", index):
            skippable = True
            index += 5
        elif (word := _WORD.match(text, index)) is not None:
            name, end = word.group(), word.end()
            after = end
            while after < size and text[after].isspace():
                after += 1
            if name == "r" and end < size and text[end] in "'\"":
                parsed = _literal(text, index)
                index = parsed[2] if parsed else end
                continue
            if name == "markTestSkipped" or (name == "skip" and text.startswith(":", after)):
                skippable = True
            elif name in ("test", "testWidgets") and text.startswith("(", after) and (index == 0 or text[index - 1] != "."):
                named = _name_at(text, _past_space(text, after + 1))
                if named is not None:
                    found.append(named[0])
            index = end
        else:
            index += 1
    return found, skippable


def _past_space(text: str, index: int) -> int:
    while index < len(text) and text[index].isspace():
        index += 1
    return index


def dart_registered_tests(text: str) -> list[Registered]:
    """Names of `test(`/`testWidgets(` calls, including adjacent-literal names."""
    return scan_dart(text)[0]


def _has_skip(node: ast.AST) -> bool:
    return any(
        (isinstance(child, ast.Attribute) and child.attr in _SKIP_NAMES)
        or (isinstance(child, ast.Name) and child.id in _SKIP_NAMES)
        for child in ast.walk(node)
    )


_SETUP_NAMES = {"setUp", "setUpClass", "setup_method", "setup_class", "setup_module", "setUpModule"}


def _python_tests(text: str) -> dict[str, bool]:
    """Test function name to whether it can skip.

    A test can skip through its own decorators or body, its class's decorators,
    class-level markers or setup methods, or module-level markers and calls.
    Skips raised inside pytest fixtures are not detected.
    """
    try:
        tree = ast.parse(text)
    except SyntaxError as error:
        raise ValueError(f"Python source does not parse: {error}") from error
    tests: dict[str, bool] = {}
    definitions = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
    module_skips = any(_has_skip(node) for node in tree.body if not isinstance(node, definitions) and not isinstance(node, (ast.Import, ast.ImportFrom)))

    def visit(body: Sequence[ast.stmt], inherited: bool) -> None:
        for node in body:
            if isinstance(node, ast.ClassDef):
                members = [item for item in node.body if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))]
                level = (
                    inherited
                    or any(_has_skip(decorator) for decorator in node.decorator_list)
                    or any(_has_skip(item) for item in node.body if not isinstance(item, definitions))
                    or any(_has_skip(item) for item in members if item.name in _SETUP_NAMES)
                )
                visit(node.body, level)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_"):
                tests[node.name] = tests.get(node.name, False) or inherited or _has_skip(node)

    visit(tree.body, module_skips)
    return tests


def python_registered_tests(text: str) -> set[str]:
    return set(_python_tests(text))


def is_registered(root: Path, path: str, name: str) -> bool:
    """Whether `name` is registered in `path`; parametrization ids are ignored."""
    source = (root / path).read_text()
    if path.endswith(".py"):
        return name.split("[", 1)[0] in python_registered_tests(source)
    if path.endswith(".dart"):
        return any(entry.matches(name) for entry in dart_registered_tests(source))
    return False


def can_skip(root: Path, path: str, names: Sequence[str] = ()) -> bool:
    """Whether the cited tests (or any test in the file) carry a skip marker.

    Dart markers are file-level; fixture-based pytest skips are not detected.
    """
    source = (root / path).read_text()
    if path.endswith(".dart"):
        return scan_dart(source)[1]
    if path.endswith(".py"):
        tests = _python_tests(source)
        chosen = [tests.get(name.split("[", 1)[0], False) for name in names] if names else list(tests.values())
        return any(chosen)
    return False


def _argv_entrypoints(argv: list[str]) -> list[str]:
    """Repo files an argv names as its executable script or `-m` module."""
    files = []
    for index, argument in enumerate(argv):
        if argument == "-m" and index + 1 < len(argv):
            files.append(argv[index + 1].replace(".", "/") + ".py")
        elif re.fullmatch(r"tools/[\w./-]+\.(?:py|sh)", argument):
            files.append(argument)
    return files


def verify(root: Path = ROOT) -> dict[str, Any]:
    """Return counts, or raise ValueError listing every inconsistency."""
    from tools import check_integration_inventory

    inventory = load(root)
    errors: list[str] = []
    files = set(repo_files(root))
    probes = {entry["path"]: entry for entry in json.loads((root / "tools/integration_probes.json").read_text())["entries"]}
    skips = {entry["path"]: entry for entry in json.loads((root / "tools/integration_skips.json").read_text())["entries"]}
    exclusions = json.loads((root / "pytest-exclusions.json").read_text())
    owners = inventory.get("owners", {})
    gates = inventory.get("gates", {})
    boundaries = inventory.get("boundaries", [])

    def fail(message: str) -> None:
        errors.append(message)

    for name, gate in gates.items():
        kind = gate.get("kind")
        if kind not in GATE_KINDS:
            fail(f"gate {name}: invalid kind {kind!r}")
            continue
        if not set(gate.get("platforms", ())) <= set(PLATFORMS) or not gate.get("platforms"):
            fail(f"gate {name}: platforms must be a non-empty subset of {PLATFORMS}")
        if not gate.get("title") or not gate.get("doc") or not gate.get("certifies"):
            fail(f"gate {name}: title, doc and certifies are required")
        if gate.get("scope", "host") not in ("host", "neutral"):
            fail(f"gate {name}: scope must be host or neutral")
        if type(gate.get("long")) is not bool:
            fail(f"gate {name}: long must be a boolean")
        if kind == "command":
            argv = gate.get("argv")
            if not argv or not all(isinstance(token, str) for token in argv):
                fail(f"gate {name}: argv must be a non-empty string list")
                continue
            for script in _argv_entrypoints(argv):
                if script not in files:
                    fail(f"gate {name}: entrypoint {script} does not exist")
            timeout = gate.get("timeout_seconds")
            if type(timeout) is not int or timeout <= 0:
                fail(f"gate {name}: timeout_seconds must be a positive integer")
            for requirement in gate.get("requires", ()):
                if requirement.get("kind") not in REQUIREMENT_KINDS:
                    fail(f"gate {name}: invalid requirement {requirement!r}")
                for producer in requirement.get("produced_by", ()):
                    if producer not in gates:
                        fail(f"gate {name}: unknown producer gate {producer}")
            for subsumed in gate.get("subsumes", ()):
                if subsumed not in gates:
                    fail(f"gate {name}: unknown subsumed gate {subsumed}")
            if gate["doc"].split("#", 1)[0] not in files:
                fail(f"gate {name}: doc {gate['doc']} does not exist")
        elif not gate.get("requirement", "").strip():
            fail(f"gate {name}: a {kind} gate needs an explicit requirement")

    from tools import ci_changes

    mapping = inventory.get("ci_gate_map", {})
    if set(mapping) != set(ci_changes.GATES):
        fail("ci_gate_map must name exactly the CI selection gates " + ", ".join(ci_changes.GATES))
    for ci_gate, entry in mapping.items():
        if entry.get("platform") not in PLATFORMS:
            fail(f"ci_gate_map {ci_gate}: invalid platform")
        for name in entry.get("gates", ()):
            if name not in gates:
                fail(f"ci_gate_map {ci_gate}: unknown gate {name}")
        if not entry.get("gates"):
            fail(f"ci_gate_map {ci_gate}: a CI gate needs a local equivalent or an explicit ci-only gate")

    from tools import ci_selection

    # ci_selection can require jobs that are not CI selection gates (acceptance
    # jobs, linux-native); each must map to a local, ci-only or manual gate.
    job_map = inventory.get("ci_job_map", {})
    extra_jobs = set(ci_selection.ACCEPTANCE) | {"linux-native"}
    if set(job_map) != extra_jobs:
        fail("ci_job_map must name exactly " + ", ".join(sorted(extra_jobs)))
    for job, entry in job_map.items():
        if entry.get("platform") not in PLATFORMS or not entry.get("gates"):
            fail(f"ci_job_map {job}: needs a platform and at least one gate")
        for name in entry.get("gates", ()):
            if name not in gates:
                fail(f"ci_job_map {job}: unknown gate {name}")
    every_job = set()
    for tier in ("", "pr", "release"):
        every_job.update(ci_selection.required_jobs(dict.fromkeys(ci_changes.GATES, True), tier=tier))
    for job in sorted(every_job - set(mapping) - set(job_map)):
        fail(f"required CI job {job} maps to no gate")

    ids = [boundary.get("id") for boundary in boundaries]
    if len(ids) != len(set(ids)) or not all(ids):
        fail("boundary ids must be present and unique")
    mapped_probes: set[str] = set()
    mapped_exclusions: set[str] = set()
    for boundary in boundaries:
        label = f"boundary {boundary.get('id')}"
        for field in ("title", "producer", "consumer"):
            if not str(boundary.get(field, "")).strip():
                fail(f"{label}: {field} is required")
        if not boundary.get("invariants"):
            fail(f"{label}: invariants are required")
        if boundary.get("owner") not in owners:
            fail(f"{label}: unknown owner {boundary.get('owner')!r}")
        if not boundary.get("prerequisites"):
            fail(f"{label}: prerequisites are required")
        if not boundary.get("execution_modes") or not set(boundary["execution_modes"]) <= set(EXECUTION_MODES):
            fail(f"{label}: execution_modes must be a non-empty subset of {EXECUTION_MODES}")
        if not boundary.get("platforms") or not set(boundary["platforms"]) <= set(PLATFORMS):
            fail(f"{label}: platforms must be a non-empty subset of {PLATFORMS}")
        for gate_name in (boundary.get("gate"), *boundary.get("also_gates", ())):
            if gate_name not in gates:
                fail(f"{label}: unknown gate {gate_name!r}")
        evidence = boundary.get("evidence", [])
        if not evidence:
            fail(f"{label}: evidence is required")
        if not any(entry.get("kind") == "production-both-sides" for entry in evidence) and not boundary.get("gaps"):
            fail(f"{label}: no production-both-sides evidence requires an explicit gap statement")
        for trigger in boundary.get("triggers", ()):
            if not any(glob_match(name, trigger) for name in files):
                fail(f"{label}: trigger {trigger} matches no file")
        for entry in evidence:
            path = entry.get("path", "")
            where = f"{label}: {path}"
            if entry.get("kind") not in COVERAGE_KINDS:
                fail(f"{where}: invalid kind {entry.get('kind')!r}")
            if path not in files:
                fail(f"{where}: file does not exist")
                continue
            for name in entry.get("names", ()):
                if not is_registered(root, path, name):
                    fail(f"{where}: test {name!r} is not registered")
            gate = skips.get(path, {}).get("gate")
            declared = entry.get("skip_gate")
            if gate is not None:
                if declared != gate:
                    fail(f"{where}: skip_gate {declared!r} must equal the skip inventory gate {gate!r}")
            elif declared is not None and declared not in gates:
                # A runtime skip (markTestSkipped, pytest.skip, unittest.skipUnless) is declared
                # with the inventory gate whose run must report it.
                fail(f"{where}: skip_gate {declared!r} is not an inventory gate")
            if path.endswith((".py", ".dart")) and entry.get("kind") != "manual":
                try:
                    skippable = can_skip(root, path, entry.get("names", ()))
                except ValueError as error:
                    fail(f"{where}: {error}")
                    skippable = False
                if skippable and not declared:
                    fail(f"{where}: carries a skip marker, so the entry must declare its skip_gate")
            if gate is not None and gate not in check_integration_inventory.GATES:
                fail(f"{where}: skip inventory gate {gate!r} is unknown")
            if bool(entry.get("excluded")) != (path in exclusions):
                fail(f"{where}: excluded must be true exactly for pytest-exclusions.json entries")
            if path in exclusions:
                mapped_exclusions.add(path)
            probe = probes.get(path)
            if probe is not None:
                mapped_probes.add(path)
                if (entry.get("kind") == "manual") != (probe["mode"] == "manual"):
                    fail(f"{where}: probe mode {probe['mode']!r} contradicts evidence kind {entry.get('kind')!r}")
            elif entry.get("kind") == "manual" and path not in exclusions:
                fail(f"{where}: manual evidence must be a manual probe or an explicitly run excluded module")

    for path in probes:
        if path not in mapped_probes and not str(inventory.get("unmapped_probes", {}).get(path, "")).strip():
            fail(f"probe {path} is mapped by no boundary and has no unmapped_probes reason")
    for path in exclusions:
        if path not in mapped_exclusions and not str(inventory.get("unmapped_exclusions", {}).get(path, "")).strip():
            fail(f"pytest exclusion {path} is mapped by no boundary and has no unmapped_exclusions reason")
    for kind in ("unmapped_probes", "unmapped_exclusions"):
        known = probes if kind == "unmapped_probes" else exclusions
        for path in inventory.get(kind, {}):
            if path not in known:
                fail(f"{kind} names {path}, which is not in its source inventory")

    rule_ids = []
    boundary_ids = set(ids)
    for rule in inventory.get("impact_rules", ()):
        rule_ids.append(rule.get("id"))
        label = f"impact rule {rule.get('id')}"
        if not rule.get("reason", "").strip():
            fail(f"{label}: reason is required")
        for name in rule.get("boundaries", ()):
            if name != "*" and name not in boundary_ids:
                fail(f"{label}: unknown boundary {name}")
        for name in rule.get("gates", ()):
            if name not in gates:
                fail(f"{label}: unknown gate {name}")
        for pattern in rule.get("globs", ()):
            if not any(glob_match(name, pattern) for name in files):
                fail(f"{label}: glob {pattern} matches no file")
    if len(rule_ids) != len(set(rule_ids)):
        fail("impact rule ids must be unique")
    present = {rule.get("kind") for rule in inventory.get("impact_rules", ())}
    for kind in REQUIRED_RULE_KINDS:
        if kind not in present:
            fail(f"impact rules must keep a {kind} closure rule")

    for cell in inventory.get("lifecycle_reconciliation", ()):
        label = f"lifecycle {cell.get('boundary')} / {cell.get('transition')}"
        owner = next((boundary for boundary in boundaries if boundary.get("id") == cell.get("boundary_id")), None)
        if owner is None:
            fail(f"{label}: boundary_id {cell.get('boundary_id')!r} is not an inventory boundary")
        status = cell.get("status")
        evidence = cell.get("evidence", [])
        if status not in LIFECYCLE_STATUSES:
            fail(f"{label}: invalid status {status!r}")
        if status == "open" and evidence:
            fail(f"{label}: an open cell cannot cite evidence")
        if status != "open" and not evidence:
            fail(f"{label}: {status} requires evidence")
        if status == "closed-production":
            if cell.get("missing"):
                fail(f"{label}: a closed cell cannot list missing coverage")
            gap_language = GAP_LANGUAGE.search(str(cell.get("note") or ""))
            if gap_language:
                fail(f"{label}: a closed cell's note names a gap ({gap_language.group(0)!r}); list it in missing")
            backed = [entry for entry in evidence if "production both" in str(entry.get("sides", "")).lower()]
            if not backed:
                fail(f"{label}: a closed cell needs evidence whose sides say production both")
            for entry in backed:
                # The cell's claim must agree with the evidence of the cell's own boundary: a registered test
                # that only an unrelated boundary lists proves nothing about this one.
                if owner is not None and not any(
                    item["kind"] == "production-both-sides"
                    and item["path"] == entry.get("path")
                    and entry.get("test") in item.get("names", ())
                    for item in owner.get("evidence", ())
                ):
                    fail(f"{label}: {entry.get('test')!r} is not listed as production-both-sides evidence by boundary {owner['id']}")
        elif not str(cell.get("missing") or "").strip():
            fail(f"{label}: {status} must say what is missing")
        for entry in evidence:
            path = entry.get("path", "")
            if path not in files:
                fail(f"{label}: {path} does not exist")
            elif not is_registered(root, path, entry.get("test", "")):
                fail(f"{label}: test {entry.get('test')!r} is not registered in {path}")
            if not entry.get("sides"):
                fail(f"{label}: evidence must say which side is production")

    if errors:
        raise ValueError("Boundary inventory drift:\n- " + "\n- ".join(errors))
    return {
        "boundaries": len(boundaries),
        "gates": len(gates),
        "impact_rules": len(rule_ids),
        "lifecycle_cells": len(inventory.get("lifecycle_reconciliation", ())),
        "probes_mapped": len(mapped_probes),
        "exclusions_mapped": len(mapped_exclusions),
        "evidence_entries": sum(len(boundary["evidence"]) for boundary in boundaries),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--json", action="store_true", help="print the verified counts as JSON")
    arguments = parser.parse_args(argv)
    try:
        summary = verify(arguments.root.resolve())
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    print(json.dumps(summary, sort_keys=True) if arguments.json else "Boundary inventory is consistent: " + json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
