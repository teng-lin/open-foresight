#!/usr/bin/env python3
"""Exercise the native process identity boundary against a real helper.

Usage: test_native_process.py /path/libforesight_native.dylib /path/ForesightHelper
"""

import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def check_runtime_environment_replay(lib, helper, directory):
    """Replay is read-only; a different profile cannot reconfigure workers."""
    for name, args, result in [
        (
            "fs_engine_create_backend",
            [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int],
            ctypes.c_void_p,
        ),
        ("fs_engine_probe", [ctypes.c_void_p], ctypes.c_int),
        ("fs_engine_destroy", [ctypes.c_void_p], ctypes.c_int),
        ("fs_conversation_create", [ctypes.c_void_p], ctypes.c_void_p),
        ("fs_conversation_destroy", [ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
        (
            "fs_generate",
            [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p],
            ctypes.c_int,
        ),
        ("fs_event_poll", [ctypes.c_void_p, ctypes.c_int], ctypes.c_void_p),
        ("fs_string_free", [ctypes.c_void_p], None),
    ]:
        function = getattr(lib, name)
        function.argtypes, function.restype = args, result
    getenv = ctypes.CDLL(None).getenv
    getenv.argtypes, getenv.restype = [ctypes.c_char_p], ctypes.c_char_p
    original = {
        b"FORESIGHT_HELPER": os.fsencode(helper),
        b"FORESIGHT_LITERT_CACHE": os.fsencode(directory / "profile-a/cache/litert"),
        b"PYTHONPYCACHEPREFIX": os.fsencode(directory / "profile-a/cache/python"),
        b"FORESIGHT_WHISPER_BACKEND": b"",
    }
    absent = b"FORESIGHT_WHISPER_DEVICE"
    unknown = b"FORESIGHT_UNKNOWN_RUNTIME_SETTING"
    os.environ.pop(absent.decode(), None)
    assert getenv(absent) is None
    os.environ[unknown.decode()] = "already present"
    for key, value in original.items():
        assert lib.fs_set_runtime_environment(key, value) == 0
        assert getenv(key) == value

    def check_sealed():
        for key, value in original.items():
            assert lib.fs_set_runtime_environment(key, value) == 0
            assert getenv(key) == value
            assert lib.fs_set_runtime_environment(key, value + b"-changed") == -1
            assert getenv(key) == value
        for value in (b"", b"new device"):
            assert lib.fs_set_runtime_environment(absent, value) == -1
            assert getenv(absent) is None
        assert lib.fs_set_runtime_environment(unknown, b"already present") == -1
        assert getenv(unknown) == b"already present"
        assert lib.fs_set_runtime_environment(None, b"value") == -1
        assert lib.fs_set_runtime_environment(b"FORESIGHT_HELPER", None) == -1

    runner, model = directory / "runtime-worker", directory / "model"
    model.write_text("owned protocol fixture; no model inference")
    runner.write_text(
        f"#!{sys.executable}\n"
        "import json,os,pathlib,sys\n"
        "root=pathlib.Path(__file__).parent\n"
        "if '--probe' in sys.argv:\n"
        " print('{\"worker_protocol\":1}',flush=True)\n"
        " sys.exit(0)\n"
        "assert '--serve' in sys.argv\n"
        "snapshot={k:os.environ.get(k) for k in "
        + repr([key.decode() for key in original])
        + "}\n"
        "(root/'worker.json').write_text(json.dumps({'pid':os.getpid(),'environment':snapshot}))\n"
        "print('ready 1',flush=True)\n"
        "for line in sys.stdin:\n"
        " if line.strip()=='shutdown':\n"
        "  (root/'worker.closed').write_text('closed')\n"
        "  break\n"
        " command,token,payload=line.rstrip('\\n').split(' ',2)\n"
        " assert command=='generate'\n"
        " json.loads(payload)\n"
        " print(token+' text '+json.dumps('retained runtime environment'),flush=True)\n"
        " print(token+' done completed',flush=True)\n"
    )
    runner.chmod(0o700)
    engine = lib.fs_engine_create_backend(os.fsencode(runner), os.fsencode(model), 1)
    assert engine
    conversation = None
    try:
        assert lib.fs_engine_probe(engine) == 0
        conversation = lib.fs_conversation_create(engine)
        assert conversation

        def generate(identity):
            assert lib.fs_generate(conversation, identity, b"environment") == 0
            events = []
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                pointer = lib.fs_event_poll(conversation, 100)
                if not pointer:
                    continue
                try:
                    event = json.loads(ctypes.string_at(pointer))
                finally:
                    lib.fs_string_free(pointer)
                events.append(event)
                if event["type"] == "done":
                    break
            assert events and events[-1].get("status") == "completed", events
            assert (
                "".join(e.get("text", "") for e in events if e["type"] == "delta")
                == "retained runtime environment"
            ), events

        generate(b"before-replay")
        worker = json.loads((directory / "worker.json").read_text())
        assert worker["environment"] == {
            k.decode(): v.decode() for k, v in original.items()
        }
        os.kill(worker["pid"], 0)
        check_sealed()
        generate(b"after-replay")
        assert json.loads((directory / "worker.json").read_text()) == worker
        os.kill(worker["pid"], 0)
    finally:
        try:
            if conversation:
                assert lib.fs_conversation_destroy(conversation, 1) == 0
        finally:
            assert lib.fs_engine_destroy(engine) == 0
    assert (directory / "worker.closed").read_text() == "closed"
    try:
        os.kill(worker["pid"], 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("native close did not reap its persistent worker")
    check_sealed()


def main():
    library, helper = sys.argv[1:]
    lib = ctypes.CDLL(library)
    lib.fs_process_matches.argtypes = [ctypes.c_int64] + [ctypes.c_char_p] * 3
    lib.fs_process_matches.restype = ctypes.c_int
    lib.fs_set_runtime_environment.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.fs_set_runtime_environment.restype = ctypes.c_int
    assert lib.fs_set_runtime_environment(b"PATH", b"/invalid") == -1
    assert lib.fs_set_runtime_environment(None, b"value") == -1
    for key in (b"FORESIGHT_LITERT_LIBRARY",):
        assert lib.fs_set_runtime_environment(key, b"/controlled/native/library") == 0
    assert lib.fs_set_runtime_environment(b"FORESIGHT_HELPER", os.fsencode(helper)) == 0
    with tempfile.TemporaryDirectory(prefix="fs-identity-", dir="/tmp") as directory:
        os.chmod(directory, 0o700)
        socket, storage = (
            str(Path(directory) / "helper.sock"),
            str(Path(directory) / "data"),
        )
        process = subprocess.Popen(
            [helper, socket, storage, "--allow-test-models"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            for _ in range(200):
                if Path(socket).exists():
                    break
                assert process.poll() is None, process.stderr.read()
                time.sleep(0.025)
            assert Path(socket).exists(), "helper did not start"
            # system_clock native period is microseconds in Apple libc++,
            # nanoseconds in Linux libstdc++. The authentic ID is subsequently
            # fetched over the private helper control protocol by the Dart owner.
            stamp = time.time_ns() // (1000 if sys.platform == "darwin" else 1)
            instance = f"{process.pid}-{stamp}".encode()

            def matches(pid=process.pid, sock=socket, root=storage, identity=instance):
                return lib.fs_process_matches(
                    pid, sock.encode(), root.encode(), identity
                )

            assert matches() == 1
            assert matches(sock=socket + "-other") == 0
            assert matches(root=storage + "-other") == 0
            assert matches(identity=b"0-1") == 0
            assert matches(pid=os.getpid()) == 0
            if sys.platform == "darwin":
                assert matches(identity=f"{process.pid}-1".encode()) == 0
        finally:
            process.terminate()
            process.wait(timeout=10)
        assert matches() == 0, "Exited verified helper must be positively absent"
        check_runtime_environment_replay(lib, helper, Path(directory))
    print("native helper identity and immutable environment replay boundary passed")


if __name__ == "__main__":
    main()
