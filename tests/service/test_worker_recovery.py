"""Meeting/worker recovery against real service and controlled native runners."""

import os
import signal
import time

import pytest

from test_service_process import running, poll_delay  # noqa: F401 - shared integration fixture


def _ready(peer, previous=None):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        helper = peer.call("status").get("helper") or {}
        identity = helper.get("instanceId")
        if identity and identity != previous and helper.get("pipeline") == "ready":
            return identity
        poll_delay(deadline)
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
        poll_delay(deadline)
    assert not peer.call("status").get("helper")
    peer.call("application.resume")
    assert _ready(peer, identity) != identity


def test_helper_crash_preserves_committed_data_and_restores_indexing(running):  # noqa: F811 - pytest injects the imported fixture by parameter name.
    peer = running["peer"]
    note = peer.call("notes.save", {"title": "Before crash", "body": "Durable note"})
    source = peer.call(
        "sources.import",
        {"title": "Planning", "text": "Mira sends the draft Tuesday."},
    )["id"]
    identity = _ready(peer)
    owner = peer.call("status")["pid"]
    os.kill(int(identity.split("-")[0]), signal.SIGKILL)
    # Application SQLite and the public service stay usable during helper loss.
    after = peer.call("notes.save", {"title": "During recovery", "body": "Also durable"})
    assert peer.call("status")["pid"] == owner
    assert {row["id"] for row in peer.call("notes.list")} == {note["id"], after["id"]}
    assert _ready(peer, identity) != identity
    assert peer.call("sources.get", {"id": source})["state"] == "indexed"
    imported = peer.call(
        "sources.import",
        {"title": "After recovery", "text": "Atlas review happens Friday."},
    )["id"]
    assert peer.call("sources.get", {"id": imported})["state"] == "indexed"
    results = peer.call("sources.search", {"query": "Atlas review"})
    assert imported in {row["id"] for row in results}
    assert peer.call("status")["pid"] == owner


@pytest.mark.parametrize("running", ["capture_poll_gate"], indirect=True)
def test_native_queue_overflow_is_saved_as_meeting_interruption(running):  # noqa: F811 - pytest injects the imported fixture by parameter name.
    capture = running["root"] / "fixtures" / "pw-record"
    ready = running["root"] / "fixtures" / "capture-filled"
    gate = running["root"] / "fixtures" / "hold-capture-poll"
    capture.write_text(
        '#!/usr/bin/env python3\nimport os,pathlib,sys,time\nblock=b"A"*3840\n'
        'output=1 if sys.argv[-1]=="-" else os.open(sys.argv[-1],os.O_WRONLY)\n'
        "for _ in range(2000):os.write(output,block)\n"
        f"pathlib.Path({str(ready)!r}).touch()\n"
        "while True:os.write(output,block);time.sleep(.04)\n"
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
    gate.touch()
    peer.call("meetings.start", {"id": meeting})
    try:
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            poll_delay(deadline)
        assert ready.exists(), (
            "Capture producer did not finish filling the native queue"
        )
        while time.monotonic() < deadline:
            rows = peer.call("meetings.get", {"id": meeting})["transcript"]
            if any(
                "capture_buffer_overflow" in row["text"] and row["final"] == 0
                for row in rows
            ):
                break
            poll_delay(deadline)
        else:
            raise AssertionError(
                "Native capture overflow was not persisted as an interruption"
            )
    finally:
        gate.unlink(missing_ok=True)
        peer.call("meetings.stop")
