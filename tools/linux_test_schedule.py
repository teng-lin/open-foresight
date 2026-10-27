#!/usr/bin/env python3
"""Run Linux test-only stages with one owner for every Flutter operation."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.parallel_build_gates import run_gates  # noqa: E402


def stage(root, name):
    return [
        "bash",
        str(root / "tools/build.sh"),
        "--platform",
        "linux",
        "--test-only",
        "--stage",
        name,
    ]


def branch(root, name, python):
    """Children inherit their gate's process group; never create nested sessions."""
    temporary = Path(tempfile.mkdtemp(prefix="c-", dir="/var/tmp"))
    print(f"Private {name} test storage: {temporary}", flush=True)
    env = {
        **os.environ,
        "TMPDIR": str(temporary),
        "FORESIGHT_TEST_TEMP_ROOT": str(temporary),
        "PYTHONPYCACHEPREFIX": str(temporary / "pycache"),
        "FORESIGHT_PYTHON": python,
        "FORESIGHT_BUILD_MODE": "test-only",
    }
    if name == "prerequisites":
        build = Path(env.get("FORESIGHT_BUILD_DIR", str(root / "build")))
        commands = [
            [
                "cmake",
                "-S",
                str(root),
                "-B",
                str(build),
                "-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=ON",
            ],
            [
                python,
                str(root / "tools/verify_application_no_build.py"),
                "--build",
                str(build),
            ],
        ]
    elif name == "host":
        commands = [
            [
                python,
                str(root / "tools/platform_python_tests.py"),
                "--platform",
                "linux",
                "--basetemp",
                str(temporary / "pytest"),
                "--cache-dir",
                str(temporary / "pytest-cache"),
            ]
        ]
    else:
        commands = [stage(root, name)]
        if name == "desktop":
            commands.append(
                [
                    python,
                    str(root / "tools/integration_gates.py"),
                    "--suite",
                    "fast",
                    "--native",
                    str(root / "build/native/libforesight_native.so"),
                    "--output",
                    "test-results/fast-integration",
                ]
            )
    failed = 0
    for command in commands:
        result = subprocess.run(command, cwd=root, env=env, timeout=3600)
        if result.returncode:
            if name == "prerequisites":
                return result.returncode
            failed = failed or result.returncode
    return failed


def schedule(root, python):
    logs = root / "test-results/linux-test-schedule"

    def task(name):
        return (
            name,
            [
                "xvfb-run",
                "-a",
                "dbus-run-session",
                "--",
                python,
                str(root / "tools/linux_test_schedule.py"),
                "--branch",
                name,
                "--python",
                python,
            ],
        )

    # Product verification is a prerequisite; test success is not. Never run
    # dependants after an invalid source/toolchain/artifact/no-build plan.
    if run_gates([task("prerequisites")], logs):
        return 1
    failed = run_gates([task("native")], logs)
    # Source-JIT startup and coverage collection need the runner CPU budget;
    # do not overlap Core with Flutter compilation or host compiler probes.
    failed |= run_gates([task("core")], logs)
    failed |= run_gates([task("desktop"), task("host")], logs)
    failed |= run_gates([task("service")], logs)
    return failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument(
        "--branch",
        choices=("prerequisites", "native", "core", "desktop", "host", "service"),
    )
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    return (
        branch(ROOT, args.branch, args.python)
        if args.branch
        else schedule(ROOT, args.python)
    )


if __name__ == "__main__":
    raise SystemExit(main())
