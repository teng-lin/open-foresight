#!/usr/bin/env python3
"""Overlap independent core/desktop gates, retaining logs and every exit status."""

import argparse
import codecs
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
WAIT_TIMEOUT_SECONDS = 3600
PROGRESS_INTERVAL_SECONDS = 30
LOG_POLL_INTERVAL_SECONDS = 0.25


class GateLog:
    """Stream bounded, labeled text while keeping the original bytes on disk."""

    def __init__(self, name, path):
        self.name = name
        self.reader = path.open("rb")
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.pending = ""

    def emit(self, *, final=False):
        # Limit each live turn so a noisy gate cannot starve its siblings.
        data = self.reader.read(65536)
        self.pending += self.decoder.decode(data, final=final and not data)
        self.pending = self.pending.replace("\r", "\n")
        while self.pending:
            newline = self.pending.find("\n", 0, 8192)
            if newline >= 0:
                line, self.pending = (
                    self.pending[:newline], self.pending[newline + 1 :]
                )
            elif len(self.pending) >= 8192:
                line, self.pending = self.pending[:8192], self.pending[8192:]
            elif final and not data:
                line, self.pending = self.pending, ""
            else:
                break
            print(f"[{self.name}] {line}", flush=True)
        return bool(data)

    def finish(self):
        while self.emit(final=True):
            pass

    def close(self):
        self.reader.close()


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


def run_gates(tasks, log_directory, *, outcomes=None):
    """Wait for every task, failing if any fails; reap process groups on abort."""
    log_directory.mkdir(parents=True, exist_ok=True)
    running = []
    streams = []
    logs = {}
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
            logs[process.pid] = GateLog(name, path)
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
                if outcomes is not None:
                    outcomes[name] = code
                logs[process.pid].finish()
                print(f"::group::{name} gate (exit {code})", flush=True)
                print(f"Raw log: {path}", flush=True)
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

        next_progress = time.monotonic() + PROGRESS_INTERVAL_SECONDS
        for _, process, _ in running:
            # Preserve the original per-wait budget. Heartbeats must not renew it.
            deadline = time.monotonic() + WAIT_TIMEOUT_SECONDS
            report_finished()
            while process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(process.args, WAIT_TIMEOUT_SECONDS)
                for _, owner, _ in running:
                    if owner.pid not in reported:
                        logs[owner.pid].emit()
                report_finished()
                if time.monotonic() >= next_progress:
                    report_progress()
                    next_progress = time.monotonic() + PROGRESS_INTERVAL_SECONDS
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(process.args, WAIT_TIMEOUT_SECONDS)
                try:
                    process.wait(
                        timeout=min(
                            LOG_POLL_INTERVAL_SECONDS,
                            PROGRESS_INTERVAL_SECONDS,
                            remaining,
                        )
                    )
                except subprocess.TimeoutExpired:
                    pass
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
            for log in logs.values():
                log.close()
            for stream in streams:
                stream.close()


def run_application_gates(platform, build, python, mode, *, sequential=False):
    """Collect independent checks, running dependants only after valid builds."""
    available = []
    for gate, executable in (("core", "dart"), ("desktop", "flutter")):
        if shutil.which(executable):
            available.append(gate)
        else:
            print(f"{gate} gate unavailable: add {executable} to PATH", flush=True)
    directory = ROOT / "test-results/build-gates"
    outcomes: dict[str, int] = {}

    def execute(tasks):
        if sequential:
            for task in tasks:
                run_gates([task], directory, outcomes=outcomes)
        elif tasks:
            run_gates(tasks, directory, outcomes=outcomes)

    def command(gate, phase):
        return [
            "/usr/bin/env",
            f"FORESIGHT_BUILD_MODE={phase}",
            "bash",
            str(ROOT / "tools/build_dart_gates.sh"),
            gate,
            platform,
            str(build),
            python,
        ]

    if mode != "test-only":
        # A Desktop release executable is not a widget-test prerequisite. In
        # normal mode its one full gate checks dependencies, runs its tests and
        # then collects release compilation errors, without hiding either.
        builders = (
            available
            if mode == "build-only"
            else [gate for gate in available if gate == "core"]
        )
        execute([(f"{gate}-build", command(gate, "build-only")) for gate in builders])
    if mode != "build-only":
        ready = []
        for gate in available:
            if (
                (mode == "all" and gate == "desktop")
                or mode == "test-only"
                or outcomes[f"{gate}-build"] == 0
            ):
                ready.append(gate)
            else:
                print(
                    f"Blocked {gate} checks: its build prerequisites failed", flush=True
                )
        execute(
            [
                (
                    f"{gate}-checks",
                    command(
                        gate,
                        "all" if mode == "all" and gate == "desktop" else "test-only",
                    ),
                )
                for gate in ready
            ]
        )
        # A failed analysis/test must not hide the independent compiled boundary.
        # A failed core build, however, must never run an older service binary.
        if "core" in available and (mode == "test-only" or outcomes["core-build"] == 0):
            execute(
                [
                    (
                        "service-checks",
                        [
                            "bash",
                            str(ROOT / "tools/build_service_gate.sh"),
                            platform,
                            str(build),
                            python,
                        ],
                    )
                ]
            )
        elif "core" in available:
            print("Blocked service checks: core build prerequisites failed", flush=True)
    print("Build/check outcomes: " + repr(outcomes), flush=True)
    return int(any(code != 0 for code in outcomes.values()))


def main():
    """Run both build gates against the already completed native build."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("macos", "linux"), required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--all-stages", action="store_true")
    parser.add_argument("--sequential", action="store_true")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    if args.all_stages:
        mode = os.environ.get("FORESIGHT_BUILD_MODE", "all")
        if mode not in {"all", "build-only", "test-only"}:
            parser.error("Unknown build mode")
        return run_application_gates(
            args.platform, args.build, args.python, mode, sequential=args.sequential
        )
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
