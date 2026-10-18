#!/usr/bin/env python3
"""Extract the pinned standalone LiteRT-LM Linux x86_64 C runtime.

Python is a build tool only. No interpreter, modules or site-packages enter the
application bundle. Google's wheel is a transport for its native C library.
"""

import argparse
import hashlib
import json
import io
from pathlib import Path
import urllib.request
import zipfile

PINS = json.loads(Path(__file__).with_name("pins.json").read_text())
LITERT_VERSION = PINS["litert_lm"]
VERSION = LITERT_VERSION
WHEEL_URL = PINS["litert_linux_wheel"]["url"]
LIBRARY_SHA256 = PINS["litert_linux_wheel"]["library_sha256"]
WHEEL_SHA256 = PINS["litert_linux_wheel"]["sha256"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if not WHEEL_URL.startswith("https://files.pythonhosted.org/"):
        raise ValueError("Pinned LiteRT wheel must use the official HTTPS transport")
    with urllib.request.urlopen(WHEEL_URL, timeout=120) as response:  # noqa: S310 - HTTPS host validated above.
        data = response.read()
    if hashlib.sha256(data).hexdigest() != WHEEL_SHA256:
        raise RuntimeError("LiteRT-LM archive checksum mismatch")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        library = archive.read("litert_lm/liblitert-lm.so")
    if hashlib.sha256(library).hexdigest() != LIBRARY_SHA256:
        raise RuntimeError("LiteRT-LM native library checksum mismatch")
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.destination.with_suffix(".part")
    temporary.write_bytes(library)
    temporary.replace(args.destination)
    print(
        f"{args.destination}: LiteRT-LM {VERSION}, sha256={hashlib.sha256(library).hexdigest()}"
    )


if __name__ == "__main__":
    main()
