#!/usr/bin/env python3
"""Restore verified compiler work; callers must configure, compile and test anew."""

import argparse
import importlib
import json
import os
from pathlib import Path
import tempfile

cache = importlib.import_module(
    "tools.ci_stage_cache" if __package__ else "ci_stage_cache"
)
payloads = importlib.import_module(
    "tools.ci_stage_artifacts" if __package__ else "ci_stage_artifacts"
)
stage_environment = importlib.import_module(
    "tools.ci_stage_environment" if __package__ else "ci_stage_environment"
)

ROOT = Path(__file__).resolve().parents[1]


def restore(
    root,
    platform,
    environment,
    cmake_args,
    repository,
    own_pr=0,
    event="",
    branch="",
    release=False,
):
    """Keep original provenance and changed-source/configuration invalidation.

    This never queries successful validation results or publishes an artifact.
    Unresolved searches and API failures propagate rather than authorizing a
    cold build. Only a completed verified compatibility search can report miss.
    """
    stage_environment.reject_compiler_overrides()
    environment = stage_environment.with_build_settings(environment, cmake_args)
    with tempfile.TemporaryDirectory(prefix="ci-native-work-") as temporary:
        found = cache.find_native_work(
            repository,
            platform,
            environment,
            root,
            own_pr,
            event,
            branch,
            release,
            Path(temporary) / "compilation",
        )
        if not found["hit"]:
            print(
                "Native compiler work miss: " + json.dumps(found, sort_keys=True),
                flush=True,
            )
            return found
        payloads.unpack(
            root,
            platform,
            "native",
            Path(found["download_dir"]) / "payload.tar.gz",
            found["receipt"]["content"],
            force_changed=True,
        )
        if found.get("configuration_changed"):
            (root / "build/CMakeCache.txt").unlink(missing_ok=True)
            print(
                "Refresh changed CMake inputs: "
                + ", ".join(found["configuration_changed"]),
                flush=True,
            )
        # The temporary payload is gone on return; retain original receipt and
        # producer identity as evidence, without suggesting a new publication.
        result = {key: value for key, value in found.items() if key != "download_dir"}
        print(
            f"Restored verified native compiler work from original run "
            f"{found['run_id']}; current configure/build/tests are required",
            flush=True,
        )
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux", "macos"), default="linux")
    parser.add_argument("--sdk-prefix", type=Path)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument(
        "--branch",
        default=os.environ.get("GITHUB_HEAD_REF")
        or os.environ.get("GITHUB_REF_NAME", ""),
    )
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("cmake_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.repository:
        parser.error("--repository or GITHUB_REPOSITORY is required")
    cmake_args = args.cmake_args
    if cmake_args[:1] == ["--"]:
        cmake_args = cmake_args[1:]
    environment = stage_environment.collect(
        args.platform,
        ROOT,
        args.sdk_prefix,
        stage="native",
    )
    result = restore(
        ROOT,
        args.platform,
        environment,
        cmake_args,
        args.repository,
        args.own_pr,
        args.event,
        args.branch,
        args.release,
    )
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
