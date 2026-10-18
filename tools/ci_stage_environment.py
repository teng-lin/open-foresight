#!/usr/bin/env python3
"""Record the actual toolchain and runtime used to validate a CI stage."""

import argparse
import importlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def version(command, required=False):
    if not shutil.which(command[0]):
        if required:
            raise RuntimeError(f"Missing stage tool: {command[0]}")
        return None
    return subprocess.check_output(
        command, text=True, stderr=subprocess.STDOUT, timeout=30
    ).strip()


def collect(platform_name, root=ROOT, sdk_prefix=None):
    if platform_name not in ("linux", "macos"):
        raise ValueError("Unknown stage platform")
    record = {
        "schema": 1,
        "platform": platform_name,
        "system": platform.platform(),
        "machine": platform.machine(),
        "workspace": str(root.resolve()),
        "python": sys.version,
        "compiler": version(["c++", "--version"], required=True),
        "cmake": version(["cmake", "--version"], required=True),
        "ninja": version(["ninja", "--version"], required=True),
        "dart": version(["dart", "--version"]),
        "flutter": version(["flutter", "--version", "--machine"]),
        "pins": json.loads((root / "tools/pins.json").read_text()),
        "base_image": os.environ.get("FORESIGHT_STAGE_BASE_IMAGE"),
        "packages": version(["pacman", "-Q"], required=True)
        if platform_name == "linux"
        else version(["brew", "list", "--versions"], required=True),
    }
    if platform_name == "macos":
        record["apple_sdk"] = version(["xcrun", "--show-sdk-version"], required=True)
        record["xcode"] = version(["xcodebuild", "-version"], required=True)
    if sdk_prefix:
        artifacts = importlib.import_module(
            "tools.ci_artifacts" if __package__ else "ci_artifacts"
        )
        record["sdk"] = {
            "identity": artifacts.fingerprint("macos-sdk", root),
            "prefix": str(sdk_prefix.resolve()),
        }
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux", "macos"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk-prefix", type=Path)
    args = parser.parse_args()
    record = collect(args.platform, sdk_prefix=args.sdk_prefix)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
