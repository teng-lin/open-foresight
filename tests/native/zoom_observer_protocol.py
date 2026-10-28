"""Drive the built zoom_observer_macos helper end to end, with no Zoom running.

Usage: zoom_observer_protocol.py HELPER ABSENT_HELPER NATIVE_SOURCE_DIR

HELPER is the production executable. ABSENT_HELPER is the same source built
with a bundle identifier no application owns, so "Zoom is not running" holds
even on a machine that is running Zoom. The test never sends `setup` (it would
raise the system Accessibility prompt) and never reads a real meeting.
"""

from __future__ import annotations

import json
from pathlib import Path
import selectors
import subprocess
import sys
import time
import unittest

HELPER = Path()
ABSENT = Path()
SOURCE = Path()
MAX_LINE = 262144
READ_TIMEOUT = 10.0


class Helper:
    """One helper process with framed reads under explicit deadlines."""

    def __init__(self, executable: Path, *arguments: str) -> None:
        self.process = subprocess.Popen(
            [str(executable), *(arguments or ("--protocol", "1"))],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert self.process.stdout is not None
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.out_seq = 0
        self.in_seq = 0
        self.eof = False

    def send_raw(self, data: bytes) -> None:
        assert self.process.stdin is not None
        try:
            self.process.stdin.write(data)
            self.process.stdin.flush()
        except BrokenPipeError:
            pass  # the helper may already have closed the session

    def send(self, **request: object) -> None:
        frame = {"v": 1, "seq": self.out_seq, **request}
        self.out_seq += 1
        self.send_raw(json.dumps(frame).encode() + b"\n")

    def close_stdin(self) -> None:
        assert self.process.stdin is not None
        self.process.stdin.close()

    def read(self, timeout: float = READ_TIMEOUT) -> dict | None:
        """Next frame, or None on timeout or end of stream."""
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if self.eof or remaining <= 0:
                return None
            if not self.selector.select(remaining):
                return None
            assert self.process.stdout is not None
            chunk = self.process.stdout.raw.read(65536)  # type: ignore[attr-defined]
            if not chunk:
                self.eof = True
                return None
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        frame = json.loads(line)
        assert frame["v"] == 1
        assert frame["seq"] == self.in_seq, frame
        self.in_seq += 1
        return frame

    def drain(self, timeout: float = 5.0) -> bytes:
        """Everything left on stdout until the helper closes it."""
        assert self.process.stdout is not None
        deadline = time.monotonic() + timeout
        data = self.buffer
        self.buffer = b""
        while not self.eof:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError("stdout did not reach end of stream")
            chunk = self.process.stdout.raw.read(65536)  # type: ignore[attr-defined]
            if not chunk:
                self.eof = True
            data += chunk
        return data

    def settle(self, milliseconds: int) -> list[dict]:
        """Let the helper run for `milliseconds` of its own clock.

        Waits on the helper's clock rather than sleeping, and returns every
        frame seen other than the clock replies.
        """
        self.send(type="clock", id="settle-start")
        origin = self.expect_until("clock")["monotonic_ms"]
        seen: list[dict] = []
        while True:
            self.send(type="clock", id="settle")
            frame = self.expect_until("clock", seen)
            if frame["monotonic_ms"] - origin >= milliseconds:
                return seen
            time.sleep(0.02)

    def expect_until(self, frame_type: str, seen: list[dict] | None = None) -> dict:
        for _ in range(200):
            frame = self.read()
            assert frame is not None, f"no {frame_type} frame"
            if frame["type"] == frame_type:
                return frame
            if seen is not None:
                seen.append(frame)
        raise AssertionError(f"no {frame_type} frame")

    def expect(self, frame_type: str, timeout: float = READ_TIMEOUT) -> dict:
        frame = self.read(timeout)
        assert frame is not None, f"no {frame_type} frame"
        assert frame["type"] == frame_type, frame
        return frame

    def finish(self, timeout: float = 10.0) -> tuple[int, bytes]:
        try:
            code = self.process.wait(timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(5)
            raise
        assert self.process.stderr is not None
        stderr = self.process.stderr.read()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream and not stream.closed:
                stream.close()
        self.selector.close()
        return code, stderr

    def kill(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream and not stream.closed:
                try:
                    stream.close()
                except (BrokenPipeError, OSError):
                    pass
        self.selector.close()


class ProtocolTest(unittest.TestCase):
    def start(self, executable: Path | None = None, *arguments: str) -> Helper:
        helper = Helper(executable or ABSENT, *arguments)
        self.addCleanup(helper.kill)
        return helper

    def test_hello_is_first_and_names_the_helper(self) -> None:
        helper = self.start()
        hello = helper.expect("hello")
        self.assertEqual(hello["seq"], 0)
        self.assertEqual(hello["helper"], "zoom_observer_macos")
        self.assertEqual(hello["platform"], "macos")
        self.assertEqual(hello["parser_version"], "mac-1")
        self.assertIn("helper_version", hello)
        helper.close_stdin()
        code, _ = helper.finish()
        self.assertEqual(code, 0)

    def test_capabilities_reports_zoom_not_running_without_prompting(self) -> None:
        helper = self.start()
        helper.expect("hello")
        helper.send(type="capabilities", id="c1")
        frame = helper.expect("capabilities")
        self.assertEqual(frame["id"], "c1")
        self.assertEqual(frame["state"], "zoom_not_running")
        self.assertEqual(frame["reason"], "zoom_not_running")
        self.assertIsNone(frame["zoom_version"])
        self.assertIsNone(frame["locale"])
        helper.close_stdin()
        self.assertEqual(helper.finish()[0], 0)

    def test_production_capabilities_state_is_a_protocol_state(self) -> None:
        # Zoom may or may not be running on the machine under test, so only the
        # vocabulary is asserted.
        helper = self.start(HELPER)
        helper.expect("hello")
        helper.send(type="capabilities", id="p")
        frame = helper.expect("capabilities")
        self.assertIn(
            frame["state"],
            {
                "available",
                "needs_setup",
                "permission_denied",
                "zoom_not_running",
                "no_meeting",
                "unsupported_version",
                "unsupported_platform",
                "unavailable",
            },
        )
        self.assertTrue(frame["reason"])
        helper.close_stdin()
        self.assertEqual(helper.finish()[0], 0)

    def test_start_without_a_meeting_reports_unavailable_once(self) -> None:
        helper = self.start()
        helper.expect("hello")
        helper.send(
            type="start",
            id="s",
            session="session-1",
            poll_ms=100,
            deadline_ms=1000,
        )
        started = helper.expect("started")
        self.assertEqual(started["id"], "s")
        self.assertEqual(started["session"], "session-1")
        self.assertIsNone(started["target"]["pid"])
        unavailable = helper.expect("unavailable")
        self.assertEqual(unavailable["session"], "session-1")
        self.assertEqual(unavailable["reason"], "zoom_not_running")
        self.assertIsInstance(unavailable["since_ms"], int)
        # Several 100 ms polls pass on the helper's own clock; the unchanged
        # reason is not repeated.
        quiet = helper.settle(600)
        self.assertEqual(
            [frame for frame in quiet if frame["type"] != "clock"], [], quiet
        )
        helper.send(type="stop", id="x")
        stopped = helper.expect("stopped")
        self.assertEqual(stopped["id"], "x")
        self.assertEqual(stopped["session"], "session-1")
        code, stderr = helper.finish()
        self.assertEqual(code, 0)
        self.assertLessEqual(len(stderr), 4096, "stderr stays bounded")

    def test_stop_before_start_has_no_session(self) -> None:
        helper = self.start()
        helper.expect("hello")
        helper.send(type="stop", id=1)
        stopped = helper.expect("stopped")
        self.assertEqual(stopped["id"], 1)
        self.assertIsNone(stopped["session"])
        self.assertEqual(helper.finish()[0], 0)

    def test_exits_when_stdin_closes_without_extra_frames(self) -> None:
        helper = self.start()
        helper.expect("hello")
        helper.send(type="start", id="s", session="s", poll_ms=100, deadline_ms=1000)
        helper.expect("started")
        helper.expect("unavailable")
        helper.close_stdin()
        started = time.monotonic()
        self.assertEqual(helper.drain(), b"", "no frame follows end of input")
        code, _ = helper.finish(5.0)
        self.assertEqual(code, 0)
        self.assertLess(time.monotonic() - started, 3.0)

    def test_clock_uses_the_continuous_monotonic_domain(self) -> None:
        helper = self.start()
        helper.expect("hello")
        before = time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW) // 1_000_000
        before_uptime = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) // 1_000_000
        helper.send(type="clock", id="k1")
        first = helper.expect("clock")
        after = time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW) // 1_000_000
        after_uptime = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) // 1_000_000
        self.assertEqual(first["id"], "k1")
        # mach_continuous_time is CLOCK_MONOTONIC_RAW on macOS.
        self.assertGreaterEqual(first["monotonic_ms"], before - 1)
        self.assertLessEqual(first["monotonic_ms"], after + 1)
        self.assertGreaterEqual(first["uptime_ms"], before_uptime - 1)
        self.assertLessEqual(first["uptime_ms"], after_uptime + 1)
        helper.send(type="clock", id="k2")
        second = helper.expect("clock")
        self.assertGreaterEqual(second["monotonic_ms"], first["monotonic_ms"])
        helper.close_stdin()
        self.assertEqual(helper.finish()[0], 0)

    def test_malformed_request_closes_the_session(self) -> None:
        for payload, code in [
            (b"this is not json\n", "malformed_json"),
            (b"[1, 2]\n", "malformed_json"),
            (b'{"v":1,"seq":0,"type":"launch","id":1}\n', "protocol_type"),
            (b'{"v":1,"seq":4,"type":"clock","id":1}\n', "protocol_seq"),
            (b'{"v":9,"seq":0,"type":"clock","id":1}\n', "protocol_version"),
        ]:
            with self.subTest(payload=payload):
                helper = self.start(HELPER)
                helper.expect("hello")
                helper.send_raw(payload)
                frame = helper.expect("error")
                self.assertEqual(frame["code"], code)
                self.assertNotIn("id", frame)
                self.assertEqual(helper.drain(), b"", "nothing follows an error")
                status, stderr = helper.finish()
                self.assertEqual(status, 2)
                self.assertLessEqual(len(stderr), 4096)

    def test_request_errors_do_not_close_the_session(self) -> None:
        helper = self.start()
        helper.expect("hello")
        helper.send(type="start", id="bad")  # no session
        error = helper.expect("error")
        self.assertEqual(error["code"], "invalid_request")
        self.assertEqual(error["id"], "bad")
        helper.send(type="clock", id="still-alive")
        self.assertEqual(helper.expect("clock")["id"], "still-alive")
        helper.close_stdin()
        self.assertEqual(helper.finish()[0], 0)

    def test_line_bound(self) -> None:
        # One byte over the bound, with no newline yet, is refused at once.
        helper = self.start(HELPER)
        helper.expect("hello")
        helper.send_raw(b"x" * (MAX_LINE + 1))
        frame = helper.expect("error")
        self.assertEqual(frame["code"], "line_too_long")
        self.assertEqual(helper.finish()[0], 2)
        # A line of exactly the bound is accepted and answered.
        helper = self.start(HELPER)
        helper.expect("hello")
        head = b'{"v":1,"seq":0,"type":"clock","id":"edge","pad":"'
        tail = b'"}'
        line = head + b"p" * (MAX_LINE - len(head) - len(tail)) + tail
        self.assertEqual(len(line), MAX_LINE)
        helper.send_raw(line + b"\n")
        self.assertEqual(helper.expect("clock")["id"], "edge")
        helper.close_stdin()
        self.assertEqual(helper.finish()[0], 0)

    def test_stdout_carries_only_frames(self) -> None:
        helper = self.start()
        helper.expect("hello")
        helper.send_raw(b"garbage\n")
        helper.expect("error")
        # Every remaining byte is read: stray output would show up here.
        self.assertEqual(helper.drain(), b"")
        code, _ = helper.finish()
        self.assertEqual(code, 2)

    def test_usage_errors(self) -> None:
        for arguments in [("--protocol", "2"), ("--protocol",), ("--help",), ()]:
            with self.subTest(arguments=arguments):
                process = subprocess.run(
                    [str(HELPER), *arguments],
                    capture_output=True,
                    stdin=subprocess.DEVNULL,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(process.returncode, 64)
                self.assertEqual(process.stdout, b"")
                self.assertIn(b"--protocol 1", process.stderr)

    def test_helper_identity_is_embedded_and_build_conventions_hold(self) -> None:
        data = HELPER.read_bytes()
        self.assertIn(b"org.openforesight.zoom-observer", data)
        archs = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(HELPER)],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        ).stdout.split()
        self.assertIn("arm64", archs)
        load = subprocess.run(
            ["/usr/bin/otool", "-arch", "arm64", "-l", str(HELPER)],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        ).stdout
        self.assertIn("minos 15.0", load)

    def test_helper_is_passive(self) -> None:
        forbidden = [
            "AXUIElementPerformAction",
            "AXUIElementSetAttributeValue",
            "AXUIElementPostKeyboardEvent",
            "AXEnhancedUserInterface",
            "AXManualAccessibility",
            "activateWithOptions",
            "activateIgnoringOtherApps",
            "launchApplication",
            "openApplicationAtURL",
            "CGEventPost",
            "NSAppleScript",
        ]
        sources = {}
        for name in (
            "zoom_observer_macos.mm",
            "zoom_observer_core.cpp",
            "zoom_ax_parser.mm",
            "zoom_collector.cpp",
            "zoom_mac_source.cpp",
        ):
            # Whitespace-collapsed, so reformatting cannot hide a call.
            sources[name] = " ".join(
                (SOURCE / name).read_text(encoding="utf-8").split()
            )
            for token in forbidden:
                self.assertNotIn(token, sources[name], f"{name} must stay passive")
        # The only prompting request is the explicit setup path.
        self.assertEqual(
            sources["zoom_mac_source.cpp"].count("accessibility_trusted(true)"), 1
        )
        self.assertEqual(
            sources["zoom_mac_source.cpp"].count("accessibility_trusted(false)"), 1
        )
        for name in ("zoom_observer_core.cpp", "zoom_collector.cpp"):
            self.assertNotIn("accessibility_trusted", sources[name])
        self.assertEqual(
            sources["zoom_observer_macos.mm"].count("kAXTrustedCheckOptionPrompt"), 1
        )


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    HELPER, ABSENT, SOURCE = (Path(argument).resolve() for argument in sys.argv[1:4])
    unittest.main(argv=[sys.argv[0]], verbosity=2)
