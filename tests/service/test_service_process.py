"""Real application/MCP subprocess integration with controlled inference/audio.

Run after building: .venv/bin/python -m pytest tests/service -v
These fixtures verify ownership and data flow, not inference quality.
"""

import concurrent.futures
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


class ApprovalDesktop:
    """Explicit synthetic UI host for tests that exercise approved operations."""

    def __init__(self, path, profile, root):
        self.peer = Peer(path)
        self.peer.call(
            "status"
        )  # Wait until service initialization publishes the capability.
        self.peer.call(
            "security.attach_desktop",
            {"token": (profile / ".desktop-capability").read_text()},
        )
        self.peer.call("security.allow_import_root", {"path": str(root)})
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
        if self.peer.socket.fileno() < 0:
            return
        try:
            self.peer.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.thread.join(timeout=3)
        self.peer.close()


class McpPeer:
    def __init__(self, env):
        self.runtime = Path(env["FORESIGHT_RUNTIME"])
        self.service_pid = None
        self.previous_reply = None
        self.previous_error = None
        self.process = subprocess.Popen(
            [str(MCP)],
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


@pytest.fixture
def running(tmp_path, request):
    assert SERVICE.is_file() and MCP.is_file(), (
        "Build service and MCP executables first"
    )
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir(mode=0o700)
    model = fixtures / "model.litertlm"
    model.write_bytes(b"controlled embedding fixture")
    asset = fixtures / "asset.bin"
    asset.write_bytes(b"controlled model fixture")
    runner = fixtures / "runner"
    runner.write_text(
        "#!/usr/bin/env python3\nimport json,sys,time,os,pathlib\n"
        'if "-n" in sys.argv and sys.argv[sys.argv.index("-n")+1]=="0": sys.exit(0)\n'
        'if "-f" in sys.argv: print("Mira sends the draft Tuesday."); sys.exit(0)\n'
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
    env.update(
        FORESIGHT_DATA=str(tmp_path / "data"),
        FORESIGHT_RUNTIME=str(tmp_path / "run"),
        FORESIGHT_SERVICE=str(SERVICE),
        FORESIGHT_SERVICE_TRACE="1",
        FORESIGHT_HELPER=str(HELPER),
        FORESIGHT_NATIVE=str(NATIVE),
        FORESIGHT_CAPTURE_RUNTIME=str(capture),
        FORESIGHT_MODEL_WORKER=str(HELPER.parent / "model_worker_fixture"),
        FORESIGHT_DELAY_GENERATION=str(fixtures / "delay"),
        PATH=str(fixtures) + ":" + env["PATH"],
    )
    if getattr(request, "param", None) == "capture_poll_gate":
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
            tmp_path / "run/application.sock", tmp_path / "data", tmp_path
        )
        if getattr(request, "param", None) != "without_embedding":
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
    peer.call("models.embedding", {"path": str(running["root"] / "fixtures/model.litertlm")})
    with sqlite3.connect(running["root"] / "data/application.db") as db:
        after = db.execute(
            "SELECT content,revision,state,error FROM sources WHERE id=?", [imported]
        ).fetchone()
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


def test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations(
    running,
):
    import shutil

    dart = os.environ.get("FORESIGHT_DART_EXECUTABLE") or shutil.which("dart")
    if not dart:
        pytest.skip("Dart executable required for the desktop facade integration probe")
    result = subprocess.run(
        [
            dart,
            "--packages="
            + str(ROOT / "packages/foresight_core/.dart_tool/package_config.json"),
            str(ROOT / "tests/service/remote_client_probe.dart"),
        ],
        env=running["env"],
        capture_output=True,
        text=True,
        timeout=40,
    )
    assert result.returncode == 0, result.stdout + "\n" + result.stderr
    report = json.loads(result.stdout)
    assert report["read_only"] and report["changes"] and report["reconnected"]
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
        completed = subprocess.run(
            [
                flutter,
                "test",
                "--no-pub",
                "-d",
                "macos" if mac_ui else "linux",
                "integration_test/service_mcp_test.dart",
                "--reporter",
                "expanded",
            ],
            cwd=ROOT / "apps/desktop",
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
        )
        assert completed.returncode == 0, completed.stdout + "\n" + completed.stderr
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
        # Shutdown may wait up to five seconds for the helper, and a new
        # launcher allows ten seconds for the replacement service to bind.
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


@pytest.mark.parametrize("shutdown", ["explicit-stop", "desktop-close"])
def test_service_stop_waits_for_active_capture_and_finalizes_transcript(running, shutdown):
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
        # Leave the agent connected: it must not retain the UI's daemon.
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


def test_idle_upgrade_shutdown_defers_capture_and_requires_verified_ack(running):
    import sqlite3

    peer = running["peer"]
    owner = running["process"]
    wrong = subprocess.run(
        [str(SERVICE), f"--stop-if-idle={owner.pid + 1}"],
        env=running["env"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert wrong.returncode != 0 and "ownership changed" in wrong.stderr
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
    assert refused.returncode != 0 and "final transcript" in refused.stderr
    assert owner.poll() is None and peer.call("status")["capture"]["active"]
    deadline = time.monotonic() + 15
    while sum(peer.call("status")["capture"]["samples"]) < 24000:
        assert time.monotonic() < deadline, "capture stopped after deferred upgrade"
        poll_delay(deadline)
    peer.call("meetings.stop")
    stopped = subprocess.run(
        [str(SERVICE), f"--stop-if-idle={owner.pid}"],
        env=running["env"],
        capture_output=True,
        text=True,
        timeout=15,
    )
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
            stopped = subprocess.run(
                [str(SERVICE), f"--stop-if-idle={service.pid}"],
                env=env,
                text=True,
                capture_output=True,
                timeout=20,
            )
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
    print(f"Endpoint record: {record.read_text() if record.exists() else 'missing'}")
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
    except Exception:
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
