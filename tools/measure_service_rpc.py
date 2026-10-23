#!/usr/bin/env python3
"""Measure real service status RPC latency against a verified Git-free export.

Run ``verify-export`` immediately after exporting, BEFORE compiling or running
gates. Run ``measure`` only after compiling that same export and passing its
gates. Both commands compare every Git blob, executable bit and symlink target
with ``git ls-tree -rz --full-tree <commit>``; no evidence manifests are trusted.
Measurement permits only additional generated output: test-results/, coverage/,
.dart_tool/, build/, dist/, Flutter ephemeral/.symlinks/.plugin_symlinks,
.flutter-plugins[-dependencies], .packages, .coverage*, and Python/linter caches.
An unusual in-export build directory must be named with --generated-directory.
Tracked files are NEVER exempted by the generated-output allowance.

The workload uses pinned local models, real CPU inference and an owned service.
Capture uses deterministic synthetic PCM through the production FIFO protocol;
it proves progressing samples, not microphone or transcription quality. Timing
does not replace deterministic liveness tests. Completed conditions retain all 100 samples. Incomplete runs retain every
attempt collected before failure and the service's full log. A dedicated Linux
supervisor pins each owned process group until service descendants settle.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import socket
import stat
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from typing import Any, Callable

_pins = importlib.import_module("tools.model_pins" if __package__ else "model_pins")
GENERATED_DIRECTORIES = frozenset({
    "test-results", "coverage", ".dart_tool", "build", "dist", "ephemeral",
    ".symlinks", ".plugin_symlinks", "__pycache__", ".pytest_cache",
    ".mypy_cache", ".ruff_cache", ".cache", ".venv",
})
GENERATED_FILES = frozenset({
    ".flutter-plugins-dependencies", ".flutter-plugins", ".packages",
})
MODEL_NAMES = {
    "generation": "gemma-4-E2B-it.litertlm",
    "embedding": "embeddinggemma-2-740m.litertlm",
    "speech": "ggml-medium.bin",
}
EVIDENCE_TEXT = (
    "Alice owns the Apollo migration. She ships the design Friday. Bob reviews "
    "Tuesday. The implementation has three stages: schema safety, typed service "
    "admission, and desktop lifecycle verification. The project requires signed "
    "Linux and Mac acceptance before release."
)
WARM_QUESTION = "Who owns Apollo and when does she ship the design?"
STREAM_QUESTION = (
    "Explain the Apollo migration plan in detail, covering every stage and owner, "
    "review schedule, and acceptance criteria. Use complete paragraphs grounded "
    "in the source."
)
CAPTURE_SCRIPT = """import math, os, struct, sys, time
rate = int(sys.argv[sys.argv.index('--rate') + 1]) if '--rate' in sys.argv else 48000
block = b''.join(struct.pack('<h', int(4000 * math.sin(i * .17))) for i in range(rate // 25))
out = os.open(sys.argv[-1], os.O_WRONLY)
print('private synthetic PCM capture fixture connected', flush=True)
while True:
    os.write(out, block)
    time.sleep(.04)
"""


def file_identity(path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path.absolute()), "resolved_path": str(path.resolve()),
            "bytes": path.stat().st_size, "sha256": digest}


def git(repository: Path, *arguments: str) -> bytes:
    return subprocess.check_output(
        ["git", *arguments], cwd=repository, timeout=30, stderr=subprocess.PIPE,
    )


def generated(path: str, additional: tuple[str, ...]) -> bool:
    parts = Path(path).parts
    return (
        any(part in GENERATED_DIRECTORIES for part in parts[:-1])
        or parts[-1] in GENERATED_FILES
        or parts[-1].startswith(".coverage")
        or any(path.startswith(prefix + "/") for prefix in additional)
    )


def verify_export(
    repository: Path, commit: str, source: Path, *,
    allow_generated: bool = False, additional: tuple[str, ...] = (),
) -> dict[str, Any]:
    """Recompute provenance from Git and actual bytes, including exact file set."""
    source = source.resolve(strict=True)
    for prefix in additional:
        path = Path(prefix)
        if path.is_absolute() or not path.parts or any(p in {"..", ".git"} for p in path.parts):
            raise ValueError(f"Invalid generated-directory path: {prefix}")
    resolved = git(repository, "rev-parse", "--verify", f"{commit}^{{commit}}").decode().strip()
    expected: dict[str, tuple[str, str]] = {}
    for row in git(repository, "ls-tree", "-rz", "--full-tree", resolved).split(b"\0"):
        if not row:
            continue
        tree_metadata, filename = row.split(b"\t", 1)
        mode, kind, blob = tree_metadata.decode().split()
        name = os.fsdecode(filename)
        if kind != "blob" or mode not in {"100644", "100755", "120000"}:
            raise ValueError(f"Unsupported Git entry: {name} ({mode} {kind})")
        expected[name] = mode, blob
    actual = set()
    for directory, directories, files in os.walk(source, followlinks=False):
        for name in [*directories, *files]:
            path = Path(directory) / name
            relative = str(path.relative_to(source))
            if name == ".git":
                raise ValueError(f"Export contains Git metadata: {relative}")
            if path.is_symlink() or not path.is_dir():
                actual.add(relative)
    missing = expected.keys() - actual
    extras = actual - expected.keys()
    refused = sorted(p for p in extras if not allow_generated or not generated(p, additional))
    if missing or refused:
        raise ValueError(f"Export file set mismatch; missing={sorted(missing)}, extra={refused}")
    identities = []
    for name, (mode, blob) in sorted(expected.items()):
        path = source / name
        metadata = path.lstat()
        actual_mode = "120000" if stat.S_ISLNK(metadata.st_mode) else (
            "100755" if metadata.st_mode & 0o111 else "100644"
        )
        if actual_mode != mode or not (stat.S_ISLNK(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
            raise ValueError(f"Export mode mismatch: {name}")
        data = os.fsencode(os.readlink(path)) if mode == "120000" else path.read_bytes()
        actual_blob = hashlib.sha1(  # noqa: S324 -- Git blob identity, not authentication.
            b"blob " + str(len(data)).encode() + b"\0" + data,
        ).hexdigest()
        if actual_blob != blob:
            raise ValueError(f"Export blob mismatch: {name}")
        identities.append({"path": name, "mode": mode, "git_blob": blob,
                           "sha256": hashlib.sha256(data).hexdigest()})
    return {"commit": resolved, "source": str(source), "files": identities,
            "allowed_generated_files": sorted(extras), "additional_generated_directories": list(additional)}


def verify_inputs(args: argparse.Namespace) -> dict[str, Any]:
    paths = {name: getattr(args, name) for name in (
        "service", "helper", "native_library", "model_worker", "litert_library", "whisper_runtime",
    )}
    result = {name: file_identity(path) for name, path in paths.items()}
    pins = _pins.model_pins(args.source / "packages/foresight_core/lib/src/model_pins.dart")
    for kind, filename in MODEL_NAMES.items():
        path = getattr(args, kind + "_model")
        pin = pins[filename]
        identity = file_identity(path)
        if identity["sha256"] != pin["sha256"] or identity["bytes"] != pin["bytes"]:
            raise ValueError(f"Model does not match exported pin {filename}: {path}")
        result[kind + "_model"] = {**identity, "pin": pin}
    return result


class Peer:
    """One bounded RPC connection; unrelated status events do not reset timeout."""

    def __init__(self, path: Path, timeout: float = 300):
        self.socket = socket.socket(socket.AF_UNIX)
        try:
            self.socket.settimeout(timeout)
            self.socket.connect(str(path))
            self.stream = self.socket.makefile("rb")
        except BaseException:
            self.socket.close()
            raise
        self.timeout = timeout
        self.sequence = 0

    def call(self, method: str, arguments: dict[str, Any] | None = None) -> Any:
        self.sequence += 1
        request = self.sequence
        deadline = time.monotonic() + self.timeout
        self.socket.sendall((json.dumps({"id": request, "method": method, "args": arguments or {}}) + "\n").encode())
        result = None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"RPC deadline exceeded: {method}")
            self.socket.settimeout(remaining)
            line = self.stream.readline()
            if not line:
                raise RuntimeError("Service disconnected")
            row = json.loads(line)
            if row.get("id") != request:
                continue
            if "error" in row:
                raise RuntimeError(f"RPC {method}: {row['error']}")
            if "result" in row:
                result = row["result"]
            if row.get("done"):
                return result

    def interrupt(self) -> None:
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def close(self) -> None:
        self.stream.close()
        self.socket.close()


def native_active(status: dict[str, Any]) -> bool:
    generation = status.get("generation") or {}
    # Native fs_engine_state uses loading while generation work is in flight;
    # the Dart generating flag alone also covers queue/preparation time.
    return bool(generation.get("generating")) and generation.get("state") == "loading"


def capture_active(status: dict[str, Any]) -> bool:
    capture = status.get("capture") or {}
    return bool(capture.get("active")) and capture.get("state") == "capturing" and not (
        capture.get("paused") or capture.get("finishing")
    )


def sample(peer: Peer, *, delay: float = .01,
           evidence: dict[str, Any] | None = None) -> dict[str, Any]:
    result = evidence if evidence is not None else {}
    rows: list[float] = []
    states: list[dict[str, Any]] = []
    attempts: list[dict[str, Any]] = []
    result.update(n=0, raw_ms=rows, state_evidence=states, attempts=attempts, status="incomplete")
    for index in range(100):
        started = time.perf_counter_ns()
        try:
            status = peer.call("status")
        except BaseException as error:
            attempts.append({"index": index, "elapsed_ms": (time.perf_counter_ns() - started) / 1e6,
                             "error": repr(error)})
            result["error"] = repr(error)
            raise
        elapsed = (time.perf_counter_ns() - started) / 1e6
        rows.append(elapsed)
        attempts.append({"index": index, "elapsed_ms": elapsed})
        result["n"] = len(rows)
        generation, capture = status.get("generation") or {}, status.get("capture") or {}
        states.append({
            "generation_generating": bool(generation.get("generating")),
            "generation_state": generation.get("state"), "native_active": native_active(status),
            "capture_active": capture_active(status), "capture_state": capture.get("state"),
            "samples": capture.get("samples") or [],
        })
        if delay:
            time.sleep(delay)
    p95 = sorted(rows)[math.ceil(.95 * len(rows)) - 1]
    result.update(status="complete", p50_ms=statistics.median(rows), p95_ms=p95,
                  max_ms=max(rows), generation_active_count=sum(s["generation_generating"] for s in states),
                  native_active_count=sum(s["native_active"] for s in states),
                  capture_active_count=sum(s["capture_active"] for s in states),
                  target_p95_ms=50, target_met=p95 < 50, load=os.getloadavg())
    return result


def validate_sample(label: str, result: dict[str, Any]) -> None:
    if label == "warmed_streaming" and result["native_active_count"] != 100:
        raise RuntimeError("Not all 100 status samples overlapped native generation")
    if label == "warmed_capture":
        states = result["state_evidence"]
        if result["capture_active_count"] != 100 or sum(states[-1]["samples"]) <= sum(states[0]["samples"]):
            raise RuntimeError("Capture did not progress PCM samples throughout measurement")


def wait_until(condition: Callable[[], bool], *, timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() >= deadline:
            raise TimeoutError("Workload did not reach required state before deadline")
        time.sleep(.05)


def private_root(path: Path) -> Path:
    root = path.resolve()
    if not root.is_relative_to(Path("/var/tmp")):  # noqa: S108 -- required short disk-backed test root.
        raise ValueError("--temp-root must be a private disk-backed directory under /var/tmp")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = root.stat()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ValueError("--temp-root must be owned by this user with mode 0700")
    return root


def environment(args: argparse.Namespace, run: Path) -> dict[str, str]:
    capture = run / "pw-record"
    capture.write_text(f"#!{sys.executable}\n" + CAPTURE_SCRIPT)
    capture.chmod(0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith("FORESIGHT_")}
    env.update({
        "TMPDIR": str(run.parent), "FORESIGHT_TEST_TEMP_ROOT": str(run.parent),
        "FORESIGHT_DATA": str(run / "data"), "FORESIGHT_RUNTIME": str(run / "run"),
        "FORESIGHT_SERVICE": str(args.service), "FORESIGHT_HELPER": str(args.helper),
        "FORESIGHT_NATIVE": str(args.native_library), "FORESIGHT_MODEL_WORKER": str(args.model_worker),
        "FORESIGHT_LITERT_RUNNER": str(args.model_worker), "FORESIGHT_LITERT_LIBRARY": str(args.litert_library),
        "FORESIGHT_LITERT_CACHE": str(run / "litert-cache"), "FORESIGHT_LITERT_BACKEND": "cpu",
        "FORESIGHT_CAPTURE_RUNTIME": str(capture), "FORESIGHT_WHISPER_BACKEND": "cpu",
        "LD_LIBRARY_PATH": os.pathsep.join(map(str, args.library_path)),
        "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2",
    })
    return env


def host_state() -> dict[str, Any]:
    def read(path: str) -> str | None:
        file = Path(path)
        return file.read_text() if file.is_file() else None
    return {"platform": platform.platform(), "cpu": platform.processor(),
            "logical_cpus": os.cpu_count(), "affinity": sorted(os.sched_getaffinity(0)),
            "load": os.getloadavg(), "memory": read("/proc/meminfo"),
            "cpu_quota": read("/sys/fs/cgroup/cpu.max"),
            "memory_limit": read("/sys/fs/cgroup/memory.max"),
            "cpu_stat": read("/proc/stat")}


def session_members(session: int) -> list[int]:
    """Include owned worker process groups while the live supervisor pins SID."""
    members = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal() or int(entry.name) == session:
            continue
        try:
            # comm is parenthesized and may itself contain spaces or ')'.
            fields = (entry / "stat").read_text().rpartition(")")[2].split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if int(fields[3]) == session:
            members.append(int(entry.name))
    return members


def signal_session_members(session: int, kind: int) -> None:
    """Signal verified members through stable pidfds, never recycled PID/PGIDs.

    The caller retains a live/unreaped supervisor to pin the session identity.
    Open the pidfd before checking SID: if a numeric PID is recycled during the
    check, sending through the fd can only reach the original (now dead) task.
    """
    for member in session_members(session):
        try:
            descriptor = os.pidfd_open(member)
        except ProcessLookupError:
            continue
        try:
            if os.getsid(member) == session:
                signal.pidfd_send_signal(descriptor, kind)
        except ProcessLookupError:
            pass
        finally:
            os.close(descriptor)


def service_supervisor(service: Path, state: Path) -> None:
    """Keep a live session leader until the service and orphan descendants settle.

    The supervisor is a Linux child subreaper. Even when the service exits first,
    its SID cannot be reused while this process remains alive (or unreaped).
    TERM asks every session member to stop, including workers that create new
    process groups. The owner escalates through verified pidfds after a deadline.
    """
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "Cannot establish owned child subreaper")
    stopping = False

    def stop(_signal: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    try:
        child = subprocess.Popen([str(service)])
        details = {"pid": child.pid, "exit_code": None}
        written: dict[str, Any] | None = None
        while True:
            if stopping:
                signal_session_members(os.getpid(), signal.SIGTERM)
            code = child.poll()
            details["exit_code"] = code
            if written != details:
                temporary = state.with_suffix(".tmp")
                temporary.write_text(json.dumps(details))
                temporary.replace(state)
                written = details.copy()
            if code is not None:
                # Reap descendants adopted after the service exited. Do not
                # reap the direct child before Popen has recorded its status.
                try:
                    while os.waitpid(-1, os.WNOHANG)[0]:
                        pass
                except ChildProcessError:
                    pass
                if stopping and not session_members(os.getpid()):
                    return
            time.sleep(.02)
    except BaseException:
        traceback.print_exc()
        # Keep session ownership while stopping descendants from every PGID.
        # The external owner's bounded cleanup can terminate a stuck supervisor.
        while True:
            signal_session_members(os.getpid(), signal.SIGKILL)
            try:
                while os.waitpid(-1, os.WNOHANG)[0]:
                    pass
            except ChildProcessError:
                pass
            if not session_members(os.getpid()):
                os.killpg(os.getpid(), signal.SIGKILL)
                raise
            time.sleep(.02)


class Measurement:
    def __init__(self, args: argparse.Namespace, run: Path, report: dict[str, Any]):
        self.args, self.run, self.report = args, run, report
        self.peers: list[Peer] = []
        self.process: subprocess.Popen[bytes] | None = None
        self.thread: threading.Thread | None = None
        self.stream_failures: list[str] = []
        self.cleanup_timeout = 30.0

    def connect(self) -> Peer:
        peer = Peer(self.run / "run/application.sock")
        self.peers.append(peer)
        return peer

    def record(self, label: str, peer: Peer) -> None:
        result: dict[str, Any] = {}
        self.report["samples"][label] = result
        result.update(sample(peer, evidence=result))
        # Retain raw failing qualifications before raising.
        validate_sample(label, result)

    def workload(self) -> None:
        started = time.monotonic()
        with (self.run / "service.log").open("wb") as log:
            self.process = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "_supervise",
                 str(self.args.service), str(self.run / "service-state.json")], cwd=self.args.source,
                env=environment(self.args, self.run), stdout=log, stderr=log,
                start_new_session=True,
            )

        self.report["owned_supervisor_pid"] = self.process.pid

        def ready() -> bool:
            state = self.service_state()
            if state.get("exit_code") is not None:
                raise RuntimeError("Service exited during startup; see retained service.log")
            try:
                self.connect()
                return True
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process is not None and self.process.poll() is not None:
                    raise RuntimeError("Service exited during startup; see retained service.log") from None
                return False

        wait_until(ready)
        self.service_state()
        control = self.peers[0]
        control.call("status")
        self.report["startup_seconds"] = time.monotonic() - started
        control.call("security.attach_desktop", {"token": (self.run / "data/.desktop-capability").read_text()})
        for key, value in [("liveEnhance", "false"), ("proactiveAnswers", "false"), ("serviceIdleMinutes", "30")]:
            control.call("preferences.set", {"key": key, "value": value})
        observer = self.connect()
        self.record("idle_before_models", observer)
        control.call("models.embedding", {"path": str(self.args.embedding_model), "gpu": False})
        control.call("models.generation", {"path": str(self.args.generation_model), "runtime": str(self.args.model_worker)})
        control.call("sources.import", {"title": "RPC measurement evidence", "text": EVIDENCE_TEXT})
        control.call("answer", {"question": WARM_QUESTION})
        self.record("warmed_idle", observer)

        def stream() -> None:
            try:
                control.call("answer.stream", {"question": STREAM_QUESTION})
            except BaseException as error:
                self.stream_failures.append(repr(error))

        self.thread = threading.Thread(target=stream, daemon=True)
        self.thread.start()

        def generating() -> bool:
            if native_active(observer.call("status")):
                return True
            if self.thread is not None and not self.thread.is_alive():
                raise RuntimeError(f"Generation settled before native overlap: {self.stream_failures}")
            return False

        wait_until(generating)
        self.record("warmed_streaming", observer)
        self.thread.join(300)
        if self.thread.is_alive() or self.stream_failures:
            raise RuntimeError(f"Generation did not settle successfully: {self.stream_failures}")
        control.call("models.speech", {"path": str(self.args.speech_model), "runtime": str(self.args.whisper_runtime),
                                      "digest": self.report["inputs"]["speech_model"]["sha256"]})
        meeting = control.call("meetings.create", {"title": "Private capture RPC measurement"})["id"]
        control.call("meetings.start", {"id": meeting})
        first_samples: int | None = None

        def capturing() -> bool:
            nonlocal first_samples
            status = observer.call("status")
            count = sum((status.get("capture") or {}).get("samples") or [])
            if capture_active(status):
                if first_samples is not None and count > first_samples:
                    return True
                first_samples = count
            return False

        wait_until(capturing)
        time.sleep(8)
        self.record("warmed_capture", observer)
        control.call("meetings.stop", {})
        self.report["performance_target_met"] = all(
            self.report["samples"][label]["target_met"]
            for label in ("warmed_idle", "warmed_streaming", "warmed_capture")
        )
        self.report["status"] = "passed" if self.report["performance_target_met"] else "performance_target_missed"

    def service_state(self) -> dict[str, Any]:
        state = self.run / "service-state.json"
        if not state.exists():
            return {}
        details: dict[str, Any] = json.loads(state.read_text())
        self.report["owned_service_pid"] = details["pid"]
        self.report["owned_service_exit_code"] = details["exit_code"]
        return details

    def close(self) -> None:
        for peer in self.peers:
            peer.interrupt()
        process = self.process
        if process is not None:
            if process.poll() is None:
                # TERM reaches the supervisor, which also signals workers in
                # other process groups through verified session-member pidfds.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass  # The owned process can exit between poll and signal.
                try:
                    process.wait(timeout=self.cleanup_timeout)
                except subprocess.TimeoutExpired:
                    # A timed-out wait has not reaped the session leader. Kill
                    # exact verified session members, repeatedly covering children
                    # forked while an earlier pass was stopping their parents.
                    deadline = time.monotonic() + self.cleanup_timeout
                    while True:
                        signal_session_members(process.pid, signal.SIGKILL)
                        remaining = deadline - time.monotonic()
                        try:
                            process.wait(timeout=max(0, min(.05, remaining)))
                            break
                        except subprocess.TimeoutExpired:
                            if remaining > 0:
                                continue
                            # The supervisor may itself be stuck. It still pins
                            # SID/PGID until this final bounded owner termination.
                            try:
                                os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            process.wait(timeout=self.cleanup_timeout)
                            break
            self.report["owned_supervisor_exit_code"] = process.returncode
            self.service_state()
        if self.thread is not None:
            self.thread.join(5)
            self.report["stream_thread_settled"] = not self.thread.is_alive()
            if self.thread.is_alive():
                self.report["status"] = "incomplete"
        for peer in self.peers:
            peer.close()


def measure(args: argparse.Namespace) -> dict[str, Any]:
    root = private_root(args.temp_root)
    run = Path(tempfile.mkdtemp(prefix="rpc-", dir=root))
    args.output.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "status": "incomplete", "run": str(run), "samples": {},
        "runner": file_identity(Path(__file__)), "python": sys.version,
        "toolchain": dict(item.split("=", 1) for item in args.toolchain),
        "host_before": host_state(),
        "workload": {"status_samples_per_condition": 100, "sample_delay_seconds": .01,
                     "threads": {"OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2"},
                     "source_text": EVIDENCE_TEXT, "warm_question": WARM_QUESTION,
                     "stream_question": STREAM_QUESTION, "capture_warm_seconds": 8,
                     "capture": "deterministic synthetic PCM, 48 kHz; no physical audio or transcription throughput claim"},
    }
    measurement = Measurement(args, run, report)
    try:
        report["source"] = verify_export(args.repository, args.commit, args.source,
                                         allow_generated=True, additional=tuple(args.generated_directory))
        report["inputs"] = verify_inputs(args)
        measurement.workload()
    except BaseException as error:
        report["status"], report["error"] = "incomplete", repr(error)
        raise
    finally:
        try:
            measurement.close()
        except BaseException as error:
            report["status"], report["cleanup_error"] = "incomplete", repr(error)
            raise
        finally:
            report["host_after"] = host_state()
            (args.output / "rpc-responsiveness.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] == "_supervise":
        service_supervisor(Path(argv[1]), Path(argv[2]))
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify-export", help="run immediately after export, before compilation")
    timed = commands.add_parser("measure", help="verify built export and measure real local models")
    for command in (verify, timed):
        command.add_argument("--repository", type=Path, required=True)
        command.add_argument("--commit", required=True)
        command.add_argument("--source", type=Path, required=True)
        command.add_argument("--output", type=Path, required=True)
    timed.add_argument("--temp-root", type=Path, required=True)
    timed.add_argument("--generated-directory", action="append", default=[])
    timed.add_argument("--toolchain", action="append", required=True, metavar="NAME=VERSION")
    timed.add_argument("--library-path", type=Path, action="append", default=[])
    for name in ("service", "helper", "native-library", "model-worker", "litert-library", "whisper-runtime",
                 "generation-model", "embedding-model", "speech-model"):
        timed.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args(argv)
    args.repository, args.source, args.output = args.repository.resolve(), args.source.resolve(), args.output.resolve()
    if args.command == "verify-export":
        result = verify_export(args.repository, args.commit, args.source)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        return 0
    if any("=" not in item or not item.split("=", 1)[0] or not item.split("=", 1)[1] for item in args.toolchain):
        parser.error("--toolchain must be NAME=VERSION")
    for name in ("service", "helper", "native_library", "model_worker", "litert_library", "whisper_runtime",
                 "generation_model", "embedding_model", "speech_model"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    args.library_path = [path.resolve(strict=True) for path in args.library_path]
    result = measure(args)
    print(json.dumps({"status": result["status"], "report": str(args.output / "rpc-responsiveness.json")}))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
