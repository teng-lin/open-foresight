"""Real application/MCP subprocess integration with controlled inference/audio.

Run after building: .venv/bin/python -m pytest tests/service -v
These fixtures verify ownership and data flow, not inference quality.
"""

import base64
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from service_ui_report import verify_service_ui_report  # noqa: E402
from integration_gates import run_tests  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SERVICE = Path(
    os.environ.get(
        "FORESIGHT_SERVICE_EXECUTABLE", ROOT / "build/application/foresight-service"
    )
)
MCP = Path(
    os.environ.get("FORESIGHT_MCP_EXECUTABLE", ROOT / "build/application/foresight-mcp")
)
HELPER = Path(
    os.environ.get(
        "FORESIGHT_HELPER_EXECUTABLE", ROOT / "build/services/helper/ForesightHelper"
    )
)
NATIVE = Path(
    os.environ.get(
        "FORESIGHT_NATIVE_LIBRARY",
        ROOT
        / (
            "build/native/libforesight_native.dylib"
            if sys.platform == "darwin"
            else "build/native/libforesight_native.so"
        ),
    )
)


class Peer:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(30)
        self.socket.connect(str(path))
        self.reader = self.socket.makefile("r")
        self.sequence = 0
        self.events = []

    def send(self, method, args=None):
        self.sequence += 1
        self.socket.sendall(
            (
                json.dumps({"id": self.sequence, "method": method, "args": args or {}})
                + "\n"
            ).encode()
        )
        return self.sequence

    def result(self, identifier):
        result = None
        while True:
            line = self.reader.readline()
            assert line, "service disconnected"
            value = json.loads(line)
            if "event" in value:
                self.events.append(value)
                continue
            assert value["id"] == identifier, value
            if "error" in value:
                raise RuntimeError(value["error"])
            if "result" in value:
                result = value["result"]
            if value.get("done"):
                return result

    def call(self, method, args=None):
        return self.result(self.send(method, args))

    def close(self):
        self.reader.close()
        self.socket.close()

    def shutdown(self):
        self.socket.shutdown(socket.SHUT_RDWR)


class DesktopPeer(Peer):
    """A distinct native executable, authenticated by real Unix credentials."""

    def __init__(self, executable, path):
        self.process = subprocess.Popen(
            [str(executable), str(path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.reader = self.process.stdout
        self.sequence = 0
        self.events = []

    def send(self, method, args=None):
        self.sequence += 1
        self.process.stdin.write(
            json.dumps({"id": self.sequence, "method": method, "args": args or {}})
            + "\n"
        )
        self.process.stdin.flush()
        return self.sequence

    def shutdown(self):
        self.process.stdin.close()

    def close(self):
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.reader.close()
        self.process.stderr.close()


class ApprovalDesktop:
    """Explicit synthetic UI host for tests that exercise approved operations."""

    def __init__(self, path, profile, root, preferences=None):
        self.peer = DesktopPeer(root / "fixtures/desktop-peer", path)
        self.closed = False
        self.peer.call(
            "status"
        )  # Wait until service initialization publishes the capability.
        self.peer.call(
            "security.attach_desktop",
            {"token": (profile / ".desktop-capability").read_text(), "visible": True},
        )
        self.peer.call("security.allow_import_root", {"path": str(root)})
        # The review thread owns the reader after it starts. Set preferences
        # synchronously while this connection is still ours to read.
        for key, value in (preferences or {}).items():
            self.peer.call("preferences.set", {"key": key, "value": value})
        self.thread = threading.Thread(target=self._review, daemon=True)
        self.thread.start()

    def _review(self):
        try:
            for line in self.peer.reader:
                value = json.loads(line)
                if value.get("event") == "approval":
                    self.peer.send(
                        "security.decide",
                        {"approval_id": value["approval_id"], "allow": True},
                    )
        except (OSError, ValueError):
            pass

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.peer.shutdown()
        except OSError:
            pass
        self.thread.join(timeout=3)
        self.peer.close()


class McpPeer:
    def __init__(self, env, *, executable=None):
        self.runtime = Path(env["FORESIGHT_RUNTIME"])
        self.service_pid = None
        self.previous_reply = None
        self.previous_error = None
        self.process = subprocess.Popen(
            [str(executable or MCP)],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.sequence = 0
        self.notifications = []

    def send(self, method, params=None, notification=False):
        value = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if not notification:
            self.sequence += 1
            value["id"] = self.sequence
        self.process.stdin.write((json.dumps(value) + "\n").encode())
        self.process.stdin.flush()
        return value.get("id")

    def result(self, identifier):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            ready, _, _ = select.select(
                [self.process.stdout], [], [], max(0, deadline - time.monotonic())
            )
            assert ready, self.timeout_details(identifier)
            line = self.process.stdout.readline()
            assert line, f"MCP exited: {self.process.stderr.read().decode()}"
            value = json.loads(line)  # Any non-protocol stdout fails this test.
            if "method" in value:
                self.notifications.append(value)
            if value.get("id") == identifier:
                self.previous_reply = identifier
                result = value.get("result")
                self.previous_error = (
                    json.dumps(result)[:2048]
                    if isinstance(result, dict) and result.get("isError")
                    else None
                )
                return value
        raise TimeoutError(identifier)

    def timeout_details(self, identifier):
        chunks = []
        remaining = 16384
        while remaining > 0:
            ready, _, _ = select.select([self.process.stderr], [], [], 0)
            if not ready:
                break
            data = os.read(self.process.stderr.fileno(), min(remaining, 4096))
            if not data:
                break
            chunks.append(data)
            remaining -= len(data)
        owner_alive = None
        if self.service_pid is not None:
            try:
                os.kill(self.service_pid, 0)
                owner_alive = True
            except ProcessLookupError:
                owner_alive = False
            except OSError:
                pass
        sockets = {
            name: (self.runtime / name).exists()
            for name in ("application.sock", "worker.sock")
        }
        diagnostic = {
            "request": identifier,
            "previous_reply": self.previous_reply,
            "previous_error": self.previous_error,
            "mcp_pid": self.process.pid,
            "mcp_exit": self.process.poll(),
            "owner_pid": self.service_pid,
            "owner_alive": owner_alive,
            "sockets": sockets,
            "stderr": b"".join(chunks).decode(errors="replace"),
        }
        return "MCP response timeout: " + json.dumps(diagnostic)

    def call(self, method, params=None):
        response = self.result(self.send(method, params))
        assert "error" not in response, response
        return response["result"]

    def initialize(self):
        result = self.call(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "subprocess-test", "version": "1"},
            },
        )
        assert result["protocolVersion"] == "2025-11-25"
        self.send("notifications/initialized", notification=True)

    def tool(self, name, args=None):
        return self.call("tools/call", {"name": name, "arguments": args or {}})

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
            assert self.process.returncode == 0, self.process.stderr.read().decode()
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=30)
            self.process.stdout.close()
            self.process.stderr.close()


@pytest.mark.skipif(sys.platform != "linux", reason="Linux native package layout")
@pytest.mark.parametrize("entrypoint", ["service", "mcp"])
def test_direct_packaged_entrypoints_enforce_identity_without_launcher(tmp_path, entrypoint):
    from package import write_runtime_configuration
    from runtime_package_support import (
        METADATA_DIRECTORY,
        prepare as prepare_support,
        prepare_worker,
        seal as seal_support,
        seal_worker,
        stage as stage_support,
        stage_worker,
    )

    support = prepare_support(ROOT, NATIVE.parent, "linux-x86_64")
    worker = prepare_worker(ROOT, SERVICE.parent.parent)
    assert support.receipt["native_id"] == worker.receipt["native_id"]

    bundle = tmp_path / "package"
    for name in ("app", "bin", "lib", "share/open-foresight"):
        (bundle / name).mkdir(parents=True, exist_ok=True)
    for source, name in ((SERVICE, "bin/foresight-service"), (MCP, "bin/foresight-mcp"),
                         (NATIVE, "lib/libforesight_native.so"), (HELPER, "bin/ForesightHelper")):
        shutil.copy2(source, bundle / name)
    stage_support(bundle, support)
    stage_worker(bundle, worker)
    sqlite = Path(subprocess.run(["ldd", str(HELPER)], check=True, capture_output=True,
                                 text=True, timeout=30).stdout.split("libsqlite3.so.0 => ", 1)[1].split()[0])
    shutil.copy2(sqlite, bundle / "lib/libsqlite3.so.0")
    (bundle / "lib/libsqlite3.so").symlink_to("libsqlite3.so.0")
    desktop = bundle / "app/open-foresight"
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17",
                    str(ROOT / "packages/foresight_core/test/fixtures/desktop_peer.cpp"),
                    "-o", str(desktop)], check=True, capture_output=True, text=True, timeout=60)
    impostor = tmp_path / "untrusted-desktop"
    shutil.copy2(desktop, impostor)
    write_runtime_configuration(bundle, "a" * 40, "cpu", 0)
    seal_support(bundle, support, transformed=False)
    seal_worker(bundle, worker, transformed=False)
    # No launcher-selected resources, code paths, installation root or revision.
    env = {key: value for key, value in os.environ.items() if not key.startswith("FORESIGHT_")}
    env.pop("LD_LIBRARY_PATH", None)
    env.update(FORESIGHT_DATA=str(tmp_path / "data"), FORESIGHT_RUNTIME=str(tmp_path / "r"),
               FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES=json.dumps([str(impostor)]))
    log = (tmp_path / "packaged-service.log").open("w+")
    owner = None
    mcp = None
    peers = []
    try:
        if entrypoint == "service":
            owner = subprocess.Popen([str(bundle / "bin/foresight-service")], env=env,
                                     stdout=log, stderr=subprocess.STDOUT)
        else:
            mcp = McpPeer(env, executable=bundle / "bin/foresight-mcp")
            mcp.initialize()
        socket_path = tmp_path / "r/application.sock"
        deadline = time.monotonic() + 20
        while not socket_path.exists():
            assert time.monotonic() < deadline, "packaged service did not publish its endpoint"
            assert owner is None or owner.poll() is None, "packaged service exited"
            time.sleep(.02)
        peer = Peer(socket_path)
        peers.append(peer)
        status = peer.call("status")
        assert status["installation_root"] == str(bundle.resolve())
        assert status["runtime_revision"] == "a" * 40
        mapped = Path(f"/proc/{status['pid']}/maps").read_text()
        assert str((bundle / "lib/libsqlite3.so.0").resolve()) in mapped
        thief = DesktopPeer(impostor, socket_path)
        peers.append(thief)
        token = tmp_path / "data/.desktop-capability"
        with pytest.raises(RuntimeError, match="verified desktop"):
            thief.call("security.attach_desktop", {"token": token.read_text(), "visible": True})
        trusted = DesktopPeer(desktop, socket_path)
        peers.append(trusted)
        assert trusted.call("security.attach_desktop", {"token": token.read_text(), "visible": True}) is True
        model = tmp_path / "model"
        model.write_text("unused model")
        with pytest.raises(RuntimeError, match="outside this installation"):
            trusted.call("models.generation", {"path": str(model), "runtime": "/usr/bin/true", "backend": "llama_cpp"})
    finally:
        for peer in peers:
            if isinstance(peer, DesktopPeer):
                peer.shutdown()
            peer.close()
        stopped = subprocess.run([str(bundle / "bin/foresight-service"), "--stop"], env=env,
                                 capture_output=True, text=True, timeout=30)
        print(stopped.stdout, stopped.stderr)
        if mcp is not None:
            mcp.close()
        if owner is not None:
            try:
                owner.wait(timeout=10)
            except subprocess.TimeoutExpired:
                owner.kill()
                owner.wait(timeout=10)
        log.seek(0)
        print(log.read())
        log.close()
    if entrypoint == "service":
        (bundle / "share/open-foresight/runtime.json").unlink()
        missing = subprocess.run([str(bundle / "bin/foresight-service"), "--status"],
                                 env=env, capture_output=True, text=True, timeout=30)
        assert missing.returncode != 0
        assert "runtime configuration is missing" in missing.stderr
        shutil.rmtree(bundle / METADATA_DIRECTORY)
        (bundle / "share/open-foresight").rmdir()
        no_directory = subprocess.run([str(bundle / "bin/foresight-service"), "--status"],
                                      env=env, capture_output=True, text=True, timeout=30)
        assert no_directory.returncode != 0
        assert "runtime configuration is missing" in no_directory.stderr


@pytest.fixture
def first_run_catalog(tmp_path, monkeypatch):
    from first_run_loopback import LoopbackModels
    from build_diagnostic_worker import verify_worker_build

    native_build = NATIVE.resolve(strict=True).parent.parent
    dart = shutil.which("dart")
    assert dart, "First-run acceptance requires the pinned Dart SDK"
    sdk = Path(dart).resolve(strict=True).parent.parent
    receipt = verify_worker_build(
        ROOT,
        native_build,
        sdk,
        ROOT / "packages/foresight_core/.dart_tool/package_config.json",
        "aot",
    )
    compiled = tmp_path / "first-run-hosts"
    compiled.mkdir(mode=0o700)
    with LoopbackModels() as loopback:
        defines = [
            f"-D{key}={value}" for key, value in sorted(receipt["defines"].items())
        ]
        defines.extend(
            [
                "-DFORESIGHT_ENABLE_TEST_HOOKS=true",
                "-DFORESIGHT_MODEL_CATALOG_TEST_BASE64="
                + base64.b64encode(json.dumps(loopback.catalog, separators=(",", ":")).encode()).decode("ascii"),
            ]
        )
        for source, name in [
            ("service.dart", "foresight-service"),
            ("mcp.dart", "foresight-mcp"),
        ]:
            with (compiled / f"{name}.compile.log").open("w") as log:
                subprocess.run(
                    [
                        dart,
                        "compile",
                        "exe",
                        *defines,
                        str(ROOT / "packages/foresight_core/bin" / source),
                        "-o",
                        str(compiled / name),
                    ],
                    cwd=ROOT / "packages/foresight_core",
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=300,
                    check=True,
                )
        monkeypatch.setattr(
            sys.modules[__name__], "SERVICE", compiled / "foresight-service"
        )
        monkeypatch.setattr(sys.modules[__name__], "MCP", compiled / "foresight-mcp")
        yield loopback
        # Preserve acquisition evidence even if owner teardown fails below.
        (tmp_path / "first-run-downloads.json").write_text(
            json.dumps(loopback.requests, indent=2)
        )
        worker_report = tmp_path / "first-run-worker.jsonl"
        if worker_report.exists():
            for line in worker_report.read_text().splitlines():
                owner = json.loads(line)
                assert owner["uid"] == os.getuid() and owner["synthetic"] is True
                with pytest.raises(ProcessLookupError):
                    os.kill(owner["pid"], 0)


@pytest.fixture
def running(tmp_path, request):
    parameter = getattr(request, "param", None)
    options = parameter.split(",") if parameter else []
    first_run = request.getfixturevalue("first_run_catalog") if "first_run" in options else None
    assert SERVICE.is_file() and MCP.is_file(), (
        "Build service and MCP executables first"
    )
    preferences = {}
    for option in options:
        if option.startswith("idle="):
            preferences["serviceIdleMinutes"] = option.removeprefix("idle=")
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir(mode=0o700)
    desktop_peer = fixtures / "desktop-peer"
    subprocess.run(
        [os.environ.get("CXX", "c++"), "-std=c++17",
         str(ROOT / "packages/foresight_core/test/fixtures/desktop_peer.cpp"),
         "-o", str(desktop_peer)],
        check=True, capture_output=True, text=True, timeout=60,
    )
    flutter_desktop = (
        ROOT / "apps/desktop/build/macos/Build/Products/Debug/Open Foresight.app/Contents/MacOS/Open Foresight"
        if sys.platform == "darwin"
        else ROOT / "apps/desktop/build/linux/x64/debug/bundle/open-foresight"
    )
    model = fixtures / "model.litertlm"
    model.write_bytes(b"controlled embedding fixture")
    asset = fixtures / "asset.bin"
    asset.write_bytes(b"controlled model fixture")
    runner = fixtures / "runner"
    runner.write_text(
        "#!/usr/bin/env python3\nimport json,sys,time,os,pathlib\n"
        'if "-n" in sys.argv and sys.argv[sys.argv.index("-n")+1]=="0": sys.exit(0)\n'
        'if "-f" in sys.argv: print("Mira sends the draft Tuesday."); sys.exit(0)\n'
        'if "--probe" in sys.argv: print(json.dumps({"native_stop_token_sequences":True})); sys.exit(0)\n'
        'request=json.loads(sys.stdin.readline()) if "--model" in sys.argv else {}\n'
        'if "tools" in request:\n'
        ' assert request["tools"]["tools"]==[]\n'
        ' answer={"role":"assistant","content":[{"type":"text","text":"# Overview\\nMira sends the draft Tuesday.\\n# Details\\n* **Draft delivery plan**: Mira owns the draft."}]}\n'
        ' print("model "+json.dumps(answer),flush=True)\n'
        ' assert json.loads(sys.stdin.readline())=={"finish":True}\n'
        ' print("answer "+json.dumps(answer),flush=True); sys.exit(0)\n'
        'marker=pathlib.Path(os.environ["FORESIGHT_DELAY_GENERATION"])\n'
        "if marker.exists(): time.sleep(15)\n"
        'print(json.dumps({"answer":"Mira sends the draft Tuesday. [S1]","citations":["S1"]}))\n'
    )
    runner.chmod(0o700)
    capture = fixtures / "pw-record"
    capture.write_text(
        "#!/usr/bin/env python3\nimport os,sys,time,struct,math\n"
        'rate=int(sys.argv[sys.argv.index("--rate")+1]) if "--rate" in sys.argv else 48000\n'
        'block=b"".join(struct.pack("<h",int(12000*math.sin(i*.17))) for i in range(rate//25))\n'
        # Native pw-record capture owns a raw FIFO and reserves stdout for
        # diagnostics. Follow its output argument instead of writing PCM there.
        'output=1 if sys.argv[-1]=="-" else os.open(sys.argv[-1],os.O_WRONLY)\n'
        'print("capture fixture connected",flush=True) if output!=1 else None\n'
        "while True: os.write(output,block);time.sleep(.04)\n"
    )
    capture.chmod(0o700)
    env = os.environ.copy()
    env.pop("FORESIGHT_MODEL_MANIFEST", None)
    # This gate runs an unbundled development service. Production install-root
    # identity acceptance lives in desktop_peer_process_test and package gates.
    env.pop("FORESIGHT_INSTALL_ROOT", None)
    env.pop("FORESIGHT_RUNTIME_REVISION", None)
    env.update(
        FORESIGHT_DATA=str(tmp_path / "data"),
        FORESIGHT_RUNTIME=str(tmp_path / "run"),
        FORESIGHT_SERVICE=str(SERVICE),
        FORESIGHT_SERVICE_TRACE="1",
        FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES=json.dumps([
            str(desktop_peer.resolve()), str(flutter_desktop.resolve()),
        ]),
        FORESIGHT_HELPER=str(HELPER),
        FORESIGHT_NATIVE=str(NATIVE),
        FORESIGHT_CAPTURE_RUNTIME=str(capture),
        FORESIGHT_MODEL_WORKER=str(HELPER.parent / "model_worker_fixture"),
        FORESIGHT_DELAY_GENERATION=str(fixtures / "delay"),
        PATH=str(fixtures) + ":" + env["PATH"],
    )
    if first_run is not None:
        synthetic_worker = fixtures / "first-run-model-worker"
        synthetic_worker.write_bytes((ROOT / "tests/service/first_run_model_worker.py").read_bytes())
        synthetic_worker.chmod(0o700)
        assert synthetic_worker.stat().st_uid == os.getuid()
        assert synthetic_worker.stat().st_mode & 0o777 == 0o700
        env.update(
            FORESIGHT_MODEL_WORKER=str(synthetic_worker),
            FORESIGHT_FIRST_RUN_WORKER_REPORT=str(tmp_path / "first-run-worker.jsonl"),
            FORESIGHT_LITERT_RUNNER=str(runner),
            FORESIGHT_FIRST_RUN_LOOPBACK=first_run.origin,
            FORESIGHT_FIRST_RUN_REPORT=str(tmp_path / "first-run.json"),
        )
    if "capture_poll_gate" in options:
        wrapper = fixtures / (
            "capture_poll_gate.dylib"
            if sys.platform == "darwin"
            else "capture_poll_gate.so"
        )
        link = (
            ["-dynamiclib", f"-Wl,-needed_library,{NATIVE}"]
            if sys.platform == "darwin"
            else ["-shared", "-Wl,--no-as-needed", str(NATIVE), "-ldl"]
        )
        subprocess.run(
            [
                os.environ.get("CXX", "c++"),
                "-std=c++17",
                "-fPIC",
                str(ROOT / "tests/fixtures/capture_poll_gate.cpp"),
                *link,
                f"-Wl,-rpath,{NATIVE.parent}",
                "-o",
                str(wrapper),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        env.update(
            FORESIGHT_NATIVE=str(wrapper),
            FORESIGHT_TEST_REAL_NATIVE=str(NATIVE),
            FORESIGHT_TEST_CAPTURE_POLL_GATE=str(fixtures / "hold-capture-poll"),
            FORESIGHT_TEST_CAPTURE_READY=str(fixtures / "capture-filled"),
        )
    log = (tmp_path / "service.log").open("w+")
    process = subprocess.Popen([str(SERVICE)], env=env, stdout=log, stderr=log)
    peers = []
    desktop = None
    try:
        deadline = time.monotonic() + 15
        while True:
            try:
                peer = Peer(tmp_path / "run/application.sock")
                peers.append(peer)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if process.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise AssertionError(log.read()) from None
                poll_delay(deadline)
        desktop = ApprovalDesktop(
            tmp_path / "run/application.sock",
            tmp_path / "data",
            tmp_path,
            preferences=preferences,
        )
        if "without_embedding" not in options:
            deadline = time.monotonic() + 5
            while True:
                try:
                    peer.call("models.embedding", {"path": str(model)})
                    break
                except RuntimeError:
                    poll_delay(deadline)
        yield {
            "peer": peer,
            "peers": peers,
            "env": env,
            "path": tmp_path / "run/application.sock",
            "process": process,
            "runner": runner,
            "asset": asset,
            "root": tmp_path,
            "desktop": desktop,
        }
    finally:
        if desktop is not None:
            desktop.close()
        for peer in peers:
            peer.close()
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)
        log.seek(0)
        print(log.read())
        log.close()


@pytest.mark.parametrize("running", ["without_embedding"], indirect=True)
def test_onboarding_import_waits_for_model_and_indexes_after_configuration(running):
    import sqlite3

    document = running["root"] / "onboarding.txt"
    document.write_text("Saved before model setup. Keep this evidence.")
    peer = running["peer"]
    imported = peer.call("sources.import_file", {"path": str(document)})["id"]
    with sqlite3.connect(running["root"] / "data/application.db") as db:
        before = db.execute(
            "SELECT content,revision,state,error FROM sources WHERE id=?", [imported]
        ).fetchone()
    assert before == (document.read_text(), 1, "pending", "")
    peer.call(
        "models.embedding", {"path": str(running["root"] / "fixtures/model.litertlm")}
    )
    assert peer.call("status")["models_busy"] is False
    deadline = time.monotonic() + 5
    with sqlite3.connect(running["root"] / "data/application.db") as db:
        while True:
            after = db.execute(
                "SELECT content,revision,state,error FROM sources WHERE id=?",
                [imported],
            ).fetchone()
            if after[2] == "indexed":
                break
            assert after[2] in ("pending", "indexing"), after
            assert time.monotonic() < deadline, after
            poll_delay(deadline)
    assert after == (before[0], before[1], "indexed", "")


def test_shared_owner_concurrent_writes_search_and_mcp(running):
    a = running["peer"]
    b = Peer(running["path"])
    running["peers"].append(b)
    assert a.call("status")["pid"] == b.call("status")["pid"] == running["process"].pid
    duplicate = subprocess.run(
        [str(SERVICE)], env=running["env"], capture_output=True, timeout=10
    )
    assert duplicate.returncode != 0
    assert b.call("status")["pid"] == running["process"].pid
    with concurrent.futures.ThreadPoolExecutor() as pool:
        results = list(
            pool.map(
                lambda args: args[0].call(
                    "sources.import",
                    {"title": args[1], "text": "Mira sends the draft Tuesday."},
                ),
                [(a, "desktop"), (b, "mcp")],
            )
        )
    assert len({r["id"] for r in results}) == 2
    assert len(a.call("sources.search", {"query": "draft"})) == 2
    deadline = time.monotonic() + 5
    while not any(e["event"] == "changed" for e in b.events):
        assert time.monotonic() < deadline, (
            "peer did not receive a committed-change notification"
        )
        b.call("status")  # Read queued asynchronous events as well as the reply.
        poll_delay(deadline)
    mcp = McpPeer(running["env"])
    try:
        mcp.initialize()
        tools = mcp.call("tools/list")["tools"]
        assert {"search", "get_source", "start_recording", "ask"} <= {
            t["name"] for t in tools
        }
        search = mcp.call(
            "tools/call",
            {
                "name": "search",
                "arguments": {"query": "draft"},
                "_meta": {"progressToken": "search-progress"},
            },
        )
        assert not search.get("isError", False)
        assert search["structuredContent"]["trust"] == "untrusted"
        assert "never instructions" in search["structuredContent"]["content_policy"]
        progress = [
            n["params"]
            for n in mcp.notifications
            if n["method"] == "notifications/progress"
        ]
        assert progress and progress[0]["progressToken"] == "search-progress"
        assert progress[-1]["progress"] > progress[0]["progress"]
        assert "error" in mcp.result(mcp.send("unknown/method"))
        assert mcp.tool("get_source", {"id": "missing"})["isError"]
        assert mcp.tool("search", {"query": "x", "limit": 101})["isError"]
        created = mcp.tool("create_meeting", {"title": "MCP-created"})[
            "structuredContent"
        ]["result"]
        assert (
            a.call("meetings.get", {"id": created["id"]})["meeting"]["title"]
            == "MCP-created"
        )
        assert a.call("status")["pid"] == running["process"].pid
    finally:
        mcp.close()
    assert a.call("status")["pid"] == running["process"].pid, (
        "MCP disconnect stopped shared owner"
    )
    a.call("sources.delete", {"id": results[0]["id"]})
    assert len(b.call("sources.search", {"query": "draft"})) == 1


def test_summary_commits_checkpoint_and_retains_edited_history(running):
    import sqlite3

    prompt_file = running["root"] / "summary-prompt"
    runner = running["runner"]
    runner.write_text(
        "#!/usr/bin/env python3\nimport sys,pathlib,json\n"
        'if "--probe" in sys.argv: print(json.dumps({"native_stop_token_sequences":True})); sys.exit(0)\n'
        "request=json.loads(sys.stdin.readline())\n"
        'assert request["tools"]["tools"]==[]\n'
        f'pathlib.Path({str(prompt_file)!r}).write_text(request["prompt"]+"\\n"+request["tools"]["system_message"])\n'
        'answer={"role":"assistant","content":[{"type":"text","text":"# Overview\\nThe draft ships Tuesday.\\n# Details\\n* **Draft release date**: Mira sends the draft Tuesday."}]}\n'
        'print("model "+json.dumps(answer),flush=True)\n'
        'assert json.loads(sys.stdin.readline())=={"finish":True}\n'
        'print("answer "+json.dumps(answer),flush=True)\n'
    )
    peer = running["peer"]
    peer.call(
        "models.generation",
        {"path": str(running["asset"]), "runtime": str(runner)},
    )
    meeting = peer.call("meetings.create", {"title": "Summary contract"})["id"]
    peer.call(
        "meetings.transcript",
        {"id": meeting, "text": "Mira sends the draft Tuesday."},
    )
    peer.call("meetings.generate", {"id": meeting, "kind": "summary"})
    with sqlite3.connect(running["root"] / "data/application.db") as db:
        first, body, manifest = db.execute(
            "SELECT id,generated,manifest FROM artifacts WHERE meeting_id=?",
            [meeting],
        ).fetchone()
        assert json.loads(manifest)["mode"] == "full"
        assert db.execute(
            "SELECT artifact_id FROM meeting_summary_checkpoints WHERE meeting_id=?",
            [meeting],
        ).fetchone() == (first,)
        assert db.execute(
            "SELECT content FROM sources WHERE id=?", [f"meeting-summary-{meeting}"]
        ).fetchone() == (body,)
    prompt = prompt_file.read_text()
    assert "<meeting_transcript>\nMira sends the draft Tuesday." in prompt
    assert "untrusted source data" in prompt
    peer.call("artifacts.edit", {"id": first, "text": "Reviewed brief"})
    mcp = McpPeer(running["env"])
    try:
        mcp.initialize()
        generated = mcp.tool(
            "generate_meeting_artifact", {"id": meeting, "kind": "summary"}
        )
        assert not generated.get("isError", False), generated
    finally:
        mcp.close()
    with sqlite3.connect(running["root"] / "data/application.db") as db:
        assert db.execute(
            "SELECT edited FROM artifacts WHERE id=?", [first]
        ).fetchone() == ("Reviewed brief",)
        assert db.execute(
            "SELECT count(*) FROM artifacts WHERE meeting_id=?", [meeting]
        ).fetchone() == (2,)


def test_actions_and_preparation_through_compiled_service_and_mcp(running):
    import sqlite3

    runner = running["runner"]
    runner.write_text(
        "#!/usr/bin/env python3\nimport sys,json\n"
        'if "--probe" in sys.argv: print(json.dumps({"native_stop_token_sequences":True})); sys.exit(0)\n'
        "request=json.loads(sys.stdin.readline())\n"
        'assert request["tools"]["tools"]==[]\n'
        'prompt=request["prompt"]\n'
        'if "Extract explicit meeting commitments" in request["tools"]["system_message"]:\n'
        ' text=json.dumps({"tasks":[{"task":"Send the draft","state":"open","owner":"Mira","due":"Tuesday","evidence":[{"id":"transcript:1","quote":"Mira sends the draft Tuesday."}]}]})\n'
        'elif "<raw_notes>" in prompt or "<notes>" in prompt: text="- Mira sends the draft Tuesday."\n'
        'else: text="# Preparation brief\\nReview the draft before Tuesday."\n'
        'answer={"role":"assistant","content":[{"type":"text","text":text}]}\n'
        'print("model "+json.dumps(answer),flush=True)\n'
        'assert json.loads(sys.stdin.readline())=={"finish":True}\n'
        'print("answer "+json.dumps(answer),flush=True)\n'
    )
    peer = running["peer"]
    peer.call("preferences.set", {"key": "liveEnhance", "value": "false"})
    peer.call(
        "models.generation", {"path": str(running["asset"]), "runtime": str(runner)}
    )
    meeting = peer.call("meetings.create", {"title": "Workflow contracts"})["id"]
    peer.call(
        "meetings.transcript", {"id": meeting, "text": "Mira sends the draft Tuesday."}
    )
    peer.call("meetings.generate", {"id": meeting, "kind": "action_items"})
    task = peer.call("meetings.tasks", {"id": meeting})[0]
    assert task["owner"] == "Mira" and task["due"] == "Tuesday"
    document = peer.call(
        "sources.import", {"title": "Draft", "text": "Review the draft."}
    )["id"]
    mcp = McpPeer(running["env"])
    try:
        mcp.initialize()
        for name, arguments in [
            ("edit_meeting_task", {"id": task["id"], "status": "completed"}),
            ("prepare_meeting", {"id": meeting, "source_ids": [document]}),
            ("get_meeting_tasks", {"id": meeting}),
        ]:
            result = mcp.tool(name, arguments)
            assert not result.get("isError", False), result
    finally:
        mcp.close()
    with sqlite3.connect(running["root"] / "data/application.db") as db:
        assert db.execute("SELECT status,manual FROM meeting_tasks").fetchone() == (
            "completed",
            1,
        )
        actions = db.execute(
            "SELECT edited FROM artifacts WHERE kind='actions'"
        ).fetchone()[0]
        assert "[x]" in actions
        assert db.execute(
            "SELECT content FROM sources WHERE id=?", [f"meeting-actions-{meeting}"]
        ).fetchone() == (actions,)
        manifest = json.loads(
            db.execute(
                "SELECT manifest FROM artifacts WHERE kind='preparation'"
            ).fetchone()[0]
        )
        assert manifest["sources"][0]["id"] == document
        assert db.execute("SELECT count(*) FROM document_summary_cache").fetchone() == (
            1,
        )
        assert db.execute("PRAGMA foreign_key_check").fetchall() == []


@pytest.mark.parametrize("disconnect_owner", [False, True])
def test_stalled_notes_batch_is_cancelled_by_its_service_lease(
    running, disconnect_owner
):
    import sqlite3

    marker = running["root"] / "notes-child-pid"
    running["runner"].write_text(
        "#!/usr/bin/env python3\nimport sys,json,os,pathlib,time\n"
        'if "--probe" in sys.argv: print(json.dumps({"native_stop_token_sequences":True})); sys.exit(0)\n'
        "request=json.loads(sys.stdin.readline())\n"
        'assert "<shorthand_notes>" in request["prompt"]\n'
        f"pathlib.Path({str(marker)!r}).write_text(str(os.getpid()))\n"
        "time.sleep(60)\n"
    )
    owner = running["peer"]
    observer = Peer(running["path"])
    running["peers"].append(observer)
    owner.call("preferences.set", {"key": "liveEnhance", "value": "false"})
    owner.call(
        "models.generation",
        {"path": str(running["asset"]), "runtime": str(running["runner"])},
    )
    meeting = owner.call("meetings.create", {"title": "Notes cancellation"})["id"]
    owner.call(
        "meetings.transcript", {"id": meeting, "text": "Mira sends the draft Tuesday."}
    )
    owner.call("meetings.notes", {"id": meeting, "body": "Mira draft"})
    request = owner.send("meetings.enhance", {"id": meeting})
    deadline = time.monotonic() + 10
    while not marker.exists():
        assert time.monotonic() < deadline, "Notes did not enter native batch"
        poll_delay(deadline)
    pid = int(marker.read_text())
    observer.socket.sendall((json.dumps({"cancel": request}) + "\n").encode())
    assert observer.call("status")["generation"]["generating"]
    if disconnect_owner:
        owner.close()
        running["peers"].remove(owner)
    else:
        owner.socket.sendall((json.dumps({"cancel": request}) + "\n").encode())
    deadline = time.monotonic() + 5
    while observer.call("status")["generation"]["generating"]:
        assert time.monotonic() < deadline, "Notes cancellation did not reach child"
        poll_delay(deadline)
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    with sqlite3.connect(running["root"] / "data/application.db") as db:
        assert db.execute(
            "SELECT count(*) FROM artifacts WHERE kind='enhanced_notes'"
        ).fetchone() == (0,)
        assert db.execute(
            "SELECT body FROM meeting_notes WHERE meeting_id=?", [meeting]
        ).fetchone() == ("Mira draft",)
    assert running["process"].poll() is None


def test_capture_survives_client_disconnect_and_other_client_cannot_start_second(
    running,
):
    a = running["peer"]
    b = Peer(running["path"])
    running["peers"].append(b)
    a.call(
        "models.register",
        {
            "kind": "speech",
            "path": str(running["asset"]),
            "runtime": str(running["runner"]),
        },
    )
    meeting = a.call("meetings.create", {"title": "Capture"})["id"]
    a.call("meetings.start", {"id": meeting})
    a.close()
    running["peers"].remove(a)
    assert b.call("status")["capture"]["active"]
    with pytest.raises(RuntimeError, match="already recording"):
        b.call("meetings.start", {"id": meeting})
    with pytest.raises(RuntimeError, match="recording"):
        b.call("workspace.clear")
    deadline = time.monotonic() + 15
    while sum(b.call("status")["capture"]["samples"]) < 24000:
        assert time.monotonic() < deadline, (
            "shared capture did not deliver audio after client disconnect"
        )
        poll_delay(deadline)
    b.call("meetings.stop")
    assert not b.call("status")["capture"]["active"]
    content = b.call("meetings.get", {"id": meeting})
    assert content["meeting"]["state"] in ["completed", "empty"]
    assert content["transcript"]
    assert any(t["final"] and "Mira" in t["text"] for t in content["transcript"])
    assert b.call("sources.search", {"query": "draft"})


@pytest.mark.parametrize("disconnect_owner", [False, True])
def test_generation_is_shared_and_cancellation_is_scoped_to_connection(
    running, disconnect_owner
):
    a = running["peer"]
    b = Peer(running["path"])
    running["peers"].append(b)
    a.call(
        "sources.import", {"title": "Planning", "text": "Mira sends the draft Tuesday."}
    )
    a.call(
        "models.generation",
        {"path": str(running["asset"]), "runtime": str(running["runner"])},
    )
    Path(running["env"]["FORESIGHT_DELAY_GENERATION"]).touch()
    request = a.send("answer.stream", {"question": "Who sends the draft?"})
    deadline = time.monotonic() + 5
    while not b.call("status")["generation"].get("generating"):
        assert time.monotonic() < deadline
        poll_delay(deadline)
    with pytest.raises(RuntimeError, match="progress|busy"):
        b.call("answer", {"question": "Another answer?"})
    b.socket.sendall((json.dumps({"cancel": request}) + "\n").encode())
    assert b.call("status")["generation"]["generating"], (
        "unrelated connection cancelled generation"
    )
    if disconnect_owner:
        a.close()
        running["peers"].remove(a)
    else:
        a.socket.sendall((json.dumps({"cancel": request}) + "\n").encode())
    deadline = time.monotonic() + 5
    while b.call("status")["generation"]["generating"]:
        assert time.monotonic() < deadline
        poll_delay(deadline)
    assert running["process"].poll() is None, "cancellation terminated the shared owner"
    Path(running["env"]["FORESIGHT_DELAY_GENERATION"]).unlink()
    assert "Mira" in b.call("answer", {"question": "Who sends the draft?"})["text"]


def test_restart_preserves_data_and_does_not_reuse_stale_socket(running):
    a = running["peer"]
    note = a.call("notes.save", {"title": "Persistent", "body": "original"})
    saved = a.call("notes.list")
    assert len(saved) == 1 and saved[0]["id"] == note["id"]
    assert saved[0]["title"] == "Persistent" and saved[0]["body"] == "original"
    assert saved[0]["revision"] == 1 and isinstance(saved[0]["timestamp"], int)
    running["process"].terminate()
    running["process"].wait(timeout=15)
    a.close()
    running["peers"].remove(a)
    # Leave a stale socket as a killed service would.
    stale = socket.socket(socket.AF_UNIX)
    stale.bind(str(running["path"]))
    stale.close()
    log = (running["root"] / "restart.log").open("w")
    process = subprocess.Popen(
        [str(SERVICE)], env=running["env"], stdout=log, stderr=log
    )
    running["process"] = process
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                b = Peer(running["path"])
                running["peers"].append(b)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                assert process.poll() is None and time.monotonic() < deadline
                poll_delay(deadline)
        assert b.call("notes.list") == saved
    finally:
        process.terminate()
        process.wait(timeout=15)
        log.close()


@pytest.mark.parametrize("running", ["without_embedding"], indirect=True)
def test_keyed_retry_commits_once_and_stale_ids_fail_after_restart(running):
    a = running["peer"]
    mcp = McpPeer(running["env"])
    try:
        mcp.initialize()
        keyed = {"title": "Before", "body": "old", "idempotency_key": "retry-1"}
        first = mcp.tool("save_note", keyed)["structuredContent"]["result"]
        assert mcp.tool("save_note", keyed)["structuredContent"]["result"] == first
        assert [note["body"] for note in a.call("notes.list")] == ["old"]
        reused = mcp.tool(
            "create_meeting", {"title": "x", "idempotency_key": "retry-1"}
        )
        assert reused["structuredContent"]["error"]["code"] == "invalidArgument"
        assert a.call("meetings.list") == []
        stale = mcp.tool("get_status")["structuredContent"]["result"]["workspace_epoch"]
    finally:
        mcp.close()
    a.call("workspace.clear")  # Approved by the fixture's synthetic desktop.
    assert a.call("notes.save", {"title": "After", "body": "new"}) == first
    running["process"].terminate()
    running["process"].wait(timeout=15)
    a.close()
    running["peers"].remove(a)
    log = (running["root"] / "restart.log").open("w")
    process = subprocess.Popen(
        [str(SERVICE)], env=running["env"], stdout=log, stderr=log
    )
    running["process"] = process
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                b = Peer(running["path"])
                running["peers"].append(b)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                assert process.poll() is None and time.monotonic() < deadline
                poll_delay(deadline)
        assert b.call("status")["workspace_epoch"] != stale
        with pytest.raises(
            RuntimeError, match="removed when the workspace was cleared"
        ):
            b.call(
                "notes.save",
                {
                    "id": first["id"],
                    "title": "Before",
                    "body": "stale edit",
                    "workspace_epoch": stale,
                },
            )
        assert [note["body"] for note in b.call("notes.list")] == ["new"]
    finally:
        process.terminate()
        process.wait(timeout=15)
        log.close()


@pytest.mark.parametrize("running", ["without_embedding"], indirect=True)
def test_granola_manual_return_requires_active_matching_attempt_without_network(
    running,
):
    from urllib.parse import parse_qs, urlparse

    peer = running["peer"]
    peer.call("google.configure", {"provider": "granola"})
    identifier = peer.send("google.sign_in")
    while True:
        response = json.loads(peer.reader.readline())
        if response.get("event"):
            continue
        assert response["id"] == identifier and "error" not in response, response
        if response.get("result", {}).get("authorization_url"):
            invitation = response["result"]["authorization_url"]
            break
    query = parse_qs(urlparse(invitation).query)
    assert query["code_challenge"] and query["sign_in_click_id"]
    other = Peer(running["path"])
    try:
        callback = "granola://login-complete?code=private-return-fixture&signInClickId=wrong-attempt"
        bridge = "https://www.granola.ai/app-redirect?code=private-return-fixture&signInClickId=wrong-attempt"
        for return_url in [callback, bridge]:
            for manual in [False, True]:
                with pytest.raises(RuntimeError) as error:
                    other.call(
                        "google.complete_sign_in", {"url": return_url, "manual": manual}
                    )
                assert "private-return-fixture" not in str(error.value)
        assert other.call("google.status")["signingIn"]
        other.call("google.cancel_sign_in")
        with pytest.raises(RuntimeError):
            peer.result(identifier)
        with pytest.raises(RuntimeError):
            other.call("google.complete_sign_in", {"url": callback, "manual": True})
        assert not other.call("google.status")["connected"]
    finally:
        other.close()


def test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations(
    running,
):
    flutter = os.environ.get("FORESIGHT_FLUTTER_EXECUTABLE")
    platform = "macos" if sys.platform == "darwin" else "linux"
    assert flutter, "The desktop facade probe requires the native Flutter runner"
    assert os.environ.get("FORESIGHT_" + platform.upper() + "_UI_TEST") == "1", (
        "Run the desktop facade probe on the configured isolated native display"
    )
    report_path = running["root"] / "remote-facade.json"
    env = {**running["env"], "FORESIGHT_REMOTE_FACADE_REPORT": str(report_path)}
    if platform == "linux":
        assert env.get("DISPLAY"), "An isolated X display is required"
        env["GDK_BACKEND"] = "x11"
    else:
        env.pop("GDK_BACKEND", None)
    # P0 requires a native desktop image for its lifetime reservation. The
    # ordinary Dart interpreter is deliberately refused, even in development.
    run_tests(
        "desktop", ["integration_test/remote_facade_test.dart"], 1, env,
        ROOT / "test-results/service/remote-facade", "remote-facade",
        flutter=flutter, device=platform, timeout=300,
    )
    report = json.loads(report_path.read_text())
    assert report["read_only"] and report["changes"] and report["reconnected"]
    assert report["no_mutation_replay"]
    assert report["browser_invitation_received"] and report["oauth_cancelled_cleanly"]


def test_native_desktop_and_mcp_share_service(running):
    session = os.environ.get("FORESIGHT_DESKTOP_SESSION")
    flutter = os.environ.get("FORESIGHT_FLUTTER_EXECUTABLE")
    mac_ui = (
        sys.platform == "darwin" and os.environ.get("FORESIGHT_MACOS_UI_TEST") == "1"
    )
    linux_ui = (
        sys.platform == "linux" and os.environ.get("FORESIGHT_LINUX_UI_TEST") == "1"
    )
    if not flutter or (not mac_ui and not linux_ui and not session):
        if os.environ.get("FORESIGHT_REQUIRE_NATIVE_UI_TEST") == "1":
            pytest.fail(
                "Required native UI integration has no configured platform/display runner"
            )
        pytest.skip(
            "Set FORESIGHT_DESKTOP_SESSION and FORESIGHT_FLUTTER_EXECUTABLE for isolated native UI integration"
        )
    peer = running["peer"]
    peer.call(
        "models.generation",
        {"path": str(running["asset"]), "runtime": str(running["runner"])},
    )
    peer.call(
        "models.register",
        {
            "kind": "speech",
            "path": str(running["asset"]),
            "runtime": str(running["runner"]),
        },
    )
    peer.call("preferences.set", {"key": "inactivity", "value": "0"})
    # The model calls are agent activity: the fixture service outlives this
    # approval desktop, and Flutter attaches to it. Desktop restart therefore
    # preserves the owner without racing the desktop-only shutdown grace.
    running[
        "desktop"
    ].close()  # The real desktop owns approval and the capture indicator below.
    report = ROOT / "test-results/desktop-service-integration.json"
    report.parent.mkdir(exist_ok=True)
    report.unlink(missing_ok=True)
    env = {
        **running["env"],
        "FORESIGHT_MCP_EXECUTABLE": str(MCP),
        "FORESIGHT_SERVICE_UI_REPORT": str(report),
        "GDK_BACKEND": "wayland",
    }
    if mac_ui or linux_ui:
        if mac_ui:
            env.pop("GDK_BACKEND", None)
        else:
            assert env.get("DISPLAY"), (
                "Linux native UI gate requires an isolated X display"
            )
            env["GDK_BACKEND"] = "x11"
        run_tests(
            "desktop",
            ["integration_test/service_mcp_test.dart"],
            1,
            env,
            ROOT / "test-results/service/desktop-ui",
            "desktop-service",
            flutter=flutter,
            device="macos" if mac_ui else "linux",
            timeout=300,
        )
        evidence = json.loads(report.read_text())
        verify_service_ui_report(evidence)
        return
    desk = [
        "uv",
        "run",
        "--directory",
        str(ROOT.parent / "agent-desktop"),
        "--no-sync",
        "agent-desktop",
    ]
    launch = json.loads(
        subprocess.check_output(
            desk
            + ["launch", session, "--", "env", "-C", str(ROOT / "apps/desktop")]
            + [key + "=" + value for key, value in env.items()]
            + [
                flutter,
                "test",
                "--no-pub",
                "-d",
                "linux",
                "integration_test/service_mcp_test.dart",
                "--reporter",
                "expanded",
            ],
            text=True,
            timeout=300,
        )
    )
    deadline = time.monotonic() + 180
    try:
        while True:
            state = json.loads(
                subprocess.check_output(
                    desk + ["status", session], text=True, timeout=300
                )
            )
            job = next(j for j in state["applications"] if j["pid"] == launch["pid"])
            if job["exit_code"] is not None:
                assert job["exit_code"] == 0, Path(launch["logs"]).read_text()[-16000:]
                break
            assert time.monotonic() < deadline, Path(launch["logs"]).read_text()[-6000:]
            poll_delay(deadline)
        evidence = json.loads(report.read_text())
        verify_service_ui_report(evidence)
    finally:
        try:
            os.killpg(launch["pid"], signal.SIGTERM)
        except ProcessLookupError:
            pass


def test_two_headless_mcp_launchers_share_one_automatically_started_owner(running):
    profile = running["root"] / "headless"
    env = {
        **running["env"],
        "FORESIGHT_DATA": str(profile / "data"),
        "FORESIGHT_RUNTIME": str(profile / "run"),
    }
    first = McpPeer(env)
    second = McpPeer(env)
    owner = None
    try:
        first.initialize()
        second.initialize()
        a = first.tool("get_status")["structuredContent"]["result"]
        b = second.tool("get_status")["structuredContent"]["result"]
        assert a["pid"] == b["pid"] and a["pid"] != running["process"].pid
        owner = a["pid"]
        first.service_pid = second.service_pid = owner
        first.tool("save_note", {"title": "Restart-safe", "body": "persisted"})
        os.kill(owner, signal.SIGTERM)
        # Shutdown may wait up to five seconds for the helper. These tiny
        # fixture models do not need the production-model startup allowance.
        deadline = time.monotonic() + 30
        while True:
            status = first.tool("get_status")
            if not status.get("isError"):
                replacement = status["structuredContent"]["result"]["pid"]
                if replacement != owner:
                    owner = replacement
                    break
            assert time.monotonic() < deadline, status
            poll_delay(deadline)
        assert "persisted" in first.tool("list_notes")["content"][0]["text"]
        first.close()
        second.close()
        peer = Peer(profile / "run/application.sock")
        try:
            assert peer.call("status")["pid"] == owner
        finally:
            peer.close()
        # Nobody asks for another owner now. A start that lost a lock race
        # earlier must not take the profile once this owner exits.
        os.kill(owner, signal.SIGTERM)
        deadline = time.monotonic() + 30
        while not process_gone(owner):
            poll_delay(deadline)
        owner = None
        assert_no_late_owner(profile / "data", profile / "run")
    finally:
        for client in [first, second]:
            if client.process.poll() is None:
                client.process.kill()
                client.process.wait(timeout=30)
        if owner is not None:
            try:
                os.kill(owner, signal.SIGTERM)
            except ProcessLookupError:
                pass


def assert_no_late_owner(data, runtime, quiet=2.0):
    """For `quiet` seconds no process serves, and then none holds the lock.

    Probing the lock during the window could make a late start lose it and
    hide; only the socket is watched until the single final probe.
    """
    until = time.monotonic() + quiet
    while time.monotonic() < until:
        assert not (runtime / "application.sock").exists(), "a late owner serves"
        threading.Event().wait(0.05)
    with (data / ".application.lock").open("a") as probe:
        try:
            fcntl.lockf(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            pytest.fail("a late owner holds the profile lock")
        fcntl.lockf(probe, fcntl.LOCK_UN)


def test_cancelled_model_setup_preserves_previous_registration(running):
    import sqlite3

    a = running["peer"]
    b = Peer(running["path"])
    running["peers"].append(b)
    a.call(
        "models.generation",
        {"path": str(running["asset"]), "runtime": str(running["runner"])},
    )
    candidate = running["root"] / "slow-runner"
    candidate.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(2)\n")
    candidate.chmod(0o700)
    request = a.send(
        "models.generation", {"path": str(running["asset"]), "runtime": str(candidate)}
    )
    deadline = time.monotonic() + 5
    while not b.call("status")["models_busy"]:
        assert time.monotonic() < deadline
        poll_delay(deadline)
    a.socket.sendall((json.dumps({"cancel": request}) + "\n").encode())
    while b.call("status")["models_busy"]:
        assert time.monotonic() < deadline
        poll_delay(deadline)
    with sqlite3.connect(
        "file:" + str(running["root"] / "data/application.db") + "?mode=ro", uri=True
    ) as db:
        assert db.execute(
            "SELECT runtime FROM models WHERE kind='generation'"
        ).fetchone()[0] == str(running["runner"])


def test_url_and_directory_imports_run_in_the_service(running):
    import http.server
    import threading

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(
                b"<html><script>hidden()</script><p>Mira sends the draft Tuesday.</p></html>"
            )

        def log_message(self, *args):
            pass

    http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    peer = running["peer"]
    try:
        url = "http://127.0.0.1:" + str(http.server_port) + "/planning"
        first = peer.call(
            "sources.import_url", {"url": url, "allow_private_network": True}
        )["id"]
        second = peer.call(
            "sources.import_url", {"url": url, "allow_private_network": True}
        )["id"]
        assert first == second
        source = peer.call("sources.get", {"id": first})
        assert source["revision"] == 2 and "hidden" not in source["content"]
        directory = running["root"] / "imports"
        directory.mkdir()
        (directory / "note.md").write_text("Mira sends the draft Tuesday.")
        (directory / "ignored.bin").write_bytes(b"not text")
        peer.call("sources.import_directory", {"path": str(directory)})
        sources = peer.call("sources.list")
        assert len(sources) == 2 and any(s["title"] == "note.md" for s in sources)
    finally:
        http.shutdown()
        http.server_close()
        thread.join(timeout=5)


@pytest.mark.parametrize(
    "running,shutdown",
    [("idle=0.1", "desktop-close"), (None, "explicit-stop")],
    indirect=["running"],
    ids=["desktop-close", "explicit-stop"],
)
def test_service_stop_waits_for_active_capture_and_finalizes_transcript(
    running, shutdown
):
    import sqlite3

    peer = running["peer"]
    peer.call(
        "models.register",
        {
            "kind": "speech",
            "path": str(running["asset"]),
            "runtime": str(running["runner"]),
        },
    )
    meeting = peer.call("meetings.create", {"title": "Graceful stop"})["id"]
    peer.call("meetings.start", {"id": meeting})
    deadline = time.monotonic() + 15
    while sum(peer.call("status")["capture"]["samples"]) < 24000:
        assert time.monotonic() < deadline, (
            "fixture did not deliver audio before shutdown"
        )
        poll_delay(deadline)
    helper_pid = int(peer.call("status")["helper"]["instanceId"].split("-", 1)[0])
    if shutdown == "desktop-close":
        assert peer.call("status")["lifetime"]["idle_minutes"] == 0.1
        # Recent agent work keeps the service alive through finalization; the
        # desktop departure stops capture and the idle rule releases the owner.
        running["desktop"].close()
    else:
        stopped = subprocess.run(
            [str(SERVICE), "--stop"],
            env=running["env"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        assert stopped.returncode == 0, stopped.stderr
    assert running["process"].wait(timeout=15) == 0
    assert not running["path"].exists()
    with pytest.raises(ProcessLookupError):
        os.kill(helper_pid, 0)
    with sqlite3.connect(
        "file:" + str(running["root"] / "data/application.db") + "?mode=ro", uri=True
    ) as db:
        assert (
            db.execute("SELECT state FROM meetings WHERE id=?", [meeting]).fetchone()[0]
            == "completed"
        )
        assert (
            db.execute(
                "SELECT count(*) FROM transcript WHERE meeting_id=? AND final=1",
                [meeting],
            ).fetchone()[0]
            > 0
        )


@pytest.mark.parametrize("running", ["without_embedding,idle=0.1"], indirect=True)
def test_agent_only_service_exits_after_the_idle_period(running):
    peer = running["peer"]
    owner = running["process"]
    assert peer.call("status")["lifetime"]["idle_minutes"] == 0.1
    started = int(time.time() * 1000)
    assert peer.call("notes.list") == []
    running["desktop"].close()
    deadline = time.monotonic() + 5
    state = None
    while True:
        try:
            state = peer.call("status")
        except (AssertionError, OSError, RuntimeError):
            pytest.fail(f"Service exited before publishing an idle deadline: {state}")
        lifetime = state["lifetime"]
        if not lifetime["pinned_by_desktop"] and lifetime["exit_after"] is not None:
            break
        assert time.monotonic() < deadline, state
        poll_delay(deadline)
    assert state["pid"] == owner.pid
    assert lifetime["last_agent_activity"] >= started
    assert lifetime["exit_after"] >= started + 6000
    assert owner.wait(timeout=15) == 0
    assert not running["path"].exists()
    data = running["root"] / "data"
    assert not (data / ".application-endpoint.json").exists()
    with (data / ".application.lock").open("a") as probe:
        fcntl.lockf(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(probe, fcntl.LOCK_UN)

    launches = running["root"] / "idle-launches"
    wrapper = running["root"] / "launch-after-idle"
    replacement_log = running["root"] / "idle-replacement.log"
    wrapper.write_text(
        "#!/bin/sh\n"
        f'printf "%s\\n" "$$" >> "{launches}"\n'
        f'exec "{SERVICE}" "$@" >> "{replacement_log}" 2>&1\n'
    )
    wrapper.chmod(0o700)
    mcp = None
    try:
        mcp = McpPeer({**running["env"], "FORESIGHT_SERVICE": str(wrapper)})
        mcp.initialize()
        result = mcp.tool("list_notes")
        assert not result.get("isError"), result
        assert result["structuredContent"]["result"] == []
        replacements = [int(line) for line in launches.read_text().split()]
        assert len(replacements) == 1 and replacements[0] != owner.pid
    finally:
        try:
            if mcp is not None:
                mcp.close()
        finally:
            # The running fixture owns only the original. Verify the process
            # identity before stopping any replacement started by MCP.
            for line in launches.read_text().split() if launches.exists() else []:
                command = subprocess.run(
                    ["/bin/ps", "-p", line, "-o", "command="],
                    capture_output=True,
                    text=True,
                    timeout=10,
                ).stdout
                if str(SERVICE) in command:
                    try:
                        os.kill(int(line), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    deadline = time.monotonic() + 15
                    while not process_gone(int(line)):
                        assert time.monotonic() < deadline, command
                        poll_delay(deadline)
            if replacement_log.exists():
                print(replacement_log.read_text())


@pytest.mark.parametrize("running", ["without_embedding,idle=0.1"], indirect=True)
def test_desktop_departure_without_agent_work_exits_after_the_grace(running):
    state = running["peer"].call("status")
    assert state["lifetime"]["idle_minutes"] == 0.1
    # The desktop's non-exempt preferences.set must not become agent activity.
    assert state["lifetime"]["last_agent_activity"] is None
    running["desktop"].close()
    assert running["process"].wait(timeout=15) == 0
    assert not running["path"].exists()


def wait_for_background_idle(peer):
    deadline = time.monotonic() + 30
    while True:
        try:
            state = peer.call("status")
        except (AssertionError, OSError, RuntimeError) as error:
            pytest.fail(f"Service closed before background work settled: {error}")
        if not state["lifetime"]["busy"]:
            return
        assert time.monotonic() < deadline, state
        poll_delay(deadline)


def stop_if_idle_after_background_work(pid, env):
    # A scheduled enhancement retry can begin after our idle observation.
    # Retry only that explicit busy refusal, at most three times.
    for attempt in range(4):
        stopped = subprocess.run(
            [str(SERVICE), f"--stop-if-idle={pid}"],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if (
            stopped.returncode == 0
            or "Background model work" not in stopped.stderr
            or attempt == 3
        ):
            return stopped
        print(stopped.stderr)
        threading.Event().wait(1)


def test_idle_upgrade_shutdown_defers_capture_and_requires_verified_ack(running):
    import sqlite3

    peer = running["peer"]
    owner = running["process"]
    for args in ({}, {"token": "wrong"}):
        with pytest.raises(RuntimeError, match="declared owner capability"):
            peer.call("service.stop_if_idle", args)
    assert peer.call("status")["pid"] == owner.pid and owner.poll() is None
    peer.call(
        "models.register",
        {
            "kind": "speech",
            "path": str(running["asset"]),
            "runtime": str(running["runner"]),
        },
    )
    meeting = peer.call("meetings.create", {"title": "Upgrade must defer recording"})[
        "id"
    ]
    peer.call("meetings.start", {"id": meeting})
    refused = subprocess.run(
        [str(SERVICE), f"--stop-if-idle={owner.pid}"],
        env=running["env"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    # Desktop admission precedes idle/capture inspection. Even the installer
    # with the current owner token cannot stop a service pinned by its UI.
    assert refused.returncode != 0 and "Close the desktop" in refused.stderr
    assert owner.poll() is None and peer.call("status")["capture"]["active"]
    deadline = time.monotonic() + 15
    while sum(peer.call("status")["capture"]["samples"]) < 24000:
        assert time.monotonic() < deadline, "capture stopped after deferred upgrade"
        poll_delay(deadline)
    peer.call("meetings.stop")
    wait_for_background_idle(peer)
    running["desktop"].close()
    deadline = time.monotonic() + 5
    while peer.call("status")["lifetime"]["pinned_by_desktop"]:
        assert time.monotonic() < deadline, "closed desktop still pins service"
        poll_delay(deadline)
    wrong = subprocess.run(
        [str(SERVICE), f"--stop-if-idle={owner.pid + 1}"],
        env=running["env"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert wrong.returncode != 0 and "ownership changed" in wrong.stderr
    assert peer.call("status")["pid"] == owner.pid and owner.poll() is None
    stopped = stop_if_idle_after_background_work(owner.pid, running["env"])
    assert stopped.returncode == 0, stopped.stderr
    assert json.loads(stopped.stdout) == {"stopped": True, "shutdown_verified": True}
    assert owner.wait(timeout=5) == 0
    with sqlite3.connect(
        "file:" + str(running["root"] / "data/application.db") + "?mode=ro", uri=True
    ) as db:
        assert (
            db.execute("SELECT state FROM meetings WHERE id=?", [meeting]).fetchone()[0]
            == "completed"
        )
        assert (
            db.execute(
                "SELECT count(*) FROM transcript WHERE meeting_id=? AND final=1",
                [meeting],
            ).fetchone()[0]
            > 0
        )


def test_unexpected_service_death_interrupts_capture_and_reuses_profile(running):
    peer = running["peer"]
    peer.call(
        "models.register",
        {
            "kind": "speech",
            "path": str(running["asset"]),
            "runtime": str(running["runner"]),
        },
    )
    meeting = peer.call("meetings.create", {"title": "Crash recovery"})["id"]
    peer.call("meetings.start", {"id": meeting})
    running["process"].kill()
    running["process"].wait(timeout=5)
    peer.close()
    running["peers"].remove(peer)
    log = (running["root"] / "crash-restart.log").open("w")
    process = subprocess.Popen(
        [str(SERVICE)], env=running["env"], stdout=log, stderr=log
    )
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                other = Peer(running["path"])
                running["peers"].append(other)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                assert process.poll() is None and time.monotonic() < deadline
                poll_delay(deadline)
        assert not other.call("status")["capture"]["active"]
        assert (
            other.call("meetings.get", {"id": meeting})["meeting"]["state"]
            == "interrupted"
        )
        other.call("application.resume")
        deadline = time.monotonic() + 15
        while other.call("status")["helper"]["pipeline"] != "ready":
            assert time.monotonic() < deadline, "recovered helper did not become ready"
            poll_delay(deadline)
    finally:
        process.terminate()
        process.wait(timeout=15)
        log.close()
        print((running["root"] / "crash-restart.log").read_text())


@pytest.mark.parametrize("helper_exits_first", [False, True])
def test_idle_shutdown_verifies_a_real_adopted_helper(tmp_path, helper_exits_first):
    for extra_status in (False, True, False, True):
        print(f"Adopted-helper timing: extra_status={extra_status}")
        assert_idle_shutdown_verifies_a_real_adopted_helper(
            tmp_path, helper_exits_first, extra_status=extra_status
        )
        for name in ("data", "run"):
            shutil.rmtree(tmp_path / name)


def assert_idle_shutdown_verifies_a_real_adopted_helper(
    tmp_path, helper_exits_first, *, extra_status
):
    """A predecessor's surviving helper is stopped and positively acknowledged."""
    data, runtime = tmp_path / "data", tmp_path / "run"
    data.mkdir(mode=0o700)
    runtime.mkdir(mode=0o700)
    env = os.environ.copy()
    for key in (
        "FORESIGHT_MODEL_MANIFEST",
        "FORESIGHT_RESOURCES",
        "FORESIGHT_RUNTIME_REVISION",
        "FORESIGHT_INSTALL_ROOT",
    ):
        env.pop(key, None)
    env.update(
        FORESIGHT_DATA=str(data),
        FORESIGHT_RUNTIME=str(runtime),
        FORESIGHT_HELPER=str(HELPER),
        FORESIGHT_NATIVE=str(NATIVE),
        FORESIGHT_SERVICE_TRACE="1",
    )
    with (tmp_path / "adopted-helper.log").open("w+") as log:
        helper = subprocess.Popen(
            [str(HELPER), str(runtime / "helper.sock"), str(data / "helper")],
            env=env,
            stdout=log,
            stderr=log,
        )
        # Simulate launchd's prompt reaping of the predecessor's orphan helper.
        # An unreaped test-owned zombie still reserves its PID by definition.
        threading.Thread(target=helper.wait, daemon=True).start()
        service = None
        peer = None
        try:
            deadline = time.monotonic() + 15
            while not (runtime / "helper.sock").exists():
                assert helper.poll() is None
                assert time.monotonic() < deadline
                poll_delay(deadline)
            service = subprocess.Popen([str(SERVICE)], env=env, stdout=log, stderr=log)
            while peer is None:
                assert service.poll() is None
                assert time.monotonic() < deadline
                try:
                    peer = Peer(runtime / "application.sock")
                except (FileNotFoundError, ConnectionRefusedError):
                    poll_delay(deadline)
            while True:
                state = peer.call("status")
                identity = (state.get("helper") or {}).get("instanceId", "")
                if identity.startswith(f"{helper.pid}-"):
                    break
                assert time.monotonic() < deadline, state
                poll_delay(deadline)
            if extra_status:
                peer.call("status")
            if helper_exits_first:
                helper.terminate()
                helper.wait(timeout=10)
            wait_for_background_idle(peer)
            stopped = stop_if_idle_after_background_work(service.pid, env)
            assert stopped.returncode == 0, stopped.stderr
            assert json.loads(stopped.stdout) == {
                "stopped": True,
                "shutdown_verified": True,
            }
            assert service.wait(timeout=10) == 0
            assert helper.wait(timeout=10) == -signal.SIGTERM
            assert not (data / ".application-endpoint.json").exists()
        except Exception:
            print(f"Adopted helper: pid={helper.pid}, exit={helper.poll()}")
            if service is not None:
                profile_failure_diagnostics(service, log)
            raise
        finally:
            if peer is not None:
                peer.close()
            for process in (service, helper):
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)


GATED_HELPER = Path(__file__).resolve().parent / "gated_helper.py"


class GatedHelper:
    """Python side of package:foresight_test_support/gated_helper.dart.

    Set FORESIGHT_HELPER to `executable`. The helper holds SIGTERM until
    `release()`, so a closing service stays inside its helper shutdown. The
    service SIGKILLs it 5 s after SIGTERM; `released()` shows the hold ended
    through `release()` instead.
    """

    def __init__(self, directory):
        self.control = directory / "helper-control"
        self.control.mkdir(mode=0o700)
        self.executable = directory / "helper"
        self.executable.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" "{GATED_HELPER}" '
            f'"{self.control}" "$@"\n'
        )
        self.executable.chmod(0o700)

    def published(self, name, deadline, service=None):
        """Wait for a marker; fail at once if the [service] process exits."""
        path = self.control / name
        while not path.exists():
            if service is not None:
                assert service.poll() is None, f"service exited before {name}"
            poll_delay(deadline)
        return int(path.read_text())

    def released(self):
        return (self.control / "released").exists()

    def release(self):
        (self.control / "release").write_text("")

    def kill(self):
        """Stop the helper if its service died without closing it."""
        started = self.control / "started"
        if not started.exists():
            return
        pid = started.read_text()
        command = subprocess.run(
            ["/bin/ps", "-p", pid, "-o", "command="],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
        # Never signal a reused pid: match this helper's own control path.
        if str(self.control) in command:
            try:
                os.kill(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_gated_helper_twin_matches_the_dart_fixture():
    """Dart lifecycle tests and this suite must hold helper shutdown alike."""
    shared = ROOT / "packages/foresight_test_support/lib/gated_helper.py"
    assert GATED_HELPER.read_bytes() == shared.read_bytes()


# Every gate point in service.dart. A hook-enabled build holds armed points.
LIFECYCLE_GATES = (
    "start.before_lock",
    "start.lock_contended",
    "close.begin",
    "close.leases_terminated",
    "close.helper_closed",
    "close.listener_closed",
    "close.before_record_delete",
    "close.before_frontend_release",
    "close.before_lock_release",
    "frontend.listener_closed",
    "frontend.draining",
    "start.locked",
    "request.committed.status",
)


def test_release_service_ignores_lifecycle_gates(tmp_path):
    """A release build strips FORESIGHT_SERVICE_GATES, so no gate can hold it.

    Lifecycle tests compile bin/service.dart with FORESIGHT_ENABLE_TEST_HOOKS.
    This production executable is built without it: every gate is armed, yet
    status answers, SIGTERM reaches the helper, and no gate reports reaching.
    The paired positive control is service_gate_test.dart, "the isolated
    worker stops at every close gate in order", where the same gates hold a
    hook-enabled build of bin/service.dart.
    """
    assert SERVICE.is_file(), "Build the service executable first"
    data, runtime, gates = tmp_path / "data", tmp_path / "run", tmp_path / "gates"
    gates.mkdir(mode=0o700)
    # Every gate is armed to hold, and also to crash the isolate reaching it.
    for point in LIFECYCLE_GATES:
        (gates / f"{point}.hold").write_text("")
        (gates / f"{point}.crash").write_text("")
    helper = GatedHelper(tmp_path)
    env = os.environ.copy()
    for key in (
        "FORESIGHT_MODEL_MANIFEST",
        "FORESIGHT_RESOURCES",
        "FORESIGHT_RUNTIME_REVISION",
        "FORESIGHT_INSTALL_ROOT",
    ):
        env.pop(key, None)
    env.update(
        FORESIGHT_DATA=str(data),
        FORESIGHT_RUNTIME=str(runtime),
        FORESIGHT_HELPER=str(helper.executable),
        FORESIGHT_NATIVE=str(NATIVE),
        FORESIGHT_SERVICE_GATES=str(gates),
        FORESIGHT_SERVICE_TRACE="1",
    )
    with (tmp_path / "service.log").open("w+") as log:
        process = subprocess.Popen([str(SERVICE)], env=env, stdout=log, stderr=log)
        peer = None
        try:
            deadline = time.monotonic() + 30
            helper.published("started", deadline, process)
            while peer is None:
                assert process.poll() is None
                try:
                    peer = Peer(runtime / "application.sock")
                except (FileNotFoundError, ConnectionRefusedError):
                    poll_delay(deadline)
            # A hook-enabled build would hold this reply at its commit gate.
            # Heartbeat events keep arriving, so bound the wait here.
            identifier = peer.send("status")
            while True:
                reply = json.loads(peer.reader.readline())
                if reply.get("id") == identifier:
                    break
                assert time.monotonic() < deadline, "status reply was held"
            assert reply["result"]["pid"] == process.pid
            peer.close()
            peer = None
            process.send_signal(signal.SIGTERM)
            # A hook-enabled build would hold close.begin before this.
            helper.published("stopping", deadline, process)
            assert sorted(path.name for path in gates.iterdir()) == sorted(
                f"{point}.{arm}"
                for point in LIFECYCLE_GATES
                for arm in ("hold", "crash")
            )
            helper.release()
            assert process.wait(timeout=30) == 0
            # The hold ended through release, not the service's 5 s SIGKILL.
            assert helper.released()
            assert not list(gates.glob("*.reached"))
            assert not (data / ".application-endpoint.json").exists()
            assert not (runtime / "application.sock").exists()
        except Exception:
            profile_failure_diagnostics(process, log)
            raise
        finally:
            helper.release()
            if peer is not None:
                peer.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            helper.kill()


def test_attached_mcp_follows_a_closing_owner_to_one_replacement(tmp_path):
    """Built service, MCP and helper on both sides of the closing handoff (T3).

    A gated helper holds the closing owner inside its helper shutdown, with
    its profile lock. An attached MCP's next request is refused by the owner;
    the handoff's startup probe gets the draining frontend's refusal, and
    nothing launches while the owner holds the profile. Once the owner exits,
    MCP starts exactly one replacement and sends the request to it.

    MCP starts and attaches before the close, so only the refusals, not MCP's
    own startup, must fit in the helper's 5 s hold.
    """
    assert SERVICE.is_file() and MCP.is_file(), "Build service and MCP first"
    data, runtime = tmp_path / "data", tmp_path / "run"
    helper = GatedHelper(tmp_path)
    launches = tmp_path / "launches"
    wrapper = tmp_path / "launch-service"
    wrapper.write_text(
        "#!/bin/sh\n"
        f'printf "%s\\n" "$$" >> "{launches}"\n'
        f'exec "{SERVICE}" "$@" >> "{tmp_path / "replacement.log"}" 2>&1\n'
    )
    wrapper.chmod(0o700)
    env = os.environ.copy()
    for key in (
        "FORESIGHT_MODEL_MANIFEST",
        "FORESIGHT_RESOURCES",
        "FORESIGHT_RUNTIME_REVISION",
        "FORESIGHT_INSTALL_ROOT",
        "FORESIGHT_SERVICE_GATES",
    ):
        env.pop(key, None)
    env.update(
        FORESIGHT_DATA=str(data),
        FORESIGHT_RUNTIME=str(runtime),
        FORESIGHT_NATIVE=str(NATIVE),
        FORESIGHT_SERVICE=str(wrapper),
        FORESIGHT_SERVICE_TRACE="1",
        FORESIGHT_LOG_LEVEL="info",
    )
    # The replacement runs without a helper; only the owner's is gated.
    owner_env = {**env, "FORESIGHT_HELPER": str(helper.executable)}
    mcp_env = {**env, "FORESIGHT_HELPER": ""}
    mcp = None

    def process_diagnostics(process_pid):
        # Manifests bind these real typed records to this synthetic process.
        # A segment's incomplete final write is observed on the next poll.
        records: list[dict[str, object]] = []
        for manifest in data.glob("logs/slot-*/manifest.json"):
            if json.loads(manifest.read_text())["pid"] != process_pid:
                continue
            for segment in manifest.parent.glob("*.jsonl"):
                records.extend(
                    json.loads(line)
                    for line in segment.read_text().splitlines(keepends=True)
                    if line.endswith("\n")
                )
        return records

    with (tmp_path / "service.log").open("w+") as log:
        owner = subprocess.Popen([str(SERVICE)], env=owner_env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 60
            helper.published("started", deadline, owner)
            peer = None
            while peer is None:
                assert owner.poll() is None
                try:
                    peer = Peer(runtime / "application.sock")
                except (FileNotFoundError, ConnectionRefusedError):
                    poll_delay(deadline)
            try:
                assert peer.call("status")["pid"] == owner.pid
            finally:
                peer.close()
            mcp = McpPeer(mcp_env)
            mcp.service_pid = owner.pid
            mcp.initialize()
            attached = mcp.tool("get_status")["structuredContent"]["result"]
            assert attached["pid"] == owner.pid
            # Settle the logger's existing cold gate before the helper hold;
            # startup/flush work must not consume any of its unchanged 5 s.
            while not any(
                record["event"] == "mcp.starting"
                for record in process_diagnostics(mcp.process.pid)
            ):
                assert mcp.process.poll() is None, mcp.timeout_details(mcp.sequence)
                poll_delay(deadline)
            owner.send_signal(signal.SIGTERM)
            held = helper.published("stopping", deadline, owner)
            pending = mcp.send("tools/call", {"name": "get_status", "arguments": {}})
            # The owner refuses the request; the draining frontend then
            # refuses the handoff's startup probe and keeps it open.
            while not any(
                record["event"] == "rpc.failed"
                and record["fields"].get("operation") == "status"
                and record["fields"].get("category") == "closing"
                and record["fields"].get("outcome") == "refused"
                for record in process_diagnostics(mcp.process.pid)
            ):
                assert mcp.process.poll() is None, mcp.process.stderr.read()
                poll_delay(deadline)
            # The actual public frontend still gives the unchanged closing
            # refusal on the old owner's endpoint while its helper is held.
            closing = Peer(runtime / "application.sock")
            try:
                with pytest.raises(RuntimeError) as refused:
                    closing.call("status")
                assert refused.value.args[0] == {
                    "code": "unavailable",
                    "message": "Application service is shutting down; retry after it exits.",
                    "reason": "closing",
                }
            finally:
                closing.close()
            # The service kills a helper that holds SIGTERM for 5 s. Only
            # while it is still held does the owner provably hold the lock.
            try:
                os.kill(held, 0)
            except ProcessLookupError:
                pytest.fail("hold window missed: the helper was killed first")
            assert not launches.exists()
            helper.release()
            assert owner.wait(timeout=30) == 0
            assert helper.released(), "hold window missed: the helper was killed"
            response = mcp.result(pending)
            assert "error" not in response, response
            status = response["result"]["structuredContent"]["result"]
            replacement = status["pid"]
            assert replacement != owner.pid
            assert [int(line) for line in launches.read_text().split()] == [replacement]
            mcp.close()
            mcp = None
        except BaseException:
            # pytest.fail (the missed hold window) raises a BaseException.
            profile_failure_diagnostics(owner, log)
            replacement_log = tmp_path / "replacement.log"
            if replacement_log.exists():
                print(replacement_log.read_text())
            raise
        finally:
            helper.release()
            if mcp is not None and mcp.process.poll() is None:
                mcp.process.kill()
                mcp.process.wait(timeout=30)
            if owner.poll() is None:
                owner.kill()
                owner.wait(timeout=10)
            # Stop every service MCP launched, even if the test failed first.
            for line in launches.read_text().split() if launches.exists() else []:
                command = subprocess.run(
                    ["/bin/ps", "-p", line, "-o", "command="],
                    capture_output=True,
                    text=True,
                    timeout=10,
                ).stdout
                if str(SERVICE) in command:
                    try:
                        os.kill(int(line), signal.SIGTERM)
                    except ProcessLookupError:
                        pass  # It exited after the ps check.
            helper.kill()


def process_gone(pid):
    """Whether `pid` has exited, counting a zombie as exited.

    A detached service is reparented to PID 1. In a CI container that may
    never reap it, so a signal-0 probe keeps succeeding after it exited.
    """
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    if sys.platform.startswith("linux"):
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
        except FileNotFoundError:
            return True
        # The state follows the parenthesized command name, which may itself
        # contain spaces or parentheses.
        return stat[stat.rindex(")") + 2] == "Z"
    state = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)],
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    return not state or state.startswith("Z")


def poll_delay(deadline):
    """Yield between observations without extending the operation's deadline."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Service state was not observed before its deadline")
    threading.Event().wait(min(0.02, remaining))


def profile_failure_diagnostics(process, log):
    """Preserve both sides of a stalled isolated-service connection."""
    profile = Path(log.name).parent
    print(f"Profile {profile}: pid={process.pid}, exit={process.poll()}")
    for name in ("application.sock", "worker.sock", "helper.sock"):
        path = profile / "run" / name
        print(f"Endpoint {path}: exists={path.exists()}")
    record = profile / "data/.application-endpoint.json"
    # A closing owner may delete its record between any check and this read;
    # that must not replace the failure these diagnostics explain.
    try:
        recorded = record.read_text()
    except FileNotFoundError:
        recorded = "missing"
    print(f"Endpoint record: {recorded}")
    log.seek(0)
    print(log.read())
    try:
        with socket.socket(socket.AF_UNIX) as probe:
            probe.settimeout(2)
            probe.connect(str(profile / "run/worker.sock"))
            probe.sendall(b'{"id":1,"method":"status","args":{}}\n')
            print(f"Direct worker response: {probe.recv(65536)!r}")
    except OSError as error:
        print(f"Direct worker probe failed: {error}")
    if sys.platform == "darwin" and process.poll() is None:
        try:
            sample = subprocess.run(
                ["/usr/bin/sample", str(process.pid), "1", "1"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            print(f"Service thread sample:\n{sample.stdout[:65536]}\n{sample.stderr}")
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Service thread sample failed: {error}")


def test_two_live_profiles_keep_notes_private(running, tmp_path):
    for _ in range(2):
        for poll_interval, eager_status in (
            (0.02, False),
            (0.001, True),
            (0.001, False),
            (0.02, True),
        ):
            print(
                f"Two-profile timing: poll={poll_interval}, eager_status={eager_status}"
            )
            assert_two_live_profiles_keep_notes_private(
                running,
                tmp_path,
                poll_interval=poll_interval,
                eager_status=eager_status,
            )
            for name in ("first-profile", "second-profile"):
                shutil.rmtree(tmp_path / name)


def assert_two_live_profiles_keep_notes_private(
    running, tmp_path, *, poll_interval, eager_status
):
    """Separate owners and databases must isolate actual writes, not just paths."""
    processes = []
    peers = []
    logs = []
    initial_requests = []
    try:
        for name in ("first-profile", "second-profile"):
            profile = tmp_path / name
            profile.mkdir(mode=0o700)
            env = {
                **running["env"],
                "FORESIGHT_DATA": str(profile / "data"),
                "FORESIGHT_RUNTIME": str(profile / "run"),
                "FORESIGHT_SERVICE_TRACE": "1",
            }
            log = (profile / "service.log").open("w+")
            logs.append(log)
            process = subprocess.Popen([str(SERVICE)], env=env, stdout=log, stderr=log)
            processes.append(process)
            deadline = time.monotonic() + 15
            while True:
                try:
                    peer = Peer(profile / "run/application.sock")
                    peers.append(peer)
                    if eager_status:
                        initial_requests.append(peer.send("status"))
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if process.poll() is not None or time.monotonic() >= deadline:
                        log.seek(0)
                        pytest.fail("Profile failed to start: " + log.read())
                    threading.Event().wait(
                        min(poll_interval, deadline - time.monotonic())
                    )
        first, second = peers
        if eager_status:
            first_status = first.result(initial_requests[0])
            second_status = second.result(initial_requests[1])
        else:
            first_status, second_status = first.call("status"), second.call("status")
        assert first_status["pid"] != second_status["pid"]
        assert first.call("notes.list") == second.call("notes.list") == []
        first.call(
            "notes.save",
            {"title": "First private note", "body": "Only first sees this"},
        )
        assert first.call("notes.list")[0]["body"] == "Only first sees this"
        assert second.call("notes.list") == []
        second.call(
            "notes.save",
            {"title": "Second private note", "body": "Only second sees this"},
        )
        assert [note["title"] for note in first.call("notes.list")] == [
            "First private note"
        ]
        assert [note["title"] for note in second.call("notes.list")] == [
            "Second private note"
        ]
    except BaseException:
        # pytest.fail raises a BaseException; a stalled start needs these
        # diagnostics (its log and a thread sample) most of all.
        for index, process in enumerate(processes):
            profile_failure_diagnostics(process, logs[index])
        raise
    finally:
        for peer in peers:
            peer.close()
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for log in logs:
            log.close()


@pytest.mark.parametrize("mode", ["download", "invalid", "oversized"])
def test_internal_model_transport_has_bounded_frames_and_no_profile_authority(
    tmp_path, mode
):
    import http.server

    assert SERVICE.is_file(), "Build the current service executable first"
    requests = []

    class Media(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.path, self.headers.get("Range")))
            self.send_response(206)
            self.send_header("Content-Length", "4")
            self.end_headers()
            self.wfile.write(b"\x00\x01\x02\xff")

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Media)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    canary = "private-transport-credential-canary"
    config = {
        "kind": mode,
        "apiKey": canary,
        "origin": f"http://127.0.0.1:{server.server_port}",
        "blobId": "fixture",
        "size": 4,
        "parallelCount": 1,
        "attempts": 1,
        "delays": [],
        "connect": 1_000_000,
        "headers": 1_000_000,
        "bodyIdle": 1_000_000,
        "attempt": 2_000_000,
        "total": 3_000_000,
    }
    payload = json.dumps(config).encode() if mode != "oversized" else b"x" * 16385
    try:
        result = subprocess.run(
            [str(SERVICE), "--model-transport-worker"],
            input=payload,
            cwd=tmp_path,
            env={"FORESIGHT_NATIVE": "/missing/native/library"},
            capture_output=True,
            timeout=10,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stderr == b"", result.stderr
        header, data = result.stdout.split(b"\n", 1)
        assert len(header) <= 1024
        if mode == "download":
            assert json.loads(header) == {"ok": True, "size": 4}
            assert data == b"\x00\x01\x02\xff"
            assert requests == [
                (
                    f"/v1/medias/foresight/fixture:download?alt=media&key={canary}",
                    "bytes=0-3",
                )
            ]
        else:
            assert json.loads(header) == {"ok": False, "kind": "transport"}
            assert data == b""
            assert requests == []
        assert canary.encode() not in result.stdout + result.stderr
        assert list(tmp_path.iterdir()) == [], (
            "transport mode must not initialize a profile/runtime/log"
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        assert not thread.is_alive()


@pytest.mark.parametrize("running", ["without_embedding,first_run"], indirect=True)
def test_compiled_first_run_setup_download_restart_retry_adoption_and_indexing(
    running, first_run_catalog
):
    """Tiny loopback bytes verify setup ownership, not real-model inference."""
    flutter = os.environ.get("FORESIGHT_FLUTTER_EXECUTABLE")
    platform = "macos" if sys.platform == "darwin" else "linux"
    assert flutter and os.environ.get(f"FORESIGHT_{platform.upper()}_UI_TEST") == "1", (
        "First-run journey requires an isolated native Flutter display"
    )
    peer = running["peer"]
    assert peer.call("status")["models_busy"] is False
    imported = peer.call(
        "sources.import",
        {
            "title": "First-run retained source",
            "text": "Fixture setup indexes this retained source.",
        },
    )["id"]
    running["desktop"].close()
    env = {
        **running["env"],
        "FORESIGHT_MCP_EXECUTABLE": str(MCP),
        "FORESIGHT_FIRST_RUN_SOURCE_ID": imported,
    }
    if platform == "linux":
        assert env.get("DISPLAY"), "An isolated X display is required"
        env["GDK_BACKEND"] = "x11"
    run_tests(
        "desktop",
        ["integration_test/first_run_models_test.dart"],
        1,
        env,
        running["root"] / "first-run-events",
        "first-run",
        flutter=flutter,
        device=platform,
        timeout=300,
        model_fixture_catalog=first_run_catalog.catalog,
    )
    report = json.loads((running["root"] / "first-run.json").read_text())
    assert all(
        report[key]
        for key in [
            "fresh",
            "partial",
            "interrupted",
            "desktop_closed",
            "restarted",
            "checksum_rejected",
            "retried",
            "adopted",
            "indexed",
            "same_service_mcp",
        ]
    )
    generation = [r for r in first_run_catalog.requests if r["kind"] == "generation"]
    interrupted = [r for r in generation if r.get("interrupted")]
    assert interrupted and interrupted[0]["sent"] > 0
    staged = 0
    for attempt in interrupted:
        assert attempt["start"] == staged
        assert attempt["status"] == (206 if staged else 200)
        staged += attempt["sent"]
    resumed = next(r for r in generation if r["mode"] == "corrupt")
    assert 0 < staged < first_run_catalog.catalog["generation"][0]["bytes"]
    assert resumed["start"] == staged and resumed["status"] == 206
    # A checksum rejection discards the partial bytes; retry begins from zero.
    retried = [r for r in generation if r["mode"] == "good"]
    assert len(retried) == 1 and retried[0]["start"] == 0
    assert retried[0]["status"] == 200
    assert report["real_models"] == "not_run"
    assert report["real_gpu"] == "not_run"
    assert (running["root"] / "first-run-worker.jsonl").is_file()
