#!/usr/bin/env python3
"""Prepare pinned standalone ONNX Runtime for native BERT model compatibility."""

import argparse
import hashlib
import io
from pathlib import Path
import tarfile
import urllib.request

VERSION = "1.31.0"
ARCHIVE_URL = "https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-linux-x64-1.31.0.tgz"
LIBRARY_SHA256 = "469849977cb60744ea160927e1a3a0643fd4c55c0aff743251c6d293402e334e"
ARCHIVE_SHA256 = "cc5c72baf5ae5c8238a6841f0897227be2d02826b9cf98eaf02fdefaeeb03a57"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    with urllib.request.urlopen(ARCHIVE_URL, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256:
        raise RuntimeError("ONNX Runtime archive checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        member = archive.extractfile(
            "onnxruntime-linux-x64-1.31.0/lib/libonnxruntime.so.1.31.0"
        )
        if member is None:
            raise RuntimeError("ONNX Runtime archive lacks its library")
        library = member.read()
    if hashlib.sha256(library).hexdigest() != LIBRARY_SHA256:
        raise RuntimeError("ONNX Runtime library checksum mismatch")
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.destination.with_suffix(".part")
    temporary.write_bytes(library)
    temporary.replace(args.destination)
    print(
        f"{args.destination}: ONNX Runtime {VERSION}, sha256={hashlib.sha256(library).hexdigest()}"
    )


if __name__ == "__main__":
    main()
