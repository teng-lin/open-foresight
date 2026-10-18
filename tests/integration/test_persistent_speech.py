"""Exercise the native speech API across segments with one owned server."""

import ctypes
import json
import os
from pathlib import Path
import time

import pytest

LIBRARY = os.environ.get("FORESIGHT_NATIVE_LIBRARY")


@pytest.mark.skipif(not LIBRARY, reason="Build native and set FORESIGHT_NATIVE_LIBRARY")
@pytest.mark.parametrize(
    "frames",
    [
        ['"segment \u03bb\\ncontinued"'],
        [],
        ['"unterminated'],
        ["7"],
        ['"duplicate"', '"duplicate"'],
    ],
)
def test_reuses_speech_worker(tmp_path, monkeypatch, frames):
    worker = tmp_path / "foresight-whisper-worker"
    worker.write_text("""#!/usr/bin/env python3
import json,os,sys,pathlib
with open(__file__+'.starts','a') as file: file.write(str(os.getpid())+'\\n')
assert '--serve' in sys.argv
print('ready 1',flush=True)
for line in sys.stdin:
 if line.strip()=='shutdown': break
 command,token,payload=line.rstrip('\\n').split(' ',2)
 request=json.loads(payload)
 assert command=='generate' and os.path.isfile(request['prompt'])
 if pathlib.Path(__file__+'.block').exists():
  pathlib.Path(__file__+'.request').write_text(token)
  assert sys.stdin.readline().strip()=='cancel '+token
  print(token+' done cancelled',flush=True)
  continue
 for frame in json.loads(os.environ['FORESIGHT_TEST_SPEECH_FRAMES']):
  print(token+' text '+frame,flush=True)
 print(token+' done completed',flush=True)
""")
    worker.chmod(0o700)
    model = tmp_path / "model"
    model.write_text("fixture")
    monkeypatch.setenv("FORESIGHT_WHISPER_WORKER", str(worker))
    monkeypatch.setenv("FORESIGHT_TEST_SPEECH_FRAMES", json.dumps(frames))
    monkeypatch.setenv("FORESIGHT_WHISPER_BACKEND", "cpu")
    monkeypatch.setenv("FORESIGHT_DATA", str(tmp_path))
    library = ctypes.CDLL(LIBRARY)
    library.fs_speech_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    library.fs_speech_create.restype = ctypes.c_void_p
    library.fs_speech_push.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int16),
        ctypes.c_size_t,
        ctypes.c_int,
    ]
    library.fs_speech_finish.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    library.fs_speech_cancel.argtypes = [ctypes.c_void_p]
    library.fs_event_poll.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.fs_event_poll.restype = ctypes.c_void_p
    library.fs_string_free.argtypes = [ctypes.c_void_p]
    library.fs_speech_destroy.argtypes = [ctypes.c_void_p]
    speech = library.fs_speech_create(
        str(tmp_path / "whisper-cli").encode(), str(model).encode()
    )
    assert speech
    other = library.fs_speech_create(
        str(tmp_path / "whisper-cli").encode(), str(model).encode()
    )
    assert other
    try:
        for number in range(3):
            active = speech if number % 2 == 0 else other
            samples = (ctypes.c_int16 * 1600)()
            assert library.fs_speech_push(active, samples, len(samples), 16000) == 0
            assert library.fs_speech_finish(active, str(number).encode()) == 0
            events = []
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                pointer = library.fs_event_poll(active, 100)
                if pointer:
                    events.append(json.loads(ctypes.string_at(pointer)))
                    library.fs_string_free(pointer)
                    if events[-1]["type"] == "done":
                        break
            valid = len(frames) == 1 and frames[0].startswith('"segment ')
            assert events[-1]["status"] == ("completed" if valid else "failed"), events
            assert [
                event["text"] for event in events if event["type"] == "transcript"
            ] == (["segment λ\ncontinued"] if valid else [])
        if valid:
            # A cancelled segment waiting behind another channel must not join
            # that channel's active inference before it can settle cancellation.
            Path(str(worker) + ".block").write_text("block")
            samples = (ctypes.c_int16 * 1600)()
            assert library.fs_speech_push(speech, samples, len(samples), 16000) == 0
            assert library.fs_speech_finish(speech, b"active-channel") == 0
            deadline = time.monotonic() + 5
            while not Path(str(worker) + ".request").exists():
                assert time.monotonic() < deadline
                time.sleep(0.01)
            assert library.fs_speech_push(other, samples, len(samples), 16000) == 0
            assert library.fs_speech_finish(other, b"queued-channel") == 0
            began = time.monotonic()
            assert library.fs_speech_cancel(other) == 0
            pointer = library.fs_event_poll(other, 1000)
            assert pointer
            cancelled = json.loads(ctypes.string_at(pointer))
            library.fs_string_free(pointer)
            assert cancelled["type"] == "done" and cancelled["status"] == "cancelled"
            assert time.monotonic() - began < 1
            assert not library.fs_event_poll(speech, 0), (
                "Active channel was cancelled by another segment"
            )
            assert library.fs_speech_cancel(speech) == 0
            pointer = library.fs_event_poll(speech, 1000)
            assert pointer
            cancelled = json.loads(ctypes.string_at(pointer))
            library.fs_string_free(pointer)
            assert cancelled["type"] == "done" and cancelled["status"] == "cancelled"
        assert len(Path(str(worker) + ".starts").read_text().splitlines()) == 1
    finally:
        library.fs_speech_destroy(speech)
        library.fs_speech_destroy(other)


def speech_library():
    library = ctypes.CDLL(LIBRARY)
    library.fs_speech_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    library.fs_speech_create.restype = ctypes.c_void_p
    library.fs_speech_push.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_int16),
        ctypes.c_size_t,
        ctypes.c_int,
    ]
    library.fs_speech_finish.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    library.fs_speech_cancel.argtypes = [ctypes.c_void_p]
    library.fs_event_poll.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.fs_event_poll.restype = ctypes.c_void_p
    library.fs_string_free.argtypes = [ctypes.c_void_p]
    library.fs_speech_destroy.argtypes = [ctypes.c_void_p]
    return library


@pytest.mark.skipif(not LIBRARY, reason="Build native and set FORESIGHT_NATIVE_LIBRARY")
@pytest.mark.parametrize("persistent", [False, True], ids=["cli", "worker"])
@pytest.mark.parametrize("cancel", [False, True], ids=["retry", "cancel"])
def test_gpu_speech_failure_retries_cleanly_unless_cancelled(
    tmp_path, monkeypatch, persistent, cancel
):
    runtime = tmp_path / ("foresight-whisper-worker" if persistent else "whisper-cli")
    calls = tmp_path / "calls.jsonl"
    entered = tmp_path / "entered"
    runtime.write_text(
        "#!/usr/bin/env python3\n"
        + f"CALLS={str(calls)!r}\nENTERED={str(entered)!r}\nCANCEL={cancel!r}\n"
        + """import json,pathlib,signal,sys
cpu='-ng' in sys.argv or ('--backend' in sys.argv and sys.argv[sys.argv.index('--backend')+1]=='cpu')
with open(CALLS,'a') as stream: stream.write(json.dumps({'cpu':cpu,'args':sys.argv[1:]})+'\\n')
if '--serve' in sys.argv:
 print('ready 1',flush=True)
 for line in sys.stdin:
  if line.strip()=='shutdown': break
  command,token,payload=line.rstrip('\\n').split(' ',2)
  assert command=='generate'
  if cpu:
   print(token+' text '+json.dumps('CPU transcript only'),flush=True)
   print(token+' done completed',flush=True)
  else:
   print(token+' text '+json.dumps('FAILED GPU PARTIAL'),flush=True)
   pathlib.Path(ENTERED).write_text('entered')
   if CANCEL:
    assert sys.stdin.readline().strip()=='cancel '+token
    print(token+' done cancelled',flush=True)
   else:
    print(token+' done failed',flush=True)
else:
 if cpu:
  print('CPU transcript only',end='',flush=True)
 else:
  assert '-dev' in sys.argv
  print('FAILED GPU PARTIAL',end='',flush=True)
  pathlib.Path(ENTERED).write_text('entered')
  if CANCEL: signal.pause()
  sys.exit(1)
"""
    )
    runtime.chmod(0o700)
    model = tmp_path / "model"
    model.write_text("fixture")
    monkeypatch.setenv("FORESIGHT_DATA", str(tmp_path))
    monkeypatch.setenv("FORESIGHT_WHISPER_BACKEND", "gpu")
    monkeypatch.setenv("FORESIGHT_WHISPER_DEVICE", "0")
    monkeypatch.delenv("FORESIGHT_WHISPER_RUNTIME", raising=False)
    monkeypatch.setenv(
        "FORESIGHT_WHISPER_WORKER",
        str(runtime if persistent else tmp_path / "no-worker"),
    )
    library = speech_library()
    speech = library.fs_speech_create(str(runtime).encode(), str(model).encode())
    assert speech
    try:
        samples = (ctypes.c_int16 * 1600)()
        assert library.fs_speech_push(speech, samples, len(samples), 16000) == 0
        assert library.fs_speech_finish(speech, b"gpu-retry") == 0
        if cancel:
            deadline = time.monotonic() + 10
            while not entered.exists():
                assert time.monotonic() < deadline, "GPU attempt did not start"
                time.sleep(0.01)
            assert library.fs_speech_cancel(speech) == 0
        events = []
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            pointer = library.fs_event_poll(speech, 100)
            if not pointer:
                continue
            try:
                events.append(json.loads(ctypes.string_at(pointer)))
            finally:
                library.fs_string_free(pointer)
            if events[-1]["type"] == "done":
                break
        assert events and events[-1]["type"] == "done", events
        assert events[-1]["status"] == ("cancelled" if cancel else "completed")
        transcripts = [e["text"] for e in events if e["type"] == "transcript"]
        assert transcripts == ([] if cancel else ["CPU transcript only"])
        retries = [
            e
            for e in events
            if e["type"] == "state"
            and e.get("message") == "GPU speech recognition failed; retrying on CPU"
        ]
        assert len(retries) == (0 if cancel else 1), events
        attempts = [json.loads(line) for line in calls.read_text().splitlines()]
        assert [attempt["cpu"] for attempt in attempts] == (
            [False] if cancel else [False, True]
        )
        assert not list((tmp_path / "speech").iterdir()), "Staged audio leaked"
    finally:
        library.fs_speech_destroy(speech)
