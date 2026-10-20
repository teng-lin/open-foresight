#!/usr/bin/env python3
"""Allocate a distribution identity only for a new tested release candidate."""

import argparse
import os
import re
import subprocess

from tools.app_version import SOURCE
from tools.build_sequence import allocate
from tools.prepare_release import candidate_runs


def source_version(source):
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Candidate source must be a full commit")
    contents = subprocess.check_output(
        ["git", "show", f"{source}:apps/desktop/pubspec.yaml"],
        text=True,
        timeout=30,
    )
    match = SOURCE.search(contents)
    if not match:
        raise ValueError(
            "Candidate source must declare a stable version and build number"
        )
    return match[1], int(match[2])


def number(repository, source):
    _, minimum = source_version(source)
    runs = candidate_runs(repository, source, consumer="release-candidate")
    if runs:
        raise ValueError(
            "Source already has a verified tested release candidate; reuse it instead of allocating another build"
        )
    return allocate(repository, minimum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    args = parser.parse_args()
    value = number(os.environ["GITHUB_REPOSITORY"], args.source)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(
            f"version={source_version(args.source)[0]}\nbuild_number={value}\n"
        )


if __name__ == "__main__":
    main()
