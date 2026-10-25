#!/usr/bin/env python3
"""Check architecture documentation facts against the public registries.

The only authorities are the explicit registry/schema sources listed in
``SOURCES``. Application/service composition and value-supply code are never
parsed. Facts are derived textually from the Dart sources; this is not a Dart
parser and it fails closed when an expected declaration shape is missing.

Usage: python3 tools/check_architecture_facts.py [--root DIR] [--json]
Exit status: 0 consistent, 1 documentation drift, 2 missing/unparseable input.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

CORE = "packages/foresight_core/lib/src"
SOURCES = {
    "store": f"{CORE}/store.dart",
    "schema": f"{CORE}/persistence/application_schema.dart",
    "migrations": f"{CORE}/persistence/schema_migrations.dart",
    "operations": f"{CORE}/operations.dart",
    "registry": f"{CORE}/operation_registry.dart",
    "rpc_tools": f"{CORE}/mcp/rpc_tools.dart",
    "projections": f"{CORE}/mcp/operation_tool_projection.dart",
}
SCHEMA_DOC = "docs/architecture/schema-migrations.md"
SERVICE_DOC = "docs/architecture/application-service.md"


class InputError(Exception):
    """A required source is missing or no longer has the expected shape."""


@dataclass
class Facts:
    migration_steps: list[int]
    content_revisions_step: int
    schema_version_symbol: str
    application_schema_version: int | None
    request_key_lifetime_hours: int
    workspace_epoch_key: str
    operations: list[str]
    operation_wires: list[str]
    registry_rejects: list[str]
    mcp_tools: list[str]
    mcp_tool_operations: dict[str, str]
    notes: list[str] = field(default_factory=list)

    @property
    def latest_step(self) -> int:
        return self.migration_steps[-1]


def _read(root: Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        raise InputError(f"missing input: {relative}")
    return path.read_text(encoding="utf-8")


def _block(text: str, opening: int) -> str:
    """Return the brace-balanced body starting at text[opening] == '{'."""
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1 : index]
    raise InputError("unbalanced braces")


def _method_body(text: str, name: str) -> str:
    match = re.search(rf"\bvoid {re.escape(name)}\(\) \{{", text)
    if not match:
        raise InputError(f"schema_migrations.dart: no method {name}")
    return _block(text, match.end() - 1)


def migration_facts(text: str) -> tuple[list[int], dict[int, str]]:
    run = re.search(r"void run\(int version\) \{", text)
    if not run:
        raise InputError("schema_migrations.dart: ApplicationMigrations.run not found")
    body = _block(text, run.end() - 1)
    switch = re.search(r"switch \(version\) \{", body)
    if not switch:
        raise InputError("schema_migrations.dart: version switch not found")
    cases = _block(body, switch.end() - 1)
    labels = list(re.finditer(r"^\s*case (\d+):", cases, re.MULTILINE))
    default = re.search(r"^\s*default:", cases, re.MULTILINE)
    if not labels or not default:
        raise InputError("schema_migrations.dart: no case labels or default")
    bodies: dict[int, str] = {}
    for index, label in enumerate(labels):
        end = labels[index + 1].start() if index + 1 < len(labels) else default.start()
        step = int(label.group(1))
        if step in bodies:
            raise InputError(f"schema_migrations.dart: duplicate case {step}")
        bodies[step] = cases[label.end() : end]
    steps = list(bodies)
    if steps != list(range(1, len(steps) + 1)):
        raise InputError(
            f"schema_migrations.dart: steps not contiguous from 1: {steps}"
        )
    return steps, bodies


def _step_creating(text: str, bodies: dict[int, str], table: str) -> int:
    pattern = re.compile(rf"CREATE TABLE (IF NOT EXISTS )?{table}\(")
    found = []
    for step, body in bodies.items():
        expanded = body + "".join(
            _method_body(text, name) for name in re.findall(r"\b(_\w+)\(\);", body)
        )
        if pattern.search(expanded):
            found.append(step)
    if len(found) != 1:
        raise InputError(f"expected one step creating {table}, found {found}")
    return found[0]


def _enum_entries(text: str) -> list[tuple[str, str]]:
    match = re.search(r"enum Operation \{", text)
    if not match:
        raise InputError("operations.dart: enum Operation not found")
    body = _block(text, match.end() - 1)
    values = body.split(";", 1)[0]
    entries = re.findall(r"^[ ]{2}(\w+)\(\s*'([^']+)'", values, re.MULTILINE)
    if not entries:
        raise InputError("operations.dart: no enum values")
    return entries


def collect(root: Path) -> Facts:
    texts = {key: _read(root, path) for key, path in SOURCES.items()}
    notes: list[str] = []

    steps, bodies = migration_facts(texts["migrations"])
    content_step = _step_creating(texts["migrations"], bodies, "content_revisions")

    store = texts["store"]
    symbol = re.search(r"static const schemaVersion = (\w+);", store)
    lifetime = re.search(
        r"static const requestKeyLifetime = Duration\(hours: (\d+)\);", store
    )
    epoch = re.search(r"static const workspaceEpochKey = '(\w+)';", store)
    if not (symbol and lifetime and epoch):
        raise InputError(
            "store.dart: schemaVersion/requestKeyLifetime/workspaceEpochKey not found"
        )
    if "ApplicationMigrations(db).run(version)" not in store:
        raise InputError(
            "store.dart: Store no longer migrates through ApplicationMigrations"
        )

    found = re.search(
        rf"\b{re.escape(symbol.group(1))}\s*=\s*(\d+)\s*;",
        texts["schema"],
    )
    if not found:
        raise InputError(f"{SOURCES['schema']}: {symbol.group(1)} not found")
    schema_value = int(found.group(1))

    entries = _enum_entries(texts["operations"])
    names = [name for name, _ in entries]
    wires = [wire for _, wire in entries]
    for label, values in (("operation", names), ("wire name", wires)):
        if len(set(values)) != len(values):
            raise InputError(f"operations.dart: duplicate {label}")

    registry = texts["registry"]
    rejects = [
        reason
        for reason, marker in (
            ("cross-scope", "dispatch, not"),
            ("duplicate", "Duplicate handler for"),
            ("missing", "Missing ${scope.name} handlers"),
        )
        if marker in registry
    ]
    if len(rejects) != 3:
        raise InputError(
            f"operation_registry.dart: exhaustiveness checks changed: {rejects}"
        )

    tools = re.findall(
        r"_projectedTool\(\s*'(\w+)',\s*Operation\.(\w+)", texts["rpc_tools"]
    )
    projections = re.findall(
        r'OperationToolProjection\(\s*"(\w+)",\s*Operation\.(\w+)',
        texts["projections"],
    )
    if not tools or not projections:
        raise InputError("MCP tool or projection declarations not found")
    tool_names = [name for name, _ in tools]
    if len(set(tool_names)) != len(tool_names):
        raise InputError("rpc_tools.dart: duplicate tool name")
    if sorted(tools) != sorted(projections):
        raise InputError("rpc_tools.dart and operation_tool_projection.dart disagree")
    unknown = sorted({op for _, op in tools} - set(names))
    if unknown:
        raise InputError(f"MCP tools name unknown operations: {unknown}")

    return Facts(
        migration_steps=steps,
        content_revisions_step=content_step,
        schema_version_symbol=symbol.group(1),
        application_schema_version=schema_value,
        request_key_lifetime_hours=int(lifetime.group(1)),
        workspace_epoch_key=epoch.group(1),
        operations=names,
        operation_wires=wires,
        registry_rejects=rejects,
        mcp_tools=tool_names,
        mcp_tool_operations=dict(tools),
        notes=notes,
    )


def _claims(
    doc: str, pattern: str, expected: object, what: str, errors: list[str], path: str
) -> None:
    found = re.findall(pattern, doc)
    if not found:
        errors.append(f"{path}: missing statement of {what} (expected {expected})")
    for value in found:
        if int(value) != expected:
            errors.append(f"{path}: {what} stated as {value}, registry says {expected}")


def _tools_table(doc: str) -> list[str]:
    section = re.search(r"^## Tools\n(.*?)(?=^## |\Z)", doc, re.MULTILINE | re.DOTALL)
    if not section:
        return []
    names = []
    for line in section.group(1).splitlines():
        if not line.startswith("| `"):
            continue
        names.extend(re.findall(r"`(\w+)`", line.split("|")[1]))
    return names


def check(root: Path, facts: Facts) -> list[str]:
    errors: list[str] = []

    if (
        facts.application_schema_version is not None
        and facts.application_schema_version != facts.latest_step
    ):
        errors.append(
            f"{facts.schema_version_symbol}={facts.application_schema_version} "
            f"but migrations define steps through {facts.latest_step}"
        )

    doc = _read(root, SCHEMA_DOC)
    rows = [int(value) for value in re.findall(r"^\| (\d+) \|", doc, re.MULTILINE)]
    if rows != facts.migration_steps:
        missing = sorted(set(facts.migration_steps) - set(rows))
        extra = sorted(set(rows) - set(facts.migration_steps))
        errors.append(
            f"{SCHEMA_DOC}: version table rows differ from migration steps "
            f"(missing {missing}, extra {extra}; order and duplicates also compared)"
        )
    _claims(
        doc,
        r"defines steps 1–(\d+)",
        facts.latest_step,
        "latest migration step",
        errors,
        SCHEMA_DOC,
    )
    _claims(
        doc,
        r"older than (\d+) hours\s+\(`Store\.requestKeyLifetime`\)",
        facts.request_key_lifetime_hours,
        "request key lifetime",
        errors,
        SCHEMA_DOC,
    )
    if f"`{facts.workspace_epoch_key}`" not in doc:
        errors.append(
            f"{SCHEMA_DOC}: workspace epoch key `{facts.workspace_epoch_key}` not named"
        )

    doc = _read(root, SERVICE_DOC)
    _claims(
        doc,
        r"declares (\d+) operations",
        len(facts.operations),
        "operation count",
        errors,
        SERVICE_DOC,
    )
    _claims(
        doc,
        r"exposes (\d+) MCP tools",
        len(facts.mcp_tools),
        "MCP tool count",
        errors,
        SERVICE_DOC,
    )
    _claims(
        doc,
        r"frozen (\d+) MCP schemas",
        len(facts.mcp_tools),
        "MCP schema count",
        errors,
        SERVICE_DOC,
    )
    _claims(
        doc,
        r"Schema (\d+) retains prior content atomically in `content_revisions`",
        facts.content_revisions_step,
        "content_revisions schema step",
        errors,
        SERVICE_DOC,
    )
    # The per-scope split lives in operation_descriptors.dart, which is not an
    # authority here; numeric split claims cannot be verified and are refused.
    for claim in re.findall(r"own \w+ and \w+ handlers", doc):
        errors.append(f"{SERVICE_DOC}: unverifiable per-scope handler count '{claim}'")
    table = _tools_table(doc)
    if len(set(table)) != len(table):
        errors.append(f"{SERVICE_DOC}: Tools table lists a tool twice")
    missing_tools = sorted(set(facts.mcp_tools) - set(table))
    extra_tools = sorted(set(table) - set(facts.mcp_tools))
    if missing_tools:
        errors.append(f"{SERVICE_DOC}: Tools table omits {missing_tools}")
    if extra_tools:
        errors.append(f"{SERVICE_DOC}: Tools table lists unregistered {extra_tools}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument(
        "--json", action="store_true", help="print derived facts as JSON"
    )
    args = parser.parse_args(argv)
    try:
        facts = collect(args.root)
        errors = check(args.root, facts)
    except InputError as input_error:
        print(f"error: {input_error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({**asdict(facts), "latest_step": facts.latest_step}, indent=2))
    for note in facts.notes:
        print(f"note: {note}", file=sys.stderr)
    for error in errors:
        print(f"drift: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
