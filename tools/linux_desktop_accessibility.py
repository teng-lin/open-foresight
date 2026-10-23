"""Bounded AT-SPI observations/actions for one owned installed Linux desktop.

Run in a short-lived subprocess: libatspi's D-Bus calls and the entire traversal
remain bounded by the parent's subprocess timeout, including library failures.
Only public accessibility actions are used; no application capability is read.
"""

import argparse
import ctypes
import os
from pathlib import Path
import subprocess
import time
from typing import Any, BinaryIO

from installed_runtime import process_path

BUTTONS = frozenset(
    {"Start Foresight", "Skip for now", "Continue", "Get started", "Allow once"}
)
CAPTURE = "Allow microphone and system audio recording?"
MAX_NODES = 2048


class LinuxAccessibilitySession:
    """Own an accessibility bus/registry without relying on a user session daemon."""

    def __init__(self, profile, environment, output, timeout):
        self.profile, self.output, self.timeout = profile, output, timeout
        self.environment = dict(environment)
        self.children: list[tuple[subprocess.Popen[bytes], Path, dict[str, Any]]] = []
        self.logs: list[BinaryIO] = []
        self.evidence: dict[str, Any] = {"backend": "linux_atspi", "children": []}

    def _start(self, executable, arguments, environment, name):
        executable = executable.resolve(strict=True)
        log = (self.output / f"accessibility-{name}.log").open("wb")
        self.logs.append(log)
        child = subprocess.Popen(
            [str(executable), *arguments],
            cwd="/",
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        row = {"pid": child.pid, "executable": str(executable)}
        self.children.append((child, executable, row))
        self.evidence["children"].append(row)
        return child

    def start(self):
        registry = next(
            (
                path
                for path in (
                    Path("/usr/libexec/at-spi2-registryd"),
                    Path("/usr/lib/at-spi2-registryd"),
                    Path("/usr/lib/at-spi2-core/at-spi2-registryd"),
                )
                if path.is_file()
            ),
            None,
        )
        if registry is None:
            raise RuntimeError("Installed Linux GUI acceptance requires at-spi2-core")
        socket = self.profile / "run/accessibility.sock"
        self.environment.update(
            AT_SPI_BUS_ADDRESS=f"unix:path={socket}",
            NO_AT_BRIDGE="0",
            XDG_CONFIG_HOME=str(self.profile / "home/.config"),
            XDG_DATA_HOME=str(self.profile / "home/.local/share"),
            XDG_RUNTIME_DIR=str(self.profile / "run"),
        )
        # GTK3 already supplies its accessibility bridge. Explicitly loading it
        # a second time registers duplicate trees on some supported desktops.
        self.environment.pop("GTK_MODULES", None)
        bus = self._start(
            Path("/usr/bin/dbus-daemon"),
            ["--session", "--nofork", f"--address=unix:path={socket}"],
            self.environment,
            "bus",
        )
        deadline = time.monotonic() + min(5, self.timeout)
        while not socket.exists():
            if bus.poll() is not None:
                raise RuntimeError("Private accessibility bus exited; inspect its log")
            if time.monotonic() >= deadline:
                raise TimeoutError("Private accessibility bus did not start")
            time.sleep(0.01)
        self._start(registry, [], self.environment, "registry")
        return self.environment

    def close(self):
        errors = []
        try:
            for child, executable, row in reversed(self.children):
                try:
                    if "exit" in row:
                        continue
                    if child.poll() is None:
                        if process_path(child.pid) != executable:
                            raise RuntimeError(
                                "Refusing unrelated accessibility process identity"
                            )
                        child.terminate()
                        try:
                            row["exit"] = child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            row["exit"] = child.wait(timeout=5)
                            raise RuntimeError(
                                "Private accessibility process required forced cleanup"
                            ) from None
                    else:
                        row["exit"] = child.returncode
                except Exception as error:
                    row["cleanup_error"] = str(error)
                    errors.append(str(error))
        finally:
            for log in self.logs:
                log.close()
        if errors:
            raise RuntimeError("; ".join(errors))

    def check(self):
        for child, executable, _ in self.children:
            if child.poll() is not None or process_path(child.pid) != executable:
                raise RuntimeError("Owned private accessibility process is unavailable")


class _GError(ctypes.Structure):
    _fields_ = [
        ("domain", ctypes.c_uint),
        ("code", ctypes.c_int),
        ("message", ctypes.c_char_p),
    ]


class AtSpi:
    """Minimal standard libatspi ABI; returned objects/strings are released."""

    def __init__(self):
        self.atspi = ctypes.CDLL("libatspi.so.0")
        self.glib = ctypes.CDLL("libglib-2.0.so.0")
        self.gobject = ctypes.CDLL("libgobject-2.0.so.0")
        pointer, integer = ctypes.c_void_p, ctypes.c_int
        error = ctypes.POINTER(pointer)
        definitions = {
            "atspi_init": (integer, []),
            "atspi_exit": (integer, []),
            "atspi_set_timeout": (None, [integer, integer]),
            "atspi_get_desktop": (pointer, [integer]),
            "atspi_accessible_get_process_id": (ctypes.c_uint, [pointer, error]),
            "atspi_accessible_get_name": (pointer, [pointer, error]),
            "atspi_accessible_get_role_name": (pointer, [pointer, error]),
            "atspi_accessible_get_child_count": (integer, [pointer, error]),
            "atspi_accessible_get_child_at_index": (pointer, [pointer, integer, error]),
            "atspi_accessible_get_state_set": (pointer, [pointer]),
            "atspi_state_set_contains": (integer, [pointer, integer]),
            "atspi_accessible_get_text_iface": (pointer, [pointer]),
            "atspi_text_get_character_count": (integer, [pointer, error]),
            "atspi_text_get_text": (pointer, [pointer, integer, integer, error]),
            "atspi_accessible_get_action_iface": (pointer, [pointer]),
            "atspi_action_get_n_actions": (integer, [pointer, error]),
            "atspi_action_get_action_name": (pointer, [pointer, integer, error]),
            "atspi_action_do_action": (integer, [pointer, integer, error]),
        }
        for name, (result, arguments) in definitions.items():
            function = getattr(self.atspi, name)
            function.restype = result
            function.argtypes = arguments
        self.glib.g_free.argtypes = [pointer]
        self.glib.g_free.restype = None
        self.glib.g_error_free.argtypes = [pointer]
        self.glib.g_error_free.restype = None
        self.gobject.g_object_unref.argtypes = [pointer]
        self.gobject.g_object_unref.restype = None
        self.atspi.atspi_set_timeout(1000, 2000)
        if self.atspi.atspi_init() != 0:
            raise RuntimeError("Cannot initialize the private session AT-SPI bus")

    def checked(self, name, *arguments):
        error = ctypes.c_void_p()
        result = getattr(self.atspi, name)(*arguments, ctypes.byref(error))
        if error.value:
            details = ctypes.cast(error, ctypes.POINTER(_GError)).contents
            message = (details.message or b"Unknown AT-SPI error").decode(
                "utf-8", errors="replace"
            )
            self.glib.g_error_free(error)
            raise RuntimeError(f"{name}: {message}")
        return result

    def text(self, name, *arguments):
        value = self.checked(name, *arguments)
        if not value:
            return ""
        try:
            return ctypes.string_at(value).decode("utf-8", errors="replace")
        finally:
            self.glib.g_free(value)

    def content(self, node):
        text = self.atspi.atspi_accessible_get_text_iface(node)
        try:
            if not text:
                return ""
            count = self.checked("atspi_text_get_character_count", text)
            if count < 0 or count > 65536:
                raise RuntimeError("Invalid or excessive AT-SPI text length")
            return self.text("atspi_text_get_text", text, 0, count)
        finally:
            self.release(text)

    def release(self, value):
        if value:
            self.gobject.g_object_unref(value)

    def children(self, node):
        count = self.checked("atspi_accessible_get_child_count", node)
        if count < 0 or count > MAX_NODES:
            raise RuntimeError("Invalid or excessive AT-SPI child count")
        children = []
        try:
            for index in range(count):
                child = self.checked("atspi_accessible_get_child_at_index", node, index)
                if child:
                    children.append(child)
            return children
        except BaseException:
            for child in children:
                self.release(child)
            raise

    def state(self, node):
        states = self.atspi.atspi_accessible_get_state_set(node)
        try:
            return {
                value
                for value in (8, 24, 25, 30)  # enabled, sensitive, showing, visible
                if states and self.atspi.atspi_state_set_contains(states, value)
            }
        finally:
            self.release(states)

    def _action(self, node, allowed):
        action = self.atspi.atspi_accessible_get_action_iface(node)
        try:
            if action:
                count = self.checked("atspi_action_get_n_actions", action)
                for index in range(min(count, 16)):
                    name = self.text("atspi_action_get_action_name", action, index)
                    if name.lower() in allowed:
                        return bool(
                            self.checked("atspi_action_do_action", action, index)
                        )
            return None
        finally:
            self.release(action)

    def press(self, node):
        return bool(self._action(node, {"click", "press", "activate", "tap"}))

    def scroll_up(self, node):
        return self._action(node, {"scrollup"})

    def close(self):
        self.atspi.atspi_exit()


def identity(pid, executable):
    try:
        valid = (
            pid > 0
            and Path(f"/proc/{pid}").stat().st_uid == os.getuid()
            and process_path(pid) == executable
        )
    except OSError:
        valid = False
    if not valid:
        raise RuntimeError("Owned installed desktop process identity is unavailable")


def observe(api, pid, executable, button="", *, reveal=False, expected_snapshot=None):
    if button and button not in BUTTONS:
        raise ValueError("Unsupported production GUI automation button")
    if reveal and (not button or button == "Allow once"):
        raise ValueError("Only onboarding controls can be revealed")
    identity(pid, executable)
    desktop = api.atspi.atspi_get_desktop(0)
    if not desktop:
        raise RuntimeError("AT-SPI registry did not expose a desktop")
    pending: list[tuple[Any, tuple[Any, ...]]] = []
    retained = []
    lines = []
    candidates = []
    targets = []
    try:
        applications = api.children(desktop)
        retained.extend(applications)
        for application in applications:
            if api.checked("atspi_accessible_get_process_id", application) == pid:
                pending.extend((child, ()) for child in api.children(application))
        visited = set()
        while pending:
            node, ancestors = pending.pop()
            retained.append(node)
            if node in visited:
                continue
            visited.add(node)
            if len(visited) > MAX_NODES:
                raise RuntimeError("Installed desktop accessibility tree is too large")
            states = api.state(node)
            name = api.text("atspi_accessible_get_name", node)
            role = api.text("atspi_accessible_get_role_name", node)
            if not name and 25 in states and 30 in states:
                name = api.content(node)
            enabled_button = role in {"push button", "button"} and {8, 24} <= states
            if enabled_button and name == button:
                targets.append((node, ancestors))
            if 25 in states and 30 in states:
                if name:
                    label = name.replace("\r", "\\r").replace("\n", "\\n")
                    lines.append(("BUTTON:" if enabled_button else "TEXT:") + label)
                    if enabled_button and name == button:
                        candidates.append(node)
            pending.extend((child, (*ancestors, node)) for child in api.children(node))
            if len(pending) + len(visited) > MAX_NODES:
                raise RuntimeError("Installed desktop accessibility tree is too large")
        snapshot = "\n".join(lines)
        if button:
            if expected_snapshot is not None and snapshot != expected_snapshot:
                raise RuntimeError("Production approval dialog changed before action")
            if CAPTURE in snapshot:
                raise RuntimeError("GUI automation refuses a capture approval dialog")
            if reveal:
                if len(targets) > 1:
                    raise RuntimeError("Refusing ambiguous onboarding controls")
                if targets and not candidates:
                    for ancestor in reversed(targets[0][1]):
                        identity(pid, executable)
                        scrolled = api.scroll_up(ancestor)
                        if scrolled is True:
                            return "SCROLLED:" + button
                        if scrolled is False:
                            raise RuntimeError(
                                "Onboarding accessibility scroll was refused"
                            )
                return snapshot
            if len(candidates) > 1:
                raise RuntimeError("Refusing ambiguous installed desktop buttons")
            if candidates:
                identity(pid, executable)
                if api.press(candidates[0]):
                    return "CLICKED:" + button
                raise RuntimeError("Installed accessibility action was refused")
        return snapshot
    finally:
        for node in [*(node for node, _ in pending), *retained, desktop]:
            api.release(node)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--button", default="")
    parser.add_argument("--reveal", action="store_true")
    parser.add_argument("--expected-snapshot")
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    api = AtSpi()
    try:
        print(
            observe(
                api,
                args.pid,
                executable,
                args.button,
                reveal=args.reveal,
                expected_snapshot=args.expected_snapshot,
            )
        )
    finally:
        api.close()


if __name__ == "__main__":
    main()
