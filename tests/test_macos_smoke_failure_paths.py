"""Smoke orchestration failures must retain diagnostics and stop owned processes."""

from contextlib import contextmanager
import io
from pathlib import Path
import queue
import subprocess
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from test_smoke_tool_contracts import mac_smoke as mac_smoke
from test_smoke_tool_contracts import smoke


@pytest.mark.parametrize(
    "failure",
    [
        "desktop-exit",
        "desktop-mismatch",
        "desktop-status",
        "desktop-closed",
        "disconnect",
        "deferred-owner",
        "racing-db",
        "restart-owner",
        "restart-note",
        "missing-db",
        "permissions",
        "close",
    ],
)
def test_smoke_rejects_incomplete_lifecycle_and_cleans_up(
    mac_smoke, monkeypatch, failure
):
    bundle, output, state, desktop = mac_smoke
    use_desktop = failure.startswith("desktop")
    if failure == "desktop-exit":
        desktop.poll.return_value = 1
    elif failure == "desktop-closed":
        desktop.poll.side_effect = [None, 1, None, None]
    original_status = smoke.service_command
    status_calls = []

    def command(service, env, action):
        if action == "--status":
            status_calls.append(action)
            if failure == "desktop-status":
                raise subprocess.CalledProcessError(1, "status")
            result = original_status(service, env, action)
            if failure == "desktop-mismatch" and len(status_calls) == 1:
                return {"pid": 999}
            if (
                failure == "disconnect"
                and len(status_calls) == 1
                or failure == "deferred-owner"
                and len(status_calls) == 2
            ):
                return {"pid": 999}
            return result
        return original_status(service, env, action)

    monkeypatch.setattr(smoke, "service_command", command)
    ticks = iter(range(0, 1000, 31))
    monkeypatch.setattr(smoke.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(smoke.time, "sleep", lambda _: None)
    if failure == "racing-db":
        original_run = smoke.subprocess.run

        def run(args, **kw):
            if args[0] != "/usr/bin/codesign":
                data = Path(kw["env"]["FORESIGHT_DATA"])
                data.mkdir()
                (data / "application.db").touch()
            return original_run(args, **kw)

        monkeypatch.setattr(smoke.subprocess, "run", run)
    if failure == "restart-owner":
        monkeypatch.setattr(
            smoke,
            "process_path",
            lambda pid: Path("/outside") if state["peers"] == 3 else state["service"],
        )
    if failure in ("restart-note", "close"):
        original_peer = smoke.McpPeer

        class Peer(original_peer):
            def tool(self, name, arguments=None):
                if (
                    failure == "restart-note"
                    and self.index == 3
                    and name == "list_notes"
                ):
                    return []
                return super().tool(name, arguments)

            def close(self):
                if failure == "close":
                    raise RuntimeError("MCP close failed")
                super().close()

        monkeypatch.setattr(smoke, "McpPeer", Peer)
    if failure in ("missing-db", "permissions"):

        def graph(endpoint, peer, database):
            if failure != "missing-db":
                database.touch()
                database.parent.chmod(0o755)
            return {}

        monkeypatch.setattr(smoke, "source_graph_probe", graph)
    with pytest.raises(RuntimeError):
        smoke.smoke(bundle, output, desktop=use_desktop)
    assert not output.exists()
    if failure == "desktop-status":
        assert state["stops"] == []  # An unidentified owner must never be killed.
    elif failure != "restart-owner":
        assert state["owner"] is None


@pytest.mark.parametrize("unexpected", ["lock", "installer"])
def test_smoke_detects_unexpected_permission_to_upgrade_live_bundle(
    mac_smoke, monkeypatch, unexpected
):
    bundle, output, state, _ = mac_smoke
    if unexpected == "lock":

        @contextmanager
        def lock(app):
            yield

        monkeypatch.setattr(smoke, "installation_lock", lock)
    else:
        monkeypatch.setattr(smoke, "install", lambda *a, **kw: {})
    with pytest.raises(AssertionError):
        smoke.smoke(bundle, output)
    assert state["owner"] is None


def test_mcp_reader_reports_nonprotocol_stdout_and_bounds_diagnostics():
    peer = object.__new__(smoke.McpPeer)
    peer.messages, peer.errors = queue.Queue(), bytearray()
    peer.process = SimpleNamespace(
        stdout=io.BytesIO(b"diagnostic on stdout\n"), stderr=io.BytesIO(b"x" * 70000)
    )
    peer._read()
    assert isinstance(peer.messages.get_nowait(), RuntimeError)
    assert isinstance(peer.messages.get_nowait(), EOFError)
    peer._errors()
    assert len(peer.errors) == 65536


@pytest.mark.parametrize("failure", ["timeout", "exit"])
def test_mcp_close_reaps_child_and_closes_streams_even_on_failure(failure):
    peer = object.__new__(smoke.McpPeer)
    peer.messages, peer.errors = queue.Queue(), bytearray(b"retained diagnostic")
    process = SimpleNamespace(
        stdin=io.BytesIO(),
        stdout=io.BytesIO(),
        stderr=io.BytesIO(),
        wait=Mock(
            side_effect=[subprocess.TimeoutExpired("mcp", 10), 0]
            if failure == "timeout"
            else None,
            return_value=1,
        ),
        kill=Mock(),
    )
    peer.process = process
    peer.stdout_thread = peer.stderr_thread = SimpleNamespace(join=Mock())
    with pytest.raises(RuntimeError):
        peer.close()
    assert process.stdout.closed and process.stderr.closed and process.stdin.closed
    assert process.kill.called == (failure == "timeout")


def test_process_stop_checks_identity_and_handles_termination_race(
    tmp_path, monkeypatch
):
    executable = tmp_path / "service"
    executable.touch()
    monkeypatch.setattr(smoke, "process_path", lambda pid: executable.resolve())
    monkeypatch.setattr(smoke.time, "monotonic", Mock(side_effect=[0, 16]))
    with pytest.raises(AssertionError, match="still live"):
        smoke.wait_stopped(123, executable)
    process = SimpleNamespace(
        poll=Mock(return_value=None),
        terminate=Mock(side_effect=ProcessLookupError),
        wait=Mock(return_value=0),
    )
    assert smoke.stop_desktop(process) == 0
    process.wait.assert_called_once_with(timeout=15)
    process.poll.return_value, process.returncode = 1, 1
    assert smoke.stop_desktop(process) == 1


def test_smoke_cli_rejects_other_platform_without_passing_report(tmp_path, monkeypatch):
    output = tmp_path / "report.json"
    monkeypatch.setattr(smoke.sys, "platform", "linux")
    with pytest.raises(SystemExit, match="2"):
        smoke.main([str(tmp_path / "app"), "--output", str(output)])
    assert not output.exists()
