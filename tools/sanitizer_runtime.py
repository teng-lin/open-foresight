#!/usr/bin/env python3
"""Locate Clang's installed shared sanitizer runtime across compiler layouts."""

import argparse
from pathlib import Path
import subprocess


def address_runtime(compiler="clang++", kind="address"):
    # New Clang releases use an unqualified SONAME in a target directory;
    # older releases expose an architecture-qualified file in lib/linux.
    # Resolve compatibility symlinks so the dynamic loader can find the SONAME
    # beside the actual library rather than only its compatibility alias.
    names = (
        ("libclang_rt.tsan.so", "libclang_rt.tsan-x86_64.so")
        if kind == "thread"
        else ("libclang_rt.asan.so", "libclang_rt.asan-x86_64.so")
    )
    for name in names:
        candidate = Path(
            subprocess.check_output(
                [compiler, "-print-file-name=" + name], text=True, timeout=30
            ).strip()
        )
        if candidate.is_absolute() and candidate.is_file():
            return candidate.resolve(strict=True)
    raise FileNotFoundError(
        f"{compiler} cannot locate its shared {'TSan' if kind == 'thread' else 'ASan'} runtime"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument("--directory", action="store_true")
    parser.add_argument("--kind", choices=("address", "thread"), default="address")
    args = parser.parse_args()
    runtime = address_runtime(args.compiler, args.kind)
    print(runtime.parent if args.directory else runtime)


if __name__ == "__main__":
    main()
