"""Package smoke orchestration checks evidence/cleanup without a desktop session."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from tools.helper_protocol import HELPER_PROTOCOL_VERSION

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import smoke_bundle as smoke
import installed_documents as documents
import installed_runtime as runtime
import smoke_macos_bundle as peers
import installed_desktop_approval as gui
import verify_macos_release_runtime as release


@pytest.mark.parametrize(
    "failure",
    [
        None,
        "python",
        "linkage",
        "libpython",
        "ping",
        "pipeline",
        "database",
        "permissions",
        "google",
        "owner",
        "headless",
        "shutdown",
    ],
)
def test_linux_smoke_checks_relocation_isolated_owners_and_cleanup(
    tmp_path, monkeypatch, failure
):
    bundle = tmp_path / "bundle"
    bundle.mkdir()
    (bundle / "keep").write_bytes(b"source bytes")
    if failure == "python":
        (bundle / "unexpected.py").touch()
    google = bundle / "share/open-foresight/google-client.json"
    google.parent.mkdir(parents=True)
    google.write_text(
        json.dumps(
            {
                "installed": {
                    "client_id": "fixture",
                    **({"token": "wrong"} if failure == "google" else {}),
                }
            }
        )
    )
    google.chmod(0o600)
    monkeypatch.setattr(
        sys,
        "argv",
        ["smoke", str(bundle), "--output", str(tmp_path / "reports/smoke.json")],
    )
    channel = SimpleNamespace(
        close=Mock(),
        unary_unary=lambda *a, **kw: (
            lambda request, **kw2: SimpleNamespace(
                success=failure != "ping", version=HELPER_PROTOCOL_VERSION
            )
        ),
    )
    monkeypatch.setattr(smoke.grpc, "insecure_channel", lambda socket: channel)
    monkeypatch.setattr(
        smoke.grpc, "channel_ready_future", lambda ch: SimpleNamespace(result=Mock())
    )
    monkeypatch.setattr(
        smoke,
        "control_snapshot",
        lambda ch: {"pipeline": "ready" if failure == "pipeline" else "unconfigured"},
    )
    monkeypatch.setattr(smoke.time, "sleep", lambda _: None)
    clock = iter(range(0, 1000, 6))
    monkeypatch.setattr(smoke.time, "monotonic", lambda: next(clock))
    process = SimpleNamespace(
        pid=99999,
        poll=Mock(return_value=None),
        wait=Mock(
            side_effect=[subprocess.TimeoutExpired("desktop", 5), 0]
            if failure == "shutdown"
            else None,
            return_value=0,
        ),
    )

    def popen(command, **kwargs):
        env = kwargs["env"]
        data, run = Path(env["FORESIGHT_DATA"]), Path(env["FORESIGHT_RUNTIME"])
        data.mkdir(mode=0o700)
        run.mkdir(mode=0o755 if failure == "permissions" else 0o700)
        if failure == "permissions":
            run.chmod(0o755)
            assert run.stat().st_mode & 0o777 == 0o755
        if failure != "database":
            (data / "application.db").touch()
        assert "relocated bundle" in command[0]
        assert kwargs["cwd"] == "/"
        return process

    monkeypatch.setattr(smoke.subprocess, "Popen", popen)
    monkeypatch.setattr(smoke.subprocess, "run", Mock())

    def output(command, **kwargs):
        if command[0] == "ldd":
            return (
                "libmissing => not found"
                if failure == "linkage"
                else "libpython"
                if failure == "libpython"
                else "system libs"
            )
        return json.dumps({"pid": 1 if failure == "owner" else 77})

    monkeypatch.setattr(smoke.subprocess, "check_output", output)
    monkeypatch.setattr(smoke.os, "killpg", Mock())

    def mcp(bundle, env):
        headless = "headless" in env["FORESIGHT_DATA"]
        return {"pid": 77 if not headless or failure == "headless" else 88}

    monkeypatch.setattr(smoke, "mcp_roundtrip", mcp)
    report_path = tmp_path / "reports/smoke.json"
    if failure not in (None, "shutdown"):
        with pytest.raises(RuntimeError):
            smoke.main()
        assert not report_path.exists()
    else:
        smoke.main()
        report = json.loads(report_path.read_text())
        assert report["headless_mcp_startup"] is True
        assert report["mcp_same_profile_owner"] is True
        assert report["no_python_files_or_linkage"] is True
        assert len(report["linkage"]) == 7
        assert report["startup_observation_seconds"] == 10
    assert (bundle / "keep").read_bytes() == b"source bytes"
    if failure not in ("python", "linkage", "libpython"):
        channel.close.assert_called_once()
        process.wait.assert_called()


@pytest.mark.parametrize(
    "failure", [None, "owner", "attach", "import", "status", "unrelated"]
)
def test_installed_document_probe_cleans_peers_and_stops_only_its_own_service(
    tmp_path, monkeypatch, failure
):
    bundle = tmp_path / "bundle"
    bundle.mkdir()
    service = bundle / "bin/foresight-service"
    state = {"closed": [], "commands": []}

    class Mcp:
        def __init__(self, executable, env):
            assert env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"

        def tool(self, name):
            return {
                "pid": 77,
                "installation_root": "wrong"
                if failure == "owner"
                else str(bundle.resolve()),
            }

        def close(self):
            state["closed"].append("mcp")

    class Application:
        def __init__(self, endpoint, host):
            pass

        def close(self):
            state["closed"].append("application")

    monkeypatch.setattr(peers, "McpPeer", Mcp)
    monkeypatch.setattr(gui, "ApprovedApplicationPeer", Application)

    class Desktop:
        def __init__(self, *args):
            pass

        def start(self):
            if failure == "attach":
                raise RuntimeError("Actual GUI unavailable")
            return self

        def close(self):
            state["closed"].append("actual_gui")

    monkeypatch.setattr(gui, "InstalledDesktop", Desktop)
    monkeypatch.setattr(
        documents,
        "process_path",
        lambda pid: Path("/unrelated") if failure == "unrelated" else service.resolve(),
    )

    def command(executable, env, action):
        state["commands"].append(action)
        if action == "--status":
            if failure == "status":
                raise subprocess.CalledProcessError(1, "status")
            return {"pid": 77}

    monkeypatch.setattr(documents, "service_command", command)
    wait = Mock()
    monkeypatch.setattr(documents, "wait_stopped", wait)

    def import_fixtures(*args, **kwargs):
        if failure == "import":
            raise AssertionError("wrong document content")
        return {"pdf": {"status": "passed"}}

    monkeypatch.setattr(documents, "import_document_fixtures", import_fixtures)
    if failure in ("owner", "attach", "import", "unrelated"):
        with pytest.raises((RuntimeError, AssertionError)):
            documents.probe_installed_documents(bundle)
    else:
        assert documents.probe_installed_documents(bundle)["pdf"]["status"] == "passed"
    assert "mcp" in state["closed"]
    if failure not in ("status", "unrelated"):
        assert state["commands"] == ["--status", "--stop"]
        wait.assert_called_once_with(77, service)
    else:
        assert "--stop" not in state["commands"]


@pytest.mark.parametrize("failure", [False, True])
def test_release_runtime_probe_keeps_output_and_uses_clean_environment(
    tmp_path, monkeypatch, failure
):
    paths = {
        key: tmp_path / key
        for key in (
            "FORESIGHT_MODEL_WORKER",
            "FORESIGHT_QUERY_WORKER",
            "FORESIGHT_LITERT_LIBRARY",
            "FORESIGHT_WHISPER_RUNTIME",
        )
    }
    monkeypatch.setattr(release, "runtime_paths", lambda app: paths)

    def run(command, **kwargs):
        assert kwargs["cwd"] == "/"
        assert set(kwargs["env"]) == {
            "PATH",
            "HOME",
            "TMPDIR",
            "FORESIGHT_LITERT_LIBRARY",
        }
        return subprocess.CompletedProcess(
            command, 1 if failure else 0, "stdout evidence", "stderr evidence"
        )

    monkeypatch.setattr(release.subprocess, "run", run)
    report = tmp_path / "reports/runtime.json"
    monkeypatch.setattr(
        sys, "argv", ["runtime", str(tmp_path), "--output", str(report)]
    )
    if failure:
        with pytest.raises(RuntimeError, match="Packaged runtime failed"):
            release.main()
    else:
        release.main()
    data = json.loads(report.read_text())
    assert data["status"] == ("failed" if failure else "passed")
    assert len(data["checks"]) == (1 if failure else 3)
    assert data["checks"]["native_generation_embedding"]["stderr"] == "stderr evidence"


def test_runtime_service_command_prefers_installed_wrapper(tmp_path, monkeypatch):
    service = tmp_path / "bin/foresight-service"
    wrapper = tmp_path / "open-foresight-service"
    run = Mock(return_value=subprocess.CompletedProcess([], 0, '{"pid":77}', ""))
    monkeypatch.setattr(runtime.subprocess, "run", run)
    assert runtime.service_command(service, {}, "--status") == {"pid": 77}
    assert run.call_args.args[0][0] == str(service)
    wrapper.touch()
    assert runtime.service_command(service, {}, "--stop") is None
    assert run.call_args.args[0][0] == str(wrapper)
    monkeypatch.setattr(
        runtime, "process_path", Mock(side_effect=[service.resolve(), None])
    )
    monkeypatch.setattr(runtime.time, "sleep", lambda _: None)
    runtime.wait_stopped(77, service)
    monkeypatch.setattr(runtime, "process_path", lambda pid: service.resolve())
    with pytest.raises(TimeoutError, match="did not stop"):
        runtime.wait_stopped(77, service, timeout=0)


@pytest.fixture
def installed_smoke_module():
    spec = importlib.util.spec_from_file_location(
        "installed_smoke_contract",
        Path(__file__).resolve().parents[1] / "packaging/smoke_installed.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    "failure",
    [
        None,
        "root",
        "empty",
        "linkage",
        "speech",
        "activation",
        "models",
        "permissions",
        "exit",
        "shutdown",
    ],
)
def test_installer_smoke_validates_manifest_startup_and_service_stop(
    tmp_path, monkeypatch, installed_smoke_module, failure, capsys
):
    module = installed_smoke_module
    root = tmp_path / "installed"
    root.mkdir()
    library = root / "lib/native.so"
    library.parent.mkdir()
    library.write_bytes(b"\x7fELFfixture" if failure != "empty" else b"not elf")
    (root / "manifest.json").write_text(
        json.dumps(
            {
                "files": [
                    {
                        "path": "lib/native.so",
                        "sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
                    }
                ]
            }
        )
    )
    monkeypatch.setattr(
        module,
        "Path",
        lambda *args: root if args == ("/opt/open-foresight",) else Path(*args),
    )
    monkeypatch.setattr(module.os, "getuid", lambda: 0 if failure == "root" else 1000)
    content = b"speech fixture model"
    monkeypatch.setattr(
        module,
        "SPEECH_PIN",
        ("repo", "revision", "model", hashlib.sha256(content).hexdigest()),
    )
    monkeypatch.setattr(
        module.urllib.request, "urlopen", lambda *a, **kw: io.BytesIO(content)
    )
    monkeypatch.setattr(
        module, "probe_installed_documents", lambda bundle: {"pdf": "fixture"}
    )
    stopped = Mock()
    monkeypatch.setattr(module, "stop_installed_service", stopped)
    process = SimpleNamespace(
        pid=99999,
        poll=Mock(return_value=1 if failure == "exit" else None),
        wait=Mock(
            side_effect=[subprocess.TimeoutExpired("desktop", 10), 0]
            if failure == "shutdown"
            else None,
            return_value=0,
        ),
    )

    def popen(command, **kwargs):
        data, runtime = (
            Path(kwargs["env"]["FORESIGHT_DATA"]),
            Path(kwargs["env"]["FORESIGHT_RUNTIME"]),
        )
        data.mkdir(mode=0o755 if failure == "permissions" else 0o700)
        if failure == "permissions":
            data.chmod(0o755)
            assert data.stat().st_mode & 0o777 == 0o755
        runtime.mkdir(mode=0o700)
        (runtime / "helper.sock").touch()
        with sqlite3.connect(data / "application.db") as db:
            db.execute("CREATE TABLE models (id INTEGER)")
            if failure == "models":
                db.execute("INSERT INTO models VALUES (1)")
        return process

    monkeypatch.setattr(module.subprocess, "Popen", popen)

    def run(command, **kwargs):
        return subprocess.CompletedProcess(
            command,
            0,
            "not found"
            if failure == "linkage"
            else "wrong speech"
            if failure == "speech"
            else "ask what your country",
            "",
        )

    monkeypatch.setattr(module.subprocess, "run", run)
    command = Mock()
    command.__enter__ = Mock(return_value=command)
    command.__exit__ = Mock(return_value=False)
    command.recv.return_value = b"wrong" if failure == "activation" else b"accepted\n"
    monkeypatch.setattr(module.socket, "socket", lambda *a: command)
    monkeypatch.setattr(module.os, "killpg", Mock())
    monkeypatch.setattr(module.time, "sleep", lambda _: None)
    if failure not in (None, "shutdown"):
        with pytest.raises(RuntimeError):
            module.main()
    else:
        module.main()
        report = json.loads(capsys.readouterr().out)
        assert report["installed_manifest"] is True
        assert report["activation_ipc"] is True
        assert report["physical_audio_or_gpu_inference_tested"] is False
    if failure in (None, "activation", "models", "permissions", "exit", "shutdown"):
        stopped.assert_called_once()
    else:
        stopped.assert_not_called()
