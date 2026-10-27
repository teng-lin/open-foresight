#!/usr/bin/env python3
"""Synthetic embedding/tokenizer process for first-run ownership acceptance.

This deliberately performs no inference and has no GPU implementation.
"""

import hashlib
import json
import os
from pathlib import Path
import stat
import sys

PAYLOAD = (b"Synthetic embedding fixture; NOT a model.\n" * 512)[:16384]


def main():
    args = sys.argv[1:]
    if len(args) not in (2, 3) or args[0] != "--embedding":
        return 2
    if len(args) == 3 and args[2] != "--gpu":
        return 2
    model = Path(args[1])
    if model.name != "fixture-embedding.litertlm" or model.is_symlink():
        return 2
    metadata = model.stat()
    if metadata.st_uid != os.getuid() or not stat.S_ISREG(metadata.st_mode):
        return 2
    if metadata.st_size != len(PAYLOAD) or model.read_bytes() != PAYLOAD:
        return 2
    backend = "litert-lm-embedding-gpu" if len(args) == 3 else "litert-lm-embedding-cpu"
    report = os.environ.get("FORESIGHT_FIRST_RUN_WORKER_REPORT")
    if report:
        descriptor = os.open(report, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(
                {
                    "pid": os.getpid(),
                    "uid": os.getuid(),
                    "argv": args,
                    "backend": backend,
                    "synthetic": True,
                },
                stream,
            )
            stream.write("\n")
    print(
        json.dumps(
            {
                "ready": True,
                "synthetic": True,
                "dimensions": 4,
                "digest": hashlib.sha256(PAYLOAD).hexdigest(),
                "tokenizer_digest": "first-run-synthetic",
                "preprocessing": "first-run-synthetic",
                "backend": backend,
            }
        ),
        flush=True,
    )
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if request["op"] in ("encode", "embed") and not isinstance(
                request["text"], str
            ):
                raise ValueError("expected synthetic text")
            if request["op"] == "encode":
                result = list(request["text"].encode("utf-8"))
            elif request["op"] == "decode":
                result = bytes(request["tokens"]).decode("utf-8")
            elif request["op"] == "embed":
                result = [1.0, 0.0, 0.0, 0.0]
            else:
                raise ValueError("unknown operation")
            print(json.dumps({"result": result}), flush=True)
        except (KeyError, TypeError, ValueError, UnicodeError):
            print(json.dumps({"error": "Invalid synthetic worker request"}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
