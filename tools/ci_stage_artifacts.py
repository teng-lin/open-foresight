#!/usr/bin/env python3
"""Package independent CI stages, preserving modes and validating restored trees."""

import argparse
import importlib
import json
from pathlib import Path

ci_git = importlib.import_module("tools.ci_git" if __package__ else "ci_git")
digest = ci_git.digest
source_times = ci_git.source_times
restore_source_times = ci_git.restore_source_times

retained = importlib.import_module(
    "tools.ci_build_artifacts" if __package__ else "ci_build_artifacts"
)
roots = retained.roots
allowed = retained.allowed
entry = retained.entry
content = retained.content
pack = retained.pack
restore_legacy_ninja_times = retained.restore_legacy_ninja_times
discard_unlisted_event_reports = retained.discard_unlisted_event_reports
unpack = retained.unpack

ROOT = Path(__file__).resolve().parents[1]
NATIVE_PATHS = (
    "build/CMakeCache.txt",
    "build/CMakeFiles",
    "build/_deps",
    "build/Testing",
    "build/build.ninja",
    "build/.ninja_deps",
    "build/.ninja_log",
    "build/Makefile",
    "build/cmake_install.cmake",
    "build/CTestTestfile.cmake",
    "build/native",
    "build/services",
    "build/macos",
    "build/sdk/foresight-sdk.json",
    "build/sdk/share/foresight-sdk/licenses",
)


# Consumers execute these products; they never need CMake objects, third-party
# source/build trees or the compiler SDK. Keep only the SDK notices for packaging.
NATIVE_RUNTIME_PATHS = (
    "build/native/libforesight_native.so",
    "build/native/libforesight_native.dylib",
    "build/native/libforesight_sql_support.so",
    "build/native/libforesight_sql_support.dylib",
    "build/native/libforesight_diagnostic_support.so",
    "build/native/libforesight_diagnostic_support.dylib",
    "build/native/foresight-diagnostic-launcher",
    "build/native/diagnostic-native-inputs.json",
    "build/native/diagnostic-toolchain-metadata.json",
    "build/native/diagnostic-products.json",
    "build/native/diagnostic-sql-inputs.json",
    "build/native/runtime-support-build.json",
    "build/native/foresight-audio",
    "build/native/native_recording_capture_test",
    "build/services/helper/ForesightHelper",
    "build/services/helper/ForesightHelperTest",
    "build/services/helper/model_worker_fixture",
    "build/services/inference/foresight-model",
    "build/services/inference/foresight-query",
    "build/macos/foresight-notifications",
    "build/macos/foresight-file-parser",
    "build/macos/foresight-model-crypto",
    "build/macos/libforesight_sqlite3.dylib",
    "build/macos/foresight-sqlite3.json",
    "build/sdk/foresight-sdk.json",
    "build/sdk/share/foresight-sdk/licenses",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("pack", "unpack"))
    parser.add_argument("--platform", choices=("linux", "macos"), required=True)
    parser.add_argument(
        "--stage",
        choices=("native", "native-runtime", "core", "desktop", "service"),
        required=True,
    )
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    if args.command == "pack":
        if not args.output:
            parser.error("pack requires --output")
        pack(args.root, args.platform, args.stage, args.output)
    else:
        if not args.archive or not args.manifest:
            parser.error("unpack requires --archive and --manifest")
        unpack(
            args.root,
            args.platform,
            args.stage,
            args.archive,
            json.loads(args.manifest.read_text()),
        )


if __name__ == "__main__":
    main()
