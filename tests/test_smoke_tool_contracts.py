"""Smoke-tool assertions and cleanup tested with disposable bundle/process doubles."""

from contextlib import contextmanager
import io
import json
from pathlib import Path
import queue
import shutil
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import macos_bundle
import smoke_macos_bundle as smoke
import smoke_bundle as linux


@pytest.mark.parametrize(
    "reply,message",
    [
        (None, "timed out"),
        ([], "envelope"),
        ({"jsonrpc": "1.0"}, "envelope"),
        ({"jsonrpc": "2.0", "id": 999}, "Unexpected"),
        ({"jsonrpc": "2.0", "id": 1, "error": "broken"}, "MCP error"),
        (EOFError("closed"), "closed"),
    ],
)
def test_mcp_request_rejects_timeout_bad_envelopes_and_server_errors(reply, message):
    peer = object.__new__(smoke.McpPeer)
    peer.sequence, peer.errors, peer.messages = (
        0,
        bytearray(b"diagnostic"),
        queue.Queue(),
    )
    peer.send = Mock()
    if reply is not None:
        peer.messages.put(reply)
    with pytest.raises((RuntimeError, TimeoutError, EOFError), match=message):
        peer.request("status", {}, timeout=0.001)
    assert peer.send.call_args.args[0]["id"] == 1


def test_mcp_notifications_and_tool_failures_are_not_successful_replies():
    peer = object.__new__(smoke.McpPeer)
    peer.sequence, peer.errors, peer.messages = 0, bytearray(), queue.Queue()
    peer.send = Mock()
    peer.messages.put({"jsonrpc": "2.0", "method": "progress"})
    peer.messages.put({"jsonrpc": "2.0", "id": 1, "result": {"isError": True}})
    with pytest.raises(RuntimeError, match="tool failed"):
        peer.tool("broken")
    peer.messages.put(
        {"jsonrpc": "2.0", "id": 2, "result": {"structuredContent": {"result": 42}}}
    )
    assert peer.tool("valid", {"argument": 1}) == 42


@pytest.mark.parametrize(
    "item",
    [
        EOFError(),
        {"jsonrpc": "2.0", "method": "notification"},
        RuntimeError("trailing error"),
        {"jsonrpc": "2.0", "id": 1},
        12,
    ],
)
def test_mcp_close_validates_trailing_protocol_and_closes_streams(item):
    peer = object.__new__(smoke.McpPeer)
    peer.errors, peer.messages = bytearray(), queue.Queue()
    peer.messages.put(item)
    peer.process = SimpleNamespace(
        stdin=io.BytesIO(),
        stdout=io.BytesIO(),
        stderr=io.BytesIO(),
        wait=Mock(return_value=0),
    )
    peer.stdout_thread = peer.stderr_thread = SimpleNamespace(join=Mock())
    if isinstance(item, EOFError) or isinstance(item, dict) and "method" in item:
        peer.close()
    else:
        with pytest.raises(RuntimeError):
            peer.close()
    assert (
        peer.process.stdin.closed
        and peer.process.stdout.closed
        and peer.process.stderr.closed
    )


@pytest.mark.parametrize(
    "reply,expected",
    [
        ('{"id":1,"result":7}\n{"id":1,"done":true}\n', 7),
        ('{"event":"progress"}\n{"id":1,"done":true}\n', None),
        ("", EOFError),
        ('{"id":2,"done":true}\n', RuntimeError),
        ('{"id":1,"error":"denied"}\n', RuntimeError),
    ],
)
def test_application_peer_streaming_replies_are_correlated(reply, expected):
    peer = object.__new__(smoke.ApplicationPeer)
    peer.sequence, peer.reader, peer.socket = (
        0,
        io.StringIO(reply),
        SimpleNamespace(sendall=Mock(), close=Mock()),
    )
    if isinstance(expected, type):
        with pytest.raises(expected):
            peer.call("sources.list")
    else:
        assert peer.call("sources.list") == expected
    sent = json.loads(peer.socket.sendall.call_args.args[0])
    assert sent == {"id": 1, "method": "sources.list", "args": {}}
    peer.close()
    assert peer.reader.closed


def test_application_peer_desktop_attachment_requires_owned_capability_file(tmp_path):
    peer = object.__new__(smoke.ApplicationPeer)
    peer.call = Mock()
    assert peer.attach_test_desktop(tmp_path) is False
    peer.call.assert_not_called()
    (tmp_path / ".desktop-capability").write_text("capability")
    assert peer.attach_test_desktop(tmp_path) is True
    peer.call.assert_called_once_with(
        "security.attach_desktop", {"token": "capability"}
    )


@pytest.fixture
def mac_smoke(tmp_path, monkeypatch):
    bundle = tmp_path / "Input.app"
    resource = bundle / "Contents/Resources"
    resource.mkdir(parents=True)
    (resource / "runtime.json").write_text(
        '{"FORESIGHT_RUNTIME_REVISION":"fixture-revision"}'
    )
    state = {"owner": 100, "peers": 0, "service": None, "failure": None, "stops": []}
    monkeypatch.setattr(
        smoke,
        "copy_application",
        lambda source, target: shutil.copytree(source, target),
    )
    monkeypatch.setattr(
        smoke, "metadata", lambda app: {"CFBundleExecutable": "desktop"}
    )
    monkeypatch.setattr(
        macos_bundle, "audit_dependencies", lambda app: ["verified-linkage"]
    )
    monkeypatch.setattr(smoke, "parser_probe", lambda *args: {"pdf": "fixture"})

    class Peer:
        def __init__(self, executable, env):
            state["peers"] += 1
            state["service"] = (executable.parents[2] / smoke.SERVICE).resolve()
            self.index = state["peers"]
            if self.index == 3:
                state["owner"] = 100 if state["failure"] == "restart" else 200

        def tool(self, name, arguments=None):
            if name == "get_status":
                owner = (
                    999
                    if state["failure"] == "competing" and self.index == 2
                    else state["owner"]
                )
                app = state["service"].parents[6]
                return {
                    "pid": owner,
                    "installation_root": "wrong"
                    if state["failure"] == "installation"
                    else str(app),
                }
            if name == "save_note":
                return {"id": "note"}
            if name == "list_notes":
                return (
                    []
                    if state["failure"] == "note"
                    else [
                        {
                            "id": "note",
                            "body": "Persist across clients and service restart",
                        }
                    ]
                )
            raise AssertionError(name)

        def close(self):
            pass

    monkeypatch.setattr(smoke, "McpPeer", Peer)
    monkeypatch.setattr(
        smoke,
        "process_path",
        lambda pid: (
            Path("/unrelated") if state["failure"] == "owner" else state["service"]
        ),
    )

    def service_command(service, env, action):
        state["service"] = service.resolve()
        if action == "--status":
            if state["owner"] is None:
                raise subprocess.CalledProcessError(1, "status")
            return {"pid": state["owner"]}
        state["stops"].append(state["owner"])
        state["owner"] = None

    monkeypatch.setattr(smoke, "service_command", service_command)

    @contextmanager
    def lock(app):
        if state["owner"] is not None:
            raise smoke.Deferred("live service")
        yield

    monkeypatch.setattr(smoke, "installation_lock", lock)

    def install(source, destination, **kwargs):
        if not kwargs.get("stop_services"):
            raise smoke.Deferred("live service")
        state["owner"] = None
        return {
            "upgraded": state["failure"] != "upgrade",
            "maintenance_lock": "shared" if state["failure"] == "lock" else "exclusive",
        }

    monkeypatch.setattr(smoke, "install", install)
    monkeypatch.setattr(smoke, "wait_stopped", Mock())
    monkeypatch.setattr(
        smoke,
        "verify_transaction_rollback",
        lambda *args: {"status": "fixture-rollback"},
    )

    def graph(endpoint, peer, database):
        database.touch()
        return {"fixture": True}

    monkeypatch.setattr(smoke, "source_graph_probe", graph)
    monkeypatch.setattr(smoke, "verify_source_graph_restart", Mock())
    desktop = SimpleNamespace(
        poll=Mock(return_value=None),
        terminate=Mock(),
        wait=Mock(return_value=0),
        returncode=0,
    )
    monkeypatch.setattr(smoke.subprocess, "Popen", Mock(return_value=desktop))

    def run(command, **kwargs):
        if command[0] == "/usr/bin/codesign":
            return subprocess.CompletedProcess(command, 0)
        return subprocess.CompletedProcess(
            command,
            0 if state["failure"] == "racing" else 1,
            "",
            "unrelated"
            if state["failure"] == "diagnostic"
            else "installation in progress",
        )

    monkeypatch.setattr(smoke.subprocess, "run", run)
    return bundle, tmp_path / "output/smoke.json", state, desktop


@pytest.mark.parametrize("desktop", [False, True])
def test_mac_smoke_orchestration_checks_ownership_upgrade_and_persistence(
    mac_smoke, desktop
):
    bundle, output, state, process = mac_smoke
    report = smoke.smoke(
        bundle, output, desktop=desktop, expected_revision="fixture-revision"
    )
    assert report["service_pids"] == [100, 200]
    assert report["private_profile"] is True
    assert report["maintenance_lock_blocks_racing_service_start"] is True
    assert report["gates"]["real_models"] == "not_run"
    assert (report["gates"]["desktop"] != "not_run") is desktop
    assert json.loads(output.read_text()) == report
    assert state["stops"] == [200]
    assert process.terminate.called is desktop


@pytest.mark.parametrize(
    "failure,message",
    [
        ("competing", "competing"),
        ("owner", "outside"),
        ("installation", "identity"),
        ("note", "\\[\\]"),
        ("upgrade", "Verification"),
        ("lock", "Verification"),
        ("racing", "maintenance lock"),
        ("diagnostic", "unrelated"),
        ("restart", "not restarted"),
    ],
)
def test_mac_smoke_fails_at_each_ownership_or_upgrade_boundary_and_cleans_owner(
    mac_smoke, failure, message
):
    bundle, output, state, _ = mac_smoke
    state["failure"] = failure
    with pytest.raises(RuntimeError, match=message):
        smoke.smoke(bundle, output)
    assert not output.exists()
    if failure != "owner" and state["owner"] is not None:
        pytest.fail("owned service was not stopped after failure")


@pytest.mark.parametrize("problem", [None, "timeout", "id", "status", "note", "exit"])
def test_linux_mcp_roundtrip_validates_responses_and_closes_pipes(
    tmp_path, monkeypatch, problem
):
    responses = [
        {"jsonrpc": "2.0", "id": 1, "result": {}},
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "isError": problem == "status",
                "structuredContent": {"result": {"pid": 77}},
            },
        },
        {"jsonrpc": "2.0", "id": 3, "result": {"isError": problem == "note"}},
    ]
    if problem == "id":
        responses[0]["id"] = 99
    process = SimpleNamespace(
        stdin=io.BytesIO(),
        stdout=io.BytesIO(b"".join((json.dumps(r) + "\n").encode() for r in responses)),
        stderr=io.BytesIO(b"stderr evidence"),
        poll=Mock(return_value=None),
        kill=Mock(),
        wait=Mock(return_value=1 if problem == "exit" else 0),
    )
    monkeypatch.setattr(linux.subprocess, "Popen", lambda *a, **kw: process)
    monkeypatch.setattr(
        linux.select,
        "select",
        lambda *a: ([], [], []) if problem == "timeout" else ([process.stdout], [], []),
    )
    if problem:
        with pytest.raises(RuntimeError):
            linux.mcp_roundtrip(tmp_path, {})
    else:
        assert linux.mcp_roundtrip(tmp_path, {}) == {"pid": 77}
    assert process.stdout.closed and process.stderr.closed
    process.kill.assert_called_once()


@pytest.mark.parametrize(
    "failure", [None, "revision", "content", "stale", "current", "rows", "vectors"]
)
def test_source_graph_probe_checks_real_sqlite_rows_and_restart_content(
    tmp_path, monkeypatch, failure
):
    import copy
    import sqlite3

    database = tmp_path / "application.db"
    with sqlite3.connect(database) as db:
        db.execute(
            "CREATE TABLE graph_documents (model_identity TEXT, document_id TEXT, source_revision INTEGER, embedding BLOB, proj_x REAL, proj_y REAL, proj_z REAL)"
        )
        db.execute("CREATE TABLE source_details (source_id TEXT, labels TEXT)")
    sources = {}

    class Application:
        def __init__(self):
            self.closed = False

        def attach_test_desktop(self, profile):
            return True

        def call(self, method, args):
            if method == "sources.import":
                identifier = args.get("id", "a" if not sources else "b")
                revision = sources.get(identifier, {}).get("revision", 0) + 1
                sources[identifier] = {
                    "id": identifier,
                    "revision": revision,
                    "content": args["text"],
                }
                if identifier == "a" and revision == 2:
                    if failure == "revision":
                        sources[identifier]["revision"] = 1
                    elif failure == "content":
                        sources[identifier]["content"] = "wrong"
                return {"id": identifier}
            if method == "labels.set":
                with sqlite3.connect(database) as db:
                    db.execute(
                        "INSERT INTO source_details VALUES (?,?)",
                        [args["id"], json.dumps(args["labels"])],
                    )
                return True
            if method == "graph.save":
                stale = args["sources"][0]["revision"] != sources["a"]["revision"]
                if stale:
                    return failure == "stale"
                if failure == "current":
                    return False
                with sqlite3.connect(database) as db:
                    for source in args["sources"]:
                        if source["id"] == "b" and failure == "rows":
                            continue
                        db.execute(
                            "INSERT INTO graph_documents VALUES (?,?,?,?,?,?,?)",
                            [
                                args["identity"],
                                source["id"],
                                source["revision"],
                                b"unexpected vector" if failure == "vectors" else b"",
                                *args["points"][source["id"]],
                            ],
                        )
                return True
            raise AssertionError(method)

        def close(self):
            self.closed = True

    application = Application()
    monkeypatch.setattr(smoke, "ApplicationPeer", lambda endpoint: application)

    class Mcp:
        def tool(self, method, args=None):
            return (
                copy.deepcopy(sources[args["id"]])
                if method == "get_source"
                else copy.deepcopy(list(sources.values()))
            )

    mcp = Mcp()
    if failure:
        with pytest.raises(RuntimeError):
            smoke.source_graph_probe(tmp_path / "socket", mcp, database)
    else:
        evidence = smoke.source_graph_probe(tmp_path / "socket", mcp, database)
        assert len(evidence["graph_rows"]) == 2
        assert evidence["sources"][0]["revision"] == 2
        smoke.verify_source_graph_restart(mcp, database, evidence)
        sources["a"]["content"] = "changed after restart"
        with pytest.raises(RuntimeError):
            smoke.verify_source_graph_restart(mcp, database, evidence)
        sources["a"]["content"] = "Alpha revision two."
        with sqlite3.connect(database) as db:
            db.execute("UPDATE graph_documents SET proj_x=123")
        with pytest.raises(RuntimeError, match="coordinates changed"):
            smoke.verify_source_graph_restart(mcp, database, evidence)
    assert application.closed


@pytest.mark.parametrize(
    "failure", [None, "text", "exit", "stdout", "stderr", "escape"]
)
def test_parser_probe_requires_exact_format_results_and_rejects_invalid_documents(
    tmp_path, monkeypatch, failure
):
    app = tmp_path / "App.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    parser = resources / "parser"
    parser.touch()
    if failure == "escape":
        (resources / "runtime.json").write_text(
            '{"FORESIGHT_FILE_PARSER":"../../../external"}'
        )
        (tmp_path / "external").touch()
    else:
        (resources / "runtime.json").write_text('{"FORESIGHT_FILE_PARSER":"parser"}')

    def run(command, **kwargs):
        path = Path(command[-1])
        if path.stem == "Invalid":
            return subprocess.CompletedProcess(
                command,
                0 if failure == "exit" else 1,
                "unexpected output" if failure == "stdout" else "",
                "" if failure == "stderr" else "unsupported document",
            )
        kind = path.suffix[1:]
        assert path.read_bytes().startswith(b"%PDF" if kind == "pdf" else b"{\\rtf1")
        return subprocess.CompletedProcess(
            command,
            0,
            "wrong"
            if failure == "text"
            else f"Open Foresight packaged {kind.upper()} smoke.",
            "",
        )

    monkeypatch.setattr(smoke.subprocess, "run", run)
    if failure:
        with pytest.raises((RuntimeError, AssertionError)):
            smoke.parser_probe(app, tmp_path / "fixtures", {})
    else:
        report = smoke.parser_probe(app, tmp_path / "fixtures", {})
        assert report["invalid_documents"] == "rejected_with_stderr"
        assert (
            (tmp_path / "fixtures/Fixture With Spaces.pdf")
            .read_bytes()
            .endswith(b"%%EOF\n")
        )


@pytest.mark.parametrize("failure", [None, "not-reached", "not-restored"])
def test_rollback_probe_requires_post_swap_fault_and_original_inode_restoration(
    tmp_path, monkeypatch, failure
):
    from test_macos_tools import portable_swap

    source, destination = tmp_path / "Source.app", tmp_path / "Installed.app"
    source.mkdir()
    destination.mkdir()
    (destination / "original").write_bytes(b"original bundle")
    original_inode = destination.stat().st_ino
    monkeypatch.setattr(
        smoke, "verify_signature", Mock(return_value={"team": "fixture"})
    )

    def install(source, destination, **kwargs):
        if failure == "not-reached":
            return
        portable_swap(source, destination)
        try:
            kwargs["verify"](destination)
        except RuntimeError:
            if failure != "not-restored":
                portable_swap(source, destination)
            raise

    monkeypatch.setattr(smoke, "install", install)
    if failure:
        with pytest.raises(
            (AssertionError, RuntimeError), match="did not reach|did not restore"
        ):
            smoke.verify_transaction_rollback(source, destination)
    else:
        report = smoke.verify_transaction_rollback(source, destination)
        assert report["status"] == "passed_original_bundle_restored"
        assert destination.stat().st_ino == original_inode
        assert (destination / "original").read_bytes() == b"original bundle"
