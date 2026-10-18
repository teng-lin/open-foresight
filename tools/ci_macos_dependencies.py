#!/usr/bin/env python3
"""Use trusted dependency artifacts, or build the pinned sources locally."""

import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import ROOT, fingerprint, pull  # noqa: E402
from tools.ci_verify_dependency import verify  # noqa: E402


def ensure(component, prefix, repository, own_head="", own_pr=0):
    if pull(
        repository,
        component,
        fingerprint(component),
        prefix,
        own_head=own_head,
        own_pr=own_pr,
    ):
        verify(component, prefix)
        return "artifact"
    if component == "macos-runtime":
        vendor = prefix.parent / "macos-vendor"
        ensure("macos-vendor", vendor, repository, own_head, own_pr)
        command = [
            sys.executable,
            str(ROOT / "tools/build_macos_runtimes.py"),
            "--prefix",
            str(prefix),
            "--vendor-prefix",
            str(vendor),
        ]
    else:
        script = (
            "build_macos_sdk.py"
            if component == "macos-sdk"
            else "build_macos_vendor.py"
        )
        command = [
            sys.executable,
            str(ROOT / "tools" / script),
            "--prefix",
            str(prefix),
        ]
    subprocess.run(command, check=True, timeout=10800)
    verify(component, prefix)
    return "local"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--component", choices=("macos-sdk", "macos-runtime"), required=True
    )
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-head", default="")
    parser.add_argument("--own-pr", type=int, default=0)
    args = parser.parse_args()
    print(
        ensure(args.component, args.prefix, args.repository, args.own_head, args.own_pr)
    )


if __name__ == "__main__":
    main()
