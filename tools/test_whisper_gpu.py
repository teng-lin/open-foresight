#!/usr/bin/env python3
"""Verify Vulkan Whisper and native speech events using a file, never a microphone."""

import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--device", type=int, default=0)
    parser.add_argument("--expect-device", default="NVIDIA GeForce RTX 5070")
    args = parser.parse_args()
    results = {}
    for backend in ("gpu", "cpu"):
        command = [
            str(args.runner.resolve()),
            "-m",
            str(args.model.resolve()),
            "-f",
            str(args.audio.resolve()),
            "-l",
            "en",
            "-nt",
            "-t",
            "4",
        ]
        if backend == "cpu":
            command.append("-ng")
        else:
            command.extend(["-dev", str(args.device)])
        start = time.monotonic()
        result = subprocess.run(command, text=True, capture_output=True, timeout=90)
        assert result.returncode == 0, result.stderr
        assert "ask not what your country" in result.stdout.lower(), result.stdout
        if backend == "gpu":
            assert f"using Vulkan{args.device} backend" in result.stderr, result.stderr
            assert any(
                f"{args.device} = {args.expect_device}" in line
                for line in result.stderr.splitlines()
            ), result.stderr
        results[backend] = {
            "seconds": time.monotonic() - start,
            "transcript": result.stdout.strip(),
            "diagnostics": result.stderr,
        }
    os.environ["FORESIGHT_WHISPER_BACKEND"] = "gpu"
    os.environ["FORESIGHT_WHISPER_DEVICE"] = str(args.device)
    os.environ["FORESIGHT_WHISPER_RUNTIME"] = str(args.runner.resolve())
    lib = C.CDLL(str(args.native.resolve()))
    abi = getattr(lib, "fs_abi_version", None)
    if abi is None:
        raise RuntimeError("Incompatible native ABI")
    abi.argtypes = []
    abi.restype = C.c_int
    if abi() != 1:
        raise RuntimeError("Incompatible native ABI")
    for name, inputs, output in (
        ("fs_speech_create", [C.c_char_p, C.c_char_p], C.c_void_p),
        (
            "fs_speech_push",
            [C.c_void_p, C.POINTER(C.c_int16), C.c_size_t, C.c_int],
            C.c_int,
        ),
        ("fs_speech_finish", [C.c_void_p, C.c_char_p], C.c_int),
        ("fs_event_poll", [C.c_void_p, C.c_int], C.c_void_p),
        ("fs_string_free", [C.c_void_p], None),
        ("fs_speech_destroy", [C.c_void_p], None),
    ):
        function = getattr(lib, name)
        function.argtypes, function.restype = inputs, output
    with wave.open(str(args.audio)) as source:
        assert source.getsampwidth() == 2 and source.getnchannels() == 1
        rate = source.getframerate()
        pcm = source.readframes(source.getnframes())
    samples = (C.c_int16 * (len(pcm) // 2)).from_buffer_copy(pcm)
    speech = lib.fs_speech_create(
        str(args.runner.resolve()).encode(), str(args.model.resolve()).encode()
    )
    assert speech
    events = []
    try:
        assert lib.fs_speech_push(speech, samples, len(samples), rate) == 0
        assert lib.fs_speech_finish(speech, b"gpu-file-acceptance") == 0
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            pointer = lib.fs_event_poll(speech, 100)
            if not pointer:
                continue
            try:
                event = json.loads(C.string_at(pointer))
            finally:
                lib.fs_string_free(pointer)
            events.append(event)
            if event["type"] == "done":
                break
        assert events[-1]["type"] == "done" and events[-1]["status"] == "completed", (
            events
        )
        transcript = next(e for e in events if e["type"] == "transcript")
        assert (
            transcript["final"]
            and "ask not what your country" in transcript["text"].lower()
        ), events
    finally:
        lib.fs_speech_destroy(speech)
    report = {
        "passed": True,
        "method": "controlled audio file; no microphone capture",
        "physical_microphone_verified": False,
        "cli": results,
        "native_events": events,
        "sha256": {
            name: hashlib.sha256(path.read_bytes()).hexdigest()
            for name, path in vars(args).items()
            if isinstance(path, Path) and name != "report"
        },
        "selected_device": args.device,
        "expected_device": args.expect_device,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(
        json.dumps(
            {"passed": True, "seconds": {k: v["seconds"] for k, v in results.items()}}
        )
    )


if __name__ == "__main__":
    main()
