"""Offline tests of RPC timing, exact export provenance and owned cleanup."""

import argparse
import hashlib
import io
import json
import os
import sys
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import threading
from types import SimpleNamespace

import pytest

from tools import measure_service_rpc as rpc


def command(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, timeout=30, stderr=subprocess.PIPE)


@pytest.fixture
def export(tmp_path):
    repository = tmp_path / "repository"
    repository.mkdir()
    command(repository, "init", "--quiet")
    (repository / "plain").write_bytes(b"source\n")
    (repository / "executable").write_bytes(b"#!/bin/sh\nexit 0\n")
    (repository / "executable").chmod(0o755)
    (repository / "link").symlink_to("plain")
    (repository / "build").mkdir()
    (repository / "build/tracked").write_text("tracked even under build")
    pins = []
    for filename in rpc.MODEL_NAMES.values():
        data = filename.encode()
        pins.append({"name": filename, "filename": filename, "repository": "fixture/repository",
                     "revision": "a" * 40, "sha256": hashlib.sha256(data).hexdigest(),
                     "bytes": len(data), "minimumMemoryGb": 0})
    pin_file = repository / "packages/foresight_core/lib/src/model_pins.dart"
    pin_file.parent.mkdir(parents=True)
    pin_file.write_text("// BEGIN FORESIGHT MODEL PINS\nconst modelPinsJson = r'''\n" +
                        json.dumps(pins) + "\n''';\n// END FORESIGHT MODEL PINS\n")
    command(repository, "add", ".")
    command(repository, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--quiet", "-m", "fixture")
    commit = command(repository, "rev-parse", "HEAD").decode().strip()
    source = tmp_path / "source"
    source.mkdir()
    with tarfile.open(fileobj=io.BytesIO(command(repository, "archive", "HEAD"))) as archive:
        archive.extractall(source, filter="data")
    return repository, commit, source


@pytest.fixture
def inputs(export, tmp_path):
    repository, commit, source = export
    args = argparse.Namespace(repository=repository, commit=commit, source=source,
                              output=tmp_path / "report", toolchain=["fixture=1"],
                              generated_directory=[], library_path=[], runtime_file=[], desktop_host=None)
    for name in ("service", "helper", "native_library", "model_worker", "litert_library", "whisper_runtime"):
        path = tmp_path / name
        path.write_bytes(name.encode())
        setattr(args, name, path)
    for kind, filename in rpc.MODEL_NAMES.items():
        path = tmp_path / filename
        path.write_bytes(filename.encode())
        setattr(args, kind + "_model", path)
    return args


def test_pristine_export_verifies_bytes_modes_symlink_and_exact_set(export):
    repository, commit, source = export
    report = rpc.verify_export(repository, commit, source)
    assert report["commit"] == commit
    assert {row["mode"] for row in report["files"]} == {"100644", "100755", "120000"}
    assert report["allowed_generated_files"] == []
    assert len(report["files"]) == 5


@pytest.mark.parametrize("change, message", [
    ("content", "blob mismatch"), ("mode", "mode mismatch"),
    ("symlink", "blob mismatch"), ("symlink-mode", "mode mismatch"),
    ("missing", "file set mismatch"), ("extra", "file set mismatch"),
    ("git-file", "Git metadata"), ("git-directory", "Git metadata"),
    ("tracked-generated", "blob mismatch"),
])
def test_export_refuses_modified_inputs_even_inside_generated_paths(export, change, message):
    repository, commit, source = export
    if change == "content":
        (source / "plain").write_text("tampered")
    elif change == "mode":
        (source / "plain").chmod(0o755)
    elif change == "symlink":
        (source / "link").unlink()
        (source / "link").symlink_to("executable")
    elif change == "symlink-mode":
        (source / "link").unlink()
        (source / "link").write_bytes(b"plain")
    elif change == "missing":
        (source / "plain").unlink()
    elif change == "extra":
        (source / "untracked").write_text("not generated")
    elif change == "git-file":
        (source / ".git").write_text("gitdir: elsewhere")
    elif change == "git-directory":
        (source / ".git").mkdir()
    else:
        (source / "build/tracked").write_text("tampered tracked build file")
    with pytest.raises(ValueError, match=message):
        rpc.verify_export(repository, commit, source, allow_generated=True)


def test_generated_allowance_is_explicit_and_only_applies_to_additional_files(export):
    repository, commit, source = export
    names = ["test-results/run.json", "coverage/lcov.info", "build/native/lib.so", ".dart_tool/state",
             "app/linux/flutter/ephemeral/generated", ".coverage.worker", ".flutter-plugins-dependencies",
             "__pycache__/script.pyc", ".ruff_cache/data", "custom/output/object"]
    for name in names:
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"generated")
    with pytest.raises(ValueError, match="file set mismatch"):
        rpc.verify_export(repository, commit, source)
    with pytest.raises(ValueError, match="custom/output/object"):
        rpc.verify_export(repository, commit, source, allow_generated=True)
    result = rpc.verify_export(repository, commit, source, allow_generated=True, additional=("custom/output",))
    assert result["allowed_generated_files"] == sorted(names)


@pytest.mark.parametrize("prefix", ["/absolute", "../outside", ".git", ""])
def test_generated_directory_cannot_escape_export(export, prefix):
    repository, commit, source = export
    with pytest.raises(ValueError, match="generated-directory"):
        rpc.verify_export(repository, commit, source, additional=(prefix,))


def test_unsupported_git_entry_is_refused(export, monkeypatch):
    repository, commit, source = export
    original = rpc.git
    monkeypatch.setattr(rpc, "git", lambda repo, *args: (
        b"160000 commit abc\tsubmodule\0" if args[0] == "ls-tree" else original(repo, *args)
    ))
    with pytest.raises(ValueError, match="Unsupported Git entry"):
        rpc.verify_export(repository, commit, source)


def test_models_and_all_binary_inputs_are_hashed_directly_from_actual_bytes(inputs):
    result = rpc.verify_inputs(inputs)
    assert len(result) == 10
    assert result["service"]["sha256"] == hashlib.sha256(b"service").hexdigest()
    assert result["speech_model"]["pin"]["filename"] == rpc.MODEL_NAMES["speech"]
    inputs.generation_model.write_bytes(b"wrong pinned model")
    with pytest.raises(ValueError, match="Model does not match exported pin"):
        rpc.verify_inputs(inputs)


def test_model_size_is_verified_even_if_digest_matches(inputs, monkeypatch):
    original = rpc.file_identity
    monkeypatch.setattr(rpc, "file_identity", lambda path: {
        **original(path), "bytes": -1,
    })
    with pytest.raises(ValueError, match="Model does not match exported pin"):
        rpc.verify_inputs(inputs)


def status(*, generating=False, state="ready", capture=False, samples=0):
    return {"generation": {"generating": generating, "state": state},
            "capture": {"active": capture, "state": "capturing", "samples": [samples]}}


def test_sampling_has_100_roundtrips_correct_percentiles_and_raw_state(monkeypatch):
    clock = iter(i * 1_000_000 for value in range(100) for i in (0, value + 1))
    monkeypatch.setattr(rpc.time, "perf_counter_ns", lambda: next(clock))
    peer = SimpleNamespace(call=lambda method: status(generating=True, state="loading", capture=True, samples=5))
    result = rpc.sample(peer, delay=0)
    assert result["n"] == 100
    assert result["p50_ms"] == 50.5
    assert result["p95_ms"] == 95
    assert result["max_ms"] == 100
    assert result["target_met"] is False
    assert result["native_active_count"] == result["capture_active_count"] == 100
    assert result["raw_ms"] == list(range(1, 101))
    assert result["state_evidence"][0]["samples"] == [5]


@pytest.mark.parametrize("wire, native, capture", [
    ({}, False, False), ({"generation": None, "capture": None}, False, False),
    (status(generating=True), False, False),
    (status(state="loading"), False, False),
    (status(generating=True, state="loading", capture=True), True, True),
    ({"capture": {"active": True, "state": "capturing", "paused": True}}, False, False),
    ({"capture": {"active": True, "state": "capturing", "finishing": True}}, False, False),
    ({"capture": {"active": True, "state": "starting"}}, False, False),
])
def test_native_overlap_and_capture_require_actual_workload_state(wire, native, capture):
    assert rpc.native_active(wire) is native
    assert rpc.capture_active(wire) is capture


def test_sample_validation_requires_every_overlap_and_pcm_progress():
    result = {"native_active_count": 99, "capture_active_count": 100,
              "generation_active_count": 0, "stream_chunks_during_samples": [1],
              "state_evidence": [{"samples": [5]}, {"samples": [5]}]}
    with pytest.raises(RuntimeError, match="native generation"):
        rpc.validate_sample("warmed_streaming", result)
    result["native_active_count"] = 100
    rpc.validate_sample("warmed_streaming", result)
    with pytest.raises(RuntimeError, match="progress PCM"):
        rpc.validate_sample("warmed_capture", result)
    result["state_evidence"][-1]["samples"] = [6]
    rpc.validate_sample("warmed_capture", result)
    result["capture_active_count"] = 99
    with pytest.raises(RuntimeError, match="progress PCM"):
        rpc.validate_sample("warmed_capture", result)


def test_wait_until_is_bounded_and_polls(monkeypatch):
    times = iter([0, 1, 2])
    monkeypatch.setattr(rpc.time, "monotonic", lambda: next(times))
    monkeypatch.setattr(rpc.time, "sleep", lambda seconds: None)
    with pytest.raises(TimeoutError, match="required state"):
        rpc.wait_until(lambda: False, timeout=2)
    times = iter([0, 0])
    flags = iter([False, True])
    rpc.wait_until(lambda: next(flags))


@pytest.fixture
def private(tmp_path):
    # pytest's temp root is configured by the invoking TMPDIR; this directory is
    # independently short and private so socket protocol tests are deterministic.
    import tempfile
    root = Path(tempfile.mkdtemp(prefix="rpc-unit-", dir="/var/tmp"))
    root.chmod(0o700)
    yield root
    shutil.rmtree(root)


def test_private_root_rejects_public_modes_and_non_var_tmp(private, tmp_path, monkeypatch):
    assert rpc.private_root(private) == private
    child = private / "child"
    assert rpc.private_root(child) == child
    private.chmod(0o755)
    with pytest.raises(ValueError, match="0700"):
        rpc.private_root(private)
    private.chmod(0o700)
    monkeypatch.setattr(rpc.os, "getuid", lambda: -1)
    with pytest.raises(ValueError, match="owned by this user"):
        rpc.private_root(private)
    with pytest.raises(ValueError, match="under /var/tmp"):
        rpc.private_root(Path("/tmp/unacceptable"))


def test_environment_clears_injected_hooks_and_records_explicit_runtime_paths(inputs, private, monkeypatch):
    monkeypatch.setenv("FORESIGHT_CRASH_AT", "hostile")
    monkeypatch.setenv("FORESIGHT_STARTUP_ENV", "hostile")
    monkeypatch.setenv("LD_LIBRARY_PATH", "/unqualified")
    inputs.library_path = [Path("/explicit/one"), Path("/explicit/two")]
    env = rpc.environment(inputs, private)
    assert "FORESIGHT_CRASH_AT" not in env
    assert "FORESIGHT_STARTUP_ENV" not in env
    assert env["FORESIGHT_NATIVE"] == str(inputs.native_library)
    assert env["FORESIGHT_LITERT_BACKEND"] == "cpu"
    assert env["LD_LIBRARY_PATH"] == "/explicit/one:/explicit/two"
    assert (private / "pw-record").stat().st_mode & 0o777 == 0o700
    assert "os.write(out, block)" in (private / "pw-record").read_text()


class FakeSocket:
    def __init__(self, lines=()):
        self.lines = io.BytesIO(b"".join(lines))
        self.closed = False
        self.sent = []

    def settimeout(self, value):
        self.timeout = value

    def connect(self, path):
        self.path = path

    def recv(self, size):
        return self.lines.readline()

    def sendall(self, value):
        self.sent.append(json.loads(value))

    def shutdown(self, how):
        self.interrupted = True

    def close(self):
        self.closed = True


def test_peer_filters_events_preserves_result_and_has_operation_deadline(monkeypatch):
    sock = FakeSocket([b'{"event":"status"}\n', b'{"id":1,"result":{"value":3}}\n',
                       b'{"id":1,"done":true}\n'])
    monkeypatch.setattr(rpc.socket, "socket", lambda *args: sock)
    peer = rpc.Peer(Path("/fixture.sock"))
    assert peer.call("status") == {"value": 3}
    assert sock.sent == [{"id": 1, "method": "status", "args": {}}]
    peer.interrupt()
    peer.close()
    assert sock.closed


@pytest.mark.parametrize("lines, message", [
    ([], "Service disconnected"),
    ([b'{"id":1,"error":{"code":"busy"}}\n'], "RPC status"),
])
def test_peer_rejects_disconnection_and_rpc_errors(monkeypatch, lines, message):
    monkeypatch.setattr(rpc.socket, "socket", lambda *args: FakeSocket(lines))
    peer = rpc.Peer(Path("/fixture.sock"))
    with pytest.raises(RuntimeError, match=message):
        peer.call("status")
    peer.close()


def test_peer_event_flood_cannot_extend_deadline(monkeypatch):
    sock = FakeSocket([b'{"event":"status"}\n'])
    monkeypatch.setattr(rpc.socket, "socket", lambda *args: sock)
    peer = rpc.Peer(Path("/fixture.sock"), timeout=1)
    times = iter([0, 0, .1, .1, 1.1])
    monkeypatch.setattr(rpc.time, "monotonic", lambda: next(times))
    with pytest.raises(TimeoutError, match="RPC deadline"):
        peer.call("status")
    peer.close()


def test_peer_closes_failed_connect_and_ignores_shutdown_of_closed_socket(monkeypatch):
    sock = FakeSocket()
    def refuse(path):
        raise ConnectionRefusedError("not ready")
    sock.connect = refuse
    monkeypatch.setattr(rpc.socket, "socket", lambda *args: sock)
    with pytest.raises(ConnectionRefusedError):
        rpc.Peer(Path("/fixture.sock"))
    assert sock.closed
    sock.connect = lambda path: None
    peer = rpc.Peer(Path("/fixture.sock"))
    sock.shutdown = lambda how: (_ for _ in ()).throw(OSError("already closed"))
    peer.interrupt()
    peer.close()


class WorkPeer:
    def __init__(self, path, state=None):
        self.path = path
        self.calls = []
        self.samples = 0
        self.state = state if state is not None else {}
        self.interrupted = self.closed = False

    def call(self, method, arguments=None, *, on_result=None):
        self.calls.append((method, arguments))
        if method == "status":
            self.samples += 1
            if self.state.get("on_result") and self.state.get("generating"):
                self.state["on_result"](f"Changed answer chunk {self.samples}")
            result = status(generating=self.state.get("generating", False),
                            state="loading" if self.state.get("generating") else "ready",
                            capture=self.state.get("capturing", False), samples=self.samples)
            result["capture"]["meeting_summaries"] = {
                "7": {"active": self.state.get("generating", False), "preview": f"Summary chunk {self.samples}"}
            }
            return result
        if method == "meetings.generate":
            self.state["summary_runs"] = self.state.get("summary_runs", 0) + 1
            # The warm summary settles before sampling; the second is async.
            self.state["generating"] = self.state["summary_runs"] > 1
        if method == "meetings.start":
            self.state["capturing"] = True
        if method == "meetings.stop":
            self.state["capturing"] = False
        if method == "meetings.create":
            return {"id": 7}
        return None

    def interrupt(self):
        self.interrupted = True

    def close(self):
        self.closed = True


class FakeProcess:
    pid = 12345
    returncode = None

    def terminate(self):
        pass

    def kill(self):
        self.returncode = -9

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.returncode = -15


class FakeThread:
    def __init__(self, target=None, daemon=False):
        self.target = target
        self.alive = True

    def start(self):
        self.target()

    def join(self, timeout):
        self.alive = False

    def is_alive(self):
        return self.alive


@pytest.fixture
def workload(inputs, private, monkeypatch):
    inputs.temp_root = private
    state = {}
    monkeypatch.setattr(rpc.Measurement, "capture_runtime_mappings", lambda self, condition: None)
    monkeypatch.setattr(rpc.Measurement, "verify_service_image", lambda self: None)
    monkeypatch.setattr(rpc, "Peer", lambda path: WorkPeer(path, state))
    monkeypatch.setattr(rpc.subprocess, "Popen", lambda *args, **kwargs: FakeProcess())
    class PhaseThread(FakeThread):
        def join(self, timeout):
            super().join(timeout)
            if not self.alive:
                state["generating"] = False
    monkeypatch.setattr(rpc.threading, "Thread", PhaseThread)
    monkeypatch.setattr(rpc.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(rpc.os, "killpg", lambda pid, sig: None)
    (private / "data").mkdir()
    (private / "data/.desktop-capability").write_text("private fixture capability")
    report = {"samples": {}, "inputs": rpc.verify_inputs(inputs)}
    return rpc.Measurement(inputs, private, report)


def test_full_workload_records_warm_stream_and_pcm_conditions_and_cleans_up(workload):
    workload.workload()
    assert workload.report["status"] == "passed"
    assert set(workload.report["samples"]) == {"idle_before_models", "warmed_idle", "warmed_streaming", "warmed_capture"}
    assert all(row["n"] == 100 for row in workload.report["samples"].values())
    assert workload.peers[0].calls[-1] == ("meetings.stop", {})
    workload.close()
    assert workload.report["owned_supervisor_exit_code"] == -15
    assert workload.report["stream_thread_settled"] is True
    assert all(peer.closed and peer.interrupted for peer in workload.peers)


def test_workload_keeps_performance_target_miss_honest(workload, monkeypatch):
    original = rpc.sample
    monkeypatch.setattr(rpc, "sample", lambda peer, **kwargs: {**original(peer, delay=0, **kwargs), "target_met": False})
    workload.workload()
    assert workload.report["status"] == "performance_target_missed"
    workload.close()


def test_workload_retries_connect_and_reports_early_process_exit(workload, monkeypatch):
    original = workload.connect
    calls = []
    def connect():
        calls.append(1)
        if len(calls) == 1:
            raise FileNotFoundError("not ready")
        return original()
    monkeypatch.setattr(workload, "connect", connect)
    workload.workload()
    assert len(calls) == 3
    workload.close()
    monkeypatch.setattr(workload, "connect", lambda: (_ for _ in ()).throw(ConnectionRefusedError()))
    monkeypatch.setattr(rpc.subprocess, "Popen", lambda *a, **kw: SimpleNamespace(pid=12345, poll=lambda: 2))
    with pytest.raises(RuntimeError, match="exited during startup"):
        workload.workload()


def test_generation_without_native_overlap_and_generation_failure_are_refused(workload, monkeypatch):
    monkeypatch.setattr(rpc, "native_active", lambda wire: False)
    monkeypatch.setattr(FakeThread, "start", lambda self: setattr(self, "alive", False))
    with pytest.raises(RuntimeError, match="before native overlap"):
        workload.workload()
    workload.close()


def test_stream_exception_is_retained_and_refused_after_settlement(workload, monkeypatch):
    original = WorkPeer.call
    def call(self, method, args=None, **kwargs):
        if method == "meetings.generate" and self.state.get("summary_runs"):
            raise RuntimeError("native fixture failure")
        return original(self, method, args, **kwargs)
    monkeypatch.setattr(WorkPeer, "call", call)
    with pytest.raises(RuntimeError, match="native fixture failure"):
        workload.workload()
    assert "native fixture failure" in workload.stream_failures[0]
    workload.close()


def test_stream_thread_must_settle_and_capture_must_start(workload, monkeypatch):
    monkeypatch.setattr(FakeThread, "join", lambda self, timeout: None)
    with pytest.raises(RuntimeError, match="did not settle"):
        workload.workload()
    workload.close()
    assert workload.report["status"] == "incomplete"


def test_capture_waits_for_active_state_before_counting_progress(workload, monkeypatch):
    original = rpc.capture_active
    calls = []
    def active(wire):
        calls.append(1)
        return len(calls) > 302 and original(wire)
    monkeypatch.setattr(rpc, "capture_active", active)
    workload.workload()
    assert workload.report["status"] == "passed"
    workload.close()


def test_failed_qualification_retains_all_raw_samples(workload, monkeypatch):
    monkeypatch.setattr(rpc, "sample", lambda peer, **_kwargs: {"native_active_count": 0, "raw_ms": [1] * 100, "first_status_ns": 0, "last_status_ns": 1})
    with pytest.raises(RuntimeError, match="native generation"):
        workload.record("warmed_streaming", WorkPeer(Path("fixture")))
    assert len(workload.report["samples"]["warmed_streaming"]["raw_ms"]) == 100


def test_close_kills_verified_session_members_on_deadline_and_joins_thread(workload, monkeypatch):
    process = FakeProcess()
    calls = []
    waits = []
    def wait(timeout):
        waits.append(timeout)
        if len(waits) == 1:
            raise subprocess.TimeoutExpired("fixture", timeout)
        process.returncode = -9
    process.wait = wait
    workload.process = process
    workload.thread = FakeThread()
    process.terminate = lambda: calls.append(("supervisor", process.pid, rpc.signal.SIGTERM))
    monkeypatch.setattr(rpc, "signal_session_members", lambda sid, sig: calls.append(("session", sid, sig)))
    workload.close()
    assert calls == [("supervisor", process.pid, rpc.signal.SIGTERM), ("session", process.pid, rpc.signal.SIGKILL)]
    assert workload.report["owned_session_escalated_to_kill"] is True
    assert waits == [30, .05]
    assert workload.report["owned_supervisor_exit_code"] == -9



def test_close_tolerates_process_exit_between_poll_and_signals(workload, monkeypatch):
    process = FakeProcess()
    waits = []
    def wait(timeout):
        waits.append(timeout)
        if len(waits) == 1:
            raise subprocess.TimeoutExpired("fixture", timeout)
        process.returncode = 0
    process.wait = wait
    workload.process = process
    def gone():
        raise ProcessLookupError("already exited")
    process.terminate = gone
    workload.close()
    assert workload.report["owned_supervisor_exit_code"] == 0

def test_close_leaves_already_exited_process_alone(workload, monkeypatch):
    process = FakeProcess()
    process.returncode = 3
    workload.process = process
    process.terminate = lambda: pytest.fail("must not signal exited PID")
    workload.close()
    assert workload.report["owned_supervisor_exit_code"] == 3
    assert workload.report["status"] == "incomplete"
    assert "not certified" in workload.report["owned_session_cleanup"]


def test_host_records_resource_limits_and_absent_optional_proc_files(monkeypatch):
    assert "load" in rpc.host_state()
    monkeypatch.setattr(Path, "is_file", lambda path: False)
    report = rpc.host_state()
    assert report["memory"] is None
    assert report["cpu_quota"] is None


def test_measure_writes_failure_report_even_when_provenance_refuses_work(inputs, private, monkeypatch):
    inputs.temp_root = private
    (inputs.source / "plain").write_text("tampered")
    monkeypatch.setattr(rpc.Measurement, "workload", lambda self: pytest.fail("no launch before verification"))
    with pytest.raises(ValueError, match="blob mismatch"):
        rpc.measure(inputs)
    report = json.loads((inputs.output / "rpc-responsiveness.json").read_text())
    assert report["status"] == "incomplete"
    assert "blob mismatch" in report["error"]
    assert "host_after" in report
    assert Path(report["run"]).stat().st_mode & 0o777 == 0o700


def test_measure_report_has_source_commit_binary_model_toolchain_and_workload(inputs, private, monkeypatch):
    inputs.temp_root = private
    monkeypatch.setattr(rpc.Measurement, "workload", lambda self: self.report.update(status="passed"))
    result = rpc.measure(inputs)
    assert result["source"]["commit"] == inputs.commit
    assert result["inputs"]["helper"]["sha256"] == hashlib.sha256(b"helper").hexdigest()
    assert result["toolchain"] == {"fixture": "1"}
    assert result["workload"]["status_samples_per_condition"] == 100
    assert result["runner"]["sha256"]


def test_measure_keeps_report_if_cleanup_itself_fails(inputs, private, monkeypatch):
    inputs.temp_root = private
    monkeypatch.setattr(rpc.Measurement, "workload", lambda self: self.report.update(status="passed"))
    monkeypatch.setattr(rpc.Measurement, "close", lambda self: (_ for _ in ()).throw(RuntimeError("cleanup")))
    with pytest.raises(RuntimeError, match="cleanup"):
        rpc.measure(inputs)
    report = json.loads((inputs.output / "rpc-responsiveness.json").read_text())
    assert report["status"] == "incomplete"
    assert "cleanup" in report["cleanup_error"]


def cli_args(args):
    return ["--repository", str(args.repository), "--commit", args.commit, "--source", str(args.source),
            "--output", str(args.output)]


def test_cli_pristine_check_and_measurement_return_codes(inputs, private, monkeypatch, capsys, native_relay):
    assert rpc.main(["verify-export", *cli_args(inputs)]) == 0
    assert json.loads(inputs.output.read_text())["commit"] == inputs.commit
    inputs.output.unlink()
    arguments = ["measure", *cli_args(inputs), "--temp-root", str(private), "--toolchain", "dart=3.9.2",
                 "--library-path", str(private), "--generated-directory", "custom-build"]
    for name in ("service", "helper", "native_library", "model_worker", "litert_library", "whisper_runtime",
                 "generation_model", "embedding_model", "speech_model"):
        arguments += ["--" + name.replace("_", "-"), str(getattr(inputs, name))]
    monkeypatch.setattr(rpc, "measure", lambda args: {"status": "passed"})
    assert rpc.main(arguments) == 0
    def host_measure(args):
        assert args.desktop_host == native_relay.resolve()
        return {"status": "passed"}
    monkeypatch.setattr(rpc, "measure", host_measure)
    assert rpc.main([*arguments, "--desktop-host", str(native_relay)]) == 0
    monkeypatch.setattr(rpc, "measure", lambda args: {"status": "performance_target_missed"})
    assert rpc.main(arguments) == 1
    assert "performance_target_missed" in capsys.readouterr().out
    for bad in ["missing-equals", "=empty-name", "empty-value="]:
        arguments[arguments.index("dart=3.9.2")] = bad
        with pytest.raises(SystemExit) as error:
            rpc.main(arguments)
        assert error.value.code == 2
        arguments[arguments.index(bad)] = "dart=3.9.2"


def test_module_entrypoint_uses_pristine_export_command(inputs):
    result = subprocess.run([rpc.sys.executable, "-m", "tools.measure_service_rpc", "verify-export", *cli_args(inputs)],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr


def test_real_socket_peer_receives_interleaved_status_events_and_reply(private):
    listener = socket.socket(socket.AF_UNIX)
    path = private / "socket"
    listener.bind(str(path))
    listener.listen(1)
    failures = []
    def serve():
        try:
            connection, _ = listener.accept()
            with connection, connection.makefile("rb") as stream:
                request = json.loads(stream.readline())
                connection.sendall(b'{"event":"status"}\n' + json.dumps({
                    "id": request["id"], "result": {"live": True}, "done": True,
                }).encode() + b"\n")
        except BaseException as error:
            failures.append(error)
    thread = threading.Thread(target=serve)
    thread.start()
    try:
        peer = rpc.Peer(path, timeout=2)
        assert peer.call("status") == {"live": True}
        peer.close()
    finally:
        thread.join(3)
        listener.close()
    assert not thread.is_alive()
    assert not failures


def test_partial_sampling_retains_successes_and_failed_attempt_in_report(inputs, private, monkeypatch):
    inputs.temp_root = private
    calls = 0

    def call(_method):
        nonlocal calls
        calls += 1
        if calls == 4:
            raise RuntimeError("status transport failed mid-condition")
        return status(generating=True, state="loading", samples=calls)

    def workload(measurement):
        measurement.record("warmed_streaming", SimpleNamespace(call=call))

    monkeypatch.setattr(rpc.Measurement, "workload", workload)
    monkeypatch.setattr(rpc.time, "sleep", lambda _delay: None)
    with pytest.raises(RuntimeError, match="mid-condition"):
        rpc.measure(inputs)
    report = json.loads((inputs.output / "rpc-responsiveness.json").read_text())
    assert report["status"] == "incomplete"
    sample = report["samples"]["warmed_streaming"]
    assert sample["status"] == "incomplete"
    assert sample["n"] == len(sample["raw_ms"]) == len(sample["state_evidence"]) == 3
    assert len(sample["attempts"]) == 4
    assert sample["attempts"][-1]["index"] == 3
    assert sample["attempts"][-1]["elapsed_ms"] >= 0
    assert "mid-condition" in sample["attempts"][-1]["error"]
    assert [row["samples"] for row in sample["state_evidence"]] == [[1], [2], [3]]
    assert "p95_ms" not in sample


@pytest.mark.skipif(sys.platform != "linux", reason="Owned process-session supervision uses Linux child subreaping and /proc")
@pytest.mark.parametrize("ignore_term,stop_supervisor", [(False, False), (True, False), (True, True)])
def test_real_supervisor_cleans_descendant_after_service_exits(private, ignore_term, stop_supervisor):
    descendant = private / "descendant.pid"
    child_script = "import time; time.sleep(20)"
    if ignore_term:
        child_script = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)"
    # The service waits for its descendant to install signal policy before exit.
    ready = private / "ready"
    child_script = child_script.replace("time.sleep(20)", f"open({str(ready)!r},'w').close(); time.sleep(20)")
    service = private / "service"
    service.write_text(f"#!{sys.executable}\nimport subprocess,time\n"
                       f"child=subprocess.Popen([{sys.executable!r},'-c',{child_script!r}],process_group=0)\n"
                       f"open({str(descendant)!r},'w').write(str(child.pid))\n"
                       f"while not __import__('os').path.exists({str(ready)!r}): time.sleep(.01)\n")
    service.chmod(0o700)
    state = private / "service-state.json"
    process = subprocess.Popen([sys.executable, str(Path(rpc.__file__).resolve()),
                                "_supervise", str(service), str(state)],
                               start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    measurement = rpc.Measurement(SimpleNamespace(), private, {})
    measurement.process = process
    measurement.cleanup_timeout = .3
    child_handle = None
    try:
        rpc.wait_until(lambda: state.exists() and json.loads(state.read_text())["exit_code"] is not None, timeout=5)
        service_state = json.loads(state.read_text())
        assert service_state["exit_code"] == 0
        assert service_state["pid"] != process.pid
        child = int(descendant.read_text())
        assert child in rpc.session_members(process.pid)
        assert os.getpgid(child) == child
        assert os.getsid(child) == process.pid
        assert process.poll() is None, "Supervisor must retain group ownership after service exits"
        child_handle = os.pidfd_open(child)
        if stop_supervisor:
            os.kill(process.pid, rpc.signal.SIGSTOP)
        measurement.close()
        assert measurement.report["owned_service_exit_code"] == 0
        assert measurement.report["owned_service_pid"] == service_state["pid"]
        assert measurement.report["owned_supervisor_exit_code"] == (-9 if stop_supervisor else 0)
        if stop_supervisor:
            assert measurement.report["status"] == "incomplete"
            assert measurement.report["owned_session_survivors_before_supervisor_kill"] == []
        elif ignore_term:
            assert measurement.report["owned_session_escalated_to_kill"] is True
            assert measurement.report["status"] == "incomplete"
            assert measurement.report["graceful_shutdown"] is False
        else:
            assert measurement.report["owned_session_cleanup"] == "supervisor verified the session empty"
            assert measurement.report["graceful_shutdown"] is True
        # The supervisor reaps on graceful exit; after SIGKILL, init may still
        # own a dead zombie briefly. Neither case leaves an executing child.
        def stopped():
            path = Path(f"/proc/{child}/stat")
            return not path.exists() or path.read_text().rpartition(")")[2].split()[0] == "Z"
        rpc.wait_until(stopped, timeout=5)
    finally:
        if child_handle is not None:
            try:
                rpc.signal.pidfd_send_signal(child_handle, rpc.signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.close(child_handle)
        if process.poll() is None:
            rpc.signal_session_members(process.pid, rpc.signal.SIGKILL)
            os.killpg(process.pid, rpc.signal.SIGKILL)
        out, err = process.communicate(timeout=5)
        assert process.returncode in {0, -9}, (out, err)


def test_supervisor_membership_ignores_disappearing_process_and_parses_comm(monkeypatch):
    entries = [SimpleNamespace(name="self"), SimpleNamespace(name="10"),
               SimpleNamespace(name="11"), SimpleNamespace(name="12"), SimpleNamespace(name="13")]
    monkeypatch.setattr(Path, "iterdir", lambda _path: entries)
    def stat(entry, _name):
        if entry.name == "11":
            raise FileNotFoundError("exited")
        if entry.name == "12":
            raise ProcessLookupError("exited")
        return SimpleNamespace(read_text=lambda: "13 (name with ) spaces) S 1 99 10 0")
    # SimpleNamespace cannot overload '/', so adapt the numeric fixture entries.
    class Entry:
        def __init__(self, name):
            self.name = name
        def __truediv__(self, name):
            return stat(self, name)
    monkeypatch.setattr(Path, "iterdir", lambda _path: [Entry(row.name) for row in entries])
    assert rpc.session_members(10) == [13]


def test_supervisor_refuses_missing_subreaper_before_launch(monkeypatch):
    monkeypatch.setattr(rpc.ctypes, "CDLL", lambda *args, **kwargs: SimpleNamespace(prctl=lambda *args: -1))
    monkeypatch.setattr(rpc.ctypes, "get_errno", lambda: 1)
    monkeypatch.setattr(rpc.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("must not launch without ownership"))
    with pytest.raises(OSError, match="subreaper"):
        rpc.service_supervisor(Path("unused"), Path("unused"))


def test_unexpected_supervisor_error_kills_its_still_owned_group(monkeypatch, capsys):
    signals = []
    handlers = {}
    monkeypatch.setattr(rpc.ctypes, "CDLL", lambda *args, **kwargs: SimpleNamespace(prctl=lambda *args: 0))
    monkeypatch.setattr(rpc.signal, "signal", lambda kind, handler: handlers.update({kind: handler}))
    monkeypatch.setattr(rpc.os, "killpg", lambda group, kind: signals.append((group, kind)))
    monkeypatch.setattr(rpc.subprocess, "Popen", lambda *args, **kwargs: (_ for _ in ()).throw(OSError("exec failed")))
    with pytest.raises(OSError, match="exec failed"):
        rpc.service_supervisor(Path("missing-service"), Path("unused"))
    assert signals == [(os.getpid(), rpc.signal.SIGKILL)]
    assert rpc.signal.SIGTERM in handlers
    assert "exec failed" in capsys.readouterr().err


@pytest.mark.parametrize("race", ["owned", "wrong session", "open exited", "lookup exited", "send exited"])
def test_session_signals_verify_sid_after_pidfd_open_and_ignore_pid_reuse(monkeypatch, race):
    calls = []
    monkeypatch.setattr(rpc, "session_members", lambda session: [17])
    def opened(pid):
        calls.append(("open", pid))
        if race == "open exited":
            raise ProcessLookupError()
        return 71
    def session(pid):
        calls.append(("sid", pid))
        if race == "lookup exited":
            raise ProcessLookupError()
        return 99 if race == "wrong session" else 10
    def sent(descriptor, kind):
        calls.append(("signal", descriptor, kind))
        if race == "send exited":
            raise ProcessLookupError()
    monkeypatch.setattr(rpc.os, "pidfd_open", opened, raising=False)
    monkeypatch.setattr(rpc.os, "getsid", session)
    monkeypatch.setattr(rpc.signal, "pidfd_send_signal", sent, raising=False)
    monkeypatch.setattr(rpc.os, "close", lambda descriptor: calls.append(("close", descriptor)))
    rpc.signal_session_members(10, rpc.signal.SIGKILL)
    expected = [("open", 17)]
    if race != "open exited":
        expected.append(("sid", 17))
        if race in {"owned", "send exited"}:
            expected.append(("signal", 71, rpc.signal.SIGKILL))
        expected.append(("close", 71))
    assert calls == expected


def test_runtime_inventory_records_search_order_and_actual_dependency_bytes(inputs, tmp_path):
    first, second = tmp_path / "first", tmp_path / "second"
    first.mkdir()
    second.mkdir()
    library = first / "libdependency.so.1"
    library.write_bytes(b"runtime bytes")
    (first / "libdependency.so").symlink_to(library.name)
    nested = first / "nested"
    nested.mkdir()
    (nested / "not-searched.so").write_bytes(b"not in direct loader search")
    explicit = second / "system-runtime.so"
    explicit.write_bytes(b"explicit runtime")
    inputs.library_path = [first]
    inputs.runtime_file = [explicit]
    result = rpc.verify_inputs(inputs)["runtime_libraries"]
    assert result["LD_LIBRARY_PATH"] == str(first)
    assert result["search_directories"] == [str(first)]
    files = {row["path"]: row for row in result["files"]}
    assert set(files) == {str(library), str(first / "libdependency.so"), str(explicit)}
    assert files[str(first / "libdependency.so")]["resolved_path"] == str(library)
    assert files[str(library)]["sha256"] == hashlib.sha256(b"runtime bytes").hexdigest()
    assert files[str(explicit)]["sha256"] == hashlib.sha256(b"explicit runtime").hexdigest()


@pytest.mark.parametrize("variable", ["LD_PRELOAD", "LD_AUDIT"])
def test_child_environment_refuses_loader_injection_without_echoing_value(inputs, private, monkeypatch, variable):
    monkeypatch.setenv(variable, "fixture-secret-loader")
    with pytest.raises(ValueError, match=variable) as error:
        rpc.environment(inputs, private)
    assert "fixture-secret-loader" not in str(error.value)
    assert not (private / "pw-record").exists()


def test_child_environment_inherits_only_recordable_allowlist(inputs, private, monkeypatch):
    monkeypatch.setenv("LANG", "C.UTF-8")
    monkeypatch.setenv("HOME", "/unrelated/personal/home")
    for variable in ["AWS_SECRET_ACCESS_KEY", "PYTHONPATH", "DBUS_SESSION_BUS_ADDRESS"]:
        monkeypatch.setenv(variable, "fixture-private-value")
    result = rpc.environment(inputs, private)
    assert result["LANG"] == "C.UTF-8"
    assert result["HOME"] == str(private / "home")
    assert result["XDG_CONFIG_HOME"] == str(private / "config")
    assert result["XDG_DATA_HOME"] == str(private / "data")
    assert not {"AWS_SECRET_ACCESS_KEY", "PYTHONPATH", "DBUS_SESSION_BUS_ADDRESS"}.intersection(result)


def test_peer_delivers_every_interleaved_stream_result_to_callback(monkeypatch):
    sock = FakeSocket([b'{"event":"status"}\n', b'{"id":1,"result":"First"}\n',
                       b'{"id":1,"result":"First second"}\n', b'{"id":1,"done":true}\n'])
    monkeypatch.setattr(rpc.socket, "socket", lambda *args: sock)
    peer = rpc.Peer(Path("/fixture.sock"))
    received = []
    assert peer.call("answer.stream", on_result=received.append) == "First second"
    assert received == ["First", "First second"]
    peer.close()


def test_stream_evidence_only_counts_changed_nonempty_text(workload, monkeypatch):
    times = iter([100, 200])
    monkeypatch.setattr(rpc.time, "monotonic_ns", lambda: next(times))
    for value in [None, {}, "", "First", "First", "First second"]:
        workload.streamed(value)
    assert workload.stream_chunks == [
        {"received_ns": 100, "characters": 5, "sha256": hashlib.sha256(b"First").hexdigest()},
        {"received_ns": 200, "characters": 12, "sha256": hashlib.sha256(b"First second").hexdigest()},
    ]


@pytest.mark.parametrize("inside", [False, True])
def test_streaming_qualification_requires_a_chunk_inside_status_sample_window(workload, monkeypatch, inside):
    workload.stream_chunks = [{"received_ns": 99}, {"received_ns": 201}]
    if inside:
        workload.stream_chunks.append({"received_ns": 150})
    def sample(peer, *, evidence, on_status):
        evidence.update(native_active_count=100, first_status_ns=100, last_status_ns=200)
        return evidence
    monkeypatch.setattr(rpc, "sample", sample)
    if inside:
        workload.record("warmed_streaming", None)
    else:
        with pytest.raises(RuntimeError, match="between first and last"):
            workload.record("warmed_streaming", None)
    assert workload.report["samples"]["warmed_streaming"]["stream_chunks_during_samples"] == (
        [{"received_ns": 150}] if inside else []
    )


@pytest.mark.parametrize("label,generation,capture", [
    ("idle_before_models", 1, 0), ("idle_before_models", 0, 1),
    ("warmed_idle", 1, 0), ("warmed_idle", 0, 1), ("warmed_capture", 1, 100),
])
def test_idle_and_capture_conditions_reject_wrong_workload_overlap(label, generation, capture):
    with pytest.raises(RuntimeError, match="condition contained active generation|Idle condition"):
        rpc.validate_sample(label, {"generation_active_count": generation, "capture_active_count": capture})


@pytest.mark.parametrize("failure", [False, True])
def test_complete_and_failed_reports_copy_and_hash_service_output(inputs, private, monkeypatch, failure):
    inputs.temp_root = private
    output = b"Full service output\nincluding arbitrary bytes: \xff\n"
    def workload(measurement):
        (measurement.run / "service.log").write_bytes(output)
        if failure:
            raise RuntimeError("workload failed after output")
        measurement.report["status"] = "passed"
    monkeypatch.setattr(rpc.Measurement, "workload", workload)
    if failure:
        with pytest.raises(RuntimeError, match="after output"):
            rpc.measure(inputs)
    else:
        rpc.measure(inputs)
    report = json.loads((inputs.output / "rpc-responsiveness.json").read_text())
    assert (inputs.output / "service.log").read_bytes() == output
    assert report["service_log"]["path"] == str(inputs.output / "service.log")
    assert report["service_log"]["sha256"] == hashlib.sha256(output).hexdigest()
    assert report["service_log_source"]["sha256"] == report["service_log"]["sha256"]
    assert report["status"] == ("incomplete" if failure else "passed")


def test_log_retention_failure_keeps_source_digest_and_incomplete_json(inputs, private, monkeypatch):
    inputs.temp_root = private
    def workload(measurement):
        (measurement.run / "service.log").write_text("retained source log")
        measurement.report["status"] = "passed"
    monkeypatch.setattr(rpc.Measurement, "workload", workload)
    monkeypatch.setattr(rpc.shutil, "copyfile", lambda *args: (_ for _ in ()).throw(OSError("copy storage failure")))
    rpc.measure(inputs)
    report = json.loads((inputs.output / "rpc-responsiveness.json").read_text())
    assert report["status"] == "incomplete"
    assert "copy storage failure" in report["log_error"]
    assert report["service_log_source"]["sha256"] == hashlib.sha256(b"retained source log").hexdigest()


def test_idle_refuses_paused_capture_even_without_progress():
    peer = SimpleNamespace(call=lambda method: {
        "capture": {"active": True, "state": "capturing", "paused": True},
    })
    result = rpc.sample(peer, delay=0)
    assert result["capture_active_count"] == 0
    assert result["capture_present_count"] == 100
    with pytest.raises(RuntimeError, match="Idle condition"):
        rpc.validate_sample("warmed_idle", result)


def test_cleanup_snapshot_records_only_live_members_of_pinned_session(monkeypatch):
    monkeypatch.setattr(rpc, "session_members", lambda session: [11, 12, 13, 14, 15, 16])
    def stat(path):
        pid = int(path.parent.name)
        if pid == 11:
            raise FileNotFoundError()
        if pid == 12:
            raise ProcessLookupError()
        state, session = {13: ("Z", 10), 14: ("X", 10), 15: ("S", 99), 16: ("D", 10)}[pid]
        return f"{pid} (fixture) {state} 1 88 {session} 0"
    monkeypatch.setattr(Path, "read_text", stat)
    assert rpc.live_session_members(10) == [{"pid": 16, "state": "D", "process_group": 88}]


# A real native byte relay exercises the OS peer identity and pipe transport.
NATIVE_RELAY_SOURCE = r'''
#include <cerrno>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
int main(int argc, char** argv) {
  if (argc != 2 || strlen(argv[1]) >= sizeof(sockaddr_un::sun_path)) return 2;
  int peer = socket(AF_UNIX, SOCK_STREAM, 0);
  if (peer < 0) return 3;
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  strcpy(address.sun_path, argv[1]);
  if (connect(peer, reinterpret_cast<sockaddr*>(&address), sizeof(address))) return 4;
  pollfd streams[2]{{STDIN_FILENO, POLLIN, 0}, {peer, POLLIN, 0}};
  char bytes[16384];
  while (true) {
    if (poll(streams, 2, -1) < 0) { if (errno == EINTR) continue; return 5; }
    for (int i = 0; i < 2; ++i) {
      if (!(streams[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      auto count = read(streams[i].fd, bytes, sizeof(bytes));
      if (count <= 0) { close(peer); return 0; }
      ssize_t offset = 0;
      int output = i == 0 ? peer : STDOUT_FILENO;
      while (offset < count) {
        auto sent = write(output, bytes + offset, count - offset);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return 6;
        offset += sent;
      }
    }
  }
}
'''


@pytest.fixture(scope="module")
def native_relay(tmp_path_factory):
    directory = tmp_path_factory.mktemp("native-relay")
    source = directory / "relay.cpp"
    source.write_text(NATIVE_RELAY_SOURCE)
    executable = directory / "desktop-relay"
    built = subprocess.run(["c++", "-std=c++17", "-O0", str(source), "-o", str(executable)],
                           capture_output=True, text=True, timeout=30)
    assert built.returncode == 0, built.stdout + built.stderr
    return executable


@pytest.fixture
def relay_server(private):
    servers = []

    def start(handler):
        path = private / f"relay-{len(servers)}.sock"
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path))
        listener.listen()
        stop, entered = threading.Event(), threading.Event()
        state = SimpleNamespace(connection=None, errors=[], stop=stop, entered=entered, path=path)

        def serve():
            try:
                connection, _ = listener.accept()
                state.connection = connection
                entered.set()
                handler(connection, stop)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Deadline/cancellation intentionally closes the owned peer.
            except BaseException as error:
                if not stop.is_set():
                    state.errors.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        servers.append((listener, state, thread))
        return state

    yield start
    for listener, state, thread in servers:
        state.stop.set()
        if state.connection is not None:
            state.connection.close()
        listener.close()
        thread.join(3)
        assert not thread.is_alive(), "owned fake service did not settle"
        assert not state.errors, state.errors


def relay_request(connection):
    with connection.makefile("rb") as reader:
        return json.loads(reader.readline())


def test_native_relay_is_actual_socket_peer_and_records_executable_exit_and_log(native_relay, relay_server, private, monkeypatch):
    import struct
    seen = {}

    def respond(connection, stop):
        seen["pid"] = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
        request = relay_request(connection)
        connection.sendall((json.dumps({"event": "status"}) + "\n" +
                            json.dumps({"id": request["id"], "result": "first"}) + "\n" +
                            json.dumps({"id": request["id"], "result": "second", "done": True}) + "\n").encode())
        connection.recv(1)

    service = relay_server(respond)
    evidence = {}
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", evidence, {}, timeout=1)
    # Nonblocking readiness may race; both retry paths must preserve the deadline.
    original_read, original_write = os.read, os.write
    attempts = {"read": 0, "write": 0}

    def once(kind, original, *args):
        attempts[kind] += 1
        if attempts[kind] == 1:
            raise BlockingIOError()
        return original(*args)

    monkeypatch.setattr(rpc.os, "read", lambda *args: once("read", original_read, *args))
    monkeypatch.setattr(rpc.os, "write", lambda *args: once("write", original_write, *args))
    chunks = []
    try:
        assert peer.call("answer.stream", on_result=chunks.append) == "second"
        assert chunks == ["first", "second"]
        assert seen["pid"] == peer.process.pid == evidence["pid"]
        assert evidence["executed_image"]["sha256"] == rpc.file_identity(native_relay)["sha256"]
    finally:
        peer.close()
        peer.close()
    assert evidence["exit_code"] == 0
    assert evidence["log"]["sha256"] == hashlib.sha256(b"").hexdigest()
    assert "not graphical acceptance" in evidence["kind"]


@pytest.mark.parametrize("mode", ["partial", "events", "hung", "blocked-write"])
def test_native_relay_absolute_deadline_survives_partial_lines_events_and_blocked_pipes(native_relay, relay_server, private, mode):
    def respond(connection, stop):
        if mode == "blocked-write":
            stop.wait(3)
            return
        relay_request(connection)
        while not stop.wait(.005):
            if mode == "partial":
                connection.sendall(b" ")
            elif mode == "events":
                connection.sendall(b'{"event":"status"}\n')

    service = relay_server(respond)
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", {}, {}, timeout=.15, close_timeout=.2)
    started = rpc.time.monotonic()
    try:
        with pytest.raises(TimeoutError, match="RPC deadline exceeded: status"):
            peer.call("status", {"large": "x" * 4_000_000} if mode == "blocked-write" else {})
        assert rpc.time.monotonic() - started < 3
    finally:
        service.stop.set()
        peer.close()
    assert peer.process.returncode is not None


def test_native_relay_cancel_interrupts_pending_read_and_reaps_process(native_relay, relay_server, private):
    service = relay_server(lambda connection, stop: stop.wait(3))
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", {}, {}, close_timeout=.2)
    errors = []

    def call():
        try:
            peer.call("status")
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=call)
    thread.start()
    assert service.entered.wait(2)
    peer.interrupt()
    thread.join(2)
    assert not thread.is_alive()
    assert len(errors) == 1 and "interrupted" in str(errors[0])
    peer.close()
    assert peer.process.returncode == 0


def test_native_relay_stopped_process_has_bounded_escalated_cleanup(native_relay, relay_server, private):
    import signal
    service = relay_server(lambda connection, stop: stop.wait(3))
    evidence = {}
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", evidence, {}, close_timeout=.1)
    try:
        assert service.entered.wait(2)
        os.kill(peer.process.pid, signal.SIGSTOP)
    finally:
        peer.close()
    assert evidence["forced_kill"] is True
    assert evidence["exit_code"] == -signal.SIGKILL


@pytest.mark.parametrize("failure", ["setup", "image"])
def test_native_relay_constructor_failure_closes_owned_process(native_relay, relay_server, private, monkeypatch, failure):
    service = relay_server(lambda connection, stop: connection.recv(1))
    evidence = {}
    if failure == "setup":
        monkeypatch.setattr(rpc.os, "set_blocking", lambda *args: (_ for _ in ()).throw(OSError("setup failed")))
        expected, message = OSError, "setup failed"
    else:
        original = rpc.file_identity
        def identity(path):
            value = original(path)
            if str(path).startswith("/proc/"):
                value["sha256"] = "different"
            return value
        monkeypatch.setattr(rpc, "file_identity", identity)
        expected, message = ValueError, "different image"
    with pytest.raises(expected, match=message):
        rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", evidence, {})
    assert evidence["exit_code"] == 0
    assert evidence["log"]["sha256"]


def test_native_relay_waits_for_parent_to_native_exec_transition(native_relay, relay_server, private, monkeypatch):
    service = relay_server(lambda connection, stop: stop.wait(3))
    original = rpc.file_identity
    parent_path = Path(f"/proc/{os.getpid()}/exe")
    parent = original(parent_path)
    observed = []

    def identity(path):
        if str(path).startswith("/proc/") and path != parent_path:
            observed.append(path)
            if len(observed) <= 2:
                return dict(parent)
        return original(path)

    monkeypatch.setattr(rpc, "file_identity", identity)
    evidence = {}
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", evidence, {})
    try:
        assert len(observed) == 3
        assert evidence["executed_image"]["sha256"] == original(native_relay)["sha256"]
        assert evidence["executed_image"]["sha256"] != parent["sha256"]
    finally:
        peer.close()


def test_native_relay_rejects_parent_image_that_never_executes(native_relay, relay_server, private, monkeypatch):
    service = relay_server(lambda connection, stop: stop.wait(3))
    original = rpc.file_identity
    parent_path = Path(f"/proc/{os.getpid()}/exe")
    parent = original(parent_path)

    def identity(path):
        if str(path).startswith("/proc/"):
            return dict(parent)
        return original(path)

    monkeypatch.setattr(rpc, "file_identity", identity)
    evidence = {}
    with pytest.raises(ValueError, match="different image"):
        rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", evidence, {}, timeout=.03)
    assert evidence["exit_code"] == 0
    assert evidence["log"]["sha256"]


@pytest.mark.parametrize("name, data, mode, error", [
    ("relay", b"#!/bin/sh\n", 0o755, "native ELF"),
    ("relay", b"\x7fELF", 0o644, "native ELF"),
    ("python3.13", b"\x7fELF", 0o755, "interpreter"),
    ("renamed", b"\x7fELF\0Py_Main", 0o755, "interpreter"),
    ("renamed", b"\x7fELF\0Dart_Initialize", 0o755, "interpreter"),
])
def test_native_host_refuses_scripts_sdk_and_nonexecutables(private, name, data, mode, error):
    path = private / name
    path.write_bytes(data)
    path.chmod(mode)
    with pytest.raises(ValueError, match=error):
        rpc.desktop_host_identity(path)


def test_native_host_input_hash_and_environment_are_explicit(inputs, private, native_relay, monkeypatch):
    monkeypatch.setenv("FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES", '["untrusted"]')
    assert "FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES" not in rpc.environment(inputs, private)
    link = private / "relay-link"
    link.symlink_to(native_relay)
    inputs.desktop_host = link
    assert rpc.verify_inputs(inputs)["desktop_host"]["sha256"] == rpc.file_identity(native_relay)["sha256"]
    assert json.loads(rpc.environment(inputs, private)["FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES"]) == [str(native_relay.resolve())]


def test_workload_native_host_attaches_visible_and_replaces_plain_control(workload, native_relay, monkeypatch):
    workload.args.desktop_host = native_relay
    hosts = []
    def create(executable, path, log, evidence, environment):
        assert executable == native_relay
        assert json.loads(environment["FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES"]) == [str(native_relay.resolve())]
        host = WorkPeer(path, workload.peers[0].state)
        hosts.append(host)
        evidence.update(pid=123, kind="synthetic native UI peer")
        return host
    monkeypatch.setattr(rpc, "DesktopHostPeer", create)
    workload.workload()
    assert ("security.attach_desktop", {"token": "private fixture capability", "visible": True}) in hosts[0].calls
    assert workload.report["desktop_host"]["pid"] == 123
    workload.close()


def test_native_host_evidence_log_is_retained_on_failure(inputs, private, native_relay, monkeypatch):
    inputs.desktop_host, inputs.temp_root = native_relay, private
    def fail(measurement):
        (measurement.run / "desktop-host.log").write_bytes(b"relay failure\n")
        raise RuntimeError("failed relay")
    monkeypatch.setattr(rpc.Measurement, "workload", fail)
    with pytest.raises(RuntimeError, match="failed relay"):
        rpc.measure(inputs)
    report = json.loads((inputs.output / "rpc-responsiveness.json").read_text())
    assert report["status"] == "incomplete"
    assert report["desktop_host_log"]["sha256"] == hashlib.sha256(b"relay failure\n").hexdigest()


def test_native_relay_eof_is_reported_as_disconnection(native_relay, relay_server, private):
    def respond(connection, stop):
        relay_request(connection)
        connection.sendall(b'{"id":1')
        connection.shutdown(socket.SHUT_RDWR)
    service = relay_server(respond)
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", {}, {})
    try:
        with pytest.raises(RuntimeError, match="Service disconnected"):
            peer.call("status")
    finally:
        peer.close()


def test_native_host_flag_cannot_bypass_exact_source_precheck(inputs, private, native_relay, monkeypatch):
    inputs.desktop_host, inputs.temp_root = native_relay, private
    (inputs.source / "plain").write_text("tampered")
    monkeypatch.setattr(rpc, "DesktopHostPeer", lambda *args, **kwargs: pytest.fail("unverified export launched host"))
    with pytest.raises(ValueError, match="blob mismatch"):
        rpc.measure(inputs)


@pytest.mark.parametrize("mode", ["partial", "events", "hung", "blocked-write"])
def test_direct_peer_absolute_deadline_bounds_partial_lines_and_events(relay_server, mode):
    def respond(connection, stop):
        if mode == "blocked-write":
            stop.wait(3)
            return
        relay_request(connection)
        while not stop.wait(.005):
            if mode == "partial":
                connection.sendall(b" ")
            elif mode == "events":
                connection.sendall(b'{"event":"status"}\n')
    service = relay_server(respond)
    peer = rpc.Peer(service.path, timeout=.15)
    started = rpc.time.monotonic()
    try:
        with pytest.raises(TimeoutError):
            peer.call("status", {"large": "x" * 4_000_000} if mode == "blocked-write" else {})
        assert rpc.time.monotonic() - started < 3
    finally:
        service.stop.set()
        peer.close()


@pytest.mark.parametrize("active,native,meeting,preview,accepted", [
    (True, True, "7", "Actual model preview", True),
    (False, True, "7", "Completed preview", False),
    (True, False, "7", "Preview before native inference", False),
    (True, True, "8", "Another meeting", False),
    (True, True, "7", "", False),
])
def test_summary_evidence_requires_same_active_meeting_and_actual_native_work(workload, active, native, meeting, preview, accepted):
    workload.summary_id = 7
    wire = status(generating=native, state="loading" if native else "ready")
    wire["capture"]["meeting_summaries"] = {meeting: {"active": active, "preview": preview}}
    workload.summary_preview(wire, 123)
    workload.summary_preview(wire, 124)
    assert len(workload.stream_chunks) == int(accepted)
    if accepted:
        assert workload.stream_chunks == [{"received_ns": 123, "characters": len(preview),
                                           "sha256": hashlib.sha256(preview.encode()).hexdigest()}]


def test_summary_workload_warms_then_regenerates_real_summary_contract(workload):
    workload.workload()
    calls = workload.peers[0].calls
    assert [method for method, _ in calls].count("meetings.generate") == 2
    assert ("meetings.transcript", {"id": 7, "text": rpc.EVIDENCE_TEXT}) in calls
    assert all(method not in {"answer", "answer.stream"} for method, _ in calls)
    sample = workload.report["samples"]["warmed_streaming"]
    assert sample["native_active_count"] == 100
    assert len(sample["stream_chunks_during_samples"]) == 99
    assert sample["stream_chunks_during_samples"][0]["received_ns"] > sample["first_status_ns"]
    assert sample["stream_chunks_during_samples"][-1]["received_ns"] == sample["last_status_ns"]
    workload.close()


def test_supervisor_sends_graceful_term_once_and_waits_for_real_service_cleanup(private):
    ready = private / "graceful.ready"
    finished = private / "graceful.finished"
    service = private / "graceful-service"
    service.write_text(f'''#!{sys.executable}
import signal,time
stopping = False
def stop(kind, frame):
    global stopping
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    stopping = True
signal.signal(signal.SIGTERM, stop)
open({str(ready)!r}, 'w').close()
while not stopping: time.sleep(.01)
time.sleep(.2)
open({str(finished)!r}, 'w').close()
''')
    service.chmod(0o700)
    state = private / "service-state.json"
    process = subprocess.Popen([sys.executable, str(Path(rpc.__file__).resolve()), "_supervise", str(service), str(state)],
                               start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    measurement = rpc.Measurement(SimpleNamespace(), private, {})
    measurement.process, measurement.cleanup_timeout = process, 2
    try:
        rpc.wait_until(lambda: ready.exists() and state.exists(), timeout=5)
        measurement.close()
        assert finished.exists(), "A repeated TERM interrupted graceful cleanup"
        assert measurement.report["owned_service_exit_code"] == 0
        assert measurement.report["owned_supervisor_exit_code"] == 0
        assert not measurement.report.get("owned_session_escalated_to_kill")
    finally:
        if process.poll() is None:
            rpc.signal_session_members(process.pid, rpc.signal.SIGKILL)
            process.kill()
        out, err = process.communicate(timeout=5)
        assert process.returncode == 0, (out, err)


def test_term_once_tracks_process_start_and_new_descendants_without_signalling_reused_session(monkeypatch):
    calls = []
    starts = {17: "100"}
    monkeypatch.setattr(rpc, "session_members", lambda session: list(starts))
    monkeypatch.setattr(rpc.os, "pidfd_open", lambda pid: pid, raising=False)
    monkeypatch.setattr(rpc.os, "getsid", lambda pid: 10)
    monkeypatch.setattr(rpc.os, "close", lambda fd: None)
    monkeypatch.setattr(rpc.signal, "pidfd_send_signal", lambda fd, kind: calls.append(fd), raising=False)
    def stat(path):
        pid = int(path.parts[2])
        return f'{pid} (test) S 1 17 10 ' + '0 ' * 15 + starts[pid]
    monkeypatch.setattr(Path, "read_text", stat)
    once = set()
    rpc.signal_session_members(10, rpc.signal.SIGTERM, once=once)
    rpc.signal_session_members(10, rpc.signal.SIGTERM, once=once)
    starts[18] = "101"
    rpc.signal_session_members(10, rpc.signal.SIGTERM, once=once)
    starts[17] = "102"
    rpc.signal_session_members(10, rpc.signal.SIGTERM, once=once)
    assert calls == [17, 18, 17]
    assert once == {(17, "100"), (18, "101"), (17, "102")}


def test_term_once_does_not_certify_failed_signal_or_signal_process_that_left_session(monkeypatch):
    monkeypatch.setattr(rpc, "session_members", lambda session: [17])
    monkeypatch.setattr(rpc.os, "pidfd_open", lambda pid: pid, raising=False)
    monkeypatch.setattr(rpc.os, "getsid", lambda pid: 10)
    monkeypatch.setattr(rpc.os, "close", lambda fd: None)
    monkeypatch.setattr(Path, "read_text", lambda path: '17 (test) S 1 17 10 ' + '0 ' * 15 + '100')
    monkeypatch.setattr(rpc.signal, "pidfd_send_signal", lambda fd, kind: (_ for _ in ()).throw(ProcessLookupError()), raising=False)
    once = set()
    rpc.signal_session_members(10, rpc.signal.SIGTERM, once=once)
    assert not once
    monkeypatch.setattr(Path, "read_text", lambda path: '17 (test) S 1 17 99 ' + '0 ' * 15 + '100')
    monkeypatch.setattr(rpc.signal, "pidfd_send_signal", lambda *args: pytest.fail("moved outside session"), raising=False)
    rpc.signal_session_members(10, rpc.signal.SIGTERM, once=once)
    assert not once


def map_line(path, permissions="r--p"):
    metadata = path.stat()
    return f"1000-2000 {permissions} 00000000 {os.major(metadata.st_dev):x}:{os.minor(metadata.st_dev):x} {metadata.st_ino} {path}\n"


def fake_maps(monkeypatch, text, session=41):
    original = Path.read_text
    monkeypatch.setattr(rpc, "session_members", lambda sid: [])
    monkeypatch.setattr(rpc.os, "pidfd_open", lambda pid: pid, raising=False)
    monkeypatch.setattr(rpc.os, "getsid", lambda pid: session)
    monkeypatch.setattr(rpc.os, "close", lambda fd: None)
    monkeypatch.setattr(rpc.signal, "pidfd_send_signal", lambda fd, kind: None, raising=False)
    monkeypatch.setattr(Path, "read_text", lambda path: text if str(path).startswith("/proc/") else original(path))


def test_maps_inventory_reuses_qualified_model_hash_and_deduplicates_snapshots(private, monkeypatch):
    model = private / "mapped model"
    model.write_bytes(b"known model bytes")
    identity = rpc.file_identity(model)
    fake_maps(monkeypatch, map_line(model) + map_line(model) + "2000-3000 rw-p 0 00:00 0\n" +
              "3000-4000 r-xp 0 00:00 0 [vdso]\n")
    report = {"inputs": {"models": [identity]}}
    inventory = rpc.RuntimeInventory(report)
    monkeypatch.setattr(rpc.hashlib, "file_digest", lambda *args: pytest.fail("known model rehashed"))
    inventory.capture(41, "idle:before")
    inventory.capture(41, "idle:after")
    inventory.finish()
    inventory.finish()
    assert not inventory.pending
    assert len(report["mapped_runtime_files"]) == 1
    assert report["mapped_runtime_files"][0]["sha256"] == identity["sha256"]
    assert report["mapped_runtime_files"][0]["hash_source"].startswith("qualified input")
    assert all(snapshot["status"] == "complete" for snapshot in report["mapped_runtime_snapshots"])
    assert report["mapped_runtime_snapshots"][0]["processes"][0]["special_mappings"] == ["anonymous", "[vdso]"]


def test_maps_inventory_pins_unlisted_files_and_hashes_only_after_workload(private, monkeypatch):
    path = private / "implicit runtime.so"
    path.write_bytes(b"actual mapped dependency")
    fake_maps(monkeypatch, map_line(path, "r-xp"))
    report = {}
    inventory = rpc.RuntimeInventory(report)
    inventory.capture(41, "streaming:before")
    assert "sha256" not in report["mapped_runtime_files"][0]
    pending = list(inventory.pending.values())
    path.unlink()  # Open descriptors retain the actual observed inode.
    inventory.finish()
    assert all(stream.closed for stream in pending)
    identity = report["mapped_runtime_files"][0]
    assert identity["sha256"] == hashlib.sha256(b"actual mapped dependency").hexdigest()
    assert identity["changed_since_snapshot"]  # unlink changed ctime, not mapped contents
    assert report["mapped_runtime_hash_ms"] >= 0


@pytest.mark.parametrize("failure", ["deleted", "missing", "inode", "relative", "maps-denied", "maps-missing"])
def test_maps_refuse_unqualified_mapping_and_keep_failure_snapshot(private, monkeypatch, failure):
    path = private / "runtime.so"
    path.write_bytes(b"runtime")
    text = map_line(path)
    if failure == "deleted":
        text = text.rstrip() + " (deleted)\n"
    elif failure == "missing":
        path.unlink()
    elif failure == "inode":
        text = text.replace(str(path.stat().st_ino), "999999")
    elif failure == "relative":
        text = "1000-2000 r--p 0 00:00 1 relative-path\n"
    fake_maps(monkeypatch, text)
    if failure in {"maps-denied", "maps-missing"}:
        error = PermissionError if failure == "maps-denied" else FileNotFoundError
        monkeypatch.setattr(Path, "read_text", lambda path: (_ for _ in ()).throw(error("cannot read maps")))
    report = {"status": "passed"}
    inventory = rpc.RuntimeInventory(report)
    try:
        with pytest.raises((ValueError, FileNotFoundError, PermissionError)):
            inventory.capture(41, "warmed_streaming:before")
    finally:
        inventory.finish()
    snapshot = report["mapped_runtime_snapshots"][0]
    assert snapshot["status"] == "incomplete" and snapshot["error"]
    assert snapshot["elapsed_ms"] >= 0
    assert report["status"] == "incomplete"


@pytest.mark.parametrize("race", ["open-exited", "left-session", "read-exited"])
def test_maps_snapshot_accounts_for_exited_and_moved_processes(private, monkeypatch, race):
    fake_maps(monkeypatch, "")
    if race == "open-exited":
        monkeypatch.setattr(rpc.os, "pidfd_open", lambda pid: (_ for _ in ()).throw(ProcessLookupError()), raising=False)
    elif race == "left-session":
        monkeypatch.setattr(rpc.os, "getsid", lambda pid: 99)
    else:
        monkeypatch.setattr(rpc.signal, "pidfd_send_signal", lambda *args: (_ for _ in ()).throw(ProcessLookupError()), raising=False)
    report = {}
    rpc.RuntimeInventory(report).capture(41, "capture:after")
    snapshot = report["mapped_runtime_snapshots"][0]
    assert snapshot["status"] == "complete"
    assert snapshot["processes"][0]["status"] != "complete"


@pytest.mark.parametrize("mutable", [False, True])
def test_maps_record_mutable_shared_data_and_refuse_changed_runtime(private, monkeypatch, mutable):
    data = private / "data"
    data.mkdir()
    path = data / "mapped"
    path.write_bytes(b"before")
    fake_maps(monkeypatch, map_line(path, "rw-s" if mutable else "r-xp"))
    report = {}
    inventory = rpc.RuntimeInventory(report, private_roots=(data,))
    inventory.capture(41, "before")
    pending = list(inventory.pending.values())
    path.write_bytes(b"after changed")
    if mutable:
        inventory.finish()
        assert report["mapped_runtime_files"][0]["changed_since_snapshot"]
        assert "sha256" not in report["mapped_runtime_files"][0]
        assert report["mapped_runtime_files"][0]["post_run_sha256"] == hashlib.sha256(b"after changed").hexdigest()
    else:
        with pytest.raises(ValueError, match="changed since snapshot"):
            inventory.finish()
        assert report["status"] == "incomplete" and report["mapped_runtime_error"]
    assert all(stream.closed for stream in pending)


def test_maps_observations_surround_rpc_window_and_survive_sampling_failure(workload, monkeypatch):
    events = []
    monkeypatch.setattr(workload, "capture_runtime_mappings", lambda label: events.append(label))
    def fail(peer, *, evidence, on_status):
        events.append("RPC sample window")
        evidence.update(raw_ms=[1, 2], status="incomplete")
        raise RuntimeError("sample failed")
    monkeypatch.setattr(rpc, "sample", fail)
    with pytest.raises(RuntimeError, match="sample failed"):
        workload.record("warmed_streaming", None)
    assert events == ["warmed_streaming:before samples", "RPC sample window", "warmed_streaming:after samples"]
    assert workload.report["samples"]["warmed_streaming"]["raw_ms"] == [1, 2]


def test_real_maps_inventory_discovers_implicit_native_library_in_worker_subgroup(private):
    library = private / "implicit runtime.so"
    compiled = subprocess.run(["c++", "-x", "c++", "-shared", "-fPIC", "-o", str(library), "-"],
                              input='extern "C" int fixture_value() { return 7; }',
                              text=True, capture_output=True, timeout=30)
    assert compiled.returncode == 0, compiled.stdout + compiled.stderr
    ready = private / "worker.ready"
    child_code = f"import ctypes,time; runtime=ctypes.CDLL({str(library)!r}); assert runtime.fixture_value()==7; open({str(ready)!r},'w').close(); time.sleep(20)"
    service = private / "maps-service"
    service.write_text(f"#!{sys.executable}\nimport subprocess,time\nsubprocess.Popen([{sys.executable!r},'-c',{child_code!r}],process_group=0)\ntime.sleep(20)\n")
    service.chmod(0o700)
    state = private / "service-state.json"
    process = subprocess.Popen([sys.executable, str(Path(rpc.__file__).resolve()), "_supervise", str(service), str(state)],
                               start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    report = {}
    inventory = rpc.RuntimeInventory(report)
    measurement = rpc.Measurement(SimpleNamespace(), private, report)
    measurement.process, measurement.cleanup_timeout = process, 2
    try:
        rpc.wait_until(lambda: ready.exists() and state.exists(), timeout=5)
        inventory.capture(process.pid, "warmed_streaming:before samples")
        mapped = [entry for entry in report["mapped_runtime_files"] if entry["path"] == str(library)]
        assert len(mapped) == 1 and "sha256" not in mapped[0]
        owner = next(entry for entry in report["mapped_runtime_snapshots"][0]["processes"]
                     if mapped[0] in entry.get("files", []))
        assert owner["pid"] != process.pid and os.getpgid(owner["pid"]) == owner["pid"]
        inventory.finish()
        assert mapped[0]["sha256"] == rpc.file_identity(library)["sha256"]
        assert "r-xp" in mapped[0]["mapping_permissions"]
        measurement.close()
        assert report["owned_supervisor_exit_code"] == 0
    finally:
        inventory.finish()
        if process.poll() is None:
            rpc.signal_session_members(process.pid, rpc.signal.SIGKILL)
            process.kill()
        out, err = process.communicate(timeout=5)
        assert process.returncode in {0, -9}, (out, err)


def test_file_and_deferred_mapping_hash_reject_concurrent_content_change(private, monkeypatch):
    path = private / "changing-runtime"
    path.write_bytes(b"before")
    original = rpc.hashlib.file_digest
    def changed(stream, algorithm):
        digest = original(stream, algorithm)
        path.write_bytes(b"different bytes")
        return digest
    monkeypatch.setattr(rpc.hashlib, "file_digest", changed)
    with pytest.raises(ValueError, match="File changed while hashing"):
        rpc.file_identity(path)
    fake_maps(monkeypatch, map_line(path, "r-xp"))
    inventory = rpc.RuntimeInventory({})
    inventory.capture(41, "before")
    streams = list(inventory.pending.values())
    with pytest.raises(ValueError, match="Mapped file changed while hashing"):
        inventory.finish()
    assert all(stream.closed for stream in streams)
    assert inventory.report["status"] == "incomplete"


def test_btrfs_device_alias_requires_matching_most_specific_filesystem_mount(private):
    inventory = rpc.RuntimeInventory({})
    inventory.mounts = [
        {"path": "/", "filesystem": "btrfs", "device": [0, 29]},
        {"path": str(private), "filesystem": "ext4", "device": [0, 30]},
    ]
    assert inventory.btrfs_device(Path("/home/fixture"), (0, 29))["filesystem"] == "btrfs"
    assert inventory.btrfs_device(private / "file", (0, 29)) is None
    assert inventory.btrfs_device(Path("/home/fixture"), (0, 99)) is None
    inventory.mounts = []
    assert inventory.btrfs_device(private / "file", (0, 29)) is None


def test_non_btrfs_mapping_device_mismatch_cannot_qualify(private):
    path = private / "runtime"
    path.write_bytes(b"runtime")
    inventory = rpc.RuntimeInventory({})
    inventory.mounts = [{"path": "/", "filesystem": "ext4", "device": [0, 29]}]
    with pytest.raises(ValueError, match="identity changed"):
        inventory.mapped_file(path, "ff:ff", str(path.stat().st_ino), "r-xp")
    assert not inventory.pending


def test_measurement_inventories_both_owned_service_and_explicit_native_host(native_relay, relay_server, private):
    service = relay_server(lambda connection, stop: stop.wait(3))
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", {}, {})
    measurement = rpc.Measurement(SimpleNamespace(), private, {})
    measurement.peers = [peer]
    measurement.process = FakeProcess()
    captures = []
    measurement.runtime_inventory.capture = lambda pid, condition: captures.append((pid, condition))
    try:
        measurement.capture_runtime_mappings("warmed_streaming:before samples")
        assert captures == [(FakeProcess.pid, "warmed_streaming:before samples"),
                            (peer.process.pid, "warmed_streaming:before samples:native desktop relay")]
    finally:
        peer.close()


@pytest.mark.parametrize("seeded", [False, True])
def test_maps_reject_same_size_runtime_rewrite_even_when_mtime_restored(private, monkeypatch, seeded):
    path = private / "rewritten-runtime"
    path.write_bytes(b"original")
    metadata = path.stat()
    report = {"inputs": {"runtime": rpc.file_identity(path)}} if seeded else {}
    fake_maps(monkeypatch, map_line(path, "r-xp"))
    inventory = rpc.RuntimeInventory(report)
    inventory.capture(41, "before samples")
    streams = list(inventory.pending.values())
    path.write_bytes(b"modified")
    os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
    assert path.stat().st_size == metadata.st_size
    assert path.stat().st_mtime_ns == metadata.st_mtime_ns
    with pytest.raises(ValueError, match="Mapped runtime changed since snapshot"):
        inventory.finish()
    assert report["status"] == "incomplete"
    assert all(stream.closed for stream in streams)


def test_summary_change_only_in_first_sample_does_not_qualify_window(workload, monkeypatch):
    original = WorkPeer.call
    native_polls = 0
    def call(self, method, arguments=None, **kwargs):
        nonlocal native_polls
        wire = original(self, method, arguments, **kwargs)
        if method == "status" and rpc.native_active(wire):
            native_polls += 1
            wire["capture"]["meeting_summaries"]["7"]["preview"] = (
                "Before sample window" if native_polls == 1 else "Changed before first reply"
            )
        return wire
    monkeypatch.setattr(WorkPeer, "call", call)
    with pytest.raises(RuntimeError, match="No changed non-empty native summary preview"):
        workload.workload()
    sample = workload.report["samples"]["warmed_streaming"]
    assert sample["n"] == sample["native_active_count"] == 100
    assert not sample["stream_chunks_during_samples"]
    assert workload.stream_chunks[-1]["received_ns"] == sample["first_status_ns"]
    workload.close()


@pytest.mark.parametrize("kind", ["rewrite", "replace"])
def test_declared_mapped_input_mutated_before_snapshot_is_refused(private, monkeypatch, kind):
    path = private / "declared-model"
    path.write_bytes(b"original")
    report = {"status": "passed", "inputs": {"generation_model": rpc.file_identity(path)}}
    if kind == "replace":
        replacement = private / "replacement"
        replacement.write_bytes(b"modified")
        replacement.replace(path)
    else:
        metadata = path.stat()
        path.write_bytes(b"modified")
        os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
    fake_maps(monkeypatch, map_line(path))
    inventory = rpc.RuntimeInventory(report)
    with pytest.raises(ValueError, match="Declared input changed before mapping snapshot"):
        inventory.capture(41, "before samples")
    inventory.finish()
    assert report["status"] == "incomplete"
    assert "Declared input changed" in report["mapped_runtime_snapshots"][0]["error"]
    assert not inventory.objects and not inventory.pending


@pytest.mark.parametrize("mismatch", [False, True])
def test_executed_service_image_is_bound_to_verified_input(private, mismatch):
    declared = rpc.file_identity(Path(sys.executable).resolve())
    if mismatch:
        declared["sha256"] = "0" * 64
    (private / "service-state.json").write_text(json.dumps({"pid": os.getpid(), "exit_code": None}))
    report = {"inputs": {"service": declared}}
    measurement = rpc.Measurement(SimpleNamespace(), private, report)
    if mismatch:
        with pytest.raises(ValueError, match="executed image differs"):
            measurement.verify_service_image()
    else:
        measurement.verify_service_image()
    assert report["executed_service_image"]["sha256"] == rpc.file_identity(Path("/proc/self/exe"))["sha256"]


@pytest.mark.parametrize("alias", [False, True])
def test_mutable_shared_file_outside_private_roots_is_refused(private, monkeypatch, alias):
    data = private / "data"
    data.mkdir()
    outside = private / "external-runtime"
    outside.write_bytes(b"before")
    path = outside
    if alias:
        path = data / "escaped-link"
        path.symlink_to(outside)
    fake_maps(monkeypatch, map_line(path, "rw-s"))
    report = {}
    inventory = rpc.RuntimeInventory(report, private_roots=(data,))
    inventory.capture(41, "before samples")
    assert not report["mapped_runtime_files"][0]["mutable_shared_data"]
    outside.write_bytes(b"changed runtime")
    with pytest.raises(ValueError, match="Mapped runtime changed"):
        inventory.finish()
    assert report["status"] == "incomplete"


def test_declared_input_in_private_root_cannot_gain_mutable_data_exemption(private, monkeypatch):
    data = private / "data"
    data.mkdir()
    path = data / "declared-runtime"
    path.write_bytes(b"before")
    fake_maps(monkeypatch, map_line(path, "rw-s"))
    report = {"inputs": {"runtime": rpc.file_identity(path)}}
    inventory = rpc.RuntimeInventory(report, private_roots=(data,))
    inventory.capture(41, "before samples")
    path.write_bytes(b"after!")
    with pytest.raises(ValueError, match="Mapped runtime changed"):
        inventory.finish()
    assert not report["mapped_runtime_files"][0]["mutable_shared_data"]


def test_supervisor_lets_service_settle_its_own_child_without_term(private):
    child_ready = private / "child.ready"
    child_term = private / "child.received-term"
    child_stop = private / "child.stop"
    child_finished = private / "child.finished"
    service_ready = private / "service.ready"
    service_finished = private / "service.finished"
    child_code = f'''import pathlib,signal,time
stop = pathlib.Path({str(child_stop)!r})
def term(kind, frame):
    pathlib.Path({str(child_term)!r}).write_text('unexpected TERM')
    raise SystemExit(3)
signal.signal(signal.SIGTERM, term)
pathlib.Path({str(child_ready)!r}).touch()
while not stop.exists(): time.sleep(.01)
time.sleep(.1)
pathlib.Path({str(child_finished)!r}).touch()
'''
    service = private / "settling-service"
    service.write_text(f'''#!{sys.executable}
import pathlib,signal,subprocess,time
stopping = False
def term(kind, frame):
    global stopping
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    stopping = True
signal.signal(signal.SIGTERM, term)
child = subprocess.Popen([{sys.executable!r}, '-c', {child_code!r}], process_group=0)
while not pathlib.Path({str(child_ready)!r}).exists(): time.sleep(.01)
pathlib.Path({str(service_ready)!r}).touch()
while not stopping: time.sleep(.01)
pathlib.Path({str(child_stop)!r}).touch()
assert child.wait(timeout=2) == 0
pathlib.Path({str(service_finished)!r}).touch()
''')
    service.chmod(0o700)
    state = private / "service-state.json"
    process = subprocess.Popen([sys.executable, str(Path(rpc.__file__).resolve()), "_supervise", str(service), str(state)],
                               start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    report = {"status": "passed"}
    measurement = rpc.Measurement(SimpleNamespace(), private, report)
    measurement.process, measurement.cleanup_timeout = process, 2
    try:
        rpc.wait_until(lambda: service_ready.exists() and state.exists(), timeout=5)
        measurement.close()
        assert child_finished.exists() and service_finished.exists()
        assert not child_term.exists(), "Supervisor interfered with service-owned child settlement"
        assert report["owned_service_exit_code"] == report["owned_supervisor_exit_code"] == 0
        assert report["graceful_shutdown"] is True and report["status"] == "passed"
        assert not report.get("owned_session_escalated_to_kill")
    finally:
        if process.poll() is None:
            rpc.signal_session_members(process.pid, rpc.signal.SIGKILL)
            process.kill()
        out, err = process.communicate(timeout=5)
        assert process.returncode in {0, -9}, (out, err)


@pytest.mark.parametrize("failure", ["ignores-term", "exit-three"])
def test_real_service_forced_or_nonzero_shutdown_cannot_pass(private, failure):
    ready = private / "failure.ready"
    service = private / "failure-service"
    policy = "signal.SIG_IGN" if failure == "ignores-term" else "lambda *args: sys.exit(3)"
    service.write_text(f"#!{sys.executable}\nimport signal,sys,time\nsignal.signal(signal.SIGTERM,{policy})\nopen({str(ready)!r},'w').close()\ntime.sleep(20)\n")
    service.chmod(0o700)
    state = private / "service-state.json"
    process = subprocess.Popen([sys.executable, str(Path(rpc.__file__).resolve()), "_supervise", str(service), str(state)],
                               start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    report = {"status": "passed"}
    measurement = rpc.Measurement(SimpleNamespace(), private, report)
    measurement.process, measurement.cleanup_timeout = process, .2
    try:
        rpc.wait_until(lambda: ready.exists() and state.exists(), timeout=5)
        measurement.close()
        assert report["status"] == "incomplete" and report["graceful_shutdown"] is False
        assert report["owned_service_exit_code"] == (-9 if failure == "ignores-term" else 3)
        assert report["owned_supervisor_exit_code"] == 0
        assert "forced or unsuccessful" in report["owned_session_cleanup"]
        assert bool(report.get("owned_session_escalated_to_kill")) == (failure == "ignores-term")
    finally:
        if process.poll() is None:
            rpc.signal_session_members(process.pid, rpc.signal.SIGKILL)
            process.kill()
        out, err = process.communicate(timeout=5)
        assert process.returncode in {0, -9}, (out, err)


@pytest.mark.parametrize("stopped", [False, True])
def test_native_relay_nonzero_or_forced_exit_blocks_success(native_relay, relay_server, private, stopped):
    service = relay_server(lambda connection, stop: stop.wait(3))
    evidence = {}
    peer = rpc.DesktopHostPeer(native_relay, service.path, private / "relay.log", evidence, {}, close_timeout=.1)
    report = {"status": "passed"}
    measurement = rpc.Measurement(SimpleNamespace(), private, report)
    measurement.peers = [peer]
    try:
        assert service.entered.wait(2)
        if stopped:
            os.kill(peer.process.pid, rpc.signal.SIGSTOP)
        else:
            peer.process.terminate()
            peer.process.wait(timeout=2)
        measurement.close()
        assert report["status"] == "incomplete" and report["graceful_shutdown"] is False
        assert evidence["graceful_shutdown"] is False
        assert evidence["exit_code"] == (-9 if stopped else -15)
        assert bool(evidence.get("forced_kill")) == stopped
    finally:
        peer.close()


def test_declared_input_hardlink_cannot_gain_private_mutable_exemption(private, monkeypatch):
    path = private / "declared-runtime"
    path.write_bytes(b"original")
    data = private / "data"
    data.mkdir()
    alias = data / "private-alias"
    alias.hardlink_to(path)
    fake_maps(monkeypatch, map_line(alias, "rw-s"))
    report = {"inputs": {"runtime": rpc.file_identity(path)}}
    inventory = rpc.RuntimeInventory(report, private_roots=(data,))
    inventory.capture(41, "before samples")
    assert not report["mapped_runtime_files"][0]["mutable_shared_data"]
    path.write_bytes(b"modified")
    with pytest.raises(ValueError, match="Mapped runtime changed"):
        inventory.finish()


@pytest.mark.parametrize("inside_first", [False, True])
def test_private_mutable_exemption_rejects_any_observed_external_hardlink(private, monkeypatch, inside_first):
    outside = private / "external"
    outside.write_bytes(b"before")
    data = private / "data"
    data.mkdir()
    alias = data / "private-alias"
    alias.hardlink_to(outside)
    names = [alias, outside] if inside_first else [outside, alias]
    fake_maps(monkeypatch, "".join(map_line(path, "rw-s") for path in names))
    inventory = rpc.RuntimeInventory({}, private_roots=(data,))
    inventory.capture(41, "before samples")
    outside.write_bytes(b"modified")
    with pytest.raises(ValueError, match="Mapped runtime changed"):
        inventory.finish()
    assert not inventory.report["mapped_runtime_files"][0]["mutable_shared_data"]
