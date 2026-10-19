"""Contract tests for acceptance evidence, isolation and skip-inventory drift."""

from contextlib import nullcontext
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import integration_gates as gates  # noqa: E402 - Imports follow the local tools path setup.
import check_integration_inventory as inventory  # noqa: E402 - Imports follow the local tools path setup.


def write_events(path, **changes):
    event = dict(type="testDone", hidden=False, skipped=False, result="success")
    event.update(changes)
    path.write_text(
        json.dumps(event) + "\n" + json.dumps(dict(type="done", success=True)) + "\n"
    )


def test_expected_executed_tests_are_required(tmp_path):
    path = tmp_path / "events.jsonl"
    write_events(path)
    assert gates.check_events(path, 1) == {"passed": 1, "skipped": 0}
    for changes in [dict(skipped=True), dict(hidden=True), dict(result="error")]:
        write_events(path, **changes)
        with pytest.raises(RuntimeError):
            gates.check_events(path, 1)
    path.write_text('{"type":"done","success":true}\n')
    with pytest.raises(RuntimeError):
        gates.check_events(path, 1)


def test_failed_run_cannot_reuse_stale_evidence(tmp_path):
    path = tmp_path / "probe.events.jsonl"
    write_events(path)
    with patch.object(
        gates.subprocess, "run", return_value=type("Result", (), {"returncode": 1})()
    ):
        with pytest.raises(RuntimeError):
            gates.run_tests(
                "desktop", ["test/example.dart"], 1, dict(os.environ), tmp_path, "probe"
            )
    assert not path.exists()


def test_native_bundle_overrides_do_not_inherit_accounts_or_capture_routes(tmp_path):
    for relative in [
        "lib/libforesight_native.so",
        "bin/ForesightHelper",
        "bin/foresight-model",
    ]:
        file = tmp_path / relative
        file.parent.mkdir(exist_ok=True)
        file.touch()
    env = gates.bundle_environment(
        tmp_path,
        {
            "PATH": "/bin",
            "FORESIGHT_DATA": "/private/profile",
            "FORESIGHT_GOOGLE_CLIENT": "/private/account",
            "FORESIGHT_MICROPHONE_TARGET": "host-mic",
        },
    )
    assert "FORESIGHT_DATA" not in env and "FORESIGHT_GOOGLE_CLIENT" not in env
    assert "FORESIGHT_MICROPHONE_TARGET" not in env
    assert env["FORESIGHT_LITERT_BACKEND"] == "cpu"
    assert env["FORESIGHT_NATIVE"] == str(tmp_path / "lib/libforesight_native.so")


def test_virtual_audio_refuses_host_devices(tmp_path):
    real_exists = Path.exists

    def exists(path):
        return True if str(path) == "/dev/snd" else real_exists(path)

    with (
        patch.object(gates.sys, "platform", "linux"),
        patch.object(Path, "exists", exists),
    ):
        with pytest.raises(RuntimeError, match="without host sound"):
            with gates.private_pipewire({}, tmp_path):
                pass


def test_inventory_catches_added_removed_or_changed_skips(tmp_path):
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/integration_probes.json").write_text(
        json.dumps({"schema": 1, "entries": []})
    )
    directory = tmp_path / "apps/desktop/test"
    directory.mkdir(parents=True)
    source = directory / "fixture.dart"
    source.write_text('test("x", () {},\n skip: flag != "1",\n);')
    entry = dict(
        path="apps/desktop/test/fixture.dart",
        gate="models",
        reason="Public fixture",
        conditions=['flag != "1"'],
    )
    (tmp_path / "tools/integration_skips.json").write_text(
        json.dumps(dict(schema=1, entries=[entry]))
    )
    assert inventory.verify(tmp_path) == 1
    for text in ['test("x", () {});', 'test("x", () {},\n skip: true,\n);']:
        source.write_text(text)
        with pytest.raises(ValueError, match="changed skip"):
            inventory.verify(tmp_path)


def test_repository_skip_inventory_is_current():
    assert inventory.verify(ROOT) > 0


def test_waveform_inspector_does_not_inherit_whisper_runtime(tmp_path):
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
    observed = []

    def run(package, files, expected, env, *rest, **kwargs):
        observed.append((package, list(files), dict(env), expected, kwargs))
        return {"passed": expected, "skipped": 0}

    def pipewire(env, output):
        return nullcontext(
            dict(
                env, FORESIGHT_LIVE_SINK="ci-sink", FORESIGHT_MICROPHONE_TARGET="ci-mic"
            )
        )

    with (
        patch.object(gates, "model_file", return_value="/fixture/model"),
        patch.object(gates, "private_pipewire", side_effect=pipewire),
        patch.object(
            gates,
            "private_x11",
            side_effect=lambda env, output: nullcontext(
                dict(env, DISPLAY=":71", GDK_BACKEND="x11", FORESIGHT_PRIVATE_X11=":71")
            ),
        ),
        patch.object(gates, "run_tests", side_effect=run),
    ):
        gates.audio_gate(args, {"PATH": "/bin"})
    assert observed[0][0] == "desktop" and observed[0][2][
        "FORESIGHT_WHISPER_RUNTIME"
    ] == str(runner)
    assert (
        observed[1][0] == "core" and "FORESIGHT_WHISPER_RUNTIME" not in observed[1][2]
    )
    assert observed[2][1] == ["integration_test/meeting_workflow_test.dart"]
    assert observed[2][3] == 1
    assert observed[2][4] == {"device": "linux"}
    meeting = observed[2][2]
    assert meeting["FORESIGHT_PLAYBACK_TARGET"] == "ci-sink"
    assert meeting["FORESIGHT_PRIVATE_PIPEWIRE"] == "1"
    assert meeting["FORESIGHT_PRIVATE_X11"] == meeting["DISPLAY"] == ":71"
    assert meeting["FORESIGHT_AUDIO_FIXTURE"].endswith("tests/fixtures/audio/jfk.wav")
    assert meeting["FORESIGHT_DATA"].endswith("/meeting-data")
    assert meeting["FORESIGHT_REFERENCE_SCREENSHOTS"].endswith("/meeting-screenshots")
    assert meeting["FORESIGHT_MEETING_REPORT"].endswith("/meeting-workflow.json")
    assert meeting["PATH"] == "/bin"
    assert not (args.output / "meeting-opener").exists()
    assert meeting["FORESIGHT_LINK_OPEN_REPORT"].endswith("/link-open.json")
    assert "FORESIGHT_PLAYBACK_TARGET" not in observed[0][2]


def test_private_profile_is_readable_after_the_suite(tmp_path):
    private = tmp_path / "meeting-data" / "nested"
    private.mkdir(parents=True)
    (tmp_path / "meeting-data").chmod(0o700)
    private.chmod(0o700)
    secret = private / "profile.db"
    secret.write_text("rows")
    secret.chmod(0o600)
    gates.publish_report_tree(tmp_path)
    assert (tmp_path / "meeting-data").stat().st_mode & 0o007 == 0o005
    assert private.stat().st_mode & 0o007 == 0o005
    assert secret.stat().st_mode & 0o007 == 0o004
    assert secret.read_text() == "rows"


def test_report_tree_continues_when_the_mount_root_cannot_be_changed(tmp_path):
    private = tmp_path / "meeting-data"
    private.mkdir()
    private.chmod(0o700)
    secret = private / "profile.db"
    secret.write_text("rows")
    secret.chmod(0o600)
    original = Path.chmod

    def chmod(self, mode):
        if self == tmp_path:
            raise PermissionError(1, "Operation not permitted", str(self))
        return original(self, mode)

    with patch.object(Path, "chmod", chmod):
        gates.publish_report_tree(tmp_path)
    assert private.stat().st_mode & 0o007 == 0o005
    assert secret.stat().st_mode & 0o007 == 0o004


def test_meeting_workflow_waits_until_the_desktop_mounts():
    source = (
        ROOT / "apps/desktop/integration_test/meeting_workflow_test.dart"
    ).read_text()
    start = source.index("Future<dynamic> startedWorkspace")
    helper = source[start : source.index("Future<void> captureWindow")]
    assert "find.text('Open Foresight could not start')" in helper
    assert "find.byType(app.Workspace)" in helper
    assert "Desktop did not start:" in helper
    assert source.count("await startedWorkspace(tester)") == 4
    assert (
        "await tester.pump();\n      final dynamic workspace = tester.state"
        not in source
    )


def test_meeting_workflow_alias_is_outside_the_device_test_directory():
    relative = gates.widget_test_alias("integration_test/meeting_workflow_test.dart")
    alias = ROOT / "apps/desktop" / relative
    try:
        assert relative == "test/private_pipewire_meeting_workflow_test.dart"
        assert alias.is_symlink()
        assert (
            alias.resolve()
            == (
                ROOT / "apps/desktop/integration_test/meeting_workflow_test.dart"
            ).resolve()
        )
        assert not str(alias).startswith(str(ROOT / "apps/desktop/integration_test"))
    finally:
        alias.unlink(missing_ok=True)


def test_model_groups_both_execute_when_desktop_group_fails(tmp_path):
    args = SimpleNamespace(
        models=tmp_path, output=tmp_path, flutter="flutter", dart="dart"
    )
    observed = []

    def run(package, *args):
        observed.append(package)
        if package == "desktop":
            raise RuntimeError("desktop fixture failed")
        return {"passed": 1, "skipped": 0}

    with (
        patch.object(gates, "model_file", return_value="/fixture/model"),
        patch.object(gates, "run_tests", side_effect=run),
    ):
        with pytest.raises(RuntimeError, match="desktop fixture failed"):
            gates.models_gate(args, {"FORESIGHT_LITERT_RUNNER": "/runner"})
    assert observed == ["desktop", "core"]


@pytest.mark.parametrize("name", ["test_new_probe.py", "accept_new_probe.py"])
def test_probe_inventory_rejects_unlisted_harnesses(tmp_path, name):
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/integration_probes.json").write_text(
        json.dumps({"schema": 1, "entries": []})
    )
    (tmp_path / "tools" / name).write_text("# Unregistered probe")
    with pytest.raises(ValueError, match="Unlisted or stale tooling probes"):
        inventory.verify_probes(tmp_path)


def test_skip_inventory_scans_desktop_integration_tests(tmp_path):
    (tmp_path / "tools").mkdir()
    for name in ("integration_probes", "integration_skips"):
        (tmp_path / "tools" / (name + ".json")).write_text(
            json.dumps({"schema": 1, "entries": []})
        )
    folder = tmp_path / "apps/desktop/integration_test"
    folder.mkdir(parents=True)
    (folder / "new.dart").write_text("test('x', () {}, skip: true,\n);")
    with pytest.raises(ValueError, match="changed skip"):
        inventory.verify(tmp_path)


@pytest.mark.parametrize("device", [None, "linux"])
def test_native_runner_executes_original_integration_source(tmp_path, device):
    """Exercise the actual argv/report boundary, including archive-only trees."""
    desktop = tmp_path / "apps/desktop"
    (desktop / "test").mkdir(parents=True)
    (desktop / "integration_test").mkdir()
    (desktop / "integration_test/workflow.dart").write_text("// fixture")
    runner = tmp_path / "flutter"
    runner.write_text(
        "#!" + sys.executable + "\n"
        "import json, pathlib, sys\n"
        "args=sys.argv[1:]\n"
        "pathlib.Path('argv.json').write_text(json.dumps(args))\n"
        "events=next(a.split('json:',1)[1] for a in args if a.startswith('--file-reporter='))\n"
        "pathlib.Path(events).write_text("
        + repr(
            '{"type":"testDone","hidden":false,"skipped":false,"result":"success"}\n'
            '{"type":"done","success":true}\n'
        )
        + ")\n"
    )
    runner.chmod(0o700)
    with (
        patch.object(gates, "ROOT", tmp_path),
        patch.object(gates.subprocess, "run", wraps=gates.subprocess.run) as launch,
    ):
        result = gates.run_tests(
            "desktop",
            ["integration_test/workflow.dart"],
            1,
            dict(os.environ),
            tmp_path / "reports",
            "probe",
            flutter=str(runner),
            device=device,
            timeout=17,
        )
    assert launch.call_args.kwargs["timeout"] == 17
    assert result == {"passed": 1, "skipped": 0}
    arguments = json.loads((desktop / "argv.json").read_text())
    assert "--no-pub" in arguments
    if device:
        assert "integration_test/workflow.dart" in arguments
        assert arguments[arguments.index("-d") + 1] == device
    else:
        assert "test/private_pipewire_workflow.dart" in arguments
        assert "-d" not in arguments
    assert list((desktop / "test").iterdir()) == []


@pytest.mark.parametrize("broken", [False, True])
def test_private_x_server_is_owned_and_stopped_on_failure(tmp_path, broken):
    binary = tmp_path / "Xvfb"
    binary.write_text(
        "#!" + sys.executable + "\n"
        "import json, os, pathlib, signal, sys\n"
        "pathlib.Path(os.environ['DISPLAY_TEST_REPORT']).write_text(json.dumps({'pid':os.getpid(),'env':dict(os.environ),'args':sys.argv[1:]}))\n"
        "os.write(int(sys.argv[sys.argv.index('-displayfd')+1]), b'71\\n')\n"
        "signal.pause()\n"
    )
    binary.chmod(0o700)
    report = tmp_path / "server.json"
    env = dict(
        os.environ,
        PATH=str(tmp_path) + os.pathsep + os.environ["PATH"],
        DISPLAY_TEST_REPORT=str(report),
        DISPLAY=":0",
        WAYLAND_DISPLAY="host",
        XAUTHORITY="host-cookie",
        HYPRLAND_INSTANCE_SIGNATURE="personal",
        XDG_ACTIVATION_TOKEN="host-activation",
        DESKTOP_STARTUP_ID="host-startup",
        FORESIGHT_PRIVATE_PIPEWIRE="1",
    )
    try:
        with gates.private_x11(env, tmp_path) as private:
            assert private["DISPLAY"] == private["FORESIGHT_PRIVATE_X11"] == ":71"
            assert private["GDK_BACKEND"] == "x11"
            for key in [
                "WAYLAND_DISPLAY",
                "XAUTHORITY",
                "HYPRLAND_INSTANCE_SIGNATURE",
                "XDG_ACTIVATION_TOKEN",
                "DESKTOP_STARTUP_ID",
            ]:
                assert key not in private
            state = json.loads(report.read_text())
            assert "DISPLAY" not in state["env"]
            assert "1280x720x24" in state["args"]
            assert state["args"][state["args"].index("-nolisten") + 1] == "tcp"
            if broken:
                raise RuntimeError("test failed during capture")
    except RuntimeError as error:
        assert broken and "test failed during capture" in str(error)
    with pytest.raises(ProcessLookupError):
        os.kill(json.loads(report.read_text())["pid"], 0)


def test_native_ui_requires_private_audio(tmp_path):
    with pytest.raises(RuntimeError, match="private Linux audio"):
        with gates.private_x11({}, tmp_path):
            pytest.fail("must not capture an inherited display")


@pytest.mark.parametrize("failure", ["empty", "invalid", "exited", "timeout", "kill"])
def test_private_x_server_startup_failures_and_forced_shutdown(
    tmp_path, monkeypatch, failure
):
    monkeypatch.setattr(gates.sys, "platform", "linux")
    binary = tmp_path / "Xvfb"
    payload = b"wrong\n" if failure == "invalid" else b"71\n"
    binary.write_text(
        "#!" + sys.executable + "\n"
        "import os, signal, sys\n"
        + (
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            if failure == "kill"
            else ""
        )
        + ("sys.exit(0)\n" if failure == "empty" else "")
        + f"os.write(int(sys.argv[sys.argv.index('-displayfd')+1]), {payload!r})\n"
        + ("sys.exit(0)\n" if failure == "exited" else "signal.pause()\n")
    )
    binary.chmod(0o700)
    processes = []
    original = gates.subprocess.Popen

    def launch(*args, **kwargs):
        process = original(*args, **kwargs)
        processes.append(process)
        if failure == "exited":
            process.wait(timeout=5)
        return process

    monkeypatch.setattr(gates.subprocess, "Popen", launch)
    if failure == "timeout":
        monkeypatch.setattr(gates.select, "select", lambda *args: ([], [], []))
    env = dict(
        os.environ,
        PATH=str(tmp_path) + os.pathsep + os.environ["PATH"],
        FORESIGHT_PRIVATE_PIPEWIRE="1",
    )
    if failure == "kill":
        with gates.private_x11(env, tmp_path) as private:
            assert private["DISPLAY"] == ":71"
        assert processes[0].returncode == -gates.signal.SIGKILL
    else:
        with pytest.raises(RuntimeError, match="Private X display"):
            with gates.private_x11(env, tmp_path):
                pytest.fail("a server without a valid readiness handshake must fail")
    assert processes and processes[0].poll() is not None
    assert (tmp_path / "xvfb.log").exists()


def test_missing_x_server_closes_readiness_descriptors(tmp_path, monkeypatch):
    monkeypatch.setattr(gates.sys, "platform", "linux")
    opened = []
    original = gates.os.pipe

    def pipe():
        pair = original()
        opened.extend(pair)
        return pair

    monkeypatch.setattr(gates.os, "pipe", pipe)
    with pytest.raises(FileNotFoundError):
        with gates.private_x11(
            {"PATH": str(tmp_path), "FORESIGHT_PRIVATE_PIPEWIRE": "1"}, tmp_path
        ):
            pytest.fail("missing Xvfb cannot provide a native display")
    for descriptor in opened:
        with pytest.raises(OSError):
            os.fstat(descriptor)
