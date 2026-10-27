#!/usr/bin/env python3
"""Run shared pre-push guards before language/platform acceptance checks."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

from tools import parallel_build_gates

ROOT = Path(__file__).resolve().parents[1]
TEMP_PARENT = Path("/var/tmp").resolve()  # noqa: S108 - canonical disk-backed parent only


def workflow_lint() -> int:
    """Refuse actionlint's silent shell-check omission or mismatched CI tools."""
    tools = (
        ("actionlint", ["-version"], "1.7.7"),
        ("shellcheck", ["--version"], "0.9.0"),
    )
    failed = False
    executables = {}
    for name, arguments, expected in tools:
        executable = shutil.which(name)
        if executable is None:
            print(f"Missing required workflow tool: {name}", flush=True)
            failed = True
            continue
        executables[name] = executable
        result = subprocess.run(
            [executable, *arguments], capture_output=True, timeout=30, check=False
        )
        output = result.stdout + result.stderr
        sys.stdout.buffer.write(output)
        sys.stdout.flush()
        version = rf"(?<![\d.]){re.escape(expected)}(?![\d.])"
        if result.returncode or re.search(version, output.decode(errors="replace")) is None:
            print(f"{name} must match hosted version {expected}", flush=True)
            failed = True
    if failed:
        return 1
    return subprocess.run(
        [executables["actionlint"]], cwd=ROOT, timeout=300, check=False
    ).returncode


def shared_tasks(python: str) -> list[tuple[str, list[str]]]:
    """Cross-language metadata checks run even when only Dart files changed."""
    return [
        ("skip-inventory", [python, "tools/check_integration_inventory.py"]),
        ("document-links", [python, "-m", "tools.check_document_links"]),
        ("subprocess-timeouts", [python, "tools/check_subprocess_timeouts.py"]),
        ("ruff", [python, "-m", "ruff", "check", "."]),
        ("mypy", [python, "-m", "mypy"]),
        ("workflow-lint", [python, "-m", "tools.check_local_validation", "--lint-workflows"]),
    ]


def python_prerequisites() -> int:
    """Record the actual compiler tools before spending time on fixture builds."""
    records: dict[str, object] = {"python": {"path": sys.executable, "version": sys.version}}
    failed = False
    for name in ("cmake", "ninja", "protoc"):
        executable = shutil.which(name)
        if executable is None:
            records[name] = {"error": "missing executable"}
            failed = True
            continue
        result = subprocess.run(
            [executable, "--version"], capture_output=True, timeout=30, check=False
        )
        text = (result.stdout + result.stderr).decode(errors="replace").strip()
        records[name] = {"path": executable, "exit": result.returncode, "version": text}
        failed |= result.returncode != 0
        if name == "protoc" and text != "libprotoc 35.1":
            failed = True
    overrides = [name for name in ("CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS") if name in os.environ]
    if overrides:
        records["inherited_compiler_overrides"] = overrides
        failed = True
    print(json.dumps(records, indent=2), flush=True)
    return int(failed)


def private_output(path: Path | None) -> Path:
    if path is None:
        # mkdtemp creates a fresh 0700 directory in the required disk-backed root.
        return Path(tempfile.mkdtemp(prefix="flv-", dir=TEMP_PARENT))
    if path.is_symlink():
        raise ValueError("Validation output must not be a symlink")
    path = path.resolve()
    if path == TEMP_PARENT or not path.is_relative_to(TEMP_PARENT):
        raise ValueError("Validation output must be below canonical /var/tmp")
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("Validation output must be owned by this user and private")
    if any(path.iterdir()):
        raise ValueError("Validation output must be empty; previous evidence is retained")
    return path


def validate(output: Path, full_python: bool) -> int:
    """Retain every guard's output; do not spend a full test run on bad metadata."""
    old_directory = Path.cwd()
    keys = ("TMPDIR", "FORESIGHT_TEST_TEMP_ROOT", "FORESIGHT_PYTHON")
    old_environment = {key: os.environ.get(key) for key in keys}
    original_timeout = parallel_build_gates.WAIT_TIMEOUT_SECONDS
    temporary = output / "tmp"
    temporary.mkdir(mode=0o700)
    report: dict[str, object] = {"shared_guards": None, "full_python": None}
    try:
        os.chdir(ROOT)
        os.environ.update(
            TMPDIR=str(temporary),
            FORESIGHT_TEST_TEMP_ROOT=str(temporary),
            FORESIGHT_PYTHON=sys.executable,
        )
        parallel_build_gates.WAIT_TIMEOUT_SECONDS = 300
        result = parallel_build_gates.run_gates(shared_tasks(sys.executable), output / "guards")
        report["shared_guards"] = result
        if result == 0 and full_python:
            parallel_build_gates.WAIT_TIMEOUT_SECONDS = 60
            result = parallel_build_gates.run_gates(
                [("python-tools", [sys.executable, "-m", "tools.check_local_validation",
                                    "--python-prerequisites"])], output / "preflight"
            )
            report["python_prerequisites"] = result
            if result == 0:
                parallel_build_gates.WAIT_TIMEOUT_SECONDS = 1800
                result = parallel_build_gates.run_gates(
                    [("python-coverage", ["bash", "tools/coverage.sh", "--basetemp",
                                          str(output / "pytest"), "-o",
                                          "cache_dir=" + str(output / "pytest-cache")])],
                    output / "python",
                )
                report["full_python"] = result
        report["status"] = "passed" if result == 0 else "failed"
        return result
    except BaseException as error:
        report.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        try:
            (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        finally:
            parallel_build_gates.WAIT_TIMEOUT_SECONDS = original_timeout
            os.chdir(old_directory)
            for key, value in old_environment.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--full-python", action="store_true")
    parser.add_argument("--lint-workflows", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--python-prerequisites", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.lint_workflows:
        return workflow_lint()
    if arguments.python_prerequisites:
        return python_prerequisites()
    if sys.version_info[:2] != (3, 13):
        parser.error("Use the supported Python 3.13 environment: .venv/bin/python")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    output = private_output(arguments.output)
    print(f"Validation evidence: {output}", flush=True)
    result = validate(output, arguments.full_python)
    if result == 0:
        print("Shared guards passed. Run the applicable AGENTS.md platform checks too.")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
