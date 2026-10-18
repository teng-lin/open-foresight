#!/usr/bin/env python3
"""Build the pinned gRPC/protobuf closure with the same sanitizers as its callers.

Mixing instrumented generated protobuf code with an uninstrumented system
protobuf library is unsupported: metadata layout and container annotations differ.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from build_macos_sdk import (
    GRPC_COMMIT,
    PROTOBUF_COMMIT,
    MODULES,
    checkout,
    require_clean_sources,
    run,
)
from sanitizer_runtime import address_runtime

ROOT = Path(__file__).resolve().parents[1]
FLAGS = "-O1 -g -shared-libasan -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / "build/sanitizer-sdk")
    parser.add_argument(
        "--sources", type=Path, default=ROOT / "build/sanitizer-sdk-sources"
    )
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    prefix, sources = args.prefix.resolve(), args.sources.resolve()
    compiler = subprocess.check_output(
        ["clang++", "--version"], text=True, timeout=30
    ).splitlines()[0]
    manifest = {
        "grpc_commit": GRPC_COMMIT,
        "protobuf_commit": PROTOBUF_COMMIT,
        "compiler": compiler,
        "flags": FLAGS,
        "recipe_sha256": hashlib.sha256(
            b"".join(
                path.read_bytes()
                for path in (
                    Path(__file__),
                    ROOT / "tools/sanitizer_runtime.py",
                    ROOT / "packaging/sanitizer-grpc.cmake",
                    ROOT / "packaging/minimal-grpc.cmake",
                )
            )
        ).hexdigest(),
    }
    # Installed generators must load the exact runtime and SDK libraries too.
    runtime = address_runtime().parent
    environment = dict(
        os.environ,
        LD_LIBRARY_PATH=os.pathsep.join(
            filter(
                None,
                (str(runtime), str(prefix / "lib"), os.environ.get("LD_LIBRARY_PATH")),
            )
        ),
        ASAN_OPTIONS="detect_leaks=0:halt_on_error=1",
        UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1",
    )
    stamp = prefix / "sanitizer-sdk.json"
    if stamp.exists():
        if json.loads(stamp.read_text()) != manifest:
            parser.error("Sanitizer SDK identity differs; choose a fresh prefix")
        if all(
            (prefix / file).exists()
            for file in (
                "bin/protoc",
                "bin/grpc_cpp_plugin",
                "lib/cmake/grpc/gRPCConfig.cmake",
                "lib/libprotobufd.so",
                "lib/libgrpc++.so",
            )
        ):
            run(prefix / "bin/protoc", "--version", env=environment)
            print("Verified instrumented SDK already installed:", prefix)
            return
    grpc = sources / "grpc"
    checkout(grpc, "https://github.com/grpc/grpc.git", GRPC_COMMIT)
    run(
        "git",
        "-C",
        grpc,
        "submodule",
        "update",
        "--init",
        "--recursive",
        "--depth",
        "1",
        *["third_party/" + module for module in MODULES],
    )
    for module in MODULES:
        require_clean_sources(grpc / "third_party" / module)
    if (
        subprocess.check_output(
            ["git", "-C", str(grpc / "third_party/protobuf"), "rev-parse", "HEAD"],
            text=True,
            timeout=30,
        ).strip()
        != PROTOBUF_COMMIT
    ):
        raise ValueError("gRPC protobuf submodule differs from the release SDK")
    build = sources / "build-clang"
    run(
        "cmake",
        "-S",
        grpc,
        "-B",
        build,
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=Debug",
        "-DCMAKE_C_COMPILER=clang",
        "-DCMAKE_CXX_COMPILER=clang++",
        "-DCMAKE_CXX_STANDARD=20",
        f"-DCMAKE_INSTALL_PREFIX={prefix}",
        "-DCMAKE_INSTALL_LIBDIR=lib",
        f"-DCMAKE_C_FLAGS={FLAGS}",
        f"-DCMAKE_CXX_FLAGS={FLAGS}",
        "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined -shared-libasan",
        "-DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address,undefined -shared-libasan",
        "-DBUILD_SHARED_LIBS=ON",
        "-DBUILD_TESTING=OFF",
        "-DgRPC_BUILD_TESTS=OFF",
        "-Dprotobuf_BUILD_TESTS=OFF",
        "-DRE2_BUILD_TESTING=OFF",
        "-DCARES_BUILD_TOOLS=OFF",
        "-DgRPC_SSL_PROVIDER=package",
        "-DgRPC_ZLIB_PROVIDER=package",
        *[
            f"-DgRPC_{name}_PROVIDER=module"
            for name in ("ABSL", "CARES", "PROTOBUF", "RE2")
        ],
        f"-DCMAKE_PROJECT_grpc_INCLUDE={ROOT / 'packaging/sanitizer-grpc.cmake'}",
        *[
            f"-DgRPC_BUILD_GRPC_{language}_PLUGIN=OFF"
            for language in ("CSHARP", "NODE", "OBJECTIVE_C", "PHP", "PYTHON", "RUBY")
        ],
        env=environment,
    )
    run("cmake", "--build", build, "--parallel", args.jobs, env=environment)
    run("cmake", "--install", build, env=environment)
    run(prefix / "bin/protoc", "--version", env=environment)
    prefix.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
