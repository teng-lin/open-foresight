"""Offline ownership, refusal and cleanup contracts for actual GUI acceptance."""

from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import sqlite3
import subprocess
import sys
import threading
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import installed_desktop_approval as gui
import smoke_macos_bundle as smoke


@pytest.fixture
def owned(tmp_path, monkeypatch):
    monkeypatch.setattr(gui.sys, "platform", "darwin")
    profile = tmp_path / "profile"
    profile.mkdir(mode=0o700)
    for name in ("home", "data", "run"):
        (profile / name).mkdir(mode=0o700)
    (profile / "run/commands.sock").touch()
    with closing(sqlite3.connect(profile / "data/application.db")) as db:
        db.execute("CREATE TABLE preferences(key TEXT,value TEXT)")
        db.execute("INSERT INTO preferences VALUES ('onboarding.complete','true')")
        db.commit()
    bundle = tmp_path / "Owned.app"
    (bundle / "Contents/MacOS").mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_bytes(
        plistlib.dumps({"CFBundleExecutable": "desktop"})
    )
    executable = bundle / "Contents/MacOS/desktop"
    executable.write_bytes(b"actual selected fixture image")
    env = {
        "HOME": str(profile / "home"),
        "FORESIGHT_DATA": str(profile / "data"),
        "FORESIGHT_RUNTIME": str(profile / "run"),
    }
    process = SimpleNamespace(
        pid=123,
        poll=Mock(return_value=None),
        terminate=Mock(),
        kill=Mock(),
        wait=Mock(return_value=0),
    )
    monkeypatch.setattr(gui.subprocess, "Popen", Mock(return_value=process))
    monkeypatch.setattr(
        gui.subprocess,
        "run",
        Mock(
            return_value=SimpleNamespace(
                returncode=0, stdout="BUTTON:Sources\nBUTTON:Settings", stderr=""
            )
        ),
    )
    monkeypatch.setattr(gui, "process_path", lambda pid: executable)
    monkeypatch.setattr(
        gui,
        "service_command",
        lambda *args: {
            "pid": 456,
            "installation_root": str(bundle),
            "profile_id": hashlib.sha256(str(profile / "data").encode()).hexdigest()[
                :24
            ],
        },
    )
    host = gui.InstalledDesktop(
        bundle, profile, env, tmp_path / "evidence", timeout=0.5
    )
    yield SimpleNamespace(
        host=host,
        bundle=bundle,
        profile=profile,
        env=env,
        process=process,
        executable=executable,
    )
    if host.process is not None:
        host.close()


def test_actual_image_private_profile_and_osascript_pid_are_recorded(owned):
    host = owned.host.start()
    assert host.evidence["startup"] == "passed_actual_gui"
    command = gui.subprocess.run.call_args.args[0]
    assert command == ["/usr/bin/osascript", "-e", gui.SCRIPT, "123", ""]
    assert "unix id is targetPid" in gui.SCRIPT
    assert (
        host.evidence["executable_sha256"]
        == hashlib.sha256(owned.executable.read_bytes()).hexdigest()
    )
    host.close()
    assert host.evidence["status"] == "closed"
    assert host.log.closed


def test_desktop_first_start_waits_for_delayed_service_and_retains_failures(
    owned, monkeypatch
):
    state = gui.service_command()
    failures = [
        subprocess.CalledProcessError(
            1, "status", output=f"starting {attempt}", stderr=f"no owner {attempt}"
        )
        for attempt in range(2)
    ]
    command = Mock(side_effect=[*failures, state])
    monkeypatch.setattr(gui, "service_command", command)
    monkeypatch.setattr(gui.time, "sleep", lambda _: None)
    owned.host.start()
    assert command.call_count == 3
    assert owned.host.evidence["service_startup_errors"] == [
        {
            "returncode": 1,
            "stdout": f"starting {attempt}",
            "stderr": f"no owner {attempt}",
        }
        for attempt in range(2)
    ]


def test_service_startup_retries_share_the_original_deadline(owned, monkeypatch):
    failure = subprocess.CalledProcessError(
        1, "status", output="still starting", stderr="service not listening"
    )
    command = Mock(side_effect=failure)
    monkeypatch.setattr(gui, "service_command", command)
    clock = iter([0, 0, 1])
    monkeypatch.setattr(gui.time, "monotonic", lambda: next(clock))
    monkeypatch.setattr(gui.time, "sleep", lambda _: None)
    with pytest.raises(TimeoutError, match="service not listening"):
        owned.host.start()
    assert command.call_count == 2
    assert owned.host.evidence["status"] == "closed_after_failure"
    assert (
        owned.host.evidence["service_startup_errors"][-1]["stdout"] == "still starting"
    )
    owned.process.terminate.assert_called_once()


def test_desktop_exit_during_service_startup_is_fatal(owned, monkeypatch):
    def starting(*_):
        owned.process.poll.return_value = 1
        raise subprocess.CalledProcessError(1, "status", stderr="no service yet")

    command = Mock(side_effect=starting)
    monkeypatch.setattr(gui, "service_command", command)
    monkeypatch.setattr(gui.time, "sleep", lambda _: None)
    with pytest.raises(RuntimeError, match="process identity"):
        owned.host.start()
    command.assert_called_once()
    assert owned.host.evidence["status"] == "closed_after_failure"
    owned.process.terminate.assert_not_called()


@pytest.mark.parametrize("field", ["installation_root", "profile_id"])
def test_successful_foreign_service_is_never_retried(owned, monkeypatch, field):
    state = gui.service_command()
    command = Mock(return_value={**state, field: "/wrong"})
    monkeypatch.setattr(gui, "service_command", command)
    with pytest.raises(RuntimeError, match="selected installation/profile"):
        owned.host.start()
    command.assert_called_once()
    assert owned.host.evidence["status"] == "closed_after_failure"


@pytest.mark.parametrize("change", ["platform", "public", "environment", "escape"])
def test_refuse_unqualified_platform_profile_environment_and_image(
    owned, monkeypatch, change
):
    if change == "platform":
        monkeypatch.setattr(gui.sys, "platform", "win32")
    elif change == "public":
        owned.profile.chmod(0o755)
    elif change == "environment":
        owned.env["HOME"] = "/owner-data"
    else:
        owned.executable.unlink()
        owned.executable.symlink_to("/bin/sh")
    with pytest.raises((ValueError, RuntimeError)):
        gui.InstalledDesktop(
            owned.bundle, owned.profile, owned.env, owned.profile.parent / "bad"
        )


@pytest.mark.parametrize("kind", ["permission", "image", "exited", "service"])
def test_start_failure_retains_diagnostic_and_closes_owned_process(
    owned, monkeypatch, kind
):
    if kind == "permission":
        gui.subprocess.run.return_value = SimpleNamespace(
            returncode=1,
            stdout="",
            stderr="osascript is not allowed assistive access (-25211)",
        )
    elif kind == "image":
        monkeypatch.setattr(gui, "process_path", lambda pid: Path("/unrelated"))
    elif kind == "exited":
        owned.process.poll.return_value = 3
    else:
        monkeypatch.setattr(
            gui, "service_command", lambda *args: {"installation_root": "/different"}
        )
    with pytest.raises(RuntimeError):
        owned.host.start()
    report = json.loads((owned.host.output / "gui-approval.json").read_text())
    if kind == "permission":
        assert "-25211" in report["accessibility_error"]
    assert owned.host.log.closed
    # Don't permit teardown to act on an unrelated PID identity.
    owned.host.process = None


def test_actual_onboarding_actions_acknowledged_by_read_only_state(owned):
    with closing(sqlite3.connect(owned.profile / "data/application.db")) as db:
        db.execute("DELETE FROM preferences")
        db.commit()
    clicked = []

    def ui(button=""):
        if button:
            clicked.append(button)
            with closing(sqlite3.connect(owned.profile / "data/application.db")) as db:
                db.execute("DELETE FROM preferences")
                if len(clicked) == 6:
                    db.execute(
                        "INSERT INTO preferences VALUES ('onboarding.complete','true')"
                    )
                else:
                    db.execute(
                        "INSERT INTO preferences VALUES ('onboarding.step',?)",
                        [str(len(clicked))],
                    )
                db.commit()
            return "CLICKED:" + button
        return (
            "BUTTON:Sources\nBUTTON:Settings"
            if len(clicked) == 6
            else "\n".join("BUTTON:" + button for button in gui.ONBOARDING)
        )

    owned.host._ui = ui
    owned.host.timeout = 3
    owned.host.start()
    assert clicked == list(gui.ONBOARDING)


def test_non_capture_request_needs_actual_correlated_gui_click(owned):
    host = owned.host.start()
    clicked = threading.Event()

    def ui(button=""):
        if button:
            clicked.set()
            return "CLICKED:" + button
        return "BUTTON:Allow once" if running.is_set() else ""

    running = threading.Event()

    def call(method, args):
        running.set()
        assert clicked.wait(1)
        return {"id": "saved"}

    host._ui = ui
    peer = SimpleNamespace(call=call, close=Mock())
    assert host.call(
        peer, "sources.import", {"title": "private", "text": "fixture"}
    ) == {"id": "saved"}
    assert host.evidence["approvals"][0]["clicked"]
    peer.close.assert_not_called()


@pytest.mark.parametrize(
    "method,args",
    [
        ("meetings.start", {}),
        ("meetings.resume", {}),
        ("security.attach_desktop", {}),
        ("preferences.set", {"key": "arbitrary"}),
        ("models.register", {"kind": "unknown"}),
        ("preferences.set", {"key": "importRoots", "value": '["/etc"]'}),
    ],
)
def test_never_approves_capture_identity_arbitrary_preferences_or_owner_roots(
    owned, method, args
):
    peer = SimpleNamespace(call=Mock(), close=Mock())
    with pytest.raises(ValueError):
        owned.host.call(peer, method, args)
    peer.call.assert_not_called()


def test_old_dialog_and_unobserved_or_capture_consent_are_rejected(owned):
    host = owned.host.start()
    peer = SimpleNamespace(call=Mock(return_value=True), close=Mock())
    host._ui = lambda button="": "BUTTON:Allow once"
    with pytest.raises(RuntimeError, match="pre-existing"):
        host.call(peer, "graph.save", {})
    host._ui = lambda button="": ""
    with pytest.raises(RuntimeError, match="without observed"):
        host.call(peer, "graph.save", {})


def test_application_socket_shutdown_unblocks_pending_reader_before_close():
    client, server = socket.socketpair()
    peer = object.__new__(smoke.ApplicationPeer)
    peer.socket = client
    peer.reader = client.makefile("r", encoding="utf8")
    peer.sequence = 0
    failures = []

    def request():
        try:
            peer.call("sources.import", {})
        except (EOFError, ValueError):
            failures.append("closed")

    worker = threading.Thread(target=request)
    worker.start()
    server.recv(4096)
    peer.close()
    worker.join(timeout=1)
    server.close()
    assert not worker.is_alive() and failures == ["closed"]


def test_external_wrapper_never_calls_desktop_attach_and_scopes_import_root(
    owned, monkeypatch
):
    peer = SimpleNamespace(
        call=Mock(return_value="read"), close=Mock(), socket=object()
    )
    monkeypatch.setattr(smoke, "ApplicationPeer", lambda endpoint: peer)
    host = SimpleNamespace(call=Mock(return_value="approved"))
    approved = gui.ApprovedApplicationPeer("/owned/socket", host)
    assert approved.socket is peer.socket
    assert approved.call("status") == "read"
    assert approved.call("sources.import", {"text": "fixture"}) == "approved"
    for method in [
        "security.attach_desktop",
        "meetings.start",
        "meetings.resume",
        "unexpected",
    ]:
        with pytest.raises(ValueError):
            approved.call(method)
    with pytest.raises(ValueError):
        approved.call("answer", {"web_search": True})
    assert approved.allow_import_root(owned.profile) == "approved"
    assert json.loads(host.call.call_args.args[2]["value"]) == [str(owned.profile)]
    approved.close()
    peer.close.assert_called_once()


@pytest.mark.parametrize("timeout", [0, -1, float("nan"), float("inf")])
def test_finite_deadline_is_required(owned, timeout):
    with pytest.raises(ValueError, match="finite"):
        gui.InstalledDesktop(
            owned.bundle,
            owned.profile,
            owned.env,
            owned.profile.parent / "invalid-timeout",
            timeout=timeout,
        )


def test_start_cannot_replace_existing_owned_process(owned):
    owned.host.start()
    with pytest.raises(RuntimeError, match="already started"):
        owned.host.start()


@pytest.mark.parametrize("kind", ["startup", "onboarding", "invalid_step"])
def test_startup_and_onboarding_waits_are_bounded(owned, monkeypatch, kind):
    if kind == "startup":
        (owned.profile / "run/commands.sock").unlink()
    else:
        with closing(sqlite3.connect(owned.profile / "data/application.db")) as db:
            db.execute("DELETE FROM preferences")
            db.execute(
                "INSERT INTO preferences VALUES('onboarding.step',?)",
                ["8" if kind == "invalid_step" else "0"],
            )
            db.commit()
    clock = iter([0, 0, 1, 2, 3, 4])
    monkeypatch.setattr(gui.time, "monotonic", lambda: next(clock))
    monkeypatch.setattr(gui.time, "sleep", lambda seconds: None)
    with pytest.raises((RuntimeError, TimeoutError)):
        owned.host.start()
    assert owned.host.evidence["failure"]


@pytest.mark.parametrize("kind", ["capture", "timeout", "click_failure"])
def test_failed_or_capture_dialog_closes_inflight_rpc(owned, kind):
    host = owned.host.start()
    running = threading.Event()
    released = threading.Event()

    def call(method, args):
        running.set()
        released.wait(2)
        raise EOFError("cancelled")

    def ui(button=""):
        if not running.is_set():
            return ""
        if kind == "capture":
            return (
                "TEXT:Allow microphone and system audio recording?\nBUTTON:Allow once"
            )
        return "BUTTON:Allow once" if kind == "click_failure" and not button else ""

    host._ui = ui
    host.timeout = 0.07
    peer = SimpleNamespace(call=call, close=lambda: released.set())
    with pytest.raises((RuntimeError, TimeoutError)):
        host.call(peer, "graph.save", {})
    assert released.wait(1)
    assert host.evidence["approvals"][0]["status"] == "failed"


def test_forced_gui_cleanup_is_not_reported_as_pass(owned):
    host = owned.host.start()
    owned.process.wait.side_effect = [gui.subprocess.TimeoutExpired("desktop", 15), -9]
    with pytest.raises(RuntimeError, match="forced cleanup"):
        host.close()
    owned.process.kill.assert_called_once()
    assert host.log.closed
    host.process = None


def test_close_without_start_and_already_exited_process(owned):
    owned.host.close()
    owned.host.start()
    owned.process.poll.return_value = 0
    owned.host.close()
    owned.process.terminate.assert_not_called()


def test_private_import_roots_are_displayed_for_consent(owned):
    host = owned.host.start()
    ready = threading.Event()
    clicked = threading.Event()
    fixture = owned.profile / "documents"
    fixture.mkdir()
    host._ui = lambda button="": (
        (clicked.set() or "CLICKED:Allow once")
        if button
        else ("BUTTON:Allow once" if ready.is_set() else "")
    )

    def call(method, args):
        ready.set()
        assert clicked.wait(1)
        return True

    assert host.call(
        SimpleNamespace(call=call, close=Mock()),
        "preferences.set",
        {"key": "importRoots", "value": json.dumps([str(fixture)])},
    )


@pytest.fixture
def linux_owned(owned, monkeypatch):
    monkeypatch.setattr(gui.sys, "platform", "linux")
    bundle = owned.bundle.parent / "LinuxBundle"
    (bundle / "app").mkdir(parents=True)
    executable = bundle / "app/open-foresight"
    executable.write_bytes(b"selected Linux fixture")
    (bundle / "open-foresight").write_text(
        "#!/usr/bin/env bash\nexec app/open-foresight\n"
    )
    environment = dict(
        owned.env, DISPLAY=":77", DBUS_SESSION_BUS_ADDRESS="unix:path=/private/session"
    )
    monkeypatch.setattr(gui, "process_path", lambda _: executable)
    monkeypatch.setattr(
        gui,
        "service_command",
        lambda *args: {
            "pid": 456,
            "installation_root": str(bundle),
            "profile_id": hashlib.sha256(
                str(owned.profile / "data").encode()
            ).hexdigest()[:24],
        },
    )
    accessibility = SimpleNamespace(
        evidence={"backend": "linux_atspi"},
        start=Mock(
            return_value=dict(environment, AT_SPI_BUS_ADDRESS="unix:path=/private/a11y")
        ),
        check=Mock(),
        close=Mock(),
    )
    monkeypatch.setattr(
        gui,
        "LinuxAccessibilitySession",
        Mock(return_value=accessibility),
        raising=False,
    )
    host = gui.InstalledDesktop(
        bundle, owned.profile, environment, owned.host.output / "linux", timeout=0.5
    )
    yield host, accessibility, owned.process
    accessibility.close.side_effect = None
    if host.process is not None:
        host.close()


def test_linux_installed_gui_uses_owned_atspi_backend(linux_owned):
    host, accessibility, _ = linux_owned
    host.start()
    assert gui.subprocess.Popen.call_args.args[0] == [
        str(host.bundle / "open-foresight")
    ]
    command = gui.subprocess.run.call_args.args[0]
    assert command == [
        sys.executable,
        str(Path(gui.__file__).with_name("linux_desktop_accessibility.py")),
        "--pid",
        "123",
        "--executable",
        str(host.executable),
        "--button",
        "",
    ]
    assert (
        gui.subprocess.run.call_args.kwargs["env"]["AT_SPI_BUS_ADDRESS"]
        == "unix:path=/private/a11y"
    )
    accessibility.check.assert_called()
    host.close()
    accessibility.close.assert_called_once()
    assert host.evidence["accessibility"]["backend"] == "linux_atspi"


def test_linux_accessibility_cleanup_failure_cannot_be_a_pass(linux_owned):
    host, accessibility, _ = linux_owned
    host.start()
    accessibility.close.side_effect = RuntimeError("Owned a11y cleanup failed")
    with pytest.raises(RuntimeError, match="a11y cleanup"):
        host.close()
    assert host.evidence["status"] == "closed_after_failure"
    assert host.log.closed


def test_linux_accessibility_cleanup_preserves_original_failure(linux_owned):
    host, accessibility, process = linux_owned
    host.start()
    process.wait.side_effect = [subprocess.TimeoutExpired("desktop", 15), -9]
    accessibility.close.side_effect = RuntimeError("Owned a11y cleanup failed")
    with pytest.raises(
        RuntimeError, match="Installed desktop required forced cleanup"
    ) as failure:
        host.close()
    assert "Owned a11y cleanup failed" in failure.value.__notes__
    assert host.evidence["status"] == "closed_after_failure"
    host.process = None


@pytest.mark.parametrize("interpreter", ["bash", "env"])
def test_linux_launcher_is_only_a_transient_identity_before_native_exec(
    linux_owned, monkeypatch, interpreter
):
    host, accessibility, _ = linux_owned
    image = {"value": Path("/usr/bin/" + interpreter).resolve()}
    monkeypatch.setattr(gui, "process_path", lambda _: image["value"])
    original_stat = Path.stat
    monkeypatch.setattr(
        Path,
        "stat",
        lambda path, *args, **kwargs: (
            SimpleNamespace(st_uid=os.geteuid())
            if str(path) == "/proc/123"
            else original_stat(path, *args, **kwargs)
        ),
    )
    argv = b"env\0bash\0" if interpreter == "env" else b"bash\0"
    reads = Mock(return_value=argv + os.fsencode(host.launcher) + b"\0")
    monkeypatch.setattr(Path, "read_bytes", reads)
    assert host._owned_launcher() is False  # No owned process exists yet.

    def exec_native(_):
        accessibility.check.assert_not_called()
        image["value"] = host.executable

    monkeypatch.setattr(gui.time, "sleep", exec_native)
    host.start()
    assert host.evidence["startup"] == "passed_actual_gui"
    accessibility.check.assert_called()
    host.close()


def test_linux_stalled_owned_launcher_is_reaped_without_accessibility(
    linux_owned, monkeypatch
):
    host, accessibility, process = linux_owned
    monkeypatch.setattr(gui, "process_path", lambda _: Path("/usr/bin/bash").resolve())
    monkeypatch.setattr(
        Path, "read_bytes", lambda _: b"bash\0" + os.fsencode(host.launcher) + b"\0"
    )
    original_stat = Path.stat
    monkeypatch.setattr(
        Path,
        "stat",
        lambda path, *args, **kwargs: (
            SimpleNamespace(st_uid=os.geteuid())
            if str(path) == "/proc/123"
            else original_stat(path, *args, **kwargs)
        ),
    )
    clock = iter([0, 1])
    monkeypatch.setattr(gui.time, "monotonic", lambda: next(clock))
    with pytest.raises(TimeoutError, match="launcher did not exec"):
        host.start()
    process.terminate.assert_called_once()
    accessibility.check.assert_not_called()
    host.process = None


@pytest.mark.parametrize(
    "arguments", [b"bash\0/another/launcher\0", b"bash\0-c\0anything\0"]
)
def test_linux_launcher_cleanup_rejects_other_interpreter_commands(
    linux_owned, monkeypatch, arguments
):
    host, _, process = linux_owned
    host.process = process
    monkeypatch.setattr(gui, "process_path", lambda _: Path("/usr/bin/bash").resolve())
    monkeypatch.setattr(Path, "read_bytes", lambda _: arguments)
    assert not host._owned_launcher()
    with pytest.raises(RuntimeError, match="process identity"):
        host.close()
    process.terminate.assert_not_called()
    host.process = None


def test_pending_launcher_requires_the_owned_effective_user(linux_owned, monkeypatch):
    host, _, process = linux_owned
    host.process = process
    monkeypatch.setattr(gui, "process_path", lambda _: Path("/usr/bin/bash").resolve())
    monkeypatch.setattr(
        Path, "read_bytes", lambda _: b"bash\0" + os.fsencode(host.launcher) + b"\0"
    )
    original_stat = Path.stat
    monkeypatch.setattr(
        Path,
        "stat",
        lambda path, *args, **kwargs: (
            SimpleNamespace(st_uid=os.geteuid() + 1)
            if str(path) == "/proc/123"
            else original_stat(path, *args, **kwargs)
        ),
    )
    assert not host._owned_launcher()
    process.terminate.assert_not_called()
    host.process = None
