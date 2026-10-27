#!/usr/bin/env python3
"""Run the complete pytest selection within a bounded whole-file worker budget."""

from collections.abc import Mapping, Sequence
import os
import sys


def worker_budget(environment: Mapping[str, str]) -> int:
    count = getattr(os, "process_cpu_count", os.cpu_count)() or 1
    affinity = getattr(os, "sched_getaffinity", None)
    if affinity is not None:
        try:
            count = min(count, len(affinity(0)))
        except OSError:
            pass
    bound = max(1, min(4, count, 2 if environment.get("CI") else 4))
    requested = environment.get("FORESIGHT_PYTEST_WORKERS", str(bound))
    if not requested.isascii() or not requested.isdecimal():
        raise ValueError("FORESIGHT_PYTEST_WORKERS must be a positive integer")
    workers = int(requested)
    if not 1 <= workers <= bound:
        raise ValueError(f"FORESIGHT_PYTEST_WORKERS must be between 1 and {bound}")
    return workers


def pytest_command(arguments: Sequence[str], workers: int) -> list[str]:
    return [
        sys.executable,
        "-m",
        "pytest",
        *arguments,
        f"--numprocesses={workers}",
        "--dist=loadfile",
        "--max-worker-restart=0",
    ]


def main() -> int:
    try:
        workers = worker_budget(os.environ)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    print(
        f"Python test workers: {workers} (whole-file distribution; no crash restarts)",
        flush=True,
    )
    # Replace this process so pytest keeps the caller's signals, stdio and status.
    os.execv(sys.executable, pytest_command(sys.argv[1:], workers))  # noqa: S606 - exact interpreter, no shell; preserve pytest process ownership.


if __name__ == "__main__":
    raise SystemExit(main())
