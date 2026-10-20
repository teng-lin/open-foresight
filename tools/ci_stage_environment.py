#!/usr/bin/env python3
"""Record the actual toolchain and runtime used to validate a CI stage."""

import argparse
import importlib
import json
from pathlib import Path

retained = importlib.import_module("tools.ci_build_environment" if __package__ else "ci_build_environment")
reject_compiler_overrides = retained.reject_compiler_overrides
validation_context = retained.validation_context
sdk_content_digest = retained.sdk_content_digest
version = retained.version
collect = retained.collect
with_build_settings = retained.with_build_settings

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux", "macos"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk-prefix", type=Path)
    parser.add_argument("--stage", choices=("native", "core", "desktop", "service"))
    args = parser.parse_args()
    record = collect(args.platform, sdk_prefix=args.sdk_prefix, stage=args.stage)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
