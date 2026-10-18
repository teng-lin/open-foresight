"""Software GPU limitations cannot mask fallback or decoder regressions."""

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import sys
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location(
    "software_gpu", ROOT / "tools/accept_software_gpu.py"
)
gpu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpu)


def test_whisper_requires_software_vulkan_and_a_transcript():
    passed = SimpleNamespace(
        returncode=0,
        stdout="my fellow Americans",
        stderr="0 = llvmpipe\nusing Vulkan0 backend",
    )
    assert gpu.whisper_result(passed)["status"] == "passed"
    for stderr in (
        "using CPU backend",
        "0 = NVIDIA\nusing Vulkan0 backend",
        "0 = llvmpipe",
    ):
        with pytest.raises(RuntimeError):
            gpu.whisper_result(
                SimpleNamespace(returncode=0, stdout="text", stderr=stderr)
            )
    with pytest.raises(RuntimeError, match="no transcript"):
        gpu.whisper_result(
            SimpleNamespace(returncode=0, stdout="", stderr=passed.stderr)
        )


def test_only_explicit_missing_driver_capability_is_a_recorded_limit(tmp_path):
    result = SimpleNamespace(
        returncode=1, stdout="", stderr="No OpenCL platforms available"
    )
    with patch.object(gpu.subprocess, "run", return_value=result):
        assert (
            gpu.litert_probe(Path("runner"), "model", {}, tmp_path)["status"]
            == "unsupported_software_driver"
        )
    result.stderr = "model checksum mismatch"
    with (
        patch.object(gpu.subprocess, "run", return_value=result),
        pytest.raises(RuntimeError, match="Unexpected"),
    ):
        gpu.litert_probe(Path("runner"), "model", {}, tmp_path)


def test_decode_executes_on_gpu_with_sixteen_token_bound(tmp_path):
    frames = iter(
        ["ready 1", '1 answer {"content":"one two three"}', "1 done completed"]
    )
    commands = []

    class Peer:
        def __init__(self, command, *args):
            commands.append(command)

        def receive(self):
            return next(frames)

        def send(self, command):
            payload = json.loads(command.split(" ", 2)[2])
            assert payload["tools"]["tools"] == []
            assert payload["tools"]["system_message"]
            assert payload["max_output_tokens"] == 16
            commands.append(command)

    with (
        patch.object(
            gpu.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=0, stdout="{}", stderr=""),
        ),
        patch.object(gpu, "Peer", Peer),
        patch.object(gpu, "finish_peer"),
    ):
        assert (
            gpu.litert_probe(Path("runner"), "model", {}, tmp_path)["status"]
            == "passed"
        )
    assert commands[0][-3:] == ["--backend", "gpu", "--serve"]
    assert '"max_output_tokens": 16' in commands[1]
