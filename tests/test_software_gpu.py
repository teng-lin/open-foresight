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
CPU_METADATA = (ROOT / "tests/fixtures/software-vulkan-cpu.txt").read_text()


def test_cpu_preflight_uses_metadata_retained_from_actual_ci_whisper_log():
    # Exact enumeration lines retained from the failed 6f22cad acceptance job;
    # the actual combined transcript/log is also replayed during validation.
    diagnostic = (
        "And so my fellow Americans" + "\n" + CPU_METADATA + "using Vulkan0 backend\n"
    )
    result = SimpleNamespace(
        returncode=0, stdout="my fellow Americans", stderr=diagnostic
    )
    whisper = gpu.whisper_result(result)
    skipped = gpu.litert_ci_preflight(whisper, diagnostic, allow_unavailable=True)
    assert skipped["status"] == "skipped"
    assert skipped["adapter"]["type"] == "cpu"
    assert "llvmpipe" in skipped["adapter"]["name"]
    assert gpu.litert_ci_preflight(whisper, diagnostic) is None
    assert gpu.litert_ci_preflight({"status": "skipped"}, diagnostic, True) is None


@pytest.mark.parametrize(
    "diagnostic",
    [
        CPU_METADATA.replace("Found 1", "Found 2"),
        CPU_METADATA + "ggml_vulkan: Found 1 Vulkan devices:\n",
        CPU_METADATA + "ggml_vulkan: 1 = NVIDIA GPU\n",
        CPU_METADATA + CPU_METADATA.splitlines()[-1] + "\n",
        "\n".join(CPU_METADATA.splitlines()[:-1]),
        CPU_METADATA.replace("0 = llvmpipe", "0 = NVIDIA"),
        CPU_METADATA.replace("0 = llvmpipe", "1 = llvmpipe"),
        "unknown Vulkan adapter",
    ],
)
def test_unknown_hardware_mixed_or_duplicate_metadata_never_skips(diagnostic):
    assert gpu.litert_ci_preflight({"status": "passed"}, diagnostic, True) is None


@pytest.mark.parametrize("allow_unavailable", [False, True])
@pytest.mark.parametrize("hardware", [False, True])
def test_only_explicit_ci_cpu_adapter_skips_before_litert_startup(
    tmp_path, allow_unavailable, hardware
):
    output = tmp_path / "reports"
    diagnostic = CPU_METADATA + "using Vulkan0 backend\n"
    if hardware:
        diagnostic = diagnostic.replace("0 = llvmpipe", "0 = NVIDIA")
    with (
        patch.object(
            sys,
            "argv",
            [
                "probe",
                "--bundle",
                str(tmp_path),
                "--models",
                str(tmp_path),
                "--output",
                str(output),
                *(["--allow-litert-unavailable"] if allow_unavailable else []),
            ],
        ),
        patch.object(gpu.Path, "glob", return_value=[tmp_path / "lvp_icd.x86_64.json"]),
        patch.object(
            gpu, "packaged_paths", return_value=(Path("runner"), Path("worker"), {})
        ),
        patch.object(gpu, "model_file", return_value="model") as model,
        patch.object(
            gpu.subprocess,
            "run",
            return_value=SimpleNamespace(
                returncode=0, stdout="my fellow Americans", stderr=diagnostic
            ),
        ),
        patch.object(
            gpu, "litert_probe", side_effect=RuntimeError("GPU decode crashed -11")
        ) as litert,
    ):
        if allow_unavailable and not hardware:
            gpu.main()
            litert.assert_not_called()
            assert [call.args[1] for call in model.call_args_list] == ["speech"]
            report = json.loads((output / "software-gpu.json").read_text())
            assert report["whisper"]["status"] == "passed"
            assert report["litert"]["status"] == "skipped"
            assert report["physical_gpu_verified"] is False
        else:
            with pytest.raises(RuntimeError, match="decode crashed -11"):
                gpu.main()
            litert.assert_called_once()


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
    with pytest.raises(RuntimeError, match="known speech"):
        gpu.whisper_result(
            SimpleNamespace(returncode=0, stdout="[BLANK_AUDIO]", stderr=passed.stderr)
        )
    with pytest.raises(RuntimeError, match="known speech"):
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


@pytest.mark.parametrize(
    ("content", "decoded"),
    [
        ("one two three", True),
        ("", False),
        ([{"text": "one"}], True),
        ([{"text": ""}], False),
    ],
)
def test_decode_executes_on_gpu_with_sixteen_token_bound(tmp_path, content, decoded):
    frames = iter(
        ["ready 1", "1 answer " + json.dumps({"content": content}), "1 done completed"]
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
        if decoded:
            assert (
                gpu.litert_probe(Path("runner"), "model", {}, tmp_path)["status"]
                == "passed"
            )
        else:
            with pytest.raises(RuntimeError, match="no decoded text"):
                gpu.litert_probe(Path("runner"), "model", {}, tmp_path)
    assert commands[0][-3:] == ["--backend", "gpu", "--serve"]
    assert '"max_output_tokens": 16' in commands[1]


@pytest.mark.parametrize("allow_litert_unavailable", [False, True])
def test_absent_whisper_device_fails_even_with_litert_skips(
    tmp_path, allow_litert_unavailable
):
    unavailable = SimpleNamespace(
        returncode=0,
        stdout="CPU fallback transcript",
        stderr="ggml_vulkan: No devices found.\nwhisper_backend_init_gpu: no GPU found\n",
    )
    output = tmp_path / "reports"
    with (
        patch.object(
            sys,
            "argv",
            [
                "probe",
                "--bundle",
                str(tmp_path),
                "--models",
                str(tmp_path),
                "--output",
                str(output),
                *(["--allow-litert-unavailable"] if allow_litert_unavailable else []),
            ],
        ),
        patch.object(gpu.Path, "glob", return_value=[tmp_path / "lvp_icd.json"]),
        patch.object(
            gpu, "packaged_paths", return_value=(Path("runner"), Path("worker"), {})
        ),
        patch.object(gpu, "model_file", return_value="model"),
        patch.object(gpu.subprocess, "run", return_value=unavailable),
        patch.object(gpu, "litert_probe") as litert,
        pytest.raises(RuntimeError, match="failed to execute on software Vulkan"),
    ):
        gpu.main()
    litert.assert_not_called()
    assert unavailable.stderr in (output / "whisper-vulkan.log").read_text()


@pytest.mark.parametrize("allow_unavailable", [False, True])
def test_real_whisper_command_explicitly_selects_the_software_vulkan_device(
    tmp_path, allow_unavailable
):
    icd = tmp_path / "lvp_icd.x86_64.json"
    report = tmp_path / "reports"
    calls = []

    def run(command, **options):
        calls.append((command, options))
        assert options["env"]["GGML_VK_VISIBLE_DEVICES"] == "0"
        assert options["env"]["VK_DRIVER_FILES"] == str(icd)
        assert options["env"]["VK_ICD_FILENAMES"] == str(icd)
        assert command[-2:] == ["-dev", "0"]
        return SimpleNamespace(
            returncode=0,
            stdout="my fellow Americans",
            stderr="0 = llvmpipe\nusing Vulkan0 backend",
        )

    with (
        patch.object(
            sys,
            "argv",
            [
                "probe",
                "--bundle",
                str(tmp_path),
                "--models",
                str(tmp_path),
                "--output",
                str(report),
                *(["--allow-litert-unavailable"] if allow_unavailable else []),
            ],
        ),
        patch.object(gpu.Path, "glob", return_value=[icd]),
        patch.object(
            gpu, "packaged_paths", return_value=(Path("runner"), Path("worker"), {})
        ),
        patch.object(gpu, "model_file", return_value="model"),
        patch.object(gpu.subprocess, "run", side_effect=run),
        patch.object(
            gpu,
            "litert_probe",
            return_value={
                "status": "unsupported_software_driver",
                "diagnostic": "No OpenCL platform",
            },
        ),
    ):
        gpu.main()
    assert len(calls) == 1
    evidence = json.loads((report / "software-gpu.json").read_text())
    assert evidence["whisper"]["status"] == "passed"
    assert evidence["litert"]["status"] == (
        "skipped" if allow_unavailable else "unsupported_software_driver"
    )
    if allow_unavailable:
        assert evidence["litert"]["reason"]
    assert evidence["physical_gpu_verified"] is False


@pytest.mark.parametrize("allow_litert_unavailable", [False, True])
@pytest.mark.parametrize("icds", [[], [Path("lvp1.json"), Path("lvp2.json")]])
def test_required_driver_absence_or_ambiguity_fails_before_models(
    tmp_path,
    allow_litert_unavailable,
    icds,
):
    arguments = [
        "probe",
        "--bundle",
        str(tmp_path),
        "--models",
        str(tmp_path),
        "--output",
        str(tmp_path),
        *(["--allow-litert-unavailable"] if allow_litert_unavailable else []),
    ]
    with (
        patch.object(sys, "argv", arguments),
        patch.object(gpu.Path, "glob", return_value=icds),
        patch.object(gpu, "packaged_paths") as packaged,
        pytest.raises(RuntimeError, match="Exactly one"),
    ):
        gpu.main()
    packaged.assert_not_called()
    evidence = json.loads((tmp_path / "software-gpu.json").read_text())
    assert evidence["status"] == "failed"
    assert "Install mesa-vulkan-drivers" in evidence["error"]
    assert evidence["physical_gpu_verified"] is False
