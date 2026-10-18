#!/usr/bin/env python3
"""Opt-in pinned real model/runtime installation (~1.2GB downloads).
python3 native/setup_models.py --directory ~/.local/share/open-foresight/local-models
Requires git, cmake, a C/C++ compiler, Python3 and OpenSSL development headers.
No system package changes. Existing verified assets are reused.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--directory", type=Path, required=True)
    p.add_argument("--jobs", type=int, default=4)
    a = p.parse_args()
    root = a.directory.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    registry = json.loads((Path(__file__).parent / "model_registry.json").read_text())
    installed = {}
    for kind in ["generation", "speech"]:
        entry = registry[kind]
        asset = root / entry["file"]
        if not asset.exists() or digest(asset) != entry["sha256"]:
            partial = asset.with_suffix(asset.suffix + ".partial")
            print("Downloading", entry["id"], flush=True)
            with (
                urllib.request.urlopen(entry["download"], timeout=120) as response,  # noqa: S310 - URL scheme is fixed or validated before opening.
                partial.open("wb") as f,
            ):
                shutil.copyfileobj(response, f, 1024 * 1024)
            if digest(partial) != entry["sha256"]:
                partial.unlink()
                raise RuntimeError("Asset digest mismatch: " + entry["id"])
            partial.replace(asset)
        source = root / (kind + "-runtime-source")
        build = source / "build"
        if not source.exists():
            subprocess.run(["git", "init", str(source)], check=True, timeout=3600)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "remote",
                    "add",
                    "origin",
                    entry["runtime_repository"],
                ],
                check=True,
                timeout=3600,
            )
        subprocess.run(
            [
                "git",
                "-C",
                str(source),
                "fetch",
                "--depth",
                "1",
                "origin",
                entry["runtime_revision"],
            ],
            check=True,
            timeout=3600,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(source),
                "checkout",
                "--detach",
                entry["runtime_revision"],
            ],
            check=True,
            timeout=3600,
        )
        options = ["-DGGML_NATIVE=OFF", "-DGGML_CUDA=OFF", "-DBUILD_SHARED_LIBS=OFF"]
        options += (
            ["-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_CURL=OFF"]
            if kind == "generation"
            else ["-DWHISPER_BUILD_TESTS=OFF"]
        )
        subprocess.run(
            ["cmake", "-S", str(source), "-B", str(build), *options],
            check=True,
            timeout=3600,
        )
        subprocess.run(
            [
                "cmake",
                "--build",
                str(build),
                "--target",
                entry["executable"],
                "-j",
                str(max(1, a.jobs)),
            ],
            check=True,
            timeout=3600,
        )
        executable = root / entry["executable"]
        shutil.copy2(build / "bin" / entry["executable"], executable)
        installed[kind] = {
            "id": entry["id"],
            "model": str(asset),
            "runtime": str(executable),
            "sha256": entry["sha256"],
            "runtime_revision": entry["runtime_revision"],
            "capabilities": entry["effective_capabilities"],
        }
    (root / "installed.json").write_text(json.dumps(installed, indent=2) + "\n")
    print("Registered local paths:", root / "installed.json")


if __name__ == "__main__":
    main()
