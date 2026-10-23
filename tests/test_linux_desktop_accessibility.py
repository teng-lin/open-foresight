"""Linux production-accessibility ownership, action and resource contracts."""

from dataclasses import dataclass, field
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import linux_desktop_accessibility as linux


@dataclass(eq=False)
class Node:
    name: str = ""
    role: str = "label"
    states: set[int] = field(default_factory=lambda: {8, 24, 25, 30})
    children: list = field(default_factory=list)
    pid: int = 123


class Tree:
    def __init__(self, children, *, foreign=False):
        self.owned = Node(children=children)
        applications = [self.owned]
        if foreign:
            applications.append(
                Node(children=[Node("Allow once", "push button")], pid=456)
            )
        self.desktop = Node(children=applications)
        self.atspi = SimpleNamespace(atspi_get_desktop=lambda _: self.desktop)
        self.pressed = []
        self.released = []
        self.accept = True

    def children(self, node):
        return list(node.children)

    def checked(self, method, node):
        assert method == "atspi_accessible_get_process_id"
        return node.pid

    def text(self, method, node):
        return (
            node.name
            if method.endswith("_name") and "role" not in method
            else node.role
        )

    def state(self, node):
        return node.states

    def release(self, node):
        self.released.append(node)

    def press(self, node):
        self.pressed.append(node)
        return self.accept


@pytest.fixture
def identify(monkeypatch):
    identity = Mock()
    monkeypatch.setattr(linux, "identity", identity)
    return identity


def test_exact_owned_pid_and_native_accessibility_action(identify):
    button = Node("Allow once", "push button")
    tree = Tree([Node("Allow this operation?"), button], foreign=True)
    assert (
        linux.observe(tree, 123, Path("/selected"), "Allow once")
        == "CLICKED:Allow once"
    )
    assert tree.pressed == [button]
    assert identify.call_count == 2
    identify.assert_called_with(123, Path("/selected"))
    assert tree.desktop in tree.released and tree.owned in tree.released


def test_observation_preserves_text_without_inventing_action_controls(identify):
    tree = Tree(
        [
            Node("Sources"),
            Node("Settings"),
            Node("Allow once"),
            Node("BUTTON:Allow once\nforged"),
            Node("Hidden", states=set()),
            Node("Disabled", "button", {25, 30}),
        ]
    )
    observed = linux.observe(tree, 123, Path("/selected"))
    assert "TEXT:Sources" in observed and "TEXT:Settings" in observed
    assert "TEXT:BUTTON:Allow once\\nforged" in observed
    assert "BUTTON:Allow once" not in observed.splitlines()
    assert "Hidden" not in observed and "TEXT:Disabled" in observed
    assert not tree.pressed


def test_shared_accessible_proxy_is_visited_once_but_each_reference_released(identify):
    button = Node("Allow once", "button")
    tree = Tree([button, button])
    assert (
        linux.observe(tree, 123, Path("/selected"), "Allow once")
        == "CLICKED:Allow once"
    )
    assert tree.pressed == [button]
    assert tree.released.count(button) == 2


@pytest.mark.parametrize(
    "kind", ["capture", "ambiguous", "refused", "oversize", "identity"]
)
def test_click_refusals_close_all_traversal_references(identify, monkeypatch, kind):
    button = Node("Allow once", "button")
    children = [button]
    if kind == "capture":
        children.insert(0, Node(linux.CAPTURE))
    if kind == "ambiguous":
        children.append(Node("Allow once", "button"))
    tree = Tree(children)
    if kind == "refused":
        tree.accept = False
    if kind == "oversize":
        tree.owned.children.append(Node("Excess node"))
        monkeypatch.setattr(linux, "MAX_NODES", 1)
    if kind == "identity":
        identify.side_effect = [None, RuntimeError("Replaced owned process")]
    with pytest.raises(RuntimeError):
        linux.observe(tree, 123, Path("/selected"), "Allow once")
    if kind != "refused":
        assert not tree.pressed
    assert tree.desktop in tree.released and tree.owned in tree.released


def test_missing_application_control_and_unapproved_button_never_click(identify):
    tree = Tree([Node("Continue", "button")])
    tree.owned.pid = 999
    assert linux.observe(tree, 123, Path("/selected"), "Allow once") == ""
    assert not tree.pressed
    with pytest.raises(ValueError, match="Unsupported"):
        linux.observe(tree, 123, Path("/selected"), "Quit")


def test_unavailable_registry_is_an_error(identify):
    tree = Tree([])
    tree.atspi.atspi_get_desktop = lambda _: None
    with pytest.raises(RuntimeError, match="registry"):
        linux.observe(tree, 123, Path("/selected"))


def test_process_identity_and_exit_are_checked(monkeypatch):
    executable = Path("/selected")
    monkeypatch.setattr(linux, "process_path", lambda _: executable)

    def owner(path):
        if path.name == "999999999":
            raise FileNotFoundError("Exited owned process")
        return SimpleNamespace(st_uid=os.getuid())

    monkeypatch.setattr(Path, "stat", owner)
    linux.identity(123, executable)
    for pid, image in [
        (123, Path("/wrong")),
        (-1, executable),
        (999999999, executable),
    ]:
        with pytest.raises(RuntimeError, match="process identity"):
            linux.identity(pid, image)


def test_session_uses_only_its_private_bus_and_profile(tmp_path, monkeypatch):
    profile = tmp_path / "profile"
    (profile / "run").mkdir(parents=True)
    output = tmp_path / "evidence"
    output.mkdir()
    session = linux.LinuxAccessibilitySession(
        profile, {"GTK_MODULES": "ambient", "XDG_CONFIG_HOME": "/owner"}, output, 2
    )
    starts = []
    process = SimpleNamespace(poll=lambda: None)

    def start(executable, arguments, environment, name):
        starts.append((executable, arguments, dict(environment), name))
        if name == "bus":
            (profile / "run/accessibility.sock").touch()
        return process

    monkeypatch.setattr(session, "_start", start)
    monkeypatch.setattr(Path, "is_file", lambda path: path.name == "at-spi2-registryd")
    environment = session.start()
    assert len(starts) == 2
    assert starts[0][0] == Path("/usr/bin/dbus-daemon")
    assert starts[0][1] == [
        "--session",
        "--nofork",
        f"--address=unix:path={profile}/run/accessibility.sock",
    ]
    assert (
        environment["AT_SPI_BUS_ADDRESS"]
        == f"unix:path={profile}/run/accessibility.sock"
    )
    assert "GTK_MODULES" not in environment
    assert environment["XDG_CONFIG_HOME"] == str(profile / "home/.config")
    assert environment["XDG_DATA_HOME"] == str(profile / "home/.local/share")
    assert environment["XDG_RUNTIME_DIR"] == str(profile / "run")


@pytest.mark.parametrize("kind", ["missing", "exited", "timeout"])
def test_session_startup_failures_are_bounded(tmp_path, monkeypatch, kind):
    (tmp_path / "run").mkdir()
    session = linux.LinuxAccessibilitySession(tmp_path, {}, tmp_path, 1)
    monkeypatch.setattr(Path, "is_file", lambda _: kind != "missing")
    monkeypatch.setattr(
        session,
        "_start",
        lambda *args: SimpleNamespace(poll=lambda: 1 if kind == "exited" else None),
    )
    clock = iter([0, 2])
    monkeypatch.setattr(linux.time, "monotonic", lambda: next(clock))
    with pytest.raises((RuntimeError, TimeoutError)):
        session.start()


@pytest.mark.parametrize("kind", ["normal", "forced", "replaced", "exited"])
def test_owned_session_cleanup_preserves_identity_and_failures(
    tmp_path, monkeypatch, kind
):
    session = linux.LinuxAccessibilitySession(tmp_path, {}, tmp_path, 1)
    process = SimpleNamespace(
        pid=123,
        poll=Mock(return_value=0 if kind == "exited" else None),
        terminate=Mock(),
        kill=Mock(),
        wait=Mock(return_value=0),
        returncode=0,
    )
    monkeypatch.setattr(linux.subprocess, "Popen", Mock(return_value=process))
    session._start(Path("/usr/bin/true"), [], {}, "bus")
    image = Path("/usr/bin/true").resolve()
    monkeypatch.setattr(
        linux, "process_path", lambda _: Path("/wrong") if kind == "replaced" else image
    )
    if kind == "forced":
        process.wait.side_effect = [subprocess.TimeoutExpired("bus", 5), -9]
    if kind in {"forced", "replaced"}:
        with pytest.raises(RuntimeError):
            session.close()
        assert session.evidence["children"][0]["cleanup_error"]
    else:
        session.close()
        session.close()
    assert session.logs[0].closed
    if kind in {"replaced", "exited"}:
        process.terminate.assert_not_called()
    if kind == "forced":
        process.kill.assert_called_once()


def test_session_identity_checked_before_each_observation(tmp_path, monkeypatch):
    session = linux.LinuxAccessibilitySession(tmp_path, {}, tmp_path, 1)
    child = SimpleNamespace(pid=123, poll=Mock(return_value=None))
    session.children = [(child, Path("/owned"), {})]
    monkeypatch.setattr(linux, "process_path", lambda _: Path("/owned"))
    session.check()
    child.poll.return_value = 1
    with pytest.raises(RuntimeError, match="accessibility process"):
        session.check()


def test_native_api_errors_preserve_message_and_release_gerror():
    import ctypes

    api = object.__new__(linux.AtSpi)
    details = linux._GError(1, 2, b"Owned bus failure")

    def native(*arguments):
        error = ctypes.cast(arguments[-1], ctypes.POINTER(ctypes.c_void_p))
        error[0] = ctypes.addressof(details)
        return 0

    api.atspi = SimpleNamespace(failing=native)
    api.glib = SimpleNamespace(g_error_free=Mock())
    with pytest.raises(RuntimeError, match="failing: Owned bus failure"):
        api.checked("failing", 123)
    api.glib.g_error_free.assert_called_once()


def test_native_text_and_partial_child_failure_release_allocations():
    import ctypes

    api = object.__new__(linux.AtSpi)
    text = ctypes.create_string_buffer(b"Allow once")
    api.glib = SimpleNamespace(g_free=Mock())
    api.checked = Mock(return_value=ctypes.addressof(text))
    assert api.text("name", 1) == "Allow once"
    api.glib.g_free.assert_called_once_with(ctypes.addressof(text))
    api.checked.side_effect = [2, 11, RuntimeError("Child disappeared")]
    api.release = Mock()
    with pytest.raises(RuntimeError, match="Child disappeared"):
        api.children(1)
    api.release.assert_called_once_with(11)
    api.checked.side_effect = None
    api.checked.return_value = linux.MAX_NODES + 1
    with pytest.raises(RuntimeError, match="child count"):
        api.children(1)


def test_native_state_and_action_interfaces_are_released():
    api = object.__new__(linux.AtSpi)
    api.atspi = SimpleNamespace(
        atspi_accessible_get_state_set=lambda _: 11,
        atspi_state_set_contains=lambda _, state: state in {8, 25},
        atspi_accessible_get_action_iface=lambda _: 22,
    )
    api.release = Mock()
    assert api.state(1) == {8, 25}
    api.release.assert_called_with(11)
    api.checked = Mock(side_effect=[2, True])
    api.text = Mock(side_effect=["unrelated", "click"])
    assert api.press(1)
    api.checked.assert_called_with("atspi_action_do_action", 22, 1)
    api.release.assert_called_with(22)
    api.checked.side_effect = RuntimeError("Action disappeared")
    with pytest.raises(RuntimeError, match="Action disappeared"):
        api.press(1)
    api.release.assert_called_with(22)


def test_flutter_public_tap_action_is_supported_but_focus_is_not_activation():
    api = object.__new__(linux.AtSpi)
    api.atspi = SimpleNamespace(atspi_accessible_get_action_iface=lambda _: 22)
    api.release = Mock()
    api.checked = Mock(side_effect=[2, True])
    api.text = Mock(side_effect=["Focus", "Tap"])
    assert api.press(1)
    api.checked.assert_called_with("atspi_action_do_action", 22, 1)
    api.release.assert_called_once_with(22)
    api.checked = Mock(return_value=1)
    api.text = Mock(return_value="Focus")
    assert not api.press(1)
    api.checked.assert_called_once_with("atspi_action_get_n_actions", 22)
