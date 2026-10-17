#!/usr/bin/env python3
"""Reject synchronous subprocess operations without an explicit finite timeout."""

import ast
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BLOCKING_CALLS = {"run", "call", "check_call", "check_output"}


def missing_timeouts(source: str) -> list[int]:
    tree = ast.parse(source)
    modules = {"subprocess"}
    functions: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(
                alias.asname or alias.name
                for alias in node.names
                if alias.name == "subprocess"
            )
        elif isinstance(node, ast.ImportFrom) and node.module == "subprocess":
            functions.update(
                {
                    alias.asname or alias.name: alias.name
                    for alias in node.names
                    if alias.name in BLOCKING_CALLS | {"Popen"}
                }
            )

    def subprocess_function(node: ast.expr, names: set[str]) -> bool:
        return (isinstance(node, ast.Name) and functions.get(node.id) in names) or (
            isinstance(node, ast.Attribute)
            and node.attr in names
            and isinstance(node.value, ast.Name)
            and node.value.id in modules
        )

    # Track Popen assignment targets (including self.process) separately from
    # unrelated Event/Future.wait methods. Matchers span methods for owned peers.
    processes: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Assign, ast.AnnAssign)) and isinstance(
            node.value, ast.Call
        ):
            if subprocess_function(node.value.func, {"Popen"}):
                targets = (
                    node.targets if isinstance(node, ast.Assign) else [node.target]
                )
                processes.update(
                    ast.dump(target, include_attributes=False).replace(
                        "ctx=Store()", "ctx=Load()"
                    )
                    for target in targets
                )
    missing = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        waiting = (
            isinstance(function, ast.Attribute)
            and function.attr in {"wait", "communicate"}
            and ast.dump(function.value, include_attributes=False) in processes
        )
        blocking = subprocess_function(function, BLOCKING_CALLS) or waiting
        if blocking:
            timeout = next(
                (
                    keyword.value
                    for keyword in node.keywords
                    if keyword.arg == "timeout"
                ),
                None,
            )
            if timeout is None and waiting and isinstance(function, ast.Attribute):
                # Popen.wait(timeout), Popen.communicate(input, timeout).
                position = 0 if function.attr == "wait" else 1
                if len(node.args) > position:
                    timeout = node.args[position]
            if timeout is None or (
                isinstance(timeout, ast.Constant)
                and (not isinstance(timeout.value, (int, float)) or timeout.value <= 0)
            ):
                missing.append(node.lineno)
    return missing


def main() -> int:
    files = subprocess.check_output(
        ["git", "ls-files", "*.py"], cwd=ROOT, text=True, timeout=30
    ).splitlines()
    failed = False
    for name in files:
        for line in missing_timeouts((ROOT / name).read_text()):
            print(f"{name}:{line}: subprocess call requires a finite timeout")
            failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
