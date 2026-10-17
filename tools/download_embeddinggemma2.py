#!/usr/bin/env python3
"""Acquire the pinned public EmbeddingGemma 2 bundle without replacing models."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "litert-community/embeddinggemma-2-740m-litert-lm"
REVISION = "24d962e906c7d332c6428e71c9676855024569e2"
FILENAME = "embeddinggemma-2-740m.litertlm"
SHA256 = "e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c"
SIZE = 484622336


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1048576), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--destination",
        type=Path,
        default=ROOT / "models/local/embeddinggemma2" / SHA256[:12],
    )
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    target = args.destination / FILENAME
    if target.exists():
        if target.stat().st_size != SIZE or file_hash(target) != SHA256:
            raise RuntimeError(
                "Existing model does not match the pinned artifact; preserved"
            )
    else:
        staging = args.destination / (FILENAME + "." + uuid.uuid4().hex + ".part")
        try:
            url = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{FILENAME}"
            digest = hashlib.sha256()
            size = 0
            with (
                urllib.request.urlopen(url, timeout=30) as response,
                staging.open("xb") as output,
            ):
                while block := response.read(1048576):
                    output.write(block)
                    digest.update(block)
                    size += len(block)
            if size != SIZE or digest.hexdigest() != SHA256:
                raise RuntimeError("Downloaded model size or SHA-256 does not match")
            # Publishing the verified file must never overwrite another writer.
            os.link(staging, target)
        finally:
            staging.unlink(missing_ok=True)
    receipt = {
        "repository": REPOSITORY,
        "revision": REVISION,
        "file": FILENAME,
        "sha256": SHA256,
        "bytes": SIZE,
        "license": "Apache-2.0",
        "source": "Public LiteRT Community conversion linked by Google",
        "limitation": "Exact Mac downloaded weight checksum is not established",
    }
    (args.destination / "asset-provenance.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )
    print(json.dumps({"model": str(target.resolve()), **receipt}), flush=True)


if __name__ == "__main__":
    main()
