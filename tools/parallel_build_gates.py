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
WAIT_TIMEOUT_SECONDS = 3600
PROGRESS_INTERVAL_SECONDS = 30


def signal_owned_group(process, sig):
    """Require delivery or group disappearance; bound Darwin zombie retirement."""
    deadline = time.monotonic() + 1
    while True:
        try:
            os.killpg(process.pid, sig)
            return
        except ProcessLookupError:
            return
        except PermissionError:
            # Reaping our leader does not reap orphaned descendants. Darwin can
            # temporarily report EPERM while their zombie-only group retires.
            # Never accept EPERM as success: retry only for an exited leader,
            # requiring actual signal delivery or ESRCH within the deadline.
            if (
                sys.platform != "darwin"
                or process.poll() is None
                or time.monotonic() >= deadline
            ):
                raise
            time.sleep(0.05)


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
        reported = set()

        def report_finished():
            nonlocal failed
            for name, process, path in running:
                code = process.poll()
                if code is None or process.pid in reported:
                    continue
                reported.add(process.pid)
                failed |= code != 0
                print(f"::group::{name} gate (exit {code})", flush=True)
                with path.open("rb") as stream:
                    while data := stream.read(65536):
                        sys.stdout.buffer.write(data)
                sys.stdout.flush()
                print("::endgroup::", flush=True)

        def report_progress():
            states = []
            for name, process, path in running:
                code = process.poll()
                state = "running" if code is None else f"exit {code}"
                states.append(
                    f"{name}: {state}, {path.stat().st_size} bytes, log: {path}"
                )
            print(
                f"Gate progress after {time.monotonic() - started:.1f}s: "
                + "; ".join(states),
                flush=True,
            )

        for _, process, _ in running:
            # Preserve the original per-wait budget. Heartbeats must not renew it.
            deadline = time.monotonic() + WAIT_TIMEOUT_SECONDS
            report_finished()
            while process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(process.args, WAIT_TIMEOUT_SECONDS)
                try:
                    process.wait(timeout=min(PROGRESS_INTERVAL_SECONDS, remaining))
                except subprocess.TimeoutExpired:
                    report_finished()
                    report_progress()
            report_finished()
        completed = True
        print(
            f"Parallel gates finished in {time.monotonic() - started:.1f}s", flush=True
        )
        return 1 if failed else 0
    finally:
        try:
            if not completed:
                # Each gate owns a new session: stop its compilers/test descendants
                # without signalling the caller or unrelated runner processes.
                cleanup_errors: list[OSError | subprocess.TimeoutExpired] = []
                denied = set()
                for _, process, _ in running:
                    try:
                        # Still signal groups whose leaders exited: descendants
                        # can remain, including orphan zombies on Darwin.
                        process.poll()
                        signal_owned_group(process, signal.SIGTERM)
                    except OSError as error:
                        cleanup_errors.append(error)
                        denied.add(process.pid)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and any(
                    p.poll() is None for _, p, _ in running if p.pid not in denied
                ):
                    time.sleep(0.05)
                for _, process, _ in running:
                    try:
                        process.poll()
                        signal_owned_group(process, signal.SIGKILL)
                        denied.discard(process.pid)
                    except OSError as error:
                        cleanup_errors.append(error)
                        denied.add(process.pid)
                reap_deadline = time.monotonic() + 1
                for _, process, _ in running:
                    try:
                        if process.pid in denied and process.poll() is None:
                            continue  # Failure retained; cannot claim this join.
                        process.wait(timeout=max(0, reap_deadline - time.monotonic()))
                    except (OSError, subprocess.TimeoutExpired) as error:
                        cleanup_errors.append(error)
                if cleanup_errors:
                    for secondary_error in cleanup_errors[1:]:
                        cleanup_errors[0].add_note(
                            f"Further cleanup error: {secondary_error!r}"
                        )
                    raise cleanup_errors[0]
        finally:
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
