#!/usr/bin/env python3
"""Derive independent producer inputs for the audio source/build consumer."""

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import tools.ci_app_dependency_seed as ci_app_dependency_seed
import tools.ci_linux_handoff as ci_linux_handoff
import tools.ci_tooling_image as ci_tooling_image


def prepare(sdk_image, output, seed, cache, root=None):
    """Verify pinned dependencies without building application or SDK bytes."""
    root = Path.cwd() if root is None else root
    output.mkdir(parents=True, exist_ok=True)
    if seed.exists() or seed.is_symlink():
        ci_app_dependency_seed.verify_existing(sdk_image, seed, cache, root)
    else:
        ci_app_dependency_seed.prepare(sdk_image, seed, cache, root)
    snapshot = json.loads((root / "tools/pins.json").read_text())["ubuntu_snapshot"]
    image_id = subprocess.check_output(
        ["docker", "image", "inspect", "--format", "{{.Id}}", sdk_image],
        text=True,
        timeout=60,
    ).strip()
    # Expected recipe metadata, not a claim that a tooling image was built here.
    tooling = output / "expected-tooling-inputs.json"
    tooling.write_text(
        json.dumps({"inputs": ci_tooling_image.identity(image_id, snapshot, root)})
    )
    inputs = ci_linux_handoff.input_identity(
        sdk_image,
        seed / "qualification.json",
        root / "packaging/build.Dockerfile",
        snapshot,
        tooling,
    )
    (output / "ci-inputs.json").write_text(json.dumps(inputs, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-image", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=Path, default=Path("build/app-dependency-seed"))
    parser.add_argument(
        "--cache", type=Path, default=Path("build/app-dependency-blobs")
    )
    args = parser.parse_args()
    prepare(args.sdk_image, args.output, args.seed, args.cache)


if __name__ == "__main__":
    main()
