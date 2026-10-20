#!/usr/bin/env python3
"""Preserve the distribution identity when recovering a missing platform."""

import argparse
import os
import re
import subprocess

from tools.app_version import SOURCE
from tools.build_sequence import allocate
from tools.ci_artifacts import application_descriptor
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


def number(repository, source, platforms="all", reason=""):
    version, minimum = source_version(source)
    runs = candidate_runs(repository, source, consumer="release-candidate")
    requested = (
        {"linux-app", "macos-app"} if platforms == "all" else {platforms + "-app"}
    )
    if requested & runs.keys() and not reason.strip():
        raise ValueError(
            "Requested platform already has a verified candidate; package it instead. Select only the missing platform, or supply the exact output-affecting rebuild_reason."
        )
    if not runs or reason.strip():
        if reason.strip():
            print("Explicit candidate replacement reason: " + reason, flush=True)
        return allocate(repository, minimum)
    numbers = set()
    for component, run in runs.items():
        metadata = application_descriptor(
            repository, component, source, run, consumer="release-preparation"
        )
        value = metadata.get("build_number")
        if (
            metadata.get("version") != version
            or type(value) is not int
            or value < minimum
        ):
            raise ValueError(
                "Surviving candidate distribution identity is incompatible"
            )
        numbers.add(value)
    if len(numbers) != 1:
        raise ValueError(
            "Surviving platform build numbers disagree; do not relabel either output"
        )
    return numbers.pop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--platforms", default="all", choices=("all", "linux", "macos"))
    parser.add_argument("--reason", default="")
    args = parser.parse_args()
    value = number(
        os.environ["GITHUB_REPOSITORY"], args.source, args.platforms, args.reason
    )
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(
            f"version={source_version(args.source)[0]}\nbuild_number={value}\n"
        )


if __name__ == "__main__":
    main()
