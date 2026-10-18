"""Meeting/worker recovery against real service and controlled native runners."""

import os
import signal
import time

from test_service_process import running  # noqa: F401 - shared integration fixture


def _ready(peer, previous=None):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        helper = peer.call("status").get("helper") or {}
        identity = helper.get("instanceId")
        if identity and identity != previous and helper.get("pipeline") == "ready":
            return identity
        time.sleep(0.05)
    raise AssertionError("helper did not recover")


def test_explicit_resume_restarts_helper_after_automatic_budget_is_exhausted(running):  # noqa: F811 - pytest injects the imported fixture by parameter name.
    peer = running["peer"]
    identity = _ready(peer)
    for attempt in range(4):
        os.kill(int(identity.split("-")[0]), signal.SIGKILL)
        if attempt < 3:
            identity = _ready(peer, identity)
    deadline = time.monotonic() + 3
    while peer.call("status").get("helper") and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not peer.call("status").get("helper")
    peer.call("application.resume")
    assert _ready(peer, identity) != identity


def test_native_queue_overflow_is_saved_as_meeting_interruption(running):  # noqa: F811 - pytest injects the imported fixture by parameter name.
    capture = running["root"] / "fixtures" / "pw-record"
    capture.write_text(
        '#!/usr/bin/env python3\nimport os,time\nblock=b"A"*3840\n'
        "for _ in range(2000):os.write(1,block)\n"
        "while True:os.write(1,block);time.sleep(.04)\n"
    )
    peer = running["peer"]
    peer.call(
        "models.register",
        {
            "kind": "speech",
            "path": str(running["asset"]),
            "runtime": str(running["runner"]),
        },
    )
    meeting = peer.call("meetings.create", {"title": "Overflow persists a gap"})["id"]
    peer.call("meetings.start", {"id": meeting})
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            rows = peer.call("meetings.get", {"id": meeting})["transcript"]
            if any(
                "capture_buffer_overflow" in row["text"] and row["final"] == 0
                for row in rows
            ):
                break
            time.sleep(0.02)
        else:
            raise AssertionError(
                "Native capture overflow was not persisted as an interruption"
            )
    finally:
        peer.call("meetings.stop")
