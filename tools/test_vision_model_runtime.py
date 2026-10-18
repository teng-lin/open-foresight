#!/usr/bin/env python3
"""Opt-in real-model check of recovered vision startup and native ownership.

Uses a caller-selected local SDK/model and a synthetic image in an owned
profile. No downloads, credentials, original application data or shared caches.
"""

import argparse
import hashlib
import os
import subprocess
import json
from pathlib import Path
import struct
import tempfile
import zlib

from test_packaged_model_runtime import Peer

ROOT = Path(__file__).resolve().parents[1]


def red_image(path):
    def chunk(kind, body):
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body))
        )

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 128, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\0" * 128) * 128))
        + chunk(b"IEND", b"")
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--model-type", type=int, choices=(14, 15, 16), default=14)
    parser.add_argument("--backend", choices=("cpu", "gpu"), required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.model.open("rb") as model_stream:
        model_digest = hashlib.file_digest(model_stream, "sha256").hexdigest()
    report = {
        "backend": args.backend,
        "model_type": args.model_type,
        "runtime": "native-c-api",
        "model_sha256": model_digest,
        "acceptance_passed": False,
    }
    peer = None
    try:
        with tempfile.TemporaryDirectory(
            prefix="foresight-vision-runtime-"
        ) as temporary:
            root = Path(temporary)
            image = root / "red.png"
            red_image(image)
            environment = dict(
                os.environ,
                PATH="/nonexistent",
                FORESIGHT_LITERT_LIBRARY=str(args.library.resolve()),
                FORESIGHT_LITERT_CACHE=str(root / "cache"),
            )
            peer = Peer(
                [
                    str(args.worker.resolve()),
                    "--model",
                    str(args.model.resolve()),
                    "--backend",
                    args.backend,
                    "--model-type",
                    str(args.model_type),
                    "--serve",
                ],
                environment,
                root,
                args.report.with_suffix(".stderr"),
                180,
            )
            if peer.receive() != "ready 1":
                raise RuntimeError("Native worker did not become ready")

            def request(token, prompt, messages=None, cancel=False):
                tools = {"tools": [], "system_message": "", "messages": messages or []}
                peer.send(
                    f"generate {token} "
                    + json.dumps(
                        {
                            "prompt": prompt,
                            "max_output_tokens": 512 if cancel else 64,
                            "tools": tools,
                        }
                    )
                )
                answer, cancelled = None, False
                while True:
                    line = peer.receive()
                    owner, kind, value = line.split(" ", 2)
                    if owner != str(token):
                        raise RuntimeError("Cross-request native frame: " + line)
                    if kind == "delta" and cancel and not cancelled:
                        peer.send(f"cancel {token}")
                        cancelled = True
                    if kind == "answer":
                        answer = json.loads(value)
                    if kind == "error" and not cancelled:
                        raise RuntimeError(value)
                    if kind == "done":
                        if value != ("cancelled" if cancel else "completed"):
                            raise RuntimeError("Unexpected terminal status: " + line)
                        return answer, cancelled

            answer, _ = request(
                1,
                "What is the main color? Reply with one color word.",
                [
                    {
                        "role": "user",
                        "content": [
                            {"type": "image", "path": str(image)},
                            {"type": "text", "text": "Examine this image."},
                        ],
                    }
                ],
            )
            report["answer"] = answer
            if "red" not in json.dumps(answer).lower():
                raise RuntimeError("Synthetic red image answer did not identify red")
            _, report["cancel_requested_after_stream_delta"] = request(
                2, "Count the integers from 1 to 200, one per line.", cancel=True
            )
            answer, _ = request(3, "What is 2 + 2? Reply with one digit.")
            report["reuse_answer"] = answer
            if "4" not in json.dumps(answer):
                raise RuntimeError("Engine reuse after cancellation failed")
            peer.close("shutdown")
            peer = None
            report["native_engine_closed"] = True
            report["acceptance_passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if peer is not None:
            peer.close("shutdown")
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
