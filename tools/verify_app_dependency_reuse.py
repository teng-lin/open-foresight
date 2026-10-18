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

# GNU Make 3.81 prints a backtick/apostrophe pair, not shell quoting.
# Only these complete status records may bypass command parsing.
MAKE_DIRECTORY_STATUS = re.compile(
    r"g?make(?:\[[0-9]+\])?: (?:Entering|Leaving) directory `/[^'`\r\n]*'"
)
# remake.c also uses this quoting for successful target/no-work diagnostics.
MAKE_NOOP_STATUS = re.compile(
    r"g?make(?:\[[0-9]+\])?: "
    r"(?:Nothing to be done for `[^'`\r\n]+'\.|`[^'`\r\n]+' is up to date\.)"
)


def dependency(path):
    return "_deps" in Path(path).parts


def planned_dependency_work(output):
    for line in output.splitlines():
        if MAKE_DIRECTORY_STATUS.fullmatch(line) or MAKE_NOOP_STATUS.fullmatch(line):
            continue
        try:
            tokens = shlex.split(line)
        except ValueError as error:
            raise ValueError(
                f"Unparseable dependency dry-run output: {line[:500]!r}"
            ) from error
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


def dependency_dry_runs(build, cache, generator):
    """Check every dependency subtree's ALL graph, excluding unbuilt app edges.

    Recursive Make -n does not create a just-planned application archive, so a
    later application target can fail to find it. Dependency outputs, however,
    must already exist in the qualified seed. Their complete ALL graphs include
    training libraries and tools as well as flatc and sentencepiece-static.
    """
    directories = sorted((build / "_deps").glob("*-build"))
    names = {directory.name for directory in directories}
    if not {"flatbuffers-build", "sentencepiece-build"}.issubset(names):
        raise ValueError("Qualified FlatBuffers/SentencePiece build trees are missing")
    if any(
        directory.is_symlink() or not directory.is_dir() for directory in directories
    ):
        raise ValueError("Dependency build trees must be regular directories")
    if generator == "Ninja":
        return [
            [
                "cmake",
                "--build",
                str(build),
                "--verbose",
                "--target",
                *(
                    directory.relative_to(build).as_posix() + "/all"
                    for directory in directories
                ),
                "--",
                "-n",
            ]
        ]
    program = re.search(r"^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$", cache, re.M)
    if (
        not program
        or not Path(program[1]).is_absolute()
        or Path(program[1]).name not in {"make", "gmake"}
    ):
        raise ValueError(
            "Dependency reuse guard requires the configured Make executable"
        )
    commands = []
    for directory in directories:
        if not (directory / "Makefile").is_file():
            raise ValueError("Dependency Make ALL graph is missing: " + str(directory))
        commands.append([program[1], "-C", str(directory), "-n", "VERBOSE=1", "all"])
    return commands


def verify(build, request=subprocess.check_output):
    cache = (build / "CMakeCache.txt").read_text()
    generator = re.search(
        r"^CMAKE_GENERATOR:INTERNAL=(Unix Makefiles|Ninja)$", cache, re.M
    )
    if not generator:
        raise ValueError(
            "Dependency reuse guard requires the reviewed Make or Ninja dry-run backend"
        )
    plan = build / "dependency-reuse-plan.log"
    output = ""
    for command in dependency_dry_runs(build, cache, generator[1]):
        output += "$ " + shlex.join(command) + "\n"
        plan.write_text(output)
        try:
            output += request(command, text=True, stderr=subprocess.STDOUT, timeout=120)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            diagnostic = error.output or ""
            if isinstance(diagnostic, bytes):
                diagnostic = diagnostic.decode("utf-8", errors="replace")
            output += diagnostic
            plan.write_text(output)
            status = (
                f"exit {error.returncode}"
                if isinstance(error, subprocess.CalledProcessError)
                else "timeout"
            )
            raise ValueError(
                f"Dependency ALL dry run failed ({status}); "
                f"preserve the seed and inspect {plan}:\n{diagnostic[-12000:]}"
            ) from error
        plan.write_text(output)
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
