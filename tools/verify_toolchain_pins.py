"""Check the actual stage tools against tools/pins.json without rebuilding SDKs."""

import argparse
import json
from pathlib import Path
import re
import subprocess

PINS = json.loads(Path(__file__).with_name("pins.json").read_text())


def output(command):
    result = subprocess.run(
        command, check=True, capture_output=True, text=True, timeout=30
    )
    # Dart versions have used stderr; Flutter machine JSON uses stdout and may
    # emit unrelated SDK initialization diagnostics on stderr.
    return result.stdout or result.stderr


def require(actual, expected, label):
    if actual != expected:
        raise ValueError(
            f"{label} is {actual!r}; tools/pins.json requires {expected!r}. "
            "Use the qualified toolchain; this check never rebuilds dependencies."
        )


def verify(stage, *, dart="dart", flutter="flutter", protoc="protoc"):
    if stage == "protoc":
        require(
            output([protoc, "--version"]).strip(),
            f"libprotoc {PINS['protoc']}",
            "protoc",
        )
        return
    version = re.search(r"Dart SDK version:\s+(\S+)", output([dart, "--version"]))
    require(version.group(1) if version else None, PINS["dart"], "Dart SDK")
    if stage == "desktop":
        value = json.loads(output([flutter, "--version", "--machine"]))
        require(
            value.get("frameworkVersion"), PINS["flutter"]["version"], "Flutter SDK"
        )
        require(
            value.get("frameworkRevision"),
            PINS["flutter"]["commit"],
            "Flutter revision",
        )
        require(value.get("dartSdkVersion"), PINS["dart"], "Flutter Dart SDK")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("core", "desktop", "protoc"))
    parser.add_argument("--dart", default="dart")
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--protoc", default="protoc")
    args = parser.parse_args()
    verify(args.stage, dart=args.dart, flutter=args.flutter, protoc=args.protoc)


if __name__ == "__main__":
    main()
