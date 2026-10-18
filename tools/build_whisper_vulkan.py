#!/usr/bin/env python3
"""Build a local whisper.cpp checkout with Vulkan; never install system packages."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--build", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--vulkan-include", type=Path)
    parser.add_argument("--vulkan-library", type=Path)
    parser.add_argument("--spirv-prefix", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    command = [
        "cmake",
        "-S",
        str(args.source),
        "-B",
        str(args.build),
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DGGML_VULKAN=ON",
        "-DGGML_NATIVE=OFF",
        "-DWHISPER_BUILD_TESTS=OFF",
        "-DWHISPER_BUILD_EXAMPLES=ON",
    ]
    if args.vulkan_include:
        command.append("-DVulkan_INCLUDE_DIR=" + str(args.vulkan_include))
    if args.vulkan_library:
        command.append("-DVulkan_LIBRARY=" + str(args.vulkan_library))
    if args.spirv_prefix:
        command.extend(
            [
                "-DCMAKE_PREFIX_PATH=" + str(args.spirv_prefix),
                "-DCMAKE_CXX_FLAGS=-I" + str(args.spirv_prefix / "include"),
            ]
        )
    subprocess.run(command, check=True, timeout=3600)
    subprocess.run(
        [
            "cmake",
            "--build",
            str(args.build),
            "--target",
            "whisper-cli",
            "-j",
            str(args.jobs),
        ],
        check=True,
        timeout=3600,
    )
    executable = args.build / "bin/whisper-cli"
    dependencies = subprocess.check_output(
        ["ldd", str(executable)], text=True, timeout=300
    )
    if "not found" in dependencies:
        raise RuntimeError(dependencies)
    args.output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, args.output / "whisper-cli")
    shutil.copy2(args.source / "LICENSE", args.output / "LICENSE")
    provenance = {
        "source": "https://github.com/ggml-org/whisper.cpp",
        "commit": subprocess.check_output(
            ["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True, timeout=300
        ).strip(),
        "configure": command,
        "dependencies": dependencies,
        "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "backend": "Vulkan; CPU available with -ng",
    }
    (args.output / "provenance.json").write_text(
        json.dumps(provenance, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
