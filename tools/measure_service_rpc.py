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
supervisor pins the owned session until service descendants settle.
LD_LIBRARY_PATH is recorded. All regular files directly in its explicit search
directories (including resolved symlinks), plus repeated --runtime-file inputs,
are hashed; the directory scan is non-recursive. Default system-loader files
outside those directories may also be named with --runtime-file. In addition,
/proc maps snapshots before/after each measured condition inventory actual
file-backed mappings across the owned service session and optional native host.
New mapped objects are pinned and hashed after workload/cleanup; snapshot and
hashing costs are recorded outside RPC sample windows. Deleted file/memfd
mappings fail closed. An independently verified source-cohort API caller may
explicitly supply expected diagnostic IDs to validate its sealed shared DATA
through a read-only kernel handle; no payload hash or executable exemption is
permitted. The CLI's default export-verification boundary is unchanged. Qualified model
hashes are reused only when full file identity metadata is unchanged.
Child environment inheritance is allowlisted and loader injection is refused.
--desktop-host opts into a hashed native stdio/socket relay for a synthetic visible
UI peer. This proves native host attachment, not graphical desktop acceptance.
Without this option the pre-P0 token-peer attachment protocol is unchanged.
The warmed streaming condition regenerates a meeting summary: real native
deltas update status previews before completion. Grounded answers intentionally
buffer until citation verification and cannot qualify incremental-token overlap.
"""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import importlib
from io import BufferedReader
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import shutil
import socket
import stat
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from typing import Any, BinaryIO, Callable, cast

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
# Linux UAPI F_LINUX_SPECIFIC_BASE + 10; some supported standalone CPython
# builds expose fcntl() but omit the named constant. This path is Linux-only.
DIAGNOSTIC_GET_SEALS = getattr(fcntl, "F_GET_SEALS", 1034)
EVIDENCE_TEXT = (
    "Alice owns the Apollo migration. She ships the design Friday. Bob reviews "
    "Tuesday. The implementation has three stages: schema safety, typed service "
    "admission, and desktop lifecycle verification. The project requires signed "
    "Linux and Mac acceptance before release."
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


def file_metadata(metadata: os.stat_result) -> dict[str, int]:
    return {"device": metadata.st_dev, "inode": metadata.st_ino, "bytes": metadata.st_size,
            "mtime_ns": metadata.st_mtime_ns, "ctime_ns": metadata.st_ctime_ns, "links": metadata.st_nlink}


def file_identity(path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        before = file_metadata(os.fstat(stream.fileno()))
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if before != file_metadata(os.fstat(stream.fileno())):
            raise ValueError(f"File changed while hashing: {path}")
    return {"path": str(path.absolute()), "resolved_path": str(path.resolve()),
            **before, "sha256": digest}


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


def desktop_host_identity(path: Path) -> dict[str, Any]:
    path = path.resolve(strict=True)
    with path.open("rb") as stream:
        header = stream.read(65536)
    if not path.stat().st_mode & 0o111 or header[:4] != b"\x7fELF":
        raise ValueError("--desktop-host requires an executable native ELF relay")
    if re.fullmatch(r"dart|dartaotruntime|python[0-9.]*|pypy[0-9.]*|bash|sh|zsh|node|deno|ruby|perl|lua|php|java", path.name) or any(
        marker in header for marker in (b"Dart_Initialize", b"Py_BytesMain", b"Py_Main")
    ):
        raise ValueError("--desktop-host cannot trust an SDK or script interpreter")
    return file_identity(path)


def verify_inputs(args: argparse.Namespace) -> dict[str, Any]:
    paths = {name: getattr(args, name) for name in (
        "service", "helper", "native_library", "model_worker", "litert_library", "whisper_runtime",
    )}
    result = {name: file_identity(path) for name, path in paths.items()}
    if args.desktop_host is not None:
        result["desktop_host"] = desktop_host_identity(args.desktop_host)
    libraries = {path.absolute() for path in args.runtime_file}
    for directory in args.library_path:
        libraries.update(path.absolute() for path in directory.iterdir() if path.is_file())
    result["runtime_libraries"] = {
        "LD_LIBRARY_PATH": os.pathsep.join(map(str, args.library_path)),
        "search_directories": list(map(str, args.library_path)),
        "scope": "regular files directly in explicit search directories, plus --runtime-file inputs; symlinks resolved",
        "files": [file_identity(path) for path in sorted(libraries)],
    }
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
            self.buffer = bytearray()
        except BaseException:
            self.socket.close()
            raise
        self.timeout = timeout
        self.sequence = 0

    def call(self, method: str, arguments: dict[str, Any] | None = None, *,
             on_result: Callable[[Any], None] | None = None) -> Any:
        self.sequence += 1
        request = self.sequence
        deadline = time.monotonic() + self.timeout
        self._send((json.dumps({"id": request, "method": method, "args": arguments or {}}) + "\n").encode(), deadline, method)
        result = None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"RPC deadline exceeded: {method}")
            line = self._line(deadline, method, remaining)
            if not line:
                raise RuntimeError("Service disconnected")
            row = json.loads(line)
            if row.get("id") != request:
                continue
            if "error" in row:
                raise RuntimeError(f"RPC {method}: {row['error']}")
            if "result" in row:
                result = row["result"]
                if on_result is not None:
                    on_result(result)
            if row.get("done"):
                return result

    def _send(self, payload: bytes, deadline: float, method: str) -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"RPC deadline exceeded: {method}")
        self.socket.settimeout(remaining)
        self.socket.sendall(payload)

    def _line(self, deadline: float, method: str, remaining: float) -> bytes:
        while True:
            if remaining <= 0:
                raise TimeoutError(f"RPC deadline exceeded: {method}")
            end = self.buffer.find(b"\n")
            if end >= 0:
                result = bytes(self.buffer[:end + 1])
                del self.buffer[:end + 1]
                return result
            self.socket.settimeout(remaining)
            chunk = self.socket.recv(65536)
            if not chunk:
                return b""
            self.buffer.extend(chunk)
            # A partial frame cannot renew the original operation budget.
            remaining = deadline - time.monotonic()

    def interrupt(self) -> None:
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def close(self) -> None:
        self.socket.close()


class DesktopHostPeer(Peer):
    """Explicit native host relay with a single absolute read/write RPC deadline."""

    def __init__(self, executable: Path, path: Path, log: Path,
                 evidence: dict[str, Any], child_environment: dict[str, str], *,
                 timeout: float = 300, close_timeout: float = 1):
        identity = desktop_host_identity(executable)
        self.evidence, self.log = evidence, log
        evidence.update(executable=identity, kind="synthetic native UI peer; not graphical acceptance")
        self.timeout, self.close_timeout, self.sequence = timeout, close_timeout, 0
        self.interrupted = threading.Event()
        self.buffer = bytearray()
        self.closed = False
        with log.open("wb") as output:
            self.process = subprocess.Popen(
                [identity["resolved_path"], str(path)], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=output, env=child_environment,
                start_new_session=True, bufsize=0,
            )
        evidence["pid"] = self.process.pid
        self.writer = cast(BinaryIO, self.process.stdin)
        self.reader = cast(BinaryIO, self.process.stdout)
        try:
            image = self._executed_image(identity)
            evidence["executed_image"] = image
            os.set_blocking(self.writer.fileno(), False)
            os.set_blocking(self.reader.fileno(), False)
        except BaseException:
            self.close()
            raise

    def _executed_image(self, declared: dict[str, Any]) -> dict[str, Any]:
        # Bound qualification while the sampled bytes match the invoking parent.
        # Require the declared native bytes before using the relay, and reject
        # every unrelated image immediately; this does not establish the cause
        # of a mismatched initial procfs observation.
        parent = file_identity(Path(f"/proc/{os.getpid()}/exe"))
        deadline = time.monotonic() + min(self.timeout, 1.0)
        while True:
            image = file_identity(Path(f"/proc/{self.process.pid}/exe"))
            if image["sha256"] == declared["sha256"]:
                return image
            if (image["sha256"] != parent["sha256"]
                    or self.process.poll() is not None
                    or time.monotonic() >= deadline):
                raise ValueError("Native desktop relay executed a different image")
            self.interrupted.wait(.001)

    def _check(self, deadline: float, method: str) -> float:
        if self.interrupted.is_set():
            raise RuntimeError("Desktop relay interrupted")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"RPC deadline exceeded: {method}")
        return remaining

    def _ready(self, descriptor: int, event: int, deadline: float, method: str) -> None:
        with selectors.DefaultSelector() as selector:
            selector.register(descriptor, event)
            while True:
                remaining = self._check(deadline, method)
                # Cancellation has its own bounded wakeup even with no I/O.
                if selector.select(min(.05, remaining)):
                    return

    def _send(self, payload: bytes, deadline: float, method: str) -> None:
        offset = 0
        while offset < len(payload):
            self._ready(self.writer.fileno(), selectors.EVENT_WRITE, deadline, method)
            try:
                offset += os.write(self.writer.fileno(), payload[offset:])
            except BlockingIOError:
                continue

    def _line(self, deadline: float, method: str, remaining: float) -> bytes:
        while True:
            self._check(deadline, method)
            end = self.buffer.find(b"\n")
            if end >= 0:
                result = bytes(self.buffer[:end + 1])
                del self.buffer[:end + 1]
                return result
            self._ready(self.reader.fileno(), selectors.EVENT_READ, deadline, method)
            try:
                chunk = os.read(self.reader.fileno(), 65536)
            except BlockingIOError:
                continue
            if not chunk:
                return b""
            self.buffer.extend(chunk)

    def interrupt(self) -> None:
        self.interrupted.set()

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.interrupt()
        try:
            self.writer.close()
            try:
                self.process.wait(timeout=self.close_timeout)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=self.close_timeout)
                except subprocess.TimeoutExpired:
                    self.evidence["forced_kill"] = True
                    self.process.kill()
                    self.process.wait(timeout=self.close_timeout)
        finally:
            self.reader.close()
            self.evidence["exit_code"] = self.process.returncode
            self.evidence["graceful_shutdown"] = self.process.returncode == 0 and not self.evidence.get("forced_kill", False)
            self.evidence["log"] = file_identity(self.log)


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
           evidence: dict[str, Any] | None = None,
           on_status: Callable[[dict[str, Any], int], None] | None = None) -> dict[str, Any]:
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
        received = time.monotonic_ns()
        if on_status is not None:
            on_status(status, received)
        result.setdefault("first_status_ns", received)
        result["last_status_ns"] = received
        states.append({
            "received_ns": received,
            "generation_generating": bool(generation.get("generating")),
            "generation_state": generation.get("state"), "native_active": native_active(status),
            "capture_active": capture_active(status), "capture_present": bool(capture.get("active")),
            "capture_state": capture.get("state"),
            "samples": capture.get("samples") or [],
        })
        if delay:
            time.sleep(delay)
    p95 = sorted(rows)[math.ceil(.95 * len(rows)) - 1]
    result.update(status="complete", p50_ms=statistics.median(rows), p95_ms=p95,
                  max_ms=max(rows), generation_active_count=sum(s["generation_generating"] for s in states),
                  native_active_count=sum(s["native_active"] for s in states),
                  capture_active_count=sum(s["capture_active"] for s in states),
                  capture_present_count=sum(s["capture_present"] for s in states),
                  target_p95_ms=50, target_met=p95 < 50, load=os.getloadavg())
    return result


def validate_sample(label: str, result: dict[str, Any]) -> None:
    if label in {"idle_before_models", "warmed_idle"} and (
        result["generation_active_count"] or result.get("capture_present_count", result["capture_active_count"])
    ):
        raise RuntimeError("Idle condition contained active generation or capture")
    if label == "warmed_streaming" and result["native_active_count"] != 100:
        raise RuntimeError("Not all 100 status samples overlapped native generation")
    if label == "warmed_streaming" and not result["stream_chunks_during_samples"]:
        raise RuntimeError("No changed non-empty native summary preview arrived between first and last status samples")
    if label == "warmed_capture":
        if result["generation_active_count"]:
            raise RuntimeError("Capture condition contained active generation")
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
    for variable in ("LD_PRELOAD", "LD_AUDIT"):
        if os.environ.get(variable):
            raise ValueError(f"Refuse loader injection through {variable}")
    capture = run / "pw-record"
    capture.write_text(f"#!{sys.executable}\n" + CAPTURE_SCRIPT)
    capture.chmod(0o700)
    inherited = {"PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "SSL_CERT_FILE", "SSL_CERT_DIR"}
    env = {key: os.environ[key] for key in sorted(inherited) if key in os.environ}
    env.update({
        "HOME": str(run / "home"), "XDG_CONFIG_HOME": str(run / "config"),
        "XDG_CACHE_HOME": str(run / "cache"), "XDG_DATA_HOME": str(run / "data"),
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
    if args.desktop_host is not None:
        env["FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES"] = json.dumps([str(args.desktop_host.resolve(strict=True))])
    return env


def host_state() -> dict[str, Any]:
    if sys.platform != "linux":
        raise RuntimeError("Native process measurement requires Linux")
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
    # Query the kernel SID without opening every process's stat file. Multiple
    # host-wide stat scans can exhaust cleanup's deadline on a busy host even
    # after the owned service and descendants have already settled.
    with os.scandir("/proc") as entries:
        for entry in entries:
            if not entry.name.isdecimal() or int(entry.name) == session:
                continue
            member = int(entry.name)
            try:
                if os.getsid(member) == session:
                    members.append(member)
            except ProcessLookupError:
                continue
    return members


def live_session_members(session: int) -> list[dict[str, Any]]:
    """Snapshot executing survivors before releasing the pinned session leader."""
    survivors = []
    for member in session_members(session):
        try:
            fields = Path(f"/proc/{member}/stat").read_text().rpartition(")")[2].split()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if int(fields[3]) == session and fields[0] not in {"Z", "X"}:
            survivors.append({"pid": member, "state": fields[0], "process_group": int(fields[2])})
    return survivors


def signal_session_members(session: int, kind: int, *,
                           once: set[tuple[int, str]] | None = None) -> None:
    """Signal verified members through stable pidfds, never recycled PID/PGIDs.

    The caller retains a live/unreaped supervisor to pin the session identity.
    Open the pidfd before checking SID: if a numeric PID is recycled during the
    check, sending through the fd can only reach the original (now dead) task.
    """
    if sys.platform != "linux":
        raise RuntimeError("Native process measurement requires Linux")
    for member in session_members(session):
        try:
            descriptor = os.pidfd_open(member)
        except ProcessLookupError:
            continue
        try:
            if os.getsid(member) == session:
                identity = None
                if once is not None:
                    fields = Path(f"/proc/{member}/stat").read_text().rpartition(")")[2].split()
                    identity = (member, fields[19])  # starttime distinguishes PID reuse.
                    if int(fields[3]) != session or identity in once:
                        continue
                signal.pidfd_send_signal(descriptor, kind)
                # Only record a successful signal to the still-pinned pidfd.
                if once is not None and identity is not None:
                    once.add(identity)
        except (ProcessLookupError, FileNotFoundError):
            pass
        finally:
            os.close(descriptor)


def service_supervisor(service: Path, state: Path) -> None:
    """Keep a live session leader until the service and orphan descendants settle.

    The supervisor is a Linux child subreaper. Even when the service exits first,
    its SID cannot be reused while this process remains alive (or unreaped).
    TERM first asks only the direct service to close its own children. After
    that service exits, TERM settles any remaining orphans across process groups.
    The owner escalates through verified pidfds after a deadline.
    """
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "Cannot establish owned child subreaper")
    stopping = False
    terminated: set[tuple[int, str]] = set()
    service_term_sent = False

    def stop(_signal: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    try:
        child = subprocess.Popen([str(service)])
        details = {"pid": child.pid, "exit_code": None}
        written: dict[str, Any] | None = None
        while True:
            code = child.poll()
            if stopping:
                if code is None and not service_term_sent:
                    child.terminate()
                    service_term_sent = True
                elif code is not None:
                    signal_session_members(os.getpid(), signal.SIGTERM, once=terminated)
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


class RuntimeInventory:
    """Pin mapped files outside sample windows; hash new objects after workloads.

    Known model/runtime hashes are reused only for the same device, inode, size,
    mtime and ctime. Open file descriptors pin newly observed files until hashing.
    Anonymous/special mappings are listed separately; deleted/inaccessible file
    mappings cannot silently qualify. Snapshots include all owned session PGIDs.
    """

    def __init__(self, report: dict[str, Any], *, private_roots: tuple[Path, ...] = (),
                 diagnostic_context: dict[str, str] | None = None):
        self.report = report
        # Optional only for a caller that independently verified its source/Worker
        # cohort. Header identifiers never authenticate their own expected values.
        context = diagnostic_context if diagnostic_context is not None else report.get("diagnostic_context")
        if context is not None and (
            not isinstance(context, dict) or set(context) != {"native_id", "worker_id", "catalog_id"}
            or any(not isinstance(v, str) or re.fullmatch(r"[0-9a-f]{64}", v) is None for v in context.values())
        ):
            raise ValueError("Invalid expected diagnostic context")
        self.diagnostic_context = dict(context) if context is not None else None
        self.diagnostic_handles: dict[tuple[int, int], tuple[int, bytes]] = {}
        self.diagnostic_objects: dict[tuple[int, int], dict[str, Any]] = {}
        self.private_roots = tuple(path.absolute() for path in private_roots)
        self.declared_paths: dict[str, dict[str, Any]] = {}
        self.objects: dict[tuple[int, ...], dict[str, Any]] = {}
        self.pending: dict[tuple[int, ...], BufferedReader] = {}
        self.known: dict[tuple[int, ...], dict[str, Any]] = {}
        self.finished = False
        self.mounts: list[dict[str, Any]] | None = None

    @staticmethod
    def diagnostic_metadata(descriptor: int) -> dict[str, int]:
        metadata = os.fstat(descriptor)
        seals = fcntl.fcntl(descriptor, DIAGNOSTIC_GET_SEALS)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 0
                or metadata.st_size != 16384 or seals != 7
                or fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY):
            raise ValueError("Unsafe diagnostic data handle")
        return {**file_metadata(metadata), "uid": metadata.st_uid, "gid": metadata.st_gid,
                "mode": stat.S_IMODE(metadata.st_mode), "seals": seals}

    @staticmethod
    def diagnostic_key(metadata: dict[str, Any]) -> tuple[int, ...]:
        return tuple(metadata[key] for key in ("device", "inode", "bytes", "links", "uid", "gid", "mode", "seals"))

    def diagnostic_header(self, descriptor: int) -> tuple[bytes, dict[str, int | str]]:
        header = os.pread(descriptor, 256, 0)
        if len(header) != 256 or self.diagnostic_context is None:
            raise ValueError("Incomplete diagnostic header context")
        magic, version, size, generation, parent, child = struct.unpack_from("<IHHQQQ", header)
        identifiers = {name: header[offset:offset + 32].hex() for name, offset in
                       (("native_id", 64), ("worker_id", 96), ("catalog_id", 128))}
        if (magic != 0x5044464F or version != 1 or size != 256 or generation != 1
                or not 1 < parent <= 0x7FFFFFFF or not 1 < child <= 0x7FFFFFFF or parent == child
                or not any(header[32:64]) or any(header[232:256])
                or identifiers != self.diagnostic_context):
            raise ValueError("Unqualified diagnostic header")
        words = struct.unpack_from("<9Q", header, 160)
        if any(word > 0x7FFFFFFFFFFFFFFF for word in words):
            raise ValueError("Invalid diagnostic counters")
        kinds = []
        for word in words[1:3]:
            kind, challenge = word & ~0x1FFFFFFFFFFFFFFF, word & 0x1FFFFFFFFFFFFFFF
            if word and (kind not in (0x2000000000000000, 0x4000000000000000) or not challenge):
                raise ValueError("Invalid diagnostic control kind")
            kinds.append("none" if not word else "probe" if kind == 0x2000000000000000 else "force")
        values: dict[str, int | str] = dict(zip(
            ("parent_heartbeat", "request_published", "request_consumed", "reply_published",
             "reply_consumed", "state", "child_heartbeat"), (words[0], *words[3:]), strict=True,
        ))
        values.update(parent_pid=parent, child_pid=child, control_command_kind=kinds[0], control_ack_kind=kinds[1])
        # Retain the immutable prefix only in memory, including the nonce. Never
        # serialize it or inspect/hash either queue payload.
        return header[:160], values

    @staticmethod
    def diagnostic_peers(parent: int, child: int, pid: int, session: int) -> None:
        if pid not in (parent, child):
            raise ValueError("Diagnostic mapping is not owned by either protocol peer")
        descriptors = []
        try:
            for peer in (parent, child):
                descriptor = os.pidfd_open(peer)
                descriptors.append(descriptor)
                if os.getsid(peer) != session or Path(f"/proc/{peer}").stat().st_uid != os.geteuid():
                    raise ValueError("Diagnostic peer left owned session")
            fields = Path(f"/proc/{child}/stat").read_text().rpartition(")")[2].split()
            if int(fields[1]) != parent or int(fields[3]) != session:
                raise ValueError("Diagnostic child is not the owned direct child")
            for descriptor in descriptors:
                signal.pidfd_send_signal(descriptor, 0)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)

    def mapped_diagnostic(self, pid: int, session: int, fields: list[str]) -> dict[str, Any]:
        if (self.diagnostic_context is None or fields[1] != "rw-s" or int(fields[2], 16) != 0
                or re.fullmatch(r"[0-9a-f]+-[0-9a-f]+", fields[0]) is None):
            raise ValueError("Unqualified diagnostic data mapping")
        first, last = (int(part, 16) for part in fields[0].split("-"))
        if last - first != 16384:
            raise ValueError("Unexpected diagnostic mapping size")
        device = tuple(int(part, 16) for part in fields[3].split(":"))
        descriptor = -1
        retained = False
        try:
            # This kernel-provided symlink is intentionally followed. The narrow
            # observer capability may permit it; failures never become exemptions.
            descriptor = os.open(f"/proc/{pid}/map_files/{fields[0]}", os.O_RDONLY | os.O_CLOEXEC)
            metadata = self.diagnostic_metadata(descriptor)
            if ((os.major(metadata["device"]), os.minor(metadata["device"])) != device
                    or metadata["inode"] != int(fields[4])):
                raise ValueError("Diagnostic mapping identity changed")
            immutable, counters = self.diagnostic_header(descriptor)
            self.diagnostic_peers(int(counters["parent_pid"]), int(counters["child_pid"]), pid, session)
            if (self.diagnostic_header(descriptor)[0] != immutable
                    or self.diagnostic_key(self.diagnostic_metadata(descriptor)) != self.diagnostic_key(metadata)):
                raise ValueError("Diagnostic identity changed during snapshot")
            key = (metadata["device"], metadata["inode"])
            if key in self.diagnostic_handles:
                if (self.diagnostic_handles[key][1] != immutable
                        or self.diagnostic_key(metadata) != self.diagnostic_key(self.diagnostic_objects[key])):
                    raise ValueError("Diagnostic immutable header changed")
            else:
                self.diagnostic_handles[key] = (descriptor, immutable)
                retained = True
                identity = {**metadata, "kind": "sealed diagnostic data", "mapping_permissions": ["rw-s"],
                            "mutable_shared_data": True, "payload_hashed": False, "nonce_nonzero": True,
                            "expected_context": dict(self.diagnostic_context)}
                self.diagnostic_objects[key] = identity
                self.report.setdefault("mapped_diagnostic_data", []).append(identity)
            return {**self.diagnostic_objects[key], "observed_pid": pid, "counters": counters}
        except OSError as error:
            # Do not emit a kernel address, raw header, nonce or payload on error.
            raise ValueError(f"Diagnostic data observation unavailable (errno {error.errno})") from None
        finally:
            if descriptor >= 0 and not retained:
                os.close(descriptor)

    @staticmethod
    def key(identity: dict[str, Any]) -> tuple[int, ...]:
        return tuple(identity[name] for name in ("device", "inode", "bytes", "mtime_ns", "ctime_ns", "links"))

    def seed(self, value: Any) -> None:
        if isinstance(value, dict):
            if "sha256" in value and "device" in value:
                self.known[self.key(value)] = value
                self.declared_paths[value["resolved_path"]] = value
            else:
                for child in value.values():
                    self.seed(child)
        elif isinstance(value, list):
            for child in value:
                self.seed(child)

    def btrfs_device(self, path: Path, device: tuple[int, int]) -> dict[str, Any] | None:
        # Btrfs maps report the filesystem device, whereas stat reports an
        # anonymous device per subvolume. Match the actual covering mount.
        if self.mounts is None:
            text = Path("/proc/self/mountinfo").read_text()
            self.report["mapped_runtime_mountinfo_sha256"] = hashlib.sha256(text.encode()).hexdigest()
            self.mounts = []
            for line in text.splitlines():
                before, _, after = line.partition(" - ")
                fields = before.split()
                mount_path = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), fields[4])
                self.mounts.append({"path": mount_path, "filesystem": after.split()[0],
                                    "device": [int(part) for part in fields[2].split(":")]})
        covering = [mount for mount in self.mounts if path.is_relative_to(mount["path"])]
        if covering:
            mount = max(covering, key=lambda entry: len(entry["path"]))
            if mount["filesystem"] == "btrfs" and tuple(mount["device"]) == device:
                return mount
        return None

    def mapped_file(self, path: Path, device: str, inode: str, permissions: str) -> dict[str, Any]:
        stream = path.open("rb")
        try:
            metadata = os.fstat(stream.fileno())
            major, minor = (int(part, 16) for part in device.split(":"))
            actual_device = (os.major(metadata.st_dev), os.minor(metadata.st_dev))
            mount = None
            if actual_device != (major, minor):
                mount = self.btrfs_device(path.resolve(), (major, minor))
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_ino != int(inode) or (
                actual_device != (major, minor) and mount is None
            ):
                raise ValueError(f"Mapped file identity changed: {path}")
            identity: dict[str, Any] = {"path": str(path), "resolved_path": str(path.resolve()), **file_metadata(metadata)}
            key = self.key(identity)
            declared = self.declared_paths.get(identity["resolved_path"])
            if declared is not None and key != self.key(declared):
                raise ValueError(f"Declared input changed before mapping snapshot: {path}")
            if key not in self.objects:
                if key in self.known:
                    identity.update(sha256=self.known[key]["sha256"], hash_source="qualified input with identical file metadata")
                self.pending[key] = stream
                identity.update(mapping_permissions=[], mutable_shared_data=False, private_data_paths_only=True,
                                mapped_device=[major, minor], btrfs_mount=mount)
                self.objects[key] = identity
                self.report.setdefault("mapped_runtime_files", []).append(identity)
            result = self.objects[key]
            result["mapping_permissions"] = sorted(set([*result["mapping_permissions"], permissions]))
            result["private_data_paths_only"] = result["private_data_paths_only"] and any(
                path.resolve().is_relative_to(root) for root in self.private_roots
            )
            result["mutable_shared_data"] = (
                declared is None and key not in self.known
                and result["private_data_paths_only"]
                and any(p.endswith("s") and "w" in p for p in result["mapping_permissions"])
                and not any("x" in p for p in result["mapping_permissions"])
            )
            return result
        finally:
            if stream not in self.pending.values():
                stream.close()

    def capture(self, session: int, condition: str) -> None:
        if sys.platform != "linux":
            raise RuntimeError("Native process measurement requires Linux")
        self.seed(self.report.get("inputs", {}))
        started = time.perf_counter_ns()
        snapshot: dict[str, Any] = {"condition": condition, "session": session,
                                    "status": "incomplete", "processes": []}
        self.report.setdefault("mapped_runtime_snapshots", []).append(snapshot)
        try:
            for pid in [session, *session_members(session)]:
                process: dict[str, Any] = {"pid": pid}
                snapshot["processes"].append(process)
                try:
                    descriptor = os.pidfd_open(pid)
                except ProcessLookupError:
                    process["status"] = "exited before snapshot"
                    continue
                try:
                    if os.getsid(pid) != session:
                        process["status"] = "left owned session"
                        continue
                    try:
                        maps = Path(f"/proc/{pid}/maps").read_text()
                    except FileNotFoundError:
                        signal.pidfd_send_signal(descriptor, 0)
                        raise
                    signal.pidfd_send_signal(descriptor, 0)
                    process.update(maps_sha256=hashlib.sha256(maps.encode()).hexdigest(), files=[], special_mappings=[])
                    seen = set()
                    diagnostic_seen = set()
                    for line in maps.splitlines():
                        fields = line.split(None, 5)
                        if len(fields) < 6 or fields[5].startswith("["):
                            process["special_mappings"].append(fields[5] if len(fields) == 6 else "anonymous")
                            continue
                        name = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), fields[5])
                        if name.endswith(" (deleted)"):
                            if name == "/memfd:foresight-diagnostic (deleted)" and self.diagnostic_context is not None:
                                identity = self.mapped_diagnostic(pid, session, fields)
                                diagnostic_identity_key = (identity["device"], identity["inode"])
                                if diagnostic_identity_key not in diagnostic_seen:
                                    process.setdefault("diagnostic_data", []).append(identity)
                                    diagnostic_seen.add(diagnostic_identity_key)
                                continue
                            raise ValueError(f"Deleted mapped file cannot be qualified: {name}")
                        if not name.startswith("/"):
                            raise ValueError(f"Unsupported mapped file path: {name}")
                        identity = self.mapped_file(Path(name), fields[3], fields[4], fields[1])
                        key = self.key(identity)
                        if key not in seen:
                            process["files"].append(identity)
                            seen.add(key)
                    process["status"] = "complete"
                except ProcessLookupError:
                    process["status"] = "exited during snapshot"
                finally:
                    os.close(descriptor)
            snapshot["status"] = "complete"
        except BaseException as error:
            snapshot["error"] = repr(error)
            self.report["status"] = "incomplete"
            raise
        finally:
            snapshot["elapsed_ms"] = (time.perf_counter_ns() - started) / 1e6

    def finish(self) -> None:
        if self.finished:
            return
        self.finished = True
        started = time.perf_counter_ns()
        try:
            for diagnostic_identity_key, (descriptor, immutable) in self.diagnostic_handles.items():
                if self.diagnostic_key(self.diagnostic_metadata(descriptor)) != self.diagnostic_key(self.diagnostic_objects[diagnostic_identity_key]):
                    raise ValueError("Diagnostic handle identity changed before finish")
                if self.diagnostic_header(descriptor)[0] != immutable:
                    raise ValueError("Diagnostic immutable header changed before finish")
            for key, stream in self.pending.items():
                identity = self.objects[key]
                before = file_metadata(os.fstat(stream.fileno()))
                changed = self.key(before) != key
                # Unlink only changes ownership metadata for this pinned inode.
                unlinked = before["links"] == 0 and identity["links"] > 0 and self.key(before)[:4] == key[:4]
                if changed and not identity["mutable_shared_data"] and not unlinked:
                    raise ValueError(f"Mapped runtime changed since snapshot: {identity['path']}")
                if "sha256" in identity and not changed:
                    identity.update(final_metadata=before, changed_since_snapshot=False)
                    continue
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
                if before != file_metadata(os.fstat(stream.fileno())):
                    raise ValueError(f"Mapped file changed while hashing: {identity['path']}")
                digest_field = "post_run_sha256" if identity["mutable_shared_data"] else "sha256"
                identity.update({digest_field: digest},
                                hash_source="private mutable shared data, post-run hash" if identity["mutable_shared_data"] else "pinned mapped file, hashed after workloads",
                                hashed_metadata=before, changed_since_snapshot=self.key(before) != key)
        except BaseException as error:
            self.report["mapped_runtime_error"] = repr(error)
            self.report["status"] = "incomplete"
            raise
        finally:
            self.report["mapped_runtime_hash_ms"] = (time.perf_counter_ns() - started) / 1e6
            try:
                for stream in self.pending.values():
                    stream.close()
            finally:
                self.pending.clear()
                close_failed = False
                for descriptor, _ in self.diagnostic_handles.values():
                    try:
                        os.close(descriptor)
                    except OSError:
                        close_failed = True
                self.diagnostic_handles.clear()
                if close_failed:
                    self.report["status"] = "incomplete"
                    active_error = sys.exception()
                    if active_error is not None:
                        active_error.add_note("Diagnostic data handle cleanup failed")
                    else:
                        raise ValueError("Diagnostic data handle cleanup failed")


class Measurement:
    def __init__(self, args: argparse.Namespace, run: Path, report: dict[str, Any]):
        self.args, self.run, self.report = args, run, report
        self.peers: list[Peer] = []
        self.process: subprocess.Popen[bytes] | None = None
        self.thread: threading.Thread | None = None
        self.stream_failures: list[str] = []
        self.stream_chunks: list[dict[str, Any]] = []
        self.last_chunk: str | None = None
        self.summary_id: int | None = None
        self.cleanup_timeout = 30.0
        self.runtime_inventory = RuntimeInventory(report, private_roots=tuple(run / name for name in ("data", "cache", "run", "litert-cache")))

    def connect(self) -> Peer:
        peer = Peer(self.run / "run/application.sock")
        self.peers.append(peer)
        return peer

    def record(self, label: str, peer: Peer) -> None:
        result: dict[str, Any] = {}
        self.report["samples"][label] = result
        self.capture_runtime_mappings(label + ":before samples")
        try:
            result.update(sample(peer, evidence=result, on_status=self.summary_preview))
        finally:
            self.capture_runtime_mappings(label + ":after samples")
        if label == "warmed_streaming":
            result["stream_chunks_during_samples"] = [
                chunk for chunk in self.stream_chunks
                if result["first_status_ns"] < chunk["received_ns"] <= result["last_status_ns"]
            ]
        # Retain raw failing qualifications before raising.
        validate_sample(label, result)

    def capture_runtime_mappings(self, condition: str) -> None:
        if self.process is not None:
            self.runtime_inventory.capture(self.process.pid, condition)
        for peer in self.peers:
            if isinstance(peer, DesktopHostPeer):
                self.runtime_inventory.capture(peer.process.pid, condition + ":native desktop relay")

    def summary_preview(self, status: dict[str, Any], received_ns: int) -> None:
        summaries = (status.get("capture") or {}).get("meeting_summaries") or {}
        summary = summaries.get(str(self.summary_id)) or {}
        if summary.get("active") and native_active(status):
            self.streamed(summary.get("preview"), received_ns=received_ns)

    def streamed(self, value: Any, *, received_ns: int | None = None) -> None:
        if not isinstance(value, str) or not value or value == self.last_chunk:
            return
        self.last_chunk = value
        self.stream_chunks.append({
            "received_ns": time.monotonic_ns() if received_ns is None else received_ns, "characters": len(value),
            "sha256": hashlib.sha256(value.encode()).hexdigest(),
        })

    def workload(self) -> None:
        started = time.monotonic()
        child_environment = environment(self.args, self.run)
        self.report["child_environment"] = child_environment
        self.report["stream_chunks"] = self.stream_chunks
        with (self.run / "service.log").open("wb") as log:
            self.process = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "_supervise",
                 str(self.args.service), str(self.run / "service-state.json")], cwd=self.args.source,
                env=child_environment, stdout=log, stderr=log,
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
        self.verify_service_image()
        control = self.peers[0]
        if self.args.desktop_host is not None:
            evidence: dict[str, Any] = {}
            self.report["desktop_host"] = evidence
            host = DesktopHostPeer(self.args.desktop_host, self.run / "run/application.sock",
                                   self.run / "desktop-host.log", evidence, child_environment)
            self.peers.append(host)
            control.close()
            self.peers.remove(control)
            control = host
        control.call("status")
        self.report["startup_seconds"] = time.monotonic() - started
        attachment: dict[str, Any] = {"token": (self.run / "data/.desktop-capability").read_text()}
        if self.args.desktop_host is not None:
            attachment["visible"] = True
        control.call("security.attach_desktop", attachment)
        for key, value in [("liveEnhance", "false"), ("proactiveAnswers", "false"), ("serviceIdleMinutes", "30")]:
            control.call("preferences.set", {"key": key, "value": value})
        observer = self.connect()
        self.record("idle_before_models", observer)
        control.call("models.embedding", {"path": str(self.args.embedding_model), "gpu": False})
        control.call("models.generation", {"path": str(self.args.generation_model), "runtime": str(self.args.model_worker)})
        self.summary_id = control.call("meetings.create", {"title": "RPC measurement summary"})["id"]
        self.report["streaming_meeting_id"] = self.summary_id
        control.call("meetings.transcript", {"id": self.summary_id, "text": EVIDENCE_TEXT})
        control.call("meetings.generate", {"id": self.summary_id, "kind": "summary"})
        self.record("warmed_idle", observer)

        def stream() -> None:
            try:
                control.call("meetings.generate", {"id": self.summary_id, "kind": "summary"})
            except BaseException as error:
                self.stream_failures.append(repr(error))

        self.thread = threading.Thread(target=stream, daemon=True)
        self.thread.start()

        def generating() -> bool:
            if self.stream_failures:
                raise RuntimeError(f"Generation failed: {self.stream_failures}")
            status = observer.call("status")
            self.summary_preview(status, time.monotonic_ns())
            if native_active(status) and self.stream_chunks:
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

    def verify_service_image(self) -> None:
        state = self.service_state()
        image = file_identity(Path(f"/proc/{state['pid']}/exe"))
        self.report["executed_service_image"] = image
        declared = self.report["inputs"]["service"]
        if image["sha256"] != declared["sha256"] or RuntimeInventory.key(image) != RuntimeInventory.key(declared):
            raise ValueError("Owned service executed image differs from declared service input")

    def close(self) -> None:
        for peer in self.peers:
            peer.interrupt()
        process = self.process
        if process is not None:
            if process.poll() is None:
                # The supervisor asks the service to settle its own children,
                # then signals remaining orphans through verified pidfds.
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass  # The owned process can exit between poll and signal.
                try:
                    process.wait(timeout=self.cleanup_timeout)
                except subprocess.TimeoutExpired:
                    self.report["owned_session_escalated_to_kill"] = True
                    self.report["status"] = "incomplete"
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
                            self.report["owned_session_survivors_before_supervisor_kill"] = live_session_members(process.pid)
                            self.report["status"] = "incomplete"
                            self.report["owned_supervisor_forced_kill"] = True
                            try:
                                process.kill()
                            except ProcessLookupError:
                                pass
                            process.wait(timeout=self.cleanup_timeout)
                            break
            self.report["owned_supervisor_exit_code"] = process.returncode
            if process.returncode != 0:
                self.report["status"] = "incomplete"
                self.report["owned_session_cleanup"] = "not certified by a successful supervisor exit"
            else:
                self.report["owned_session_cleanup"] = "supervisor verified the session empty"
            state = self.service_state()
            graceful = (process.returncode == 0 and state.get("exit_code") == 0
                        and not self.report.get("owned_session_escalated_to_kill"))
            self.report["graceful_shutdown"] = graceful
            if not graceful:
                self.report["status"] = "incomplete"
                if process.returncode == 0:
                    self.report["owned_session_cleanup"] = "session empty after forced or unsuccessful service shutdown"
        if self.thread is not None:
            self.thread.join(5)
            self.report["stream_thread_settled"] = not self.thread.is_alive()
            if self.thread.is_alive():
                self.report["status"] = "incomplete"
        for peer in self.peers:
            peer.close()
            relay = getattr(peer, "evidence", None)
            if isinstance(relay, dict) and "executable" in relay:
                if relay.get("forced_kill") or relay.get("exit_code") != 0:
                    self.report["status"] = "incomplete"
                    self.report["graceful_shutdown"] = False


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
                     "source_text": EVIDENCE_TEXT,
                     "generation": "meetings.generate(kind=summary), synchronous warm then repeated generation",
                     "stream_evidence": "changed nonempty capture.meeting_summaries[id].preview while summary active and native generation loading",
                     "prior_workload": "grounded answer.stream buffers verified output; unsuitable for incremental overlap",
                     "capture_warm_seconds": 8,
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
            try:
                measurement.close()
            finally:
                measurement.runtime_inventory.finish()
        except BaseException as error:
            report["status"], report["cleanup_error"] = "incomplete", repr(error)
            raise
        finally:
            try:
                log = run / "service.log"
                if (run / "desktop-host.log").exists():
                    retained_host = args.output / "desktop-host.log"
                    shutil.copyfile(run / "desktop-host.log", retained_host)
                    report["desktop_host_log"] = file_identity(retained_host)
                if log.exists():
                    report["service_log_source"] = file_identity(log)
                    retained = args.output / "service.log"
                    shutil.copyfile(log, retained)
                    report["service_log"] = file_identity(retained)
            except OSError as error:
                report["status"], report["log_error"] = "incomplete", repr(error)
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
    timed.add_argument("--desktop-host", type=Path,
                       help="explicit native relay executable for a synthetic visible desktop host")
    timed.add_argument("--runtime-file", type=Path, action="append", default=[],
                       help="additional concrete loaded library/runtime to hash, including system-loader dependencies")
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
    args.runtime_file = [path.resolve(strict=True) for path in args.runtime_file]
    if args.desktop_host is not None:
        args.desktop_host = args.desktop_host.resolve(strict=True)
    result = measure(args)
    print(json.dumps({"status": result["status"], "report": str(args.output / "rpc-responsiveness.json")}))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
