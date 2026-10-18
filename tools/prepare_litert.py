#!/usr/bin/env python3
"""Extract the pinned standalone LiteRT-LM Linux x86_64 C runtime.

Python is a build tool only. No interpreter, modules or site-packages enter the
application bundle. Google's wheel is a transport for its native C library.
"""

import argparse
import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

VERSION = "0.18.0"
WHEEL_URL = "https://files.pythonhosted.org/packages/c9/8f/eb7a5203be1d48440c6b8d6e6382c3f744dd6d338fe400555718b4d695a1/litert_lm_api-0.18.0-py3-none-manylinux_2_27_x86_64.whl"
LIBRARY_SHA256 = "193a2d8581ff525a242334863f36b439e4ba8bd08f31a33d87c503be4fb61cff"
WHEEL_SHA256 = "b64e2cf6d7dcb90ff094b74af595cc5d53faa07e0889f967d15df8d3e696b53c"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    with urllib.request.urlopen(WHEEL_URL, timeout=120) as response:
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
