#!/usr/bin/env python3
"""Overlap independent core/desktop gates, retaining logs and every exit status."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def run_gates(tasks, log_directory):
    """Wait for every task, failing if any fails; reap process groups on abort."""
    log_directory.mkdir(parents=True, exist_ok=True)
    running = []
    streams = []
    completed = False
    started = time.monotonic()
    try:
        for name, command in tasks:
            path = log_directory / f"{name}.log"
            stream = path.open("wb")
            streams.append(stream)
            process = subprocess.Popen(
                command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True
            )
            running.append((name, process, path))
            print(f"Started {name} gate; log: {path}", flush=True)
        failed = False
        for name, process, path in running:
            code = process.wait(timeout=3600)
            failed |= code != 0
            print(f"::group::{name} gate (exit {code})", flush=True)
            with path.open("rb") as stream:
                while data := stream.read(65536):
                    sys.stdout.buffer.write(data)
            sys.stdout.flush()
            print("::endgroup::", flush=True)
        completed = True
        print(
            f"Parallel gates finished in {time.monotonic() - started:.1f}s", flush=True
        )
        return 1 if failed else 0
    finally:
        if not completed:
            # Each gate owns a new session: stop its compilers/test descendants
            # without signalling the caller or unrelated runner processes.
            for _, process, _ in running:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and any(
                p.poll() is None for _, p, _ in running
            ):
                time.sleep(0.05)
            for _, process, _ in running:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=3600)
        for stream in streams:
            stream.close()


def main():
    """Run both build gates against the already completed native build."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("macos", "linux"), required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--python", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    tasks = [
        (
            gate,
            [
                "bash",
                str(ROOT / "tools/build_dart_gates.sh"),
                gate,
                args.platform,
                str(args.build),
                args.python,
            ],
        )
        for gate in ("core", "desktop")
    ]
    return run_gates(tasks, ROOT / "test-results/build-gates")


if __name__ == "__main__":
    sys.exit(main())
