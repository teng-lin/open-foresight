"""Gate orchestration contracts, with external processes replaced at launch.

These tests check selection, diagnostics and cleanup; real desktop/audio
acceptance remains the responsibility of the existing hosted integration jobs.
"""

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from tools import integration_gates as gates


@pytest.fixture(autouse=True)
def isolated_audio_host(monkeypatch):
    # Model the sound-device-free CI container, regardless of the test host.
    exists = Path.exists
    monkeypatch.setattr(
        Path, "exists", lambda path: False if path == Path("/dev/snd") else exists(path)
    )


@pytest.mark.parametrize("failure", [None, "exit", "events"])
def test_run_tests_keeps_command_output_and_cleans_integration_alias(
    tmp_path, monkeypatch, failure, capsys
):
    desktop = tmp_path / "apps/desktop"
    (desktop / "test").mkdir(parents=True)
    monkeypatch.setattr(gates, "ROOT", tmp_path)
    alias = desktop / "test/private_pipewire_meeting_test.dart"
    alias.write_text("stale alias")

    def run(command, **kwargs):
        assert command[0] == "pinned-flutter"
        assert "test/private_pipewire_meeting_test.dart" in command
        assert "--no-pub" in command
        assert alias.is_symlink()
        kwargs["stdout"].write("retained command output")
        events = Path(
            next(
                c.split("json:", 1)[1]
                for c in command
                if c.startswith("--file-reporter=")
            )
        )
        events.write_text(
            json.dumps({"type": "testDone", "result": "success"})
            + "\n"
            + json.dumps({"type": "done", "success": failure != "events"})
            + "\n"
        )
        return subprocess.CompletedProcess(command, 1 if failure == "exit" else 0)

    monkeypatch.setattr(gates.subprocess, "run", run)
    if failure:
        with pytest.raises(RuntimeError):
            gates.run_tests(
                "desktop",
                ["integration_test/meeting_test.dart"],
                1,
                {},
                tmp_path,
                "fixture",
                "pinned-flutter",
            )
        if failure == "exit":
            assert "retained command output" in capsys.readouterr().out
    else:
        assert gates.run_tests(
            "desktop",
            ["integration_test/meeting_test.dart"],
            1,
            {},
            tmp_path,
            "fixture",
            "pinned-flutter",
        ) == {"passed": 1, "skipped": 0}
    assert not alias.is_symlink()
    assert (tmp_path / "fixture.log").read_text() == "retained command output"


@pytest.mark.parametrize("system,dbus", [("darwin", True), ("linux", False)])
def test_private_audio_requires_linux_and_private_bus(
    tmp_path, monkeypatch, system, dbus
):
    monkeypatch.setattr(gates.sys, "platform", system)
    with pytest.raises(RuntimeError, match="Linux|dbus-run-session"):
        with gates.private_pipewire(
            {"DBUS_SESSION_BUS_ADDRESS": "private"} if dbus else {}, tmp_path
        ):
            pytest.fail("invalid environment reached audio tests")


@pytest.mark.parametrize("failure", [None, "readiness", "default", "body"])
def test_private_audio_retries_and_cleans_all_daemons(tmp_path, monkeypatch, failure):
    monkeypatch.setattr(gates.sys, "platform", "linux")
    # All daemons are fakes; model the required isolated host independently of
    # whether the developer's real machine exposes sound devices.
    real_exists = Path.exists
    monkeypatch.setattr(
        Path,
        "exists",
        lambda path: False if path == Path("/dev/snd") else real_exists(path),
    )
    monkeypatch.setattr(gates.time, "sleep", lambda _: None)
    processes, killed, commands = [], [], []
    clock = iter(range(0, 10000, 10))
    monkeypatch.setattr(gates.time, "monotonic", lambda: next(clock))

    def popen(command, **kwargs):
        process = SimpleNamespace(
            pid=100 + len(processes),
            poll=Mock(return_value=1 if failure in ("readiness", "default") else None),
            wait=Mock(
                side_effect=[subprocess.TimeoutExpired(command, 5), 0]
                if len(processes) == 0
                else [0]
            ),
        )
        processes.append((process, kwargs["stdout"]))
        private = kwargs["env"]
        assert private["HOME"] != str(tmp_path)
        assert Path(private["HOME"]).stat().st_mode & 0o077 == 0
        assert (
            "alsa_monitor.enabled = false"
            in (
                Path(private["HOME"])
                / ".config/wireplumber/main.lua.d/51-virtual-only.lua"
            ).read_text()
        )
        return process

    counts = {}

    def run(command, **kwargs):
        commands.append(command)
        operation = command[1]
        counts[operation] = counts.get(operation, 0) + 1
        if operation == "info":
            if failure == "readiness":
                return subprocess.CompletedProcess(command, 1)
            if counts[operation] == 1:
                raise subprocess.TimeoutExpired(command, 5)
        if operation.startswith("set-default"):
            if failure == "default" or counts[operation] == 1:
                return subprocess.CompletedProcess(command, 1)
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(gates.subprocess, "Popen", popen)
    monkeypatch.setattr(gates.subprocess, "run", run)
    monkeypatch.setattr(gates.os, "killpg", lambda pid, sig: killed.append((pid, sig)))

    def exercise():
        with gates.private_pipewire(
            {"DBUS_SESSION_BUS_ADDRESS": "private", "HOME": str(tmp_path)}, tmp_path
        ) as env:
            assert env["FORESIGHT_MICROPHONE_TARGET"].endswith("-microphone")
            assert env["PIPEWIRE_REMOTE"] == "pipewire-0"
            assert env["PUB_CACHE"] == str(tmp_path / ".pub-cache")
            assert env["FORESIGHT_LIVE_SINK"] in next(
                c[-3] for c in commands if "module-null-sink" in c
            )
            if failure == "body":
                raise RuntimeError("test body failed")

    if failure:
        with pytest.raises(RuntimeError):
            exercise()
    else:
        exercise()
    assert len(processes) == 3
    assert all(stream.closed for _, stream in processes)
    assert killed[0][0] == 102  # Teardown reverses launch order.
    assert any(sig == gates.signal.SIGKILL for _, sig in killed)
    assert not Path(processes[0][1].name).read_text()  # Logs remain available.


def test_private_audio_rejects_physical_sound_devices_before_launch(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(gates.sys, "platform", "linux")
    exists = Path.exists
    monkeypatch.setattr(
        Path, "exists", lambda path: True if str(path) == "/dev/snd" else exists(path)
    )
    launch = Mock()
    monkeypatch.setattr(gates.subprocess, "Popen", launch)
    with pytest.raises(RuntimeError, match="without host sound devices"):
        with gates.private_pipewire({"DBUS_SESSION_BUS_ADDRESS": "private"}, tmp_path):
            pytest.fail("physical audio must not reach daemon setup")
    launch.assert_not_called()


@pytest.mark.parametrize(
    "system,has_native", [("linux", True), ("darwin", False), ("linux", False)]
)
def test_fast_gate_selects_platform_failures_and_isolates_capture_path(
    tmp_path, monkeypatch, system, has_native
):
    monkeypatch.setattr(gates.sys, "platform", system)
    native = tmp_path / "native"
    if has_native:
        native.touch()
    args = SimpleNamespace(
        native=native if has_native else None,
        output=tmp_path,
        flutter="flutter",
        dart="dart",
    )

    def run(package, files, expected, env, *rest):
        runner = Path(env["PATH"].split(":")[0]) / "pw-record"
        assert runner.read_text() == "#!/bin/sh\nexit 1\n"
        assert bool(runner.stat().st_mode & 0o100)
        assert expected == (2 if system == "linux" else 1)
        assert ("test/capture_failure_test.dart" in files) == (system == "linux")
        return {"passed": expected}

    monkeypatch.setattr(gates, "run_tests", run)
    if system == "linux" and not has_native:
        with pytest.raises(ValueError, match="native"):
            gates.fast_gate(args, {"PATH": "/bin"})
    else:
        assert gates.fast_gate(args, {"PATH": "/bin"})["passed"] > 0


@pytest.mark.parametrize(
    "suite,configured",
    [
        ("reference-models", True),
        ("reference-models", False),
        ("reference-tokenizer", True),
        ("reference-tokenizer", False),
    ],
)
def test_reference_gate_requires_authorized_assets_and_existing_sockets(
    tmp_path, monkeypatch, suite, configured
):
    model = tmp_path / "query model"
    model.touch()
    args = SimpleNamespace(
        suite=suite,
        query_model=model if configured else None,
        original_socket="original" if configured else None,
        port_socket="port" if configured else None,
        output=tmp_path,
        flutter="flutter",
        dart="dart",
    )
    command = Mock(return_value={"passed": 1})
    monkeypatch.setattr(gates, "run_tests", command)
    env = {"FORESIGHT_QUERY_WORKER": "worker", "FORESIGHT_LITERT_PYTHON": "python"}
    if not configured:
        with pytest.raises(ValueError):
            gates.reference_gate(args, env)
        command.assert_not_called()
    else:
        gates.reference_gate(args, env)
        if suite == "reference-models":
            assert env["FORESIGHT_QUERY_MODEL"] == str(model.resolve())
            assert env["FORESIGHT_QUERY_PYTHON"] == "python"
        else:
            assert env["FORESIGHT_PORT_TOKENIZER_SOCKET"] == "port"


@pytest.mark.parametrize("failure", [None, "desktop", "core"])
def test_models_gate_runs_both_groups_and_aggregates_failures(
    tmp_path, monkeypatch, failure
):
    monkeypatch.setattr(
        gates, "model_file", lambda directory, kind: str(tmp_path / kind)
    )
    seen = []

    def run(package, files, expected, env, *rest):
        seen.append(package)
        assert env["FORESIGHT_GENERATION_RUNNER"] == "model-worker"
        if package == failure:
            raise RuntimeError(package + " failure")
        return {"passed": expected}

    monkeypatch.setattr(gates, "run_tests", run)
    args = SimpleNamespace(
        models=tmp_path, output=tmp_path, flutter="flutter", dart="dart"
    )
    if failure:
        with pytest.raises(RuntimeError, match=failure):
            gates.models_gate(args, {"FORESIGHT_LITERT_RUNNER": "model-worker"})
    else:
        assert set(
            gates.models_gate(args, {"FORESIGHT_LITERT_RUNNER": "model-worker"})
        ) == {"desktop", "core"}
    assert seen == ["desktop", "core"]


def test_audio_gate_uses_private_routes_and_clears_whisper_for_pcm_inspector(
    tmp_path, monkeypatch
):
    runner = tmp_path / "bin/whisper-cli-vulkan"
    runner.parent.mkdir()
    runner.touch()
    args = SimpleNamespace(
        bundle=tmp_path,
        models=tmp_path,
        output=tmp_path,
        flutter="flutter",
        dart="dart",
    )
    monkeypatch.setattr(
        gates, "model_file", lambda directory, kind: str(tmp_path / kind)
    )

    @contextmanager
    def private(env, output):
        yield dict(env, FORESIGHT_LIVE_SINK="private-sink")

    monkeypatch.setattr(gates, "private_pipewire", private)

    @contextmanager
    def display(env, output):
        assert env["FORESIGHT_PRIVATE_PIPEWIRE"] == "1"
        yield dict(env, DISPLAY=":71", FORESIGHT_PRIVATE_X11=":71")

    monkeypatch.setattr(gates, "private_x11", display)
    seen = []

    def run(package, files, expected, env, output, name, *rest, **kwargs):
        seen.append(name)
        assert ("FORESIGHT_WHISPER_RUNTIME" in env) == (name != "audio-core")
        if name == "audio-meeting":
            assert kwargs == {"device": "linux"}
            assert env["DISPLAY"] == env["FORESIGHT_PRIVATE_X11"] == ":71"
            assert env["FORESIGHT_PLAYBACK_TARGET"] == "private-sink"
            manifest = json.loads(Path(env["FORESIGHT_MODEL_MANIFEST"]).read_text())
            assert manifest["generation"]["backend"] == "litert_lm"
            assert manifest["embedding"]["runtime"] == ""
        return {"passed": expected}

    monkeypatch.setattr(gates, "run_tests", run)
    result = gates.audio_gate(args, {"FORESIGHT_LITERT_RUNNER": "worker"})
    assert result["physical_audio"] == "not_run"
    assert seen == ["audio-desktop", "audio-core", "audio-meeting"]
    runner.unlink()
    with pytest.raises(ValueError, match="include Whisper"):
        gates.audio_gate(args, {})


@pytest.mark.parametrize(
    "suite",
    ["fast", "models", "virtual-audio", "reference-models", "reference-tokenizer"],
)
@pytest.mark.parametrize("failure", [False, True])
def test_gate_cli_always_retains_pass_or_failure_summary(
    tmp_path, monkeypatch, suite, failure
):
    monkeypatch.setattr(gates, "bundle_environment", lambda bundle, env: {})

    def gate(args, env):
        assert Path(env["TMPDIR"]).is_dir()
        assert env["FORESIGHT_LITERT_CACHE"].startswith(env["TMPDIR"])
        if failure:
            raise RuntimeError("gate failed")
        return {"passed": 1}

    for name in ("fast_gate", "models_gate", "audio_gate", "reference_gate"):
        monkeypatch.setattr(gates, name, gate)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "gates",
            "--suite",
            suite,
            "--output",
            str(tmp_path),
            "--bundle",
            str(tmp_path),
            "--models",
            str(tmp_path),
        ],
    )
    if failure:
        with pytest.raises(RuntimeError, match="gate failed"):
            gates.main()
    else:
        gates.main()
    report = json.loads((tmp_path / "summary.json").read_text())
    assert report["status"] == ("failed" if failure else "passed")
    assert ("result" in report) is not failure


@pytest.mark.parametrize(
    "suite,extra",
    [
        ("models", []),
        ("virtual-audio", []),
        ("reference-models", []),
        ("models", ["--models", "/models"]),
    ],
)
def test_gate_cli_retains_argument_failure_summary(tmp_path, monkeypatch, suite, extra):
    monkeypatch.setattr(
        sys, "argv", ["gates", "--suite", suite, "--output", str(tmp_path), *extra]
    )
    with pytest.raises(SystemExit, match="2"):
        gates.main()
    assert json.loads((tmp_path / "summary.json").read_text())["status"] == "failed"


def test_model_fixture_requires_exact_hash(tmp_path, monkeypatch):
    content = b"authenticated fixture"
    monkeypatch.setitem(
        gates.MODELS,
        "tiny",
        ("repo", "revision", "model", hashlib.sha256(content).hexdigest()),
    )
    (tmp_path / "model").write_bytes(content)
    assert gates.model_file(tmp_path, "tiny") == str((tmp_path / "model").resolve())
    (tmp_path / "model").write_bytes(b"corrupt")
    with pytest.raises(ValueError, match="digest"):
        gates.model_file(tmp_path, "tiny")
