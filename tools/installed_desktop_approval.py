"""Approve explicit disposable acceptance requests through the installed GUI.

The Python RPC client remains external. Only the unchanged bundled desktop owns
its approval capability. This module never reads that capability or grants OS
permissions, and refuses all capture requests.
"""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from typing import Any, BinaryIO
import math
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import time

from installed_runtime import layout, process_path, service_command
from linux_desktop_accessibility import LinuxAccessibilitySession

# These are the exact non-capture operations used by installed acceptance probes.
APPROVABLE = frozenset(
    {
        "sources.import",
        "sources.import_file",
        "labels.set",
        "graph.save",
        "preferences.set",
        "models.embedding",
        "models.generation",
        "models.register",
        "meetings.create",
        "meetings.notes",
        "meetings.transcript",
        "meetings.enhance",
    }
)
ONBOARDING = (
    "Start Foresight",
    "Skip for now",
    "Skip for now",
    "Continue",
    "Skip for now",
    "Get started",
)
SCRIPT = """on run argv
 set targetPid to item 1 of argv as integer
 set wanted to item 2 of argv
 tell application "System Events"
  if not UI elements enabled then error "OS Accessibility is unavailable for osascript; no permission was changed"
  set targetProcess to first application process whose unix id is targetPid
  set frontmost of targetProcess to true
  set observed to ""
  tell targetProcess
   repeat with targetWindow in windows
    repeat with uiElement in entire contents of targetWindow
     try
      set elementRole to role of uiElement
      set elementName to name of uiElement as text
      if elementRole is "AXStaticText" then
       try
        set observed to observed & "TEXT:" & value of uiElement & linefeed
       end try
      end if
      if elementRole is "AXButton" and enabled of uiElement then
       set observed to observed & "BUTTON:" & elementName & linefeed
       if wanted is not "" and elementName is wanted then
        perform action "AXPress" of uiElement
        return "CLICKED:" & elementName
       end if
      end if
     end try
    end repeat
   end repeat
  end tell
  return observed
 end tell
end run"""


class InstalledDesktop:
    """Owned GUI lifetime plus bounded, request-specific production UI consent."""

    def __init__(
        self, bundle, profile, environment, output, *, timeout: float = 30
    ) -> None:
        if sys.platform not in ("darwin", "linux"):
            raise RuntimeError(
                "Installed GUI approval requires Linux AT-SPI or macOS Accessibility"
            )
        self.bundle: Path = Path(bundle).resolve(strict=True)
        self.profile: Path = Path(profile).resolve(strict=True)
        self.output: Path = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("GUI timeout must be finite and positive")
        self.timeout: float = timeout
        self.process: subprocess.Popen[bytes] | None = None
        self.log: BinaryIO | None = None
        self.accessibility: LinuxAccessibilitySession | None = None
        self.evidence: dict[str, Any] = {
            "mode": "actual_installed_desktop_os_accessibility",
            "approvals": [],
            "status": "incomplete",
        }
        for path in [
            self.profile,
            *(self.profile / name for name in ("home", "data", "run")),
        ]:
            info = path.stat()
            if not path.is_dir() or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError(
                    "GUI acceptance requires private owned profile directories"
                )
        self.environment: dict[str, str] = dict(environment)
        for key, name in [
            ("HOME", "home"),
            ("FORESIGHT_DATA", "data"),
            ("FORESIGHT_RUNTIME", "run"),
        ]:
            selected = Path(self.environment.get(key, ""))
            if not selected.is_absolute() or selected.resolve() != self.profile / name:
                raise ValueError("GUI environment does not name its private profile")
        if sys.platform == "darwin":
            info = plistlib.loads((self.bundle / "Contents/Info.plist").read_bytes())
            selected = self.bundle / "Contents/MacOS" / info["CFBundleExecutable"]
            if self.bundle.suffix != ".app":
                raise ValueError("Mac GUI acceptance requires its application bundle")
        else:
            selected = self.bundle / "app/open-foresight"
            if not self.environment.get("DISPLAY") or not self.environment.get(
                "DBUS_SESSION_BUS_ADDRESS"
            ):
                raise ValueError(
                    "Linux GUI acceptance needs a display and D-Bus session"
                )
        self.executable: Path = selected.resolve(strict=True)
        if not self.executable.is_relative_to(self.bundle):
            raise ValueError("GUI executable must belong to the selected application")
        self.launcher = self.executable
        if sys.platform == "linux":
            self.launcher = (self.bundle / "open-foresight").resolve(strict=True)
            if not self.launcher.is_relative_to(self.bundle):
                raise ValueError(
                    "GUI launcher must belong to the selected installation"
                )
        with self.executable.open("rb") as stream:
            self.evidence["executable_sha256"] = hashlib.file_digest(
                stream, "sha256"
            ).hexdigest()
        self.evidence.update(executable=str(self.executable), profile=str(self.profile))

    def _save(self):
        (self.output / "gui-approval.json").write_text(
            json.dumps(self.evidence, indent=2) + "\n"
        )

    def _identity(self) -> subprocess.Popen[bytes]:
        if (
            self.process is None
            or self.process.poll() is not None
            or process_path(self.process.pid) != self.executable
        ):
            raise RuntimeError(
                "Owned installed desktop process identity is unavailable"
            )

        return self.process

    def _owned_launcher(self):
        # The product wrapper execs the native GUI in the same owned PID. A
        # pending wrapper may only be observed/cleaned up, never approve a call.
        if sys.platform != "linux" or self.process is None:
            return False
        interpreters = {Path("/usr/bin/env").resolve(), Path("/usr/bin/bash").resolve()}
        try:
            for _ in range(3):
                image = process_path(self.process.pid)
                if image not in interpreters:
                    return False
                arguments = (
                    Path(f"/proc/{self.process.pid}/cmdline").read_bytes().split(b"\0")
                )
                uid = Path(f"/proc/{self.process.pid}").stat().st_uid
                current_image = process_path(self.process.pid)
                self.evidence["launcher_observation"] = {
                    "image": str(image),
                    "current_image": str(current_image),
                    "uid": uid,
                    "argv": [os.fsdecode(arg) for arg in arguments[:4]],
                }
                # /proc image and argv are separate reads. Retry a real exec
                # transition instead of combining observations from two images.
                if current_image != image:
                    continue
                if uid != os.geteuid() or arguments[-1] != b"":
                    return False
                arguments.pop()
                if image == Path("/usr/bin/env").resolve():
                    if len(arguments) != 3 or arguments[1] != b"bash":
                        return False
                elif len(arguments) != 2:
                    return False
                return Path(os.fsdecode(arguments[-1])).resolve() == self.launcher
            return False
        except OSError:
            return False

    def _ui(self, button="", *, reveal=False):
        process = self._identity()
        if self.accessibility is not None:
            self.accessibility.check()
        command = (
            ["/usr/bin/osascript", "-e", SCRIPT, str(process.pid), button]
            if sys.platform == "darwin"
            else [
                sys.executable,
                str(Path(__file__).with_name("linux_desktop_accessibility.py")),
                "--pid",
                str(process.pid),
                "--executable",
                str(self.executable),
                "--button",
                button,
            ]
        )
        if reveal:
            if sys.platform != "linux":
                raise ValueError("This platform does not use onboarding reveal actions")
            command.append("--reveal")
        result = subprocess.run(
            command,
            env=self.environment if sys.platform == "linux" else None,
            capture_output=True,
            text=True,
            timeout=min(5, self.timeout),
        )
        if result.returncode:
            self.evidence["accessibility_error"] = result.stderr
            self.evidence["accessibility_stdout"] = result.stdout
            self._save()
            raise RuntimeError(
                "Production GUI automation unavailable: " + result.stderr.strip()
            )
        return result.stdout.strip()

    def start(self):
        if self.process is not None:
            raise RuntimeError("Installed desktop already started")
        self.log = (self.output / "desktop.log").open("wb")
        try:
            if sys.platform == "linux":
                self.accessibility = LinuxAccessibilitySession(
                    self.profile, self.environment, self.output, self.timeout
                )
                self.evidence["accessibility"] = self.accessibility.evidence
                self.environment = self.accessibility.start()
            self.process = subprocess.Popen(
                [str(self.launcher)],
                cwd="/",
                env=self.environment,
                stdout=self.log,
                stderr=subprocess.STDOUT,
            )
            self.evidence["pid"] = self.process.pid
            deadline = time.monotonic() + self.timeout
            if sys.platform == "linux":
                while process_path(self.process.pid) != self.executable:
                    if self.process.poll() is not None or not self._owned_launcher():
                        self._identity()
                    if time.monotonic() >= deadline:
                        raise TimeoutError(
                            "Installed launcher did not exec its native GUI"
                        )
                    time.sleep(0.01)
            while not (self.profile / "run/commands.sock").exists():
                self._identity()
                if time.monotonic() >= deadline:
                    raise TimeoutError("Installed desktop startup timed out")
                time.sleep(0.05)
            while True:
                self._identity()
                try:
                    state = service_command(
                        layout(self.bundle)[1], self.environment, "--status"
                    )
                    break
                except subprocess.CalledProcessError as error:
                    self.evidence.setdefault("service_startup_errors", []).append(
                        {
                            "returncode": error.returncode,
                            "stdout": error.stdout or "",
                            "stderr": error.stderr or "",
                        }
                    )
                    if time.monotonic() >= deadline:
                        raise TimeoutError(
                            "Installed desktop did not establish its service: "
                            + (error.stderr or "")
                        ) from None
                    time.sleep(0.05)
            expected_profile = hashlib.sha256(
                str(self.profile / "data").encode()
            ).hexdigest()[:24]
            if (
                state.get("installation_root") != str(self.bundle)
                or state.get("profile_id") != expected_profile
            ):
                raise RuntimeError(
                    "GUI service does not belong to the selected installation/profile"
                )
            self.evidence["service_pid"] = state["pid"]
            # Read-only observations acknowledge the real UI's own service writes.
            # No database write or production hook seeds/skips onboarding.
            clicked_step = None
            while True:
                snapshot = self._ui()
                with closing(
                    sqlite3.connect(
                        (self.profile / "data/application.db").as_uri() + "?mode=ro",
                        uri=True,
                    )
                ) as database:
                    preferences = dict(
                        database.execute(
                            "SELECT key,value FROM preferences WHERE key IN ('onboarding.step','onboarding.complete')"
                        )
                    )
                complete = preferences.get("onboarding.complete") == "true"
                visible = set(snapshot.splitlines())
                if complete and all(
                    "BUTTON:" + title in visible or "TEXT:" + title in visible
                    for title in ("Sources", "Settings")
                ):
                    break
                if not complete:
                    step = int(preferences.get("onboarding.step", "0"))
                    if step not in range(len(ONBOARDING)):
                        raise RuntimeError("Invalid observed onboarding step")
                    button = ONBOARDING[step]
                    if step != clicked_step and "BUTTON:" + button in visible:
                        if self._ui(button) == "CLICKED:" + button:
                            clicked_step = step
                    elif step != clicked_step and sys.platform == "linux":
                        self._ui(button, reveal=True)
                if time.monotonic() >= deadline:
                    raise TimeoutError("Installed desktop onboarding timed out")
                time.sleep(0.1)
            self.evidence["startup"] = "passed_actual_gui"
            self._save()
            return self
        except BaseException as error:
            self.evidence["failure"] = str(error)
            try:
                self.close()
            except Exception as cleanup_error:
                error.add_note("Owned GUI cleanup: " + str(cleanup_error))
            raise

    def call(self, peer, method, args=None):
        args = args or {}
        if method not in APPROVABLE or (
            method == "models.register"
            and args.get("kind") not in ("embedding", "generation", "speech")
        ):
            raise ValueError(
                "GUI automation refuses this operation, including all capture requests: "
                + method
            )
        if method == "preferences.set" and args.get("key") not in (
            "importRoots",
            "liveEnhance",
            "proactiveAnswers",
        ):
            raise ValueError("GUI automation refuses arbitrary application preferences")
        if method == "preferences.set" and args.get("key") == "importRoots":
            roots = json.loads(args.get("value", "null"))
            if (
                not isinstance(roots, list)
                or not roots
                or any(
                    not isinstance(root, str)
                    or not Path(root).resolve(strict=True).is_relative_to(self.profile)
                    for root in roots
                )
            ):
                raise ValueError(
                    "Import approval roots must be disposable fixture directories"
                )
        if "BUTTON:Allow once" in self._ui().splitlines():
            raise RuntimeError("Refusing a pre-existing approval dialog")
        row = {
            "method": method,
            "arguments_sha256": hashlib.sha256(
                json.dumps(args, sort_keys=True).encode()
            ).hexdigest(),
            "clicked": False,
        }
        self.evidence["approvals"].append(row)
        executor = ThreadPoolExecutor(max_workers=1)
        future = executor.submit(peer.call, method, args)
        deadline = time.monotonic() + self.timeout
        try:
            while not future.done():
                snapshot = self._ui()
                if "Allow microphone and system audio recording?" in snapshot:
                    raise RuntimeError(
                        "GUI automation refuses a capture approval dialog"
                    )
                if not row["clicked"] and "BUTTON:Allow once" in snapshot.splitlines():
                    row["dialog_snapshot"] = snapshot[:8192]
                    row["clicked"] = self._ui("Allow once") == "CLICKED:Allow once"
                if time.monotonic() >= deadline:
                    raise TimeoutError(
                        "Installed GUI approval/request timed out: " + method
                    )
                time.sleep(0.05)
            try:
                result = future.result()
            finally:
                original = sys.exception()
                if row["clicked"]:
                    try:
                        while True:
                            if time.monotonic() >= deadline:
                                raise TimeoutError(
                                    "Clicked approval dialog did not close before deadline"
                                )
                            if "BUTTON:Allow once" not in self._ui().splitlines():
                                row["dialog_closed"] = True
                                break
                            time.sleep(0.05)
                    except Exception as error:
                        row["dialog_settlement_error"] = str(error)
                        if original is None:
                            raise
                        original.add_note("Approval dialog settlement: " + str(error))
            if not row["clicked"]:
                raise RuntimeError(
                    "Installed request completed without observed production GUI consent: "
                    + method
                )
            row["status"] = "passed_actual_gui_consent"
            return result
        except BaseException as error:
            row["status"] = "failed"
            row["error"] = str(error)
            self.evidence["failure"] = str(error)
            raise
        finally:
            if not future.done():
                peer.close()  # RPC close shuts down the socket before reader.close.
                try:
                    future.result(timeout=2)
                except TimeoutError:
                    self.evidence["cleanup_error"] = (
                        "RPC worker did not stop after socket shutdown"
                    )
                    raise RuntimeError(self.evidence["cleanup_error"]) from None
                except Exception as error:
                    self.evidence["cancelled_rpc_error"] = str(error)
            executor.shutdown(wait=False, cancel_futures=True)
            self._save()

    def close(self):
        try:
            if self.process is not None and self.process.poll() is None:
                if not self._owned_launcher():
                    self._identity()
                self.process.terminate()
                try:
                    self.evidence["exit"] = self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.evidence["exit"] = self.process.wait(timeout=15)
                    raise RuntimeError(
                        "Installed desktop required forced cleanup"
                    ) from None
            self.evidence["status"] = (
                "closed_after_failure" if "failure" in self.evidence else "closed"
            )
        finally:
            original = sys.exception()
            try:
                if self.accessibility is not None:
                    self.accessibility.close()
            except Exception as error:
                self.evidence["accessibility_cleanup_error"] = str(error)
                self.evidence.setdefault("failure", str(error))
                self.evidence["status"] = "closed_after_failure"
                if original is not None:
                    original.add_note(str(error))
                else:
                    raise
            finally:
                if self.log is not None:
                    self.log.close()
                self._save()


class ApprovedApplicationPeer:
    """An external RPC client whose writes receive real production GUI consent."""

    def __init__(self, endpoint, desktop):
        from smoke_macos_bundle import ApplicationPeer

        self.peer = ApplicationPeer(endpoint)
        self.desktop = desktop

    @property
    def socket(self):
        return self.peer.socket

    def call(self, method, args=None):
        if method.startswith("security.") or method in (
            "meetings.start",
            "meetings.resume",
        ):
            raise ValueError(
                "Installed acceptance cannot impersonate the desktop or approve capture"
            )
        if method in APPROVABLE:
            return self.desktop.call(self.peer, method, args)
        if method not in {
            "status",
            "sources.list",
            "sources.get",
            "meetings.get",
            "answer",
        } or (args or {}).get("web_search"):
            raise ValueError(
                "Installed acceptance has no GUI approval policy for " + method
            )
        return self.peer.call(method, args)

    def allow_import_root(self, path):
        # This is a separately visible approval of the public preference command,
        # not an impersonated host-only security.allow_import_root RPC.
        return self.call(
            "preferences.set",
            {
                "key": "importRoots",
                "value": json.dumps([str(Path(path).resolve(strict=True))]),
            },
        )

    def close(self):
        self.peer.close()
