#!/usr/bin/env python3
"""Select expensive CI only for changes that can affect application outputs."""

import argparse
import json
import os
from pathlib import PurePosixPath
import subprocess


GATES = ("macos", "linux-native", "linux-document-imports", "linux-bundle")

# Explicit maintenance paths only: shared tools and unknown files select all gates.
MAINTENANCE = {
    "tools/release_latest.py",
    "tests/test_release_latest.py",
    "tools/cleanup_linux_packages.py",
    "tests/test_cleanup_linux_packages.py",
    "tools/publish_linux_package_aliases.py",
    "tests/test_publish_linux_package_aliases.py",
    ".github/workflows/linux-registry.yml",
    ".github/workflows/quality.yml",
}
MACOS_FILES = {
    "tools/ci_macos_dependencies.py",
    "tools/create_dmg.py",
    "tests/test_create_dmg.py",
    "tools/build_macos_sdk.py",
    "tools/build_macos_vendor.py",
    "tools/build_macos_runtimes.py",
    "tools/clean_macos_runtime_sources.py",
    "tools/install_macos.py",
    "tools/macos_bundle.py",
    "tools/package_macos.py",
    "tools/smoke_macos_bundle.py",
    "tools/verify_macos_release_runtime.py",
}
LINUX_FILES = {
    "packaging/build.Dockerfile",
    "packaging/sdk.Dockerfile",
    "packaging/sdk-core.Dockerfile",
    "packaging/sdk-litert.Dockerfile",
    "packaging/sdk-whisper.Dockerfile",
    "packaging/minimal-grpc.cmake",
    "packaging/package_linux.py",
    "tools/build_linux_sdk.sh",
    "tools/build_linux_sdk_local.sh",
    "tools/linux_sdk_artifacts.py",
    ".github/workflows/linux-packages.yml",
}


def select_gates(paths, force=False):
    selected = dict.fromkeys(GATES, force)
    for path in paths:
        # These Markdown notices are installed payloads, so editorial suffix
        # rules must not hide changes to the package's legal contents.
        if path.startswith("packaging/notices/"):
            for gate in GATES[1:]:
                selected[gate] = True
            continue
        if (
            path.startswith("docs/")
            or PurePosixPath(path).suffix == ".md"
            or path.startswith(".github/ISSUE_TEMPLATE/")
            or path in MAINTENANCE
        ):
            continue
        if path in MACOS_FILES or path.startswith(
            ("apps/desktop/macos/", "packaging/macos/")
        ):
            selected["macos"] = True
        elif path in LINUX_FILES or path.startswith(
            ("apps/desktop/linux/", "packaging/ci/")
        ):
            for gate in GATES[1:]:
                selected[gate] = True
        else:
            selected = dict.fromkeys(GATES, True)
    return selected


def requires_build(paths):
    return any(select_gates(paths).values())


def check_gates(jobs, selected, main):
    """Reject failed classification, malformed selection and skipped selected jobs."""
    if set(selected) != set(GATES) or any(
        type(value) is not bool for value in selected.values()
    ):
        raise ValueError("Invalid platform selection")
    expected = {"changes": "success"}
    expected.update(
        {
            name: "success"
            if required and (name != "linux-bundle" or main)
            else "skipped"
            for name, required in selected.items()
        }
    )
    expected["macos-stages"] = expected["macos"]
    for name, result in expected.items():
        if jobs.get(name, {}).get("result") != result:
            raise ValueError(
                f"{name}: expected {result}, got {jobs.get(name, {}).get('result')}"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument("--check-gates", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.check_gates:
        check_gates(
            json.loads(os.environ["NEEDS"]),
            json.loads(os.environ["SELECTION"]),
            os.environ["MAIN"] == "true",
        )
        print("All selected platform gates passed.")
        return
    if not args.base:
        parser.error("--base is required for change classification")
    base = args.base
    if not base.strip("0"):
        base = subprocess.check_output(
            ["git", "hash-object", "-t", "tree", "/dev/null"], text=True, timeout=300
        ).strip()
    paths = (
        subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD"],
            timeout=300,
        )
        .decode()
        .split("\0")
    )
    subprocess.run(["git", "diff", "--check", base, "HEAD"], check=True, timeout=300)
    selected = select_gates([path for path in paths if path], force=args.force)
    print("Selected platform checks: " + json.dumps(selected, sort_keys=True))
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write("selection=" + json.dumps(selected, separators=(",", ":")) + "\n")
        for name, required in selected.items():
            stream.write(f"{name.replace('-', '_')}={str(required).lower()}\n")


if __name__ == "__main__":
    main()
