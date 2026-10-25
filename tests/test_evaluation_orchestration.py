"""Evaluation tools validate protocol results and always release owned resources."""

import ctypes
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from tools.helper_protocol import HELPER_PROTOCOL_VERSION

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import evaluate_models as models
import evaluate_pipeline as pipeline


class EvaluationChannel:
    def __init__(self, failure=None):
        self.failure, self.requests = failure, []
        self.close = Mock()

    def unary_unary(self, route, *, request_serializer, response_deserializer):
        method = route.rsplit("/", 1)[-1]

        def call(request, *, timeout):
            assert request_serializer(request) == request.SerializeToString()
            self.requests.append((method, request, timeout))
            if method == "Ping":
                return SimpleNamespace(
                    version="wrong"
                    if self.failure == "ping"
                    else HELPER_PROTOCOL_VERSION
                )
            if method == "UpdateModelPaths":
                return SimpleNamespace(
                    success=self.failure != "configuration",
                    error_message="configuration failed",
                )
            if method == "IndexDocument":
                return SimpleNamespace(
                    success=self.failure != "index", error_message="index failed"
                )
            if method == "RetrieveContext":
                if self.failure == "retrieval":
                    return SimpleNamespace(chunks=[])
                identity = (
                    "release-source"
                    if "allowed_document_ids" in request.DESCRIPTOR.fields_by_name
                    and request.allowed_document_ids
                    else models.QUERIES[
                        len([x for x in self.requests if x[0] == method]) - 1
                    ][1]
                )
                return SimpleNamespace(
                    chunks=[
                        SimpleNamespace(
                            document_id=identity,
                            text="November 12 [S1]",
                            relevance_score=0.9,
                        )
                    ]
                )
            raise AssertionError(method)

        return call


@pytest.fixture
def process_boundary(monkeypatch):
    process = SimpleNamespace(
        pid=1234, terminate=Mock(), kill=Mock(), wait=Mock(return_value=0), returncode=0
    )
    launch = Mock(return_value=process)
    monkeypatch.setattr(models.subprocess, "Popen", launch)
    monkeypatch.setattr(
        models.grpc,
        "channel_ready_future",
        lambda channel: SimpleNamespace(result=Mock()),
    )
    return process, launch


@pytest.mark.parametrize(
    "failure", [None, "ping", "configuration", "index", "retrieval", "shutdown"]
)
def test_model_evaluation_checks_all_queries_and_cleans_helper(
    tmp_path, monkeypatch, process_boundary, failure
):
    model = tmp_path / "embedding model"
    model.write_bytes(b"asset")
    output = tmp_path / "reports/retrieval.json"
    channel = EvaluationChannel(failure)
    process, launch = process_boundary
    if failure == "shutdown":
        process.wait.side_effect = [subprocess.TimeoutExpired("helper", 10), 0]
        process.returncode = 1
    monkeypatch.setattr(models.grpc, "insecure_channel", lambda socket: channel)
    monkeypatch.setattr(
        models, "control_snapshot", lambda ch: {"model": {"backend": "fixture"}}
    )
    monkeypatch.setattr(models, "process_memory", lambda pid: [{"pid": pid}])
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "evaluate",
            "--helper",
            str(tmp_path / "helper"),
            "--embedding-model",
            str(model),
            "--output",
            str(output),
        ],
    )
    if failure in ("ping", "configuration", "index", "retrieval"):
        with pytest.raises(RuntimeError):
            models.main()
        assert not output.exists()
    else:
        models.main()
        report = json.loads(output.read_text())
        assert report["top1_accuracy"] == 1
        assert report["backend"] == "fixture"
        assert len(report["queries"]) == 4
        assert all(query["top1_correct"] for query in report["queries"])
        assert report["assets"][0]["sha256"] == hashlib.sha256(b"asset").hexdigest()
    channel.close.assert_called_once()
    process.terminate.assert_called_once()
    assert process.kill.called == (failure == "shutdown")
    assert launch.call_args.args[0][0] == str((tmp_path / "helper").resolve())


def test_model_evaluation_rejects_missing_assets_and_hashes_directory(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "evaluate",
            "--helper",
            "helper",
            "--embedding-model",
            str(tmp_path / "missing"),
            "--output",
            str(tmp_path / "report"),
        ],
    )
    with pytest.raises(RuntimeError, match="Real local asset"):
        models.main()
    (tmp_path / "a").write_bytes(b"one")
    (tmp_path / ".cache").mkdir()
    (tmp_path / ".cache/ignored").write_bytes(b"excluded cache")
    manifest = models.asset_manifest(tmp_path)
    assert [entry["path"] for entry in manifest] == ["a"]
    assert manifest[0]["bytes"] == 3


@pytest.mark.parametrize(
    "failure",
    [
        None,
        "configuration",
        "index",
        "retrieval",
        "engine",
        "conversation",
        "generate",
        "terminal",
        "sequence",
        "after-done",
        "quality",
        "shutdown",
        "native-load",
        "abi",
    ],
)
def test_pipeline_evaluation_enforces_event_order_quality_and_cleanup(
    tmp_path, monkeypatch, process_boundary, failure
):
    process, _ = process_boundary
    channel = EvaluationChannel(failure)
    monkeypatch.setattr(pipeline.grpc, "insecure_channel", lambda socket: channel)
    runner, model = tmp_path / "runner", tmp_path / "model"
    runner.write_bytes(b"runner")
    model.write_bytes(b"model")
    output = tmp_path / "reports/pipeline.json"
    library = SimpleNamespace(
        **{
            name: Mock()
            for name in (
                "fs_abi_version",
                "fs_engine_create",
                "fs_conversation_create",
                "fs_generate",
                "fs_event_poll",
                "fs_string_free",
                "fs_conversation_destroy",
                "fs_engine_destroy",
            )
        }
    )
    library.fs_abi_version.return_value = 2 if failure == "abi" else 1
    library.fs_engine_create.return_value = 0 if failure == "engine" else 10
    library.fs_conversation_create.return_value = 0 if failure == "conversation" else 20
    library.fs_generate.return_value = 1 if failure == "generate" else 0
    answer = "November 12 [S1]" if failure != "quality" else "unsupported answer"
    events = [
        None,
        {"type": "delta", "text": answer, "sequence": 0},
        {
            "type": "done",
            "status": "failed" if failure == "terminal" else "completed",
            "sequence": 99 if failure == "sequence" else 1,
        },
        {"type": "delta", "text": "late"} if failure == "after-done" else None,
    ]
    pointers, buffers = [], []
    for event in events:
        if event is None:
            pointers.append(0)
        else:
            buffer = ctypes.create_string_buffer(json.dumps(event).encode())
            buffers.append(buffer)
            pointers.append(ctypes.addressof(buffer))
    library.fs_event_poll.side_effect = pointers

    def load_library(path):
        if failure == "native-load":
            raise OSError("native library failed to load")
        return library

    monkeypatch.setattr(pipeline.ctypes, "CDLL", load_library)
    if failure == "shutdown":
        process.wait.side_effect = [subprocess.TimeoutExpired("helper", 10), 0]
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "pipeline",
            "--helper",
            str(tmp_path / "helper"),
            "--embedding-model",
            str(model),
            "--native",
            str(tmp_path / "native"),
            "--runner",
            str(runner),
            "--generation-model",
            str(model),
            "--output",
            str(output),
        ],
    )
    if failure and failure != "shutdown":
        with pytest.raises((RuntimeError, OSError)):
            pipeline.main()
    else:
        pipeline.main()
    if failure in (None, "quality", "shutdown"):
        report = json.loads(output.read_text())
        assert report["quality_passed"] == (failure != "quality")
        assert report["ordered_event_count"] == 2
        assert report["model_sha256"] == hashlib.sha256(b"model").hexdigest()
        assert report["runner_sha256"] == hashlib.sha256(b"runner").hexdigest()
    else:
        assert not output.exists()
    if failure not in (
        "configuration",
        "index",
        "retrieval",
        "engine",
        "native-load",
        "abi",
    ):
        library.fs_engine_destroy.assert_called_once_with(10)
    if failure not in (
        "configuration",
        "index",
        "retrieval",
        "engine",
        "conversation",
        "native-load",
        "abi",
    ):
        library.fs_conversation_destroy.assert_called_once_with(20, 1)
    if failure in (None, "terminal", "sequence", "after-done", "quality", "shutdown"):
        assert library.fs_string_free.call_count == 2
    if failure == "abi":
        library.fs_abi_version.assert_called_once_with()
        library.fs_engine_create.assert_not_called()
        library.fs_conversation_create.assert_not_called()
        library.fs_engine_destroy.assert_not_called()
        library.fs_conversation_destroy.assert_not_called()
    channel.close.assert_called_once()
    process.terminate.assert_called_once()
    assert process.kill.called == (failure == "shutdown")


def test_memory_sampler_deduplicates_workers_and_tolerates_retired_threads(
    tmp_path, monkeypatch
):
    proc = tmp_path / "proc"
    for thread, children in (("one", "12 13"), ("two", "13 14"), ("retired", "")):
        path = proc / "10/task" / thread / "children"
        path.parent.mkdir(parents=True)
        path.write_text(children)
    for pid in (10, 12, 13):
        directory = proc / str(pid)
        directory.mkdir(exist_ok=True)
        (directory / "status").write_text(
            f"Name:\tworker-{pid}\nVmRSS:\t42 kB\nVmHWM:\t99 kB\nnot a status field\n"
        )
    original_read = Path.read_text

    def read(path, *args, **kwargs):
        if path.parent.name == "retired":
            raise FileNotFoundError("thread exited while sampling")
        return original_read(path, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", read)
    monkeypatch.setattr(models, "Path", lambda path: proc / path.removeprefix("/proc/"))
    records = models.process_memory(10)
    assert [record["pid"] for record in records] == [10, 12, 13]
    assert all(
        record["rss"] == "42 kB" and record["peak_rss"] == "99 kB" for record in records
    )


def test_control_snapshot_uses_generated_descriptor_and_empty_control_request(
    tmp_path, monkeypatch
):
    from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

    descriptor = descriptor_pb2.FileDescriptorProto(
        name="helper_control.proto",
        package="foresight.linux.control.v1",
        syntax="proto3",
    )
    state = descriptor.message_type.add(name="State")
    state.field.add(name="probe_name", number=1, type=9, label=1)
    pool = descriptor_pool.DescriptorPool()
    pool.Add(descriptor)
    cls = message_factory.GetMessageClass(
        pool.FindMessageTypeByName("foresight.linux.control.v1.State")
    )

    def compile_descriptor(command, **kwargs):
        destination = Path(
            next(
                argument.removeprefix("--descriptor_set_out=")
                for argument in command
                if argument.startswith("--descriptor_set_out=")
            )
        )
        destination.write_bytes(
            descriptor_pb2.FileDescriptorSet(file=[descriptor]).SerializeToString()
        )
        assert command[-1] == "helper_control.proto"
        assert kwargs == {"check": True, "timeout": 300}

    monkeypatch.setattr(models.subprocess, "run", compile_descriptor)

    class Channel:
        def unary_unary(self, route, *, request_serializer, response_deserializer):
            assert route.endswith("HelperControl/GetState")
            assert request_serializer(None) == b""

            def call(request, *, timeout):
                assert request is None and timeout == 10
                return response_deserializer(
                    cls(probe_name="fixture snapshot").SerializeToString()
                )

            return call

    assert models.control_snapshot(Channel()) == {"probe_name": "fixture snapshot"}


def test_pipeline_native_load_failure_reaps_real_helper_subprocess(
    tmp_path, monkeypatch
):
    helper = tmp_path / "helper"
    helper.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(60)\n")
    helper.chmod(0o700)
    processes = []
    original_popen = subprocess.Popen

    def launch(*args, **kwargs):
        process = original_popen(*args, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(pipeline.subprocess, "Popen", launch)
    args = ["pipeline", "--helper", str(helper)]
    for name in ("embedding-model", "native", "runner", "generation-model", "output"):
        args += ["--" + name, str(tmp_path / name)]
    monkeypatch.setattr(sys, "argv", args)
    try:
        with pytest.raises(OSError):
            pipeline.main()
        assert len(processes) == 1
        assert processes[0].poll() is not None
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
