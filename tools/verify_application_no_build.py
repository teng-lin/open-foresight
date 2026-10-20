#!/usr/bin/env python3
"""Fail if a restored native tree would execute any build-producing command."""

import argparse
from pathlib import Path
import re
import shlex
import subprocess

# CMake's Make backend prints recursive bookkeeping even for a complete tree.
# Accept only those known no-work commands; unknown/custom commands fail closed.
STATUS = re.compile(r"(?:g?make(?:\[\d+\])?:.*|\[\d+/\d+\] .*|ninja: no work to do\.)")


def planned_work(output):
    for line in output.splitlines():
        if (
            not line.strip()
            or line.startswith(("Change Dir: ", "Run Build Command(s): "))
            or STATUS.fullmatch(line)
            and not line.startswith("[")
        ):
            continue
        try:
            words = shlex.split(line)
        except ValueError:
            return line
        if not words:
            continue
        if len(words) > 3 and words[0] == "cd" and words[2] == "&&":
            words = words[3:]
        if any(word in ("&&", "||", ";", "|", "&") for word in words):
            return line
        program = Path(words[0]).name
        if program in ("make", "gmake") and "-f" in words:
            continue
        if program == "cmake":
            if "--check-build-system" in words:
                continue
            if (
                len(words) > 2
                and words[1] == "-E"
                and words[2]
                in (
                    "cmake_progress_start",
                    "cmake_depends",
                )
            ):
                continue
            if (
                len(words) > 2
                and words[1:3] == ["-E", "cmake_echo_color"]
                and any(word.startswith("Built target ") for word in words)
            ):
                continue
        if program == "ninja:" and words[1:] == ["no", "work", "to", "do."]:
            continue
        return line
    return None


def verify(build):
    command = ["cmake", "--build", str(build), "--verbose", "--", "-n"]
    result = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    report = build / "application-no-build-plan.log"
    report.write_text(result.stdout)
    if result.returncode or (planned := planned_work(result.stdout)):
        raise ValueError(
            f"Restored application build is not idle (exit {result.returncode}); "
            f"preserve {report} and inspect timestamps/configuration. "
            + (planned if result.returncode == 0 else result.stdout[-12000:])
        )
    print("Verified full application dry-run: no compilation, generation or linking.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    verify(args.build)


if __name__ == "__main__":
    main()
