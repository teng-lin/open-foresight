#!/usr/bin/env python3
"""Reject a planned third-party rebuild before the Ubuntu application build.

CMake has already configured the tree. Make and Ninja support the same -n dry
run switch. Application compilation/linking remains required; only commands that
produce dependency outputs (or compile dependency sources) are forbidden. Never
interpret an unsupported generator or a failed dry run as permission to compile.
"""

import argparse
from pathlib import Path
import re
import shlex
import subprocess

TOOLS = re.compile(
    r"(?:c\+\+|g\+\+|gcc|cc|clang\+\+|clang|ar|gcc-ar|llvm-ar|ranlib|gcc-ranlib|llvm-ranlib|ld|ld.lld|lld)(?:-\d+(?:\.\d+)*)?$"
)


def dependency(path):
    return "_deps" in Path(path).parts


def planned_dependency_work(output):
    for line in output.splitlines():
        try:
            tokens = shlex.split(line)
        except ValueError as error:
            raise ValueError("Unparseable dependency dry-run output") from error
        if "cmake_link_script" in tokens:
            index = tokens.index("cmake_link_script")
            if index + 1 < len(tokens) and dependency(tokens[index + 1]):
                return line
        # Ninja prefixes commands with [n/m]; Make enters a dependency directory
        # before invoking its compiler/archive commands. Track that local cwd.
        cwd_dependency = False
        for index, word in enumerate(tokens):
            if word == "cd" and index + 1 < len(tokens):
                cwd_dependency = dependency(tokens[index + 1])
            if word == "cmake_link_script" and cwd_dependency:
                return line
            if not TOOLS.fullmatch(Path(word).name):
                continue
            arguments = tokens[index + 1 :]
            if "&&" in arguments:
                arguments = arguments[: arguments.index("&&")]
            output_path = (
                arguments[arguments.index("-o") + 1]
                if "-o" in arguments and arguments.index("-o") + 1 < len(arguments)
                else ""
            )
            source_path = (
                arguments[arguments.index("-c") + 1]
                if "-c" in arguments and arguments.index("-c") + 1 < len(arguments)
                else ""
            )
            if cwd_dependency or dependency(output_path) or dependency(source_path):
                return line
            if Path(word).name in {
                "ar",
                "gcc-ar",
                "llvm-ar",
                "ranlib",
                "gcc-ranlib",
                "llvm-ranlib",
            } and any(dependency(arg) for arg in arguments):
                return line
    return None


def verify(build, request=subprocess.check_output):
    cache = (build / "CMakeCache.txt").read_text()
    if not re.search(r"^CMAKE_GENERATOR:INTERNAL=(Unix Makefiles|Ninja)$", cache, re.M):
        raise ValueError(
            "Dependency reuse guard requires the reviewed Make or Ninja dry-run backend"
        )
    output = request(
        ["cmake", "--build", str(build), "--verbose", "--", "-n"],
        text=True,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    (build / "dependency-reuse-plan.log").write_text(output)
    if planned := planned_dependency_work(output):
        raise ValueError(
            "Qualified dependency outputs would compile or relink: "
            + planned
            + "\nPreserve the seed and inspect flags/timestamps; do not silently rebuild unchanged libraries."
        )
    print(
        "Verified dry run: no dependency compilation, archive creation or relinking planned."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    verify(args.build)


if __name__ == "__main__":
    main()
