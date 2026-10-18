#!/usr/bin/env python3
"""Assemble Foresight's macOS runtime using separately cached vendor libraries."""

import argparse
import json
from pathlib import Path
import shutil

from build_macos_vendor import ROOT, WHISPER_COMMIT, digest, download, run  # noqa: F401 - compatibility API
from build_macos_vendor import verify as verify_vendor
from litert_extensions import verify_extensions_manifest


def verify(prefix):
    manifest = json.loads((prefix / "runtime-manifest.json").read_text())
    if (
        manifest.get("inference_runtime") != "native-c-api"
        or manifest.get("whisper_commit") != WHISPER_COMMIT
    ):
        raise ValueError("Stale runtime cache")
    for executable, field in (
        ("whisper-cli", "whisper_sha256"),
        ("foresight-whisper-worker", "whisper_worker_sha256"),
    ):
        if digest(prefix / "whisper" / executable) != manifest[field]:
            raise ValueError("Whisper runtime checksum mismatch")
    verify_extensions_manifest(
        prefix / "litert-extensions/build-manifest.json", platform_name="darwin"
    )
    run(prefix / "whisper/whisper-cli", "--help")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / "build/macos-runtimes")
    parser.add_argument(
        "--vendor-prefix", type=Path, default=ROOT / "build/macos-vendor"
    )
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    prefix, vendor = args.prefix.resolve(), args.vendor_prefix.resolve()
    if (prefix / "runtime-manifest.json").exists():
        verify(prefix)
        return
    verify_vendor(vendor)
    prefix.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        vendor / "litert-extensions", prefix / "litert-extensions", dirs_exist_ok=True
    )
    shutil.copytree(vendor / "whisper", prefix / "whisper", dirs_exist_ok=True)
    build = prefix / "worker-build"
    run(
        "cmake",
        "-S",
        ROOT / "services/speech",
        "-B",
        build,
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
        "-DCMAKE_PREFIX_PATH=" + str(vendor / "whisper-sdk"),
    )
    run("cmake", "--build", build, "--parallel", args.jobs)
    shutil.copy2(
        build / "bin/foresight-whisper-worker",
        prefix / "whisper/foresight-whisper-worker",
    )
    shutil.rmtree(build)
    manifest = {
        "inference_runtime": "native-c-api",
        "whisper_commit": WHISPER_COMMIT,
        "whisper_sha256": digest(prefix / "whisper/whisper-cli"),
        "whisper_worker_sha256": digest(prefix / "whisper/foresight-whisper-worker"),
    }
    stamp = prefix / "runtime-manifest.json"
    stamp.write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        verify(prefix)
    except BaseException:
        stamp.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    main()
