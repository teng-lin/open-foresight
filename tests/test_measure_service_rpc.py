"""Offline tests of RPC timing, exact export provenance and owned cleanup."""

import argparse
import hashlib
import io
import json
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
                              generated_directory=[], library_path=[])
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
    assert len(result) == 9
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

    def makefile(self, mode):
        return self.lines

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
    times = iter([0, .1, 1.1])
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
    def __init__(self, path):
        self.path = path
        self.calls = []
        self.samples = 0
        self.interrupted = self.closed = False

    def call(self, method, arguments=None):
        self.calls.append((method, arguments))
        if method == "status":
            self.samples += 1
            return status(generating=True, state="loading", capture=True, samples=self.samples)
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
    monkeypatch.setattr(rpc, "Peer", WorkPeer)
    monkeypatch.setattr(rpc.subprocess, "Popen", lambda *args, **kwargs: FakeProcess())
    monkeypatch.setattr(rpc.threading, "Thread", FakeThread)
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
    assert workload.report["owned_service_exit_code"] == -15
    assert workload.report["stream_thread_settled"] is True
    assert all(peer.closed and peer.interrupted for peer in workload.peers)


def test_workload_keeps_performance_target_miss_honest(workload, monkeypatch):
    original = rpc.sample
    monkeypatch.setattr(rpc, "sample", lambda peer: {**original(peer, delay=0), "target_met": False})
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
    monkeypatch.setattr(rpc.subprocess, "Popen", lambda *a, **kw: SimpleNamespace(poll=lambda: 2))
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
    def call(self, method, args=None):
        if method == "answer.stream":
            raise RuntimeError("native fixture failure")
        return original(self, method, args)
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
    monkeypatch.setattr(rpc, "sample", lambda peer: {"native_active_count": 0, "raw_ms": [1] * 100})
    with pytest.raises(RuntimeError, match="native generation"):
        workload.record("warmed_streaming", WorkPeer(Path("fixture")))
    assert len(workload.report["samples"]["warmed_streaming"]["raw_ms"]) == 100


def test_close_kills_only_owned_group_on_deadline_and_joins_thread(workload, monkeypatch):
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
    monkeypatch.setattr(rpc.os, "killpg", lambda pid, sig: calls.append((pid, sig)))
    workload.close()
    assert calls == [(process.pid, rpc.signal.SIGTERM), (process.pid, rpc.signal.SIGKILL)]
    assert waits == [30, 30]
    assert workload.report["owned_service_exit_code"] == -9



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
    def gone(pid, sig):
        raise ProcessLookupError("already exited")
    monkeypatch.setattr(rpc.os, "killpg", gone)
    workload.close()
    assert workload.report["owned_service_exit_code"] == 0

def test_close_leaves_already_exited_process_alone(workload, monkeypatch):
    process = FakeProcess()
    process.returncode = 3
    workload.process = process
    monkeypatch.setattr(rpc.os, "killpg", lambda *args: pytest.fail("must not signal exited PID"))
    workload.close()
    assert workload.report["owned_service_exit_code"] == 3


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


def test_cli_pristine_check_and_measurement_return_codes(inputs, private, monkeypatch, capsys):
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
