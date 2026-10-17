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
    functions: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(
                alias.asname or alias.name
                for alias in node.names
                if alias.name == "subprocess"
            )
        elif isinstance(node, ast.ImportFrom) and node.module == "subprocess":
            functions.update(
                alias.asname or alias.name
                for alias in node.names
                if alias.name in BLOCKING_CALLS
            )
    missing = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        blocking = (isinstance(function, ast.Name) and function.id in functions) or (
            isinstance(function, ast.Attribute)
            and function.attr in BLOCKING_CALLS
            and isinstance(function.value, ast.Name)
            and function.value.id in modules
        )
        if blocking:
            timeout = next(
                (
                    keyword.value
                    for keyword in node.keywords
                    if keyword.arg == "timeout"
                ),
                None,
            )
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
