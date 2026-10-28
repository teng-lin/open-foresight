"""Meeting/worker recovery against real service and controlled native runners."""

import os
import json
import signal
import sys
import time

import pytest

from test_service_process import running, poll_delay, assert_saved_pcm, wait_saved_asr  # noqa: F401 - shared integration fixture


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
    started = running["root"] / "fixtures" / "capture-started"
    progress = running["root"] / "fixtures" / "capture-progress"
    trace = running["root"] / "fixtures" / "capture-pressure.jsonl"
    inherited = running["root"] / "fixtures" / "capture-inheritance.json"
    capture.write_text(
        '#!/usr/bin/env python3\nimport json,os,pathlib,sys,time\nblock=b"A"*3840\n'
        f"pathlib.Path({str(inherited)!r}).write_text(json.dumps({{'dyld_insert_libraries':os.environ.get('DYLD_INSERT_LIBRARIES')}}))\n"
        f"pathlib.Path({str(started)!r}).touch()\n"
        'output=1 if sys.argv[-1]=="-" else os.open(sys.argv[-1],os.O_WRONLY)\n'
        "for n in range(2000):\n os.write(output,block)\n"
        f" if n%100==99:pathlib.Path({str(progress)!r}).write_text(str(n+1))\n"
        f"pathlib.Path({str(ready)!r}).touch()\n"
        "while True:os.write(output,block);time.sleep(.04)\n"
    )

    def completed_blocks():
        try:
            return max(0, min(2000, int(progress.read_text()[:16])))
        except (OSError, ValueError):
            return -1

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
        snapshots = []
        while True:
            if trace.exists():
                snapshots = [json.loads(line) for line in trace.read_text().splitlines(keepends=True) if line.endswith("\n")]
            errors = [row for row in snapshots if row.get("error")]
            state = peer.call("status")["capture"]
            content = peer.call("meetings.get", {"id": meeting})
            if errors and not state["active"] and content["meeting"]["state"] == "interrupted":
                break
            assert time.monotonic() < deadline, (
                f"bounded native handoff did not interrupt visibly: {errors}, {state} "
                f"(started={started.exists()}, completed_blocks={completed_blocks()})"
            )
            poll_delay(deadline)
        assert (running["root"] / "fixtures/recording-write-entered").is_file()
        if sys.platform == "darwin":
            assert (running["root"] / "fixtures/capture-injection-retired").is_file()
            assert json.loads(inherited.read_text())["dyld_insert_libraries"] is None
        assert (running["root"] / "fixtures/recording-write-released").is_file()
        assert not (running["root"] / "fixtures/recording-write-timeout").exists()
        # The burst deliberately exceeds real-time capture. Its entire80s must
        # not be claimed as accepted: the bounded writer stops at a real prefix.
        # Only the owned disk-worker write is delayed. The native admission,
        # queue accounting, errors and returned metadata are unchanged.
        assert 0 < len(snapshots) <= 256 and trace.stat().st_size <= 2 * 1024 * 1024
        assert all(0 <= row["queued_frames"] <= 64 * 4800 for row in snapshots)
        assert all(0 <= row["outstanding_chunks"] <= 64 for row in snapshots)
        assert errors[0]["error"] == "Recording storage handoff failed"
        assert all(row["error"] == "Recording storage handoff failed" for row in errors)
        assert errors[0]["reserved_chunks"] > 0, "reservation exhaustion is not queue overflow"
        assert errors[0]["source_sample"] > 0
        saved = assert_saved_pcm(running["root"], meeting)
        assert 0 < sum(frames for _, frames in saved.values()) < 2 * 2000 * 1920
        read_args = {"meeting_id": meeting, "workspace_epoch": peer.call("status")["workspace_epoch"]}
        presentation = peer.call("recordings.read", read_args)
        warning = presentation["meeting"]["captureError"]
        assert warning and presentation["meeting"]["activeSessionId"] is None
        assert presentation["sessions"] and all(row["captureError"] for row in presentation["sessions"])
        # The failed capture can stop before the burst writes its ready marker.
        # The real error observer has released the disk/event hold. Ensure
        # saved ASR receives its result independently of capture recovery.
        gate.unlink(missing_ok=True)
        wait_saved_asr(peer, running["root"], meeting)
        assert peer.call("recordings.read", read_args)["meeting"]["captureError"] == warning
        assert peer.call("meetings.get", {"id": meeting})["meeting"]["state"] == "interrupted"
    finally:
        gate.unlink(missing_ok=True)
        peer.call("meetings.stop")
