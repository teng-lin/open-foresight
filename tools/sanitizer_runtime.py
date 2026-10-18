#!/usr/bin/env python3
"""Locate Clang's installed shared ASan runtime across compiler layouts."""
import argparse
from pathlib import Path
import subprocess


def address_runtime(compiler='clang++'):
    # New Clang releases use an unqualified SONAME in a target directory;
    # older releases expose an architecture-qualified file in lib/linux.
    # Resolve compatibility symlinks so the dynamic loader can find the SONAME
    # beside the actual library rather than only its compatibility alias.
    for name in ('libclang_rt.asan.so', 'libclang_rt.asan-x86_64.so'):
        candidate = Path(subprocess.check_output(
            [compiler, '-print-file-name=' + name], text=True, timeout=30).strip())
        if candidate.is_absolute() and candidate.is_file():
            return candidate.resolve(strict=True)
    raise FileNotFoundError(f'{compiler} cannot locate its shared ASan runtime')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='clang++')
    parser.add_argument('--directory', action='store_true')
    args = parser.parse_args()
    runtime = address_runtime(args.compiler)
    print(runtime.parent if args.directory else runtime)


if __name__ == '__main__':
    main()
