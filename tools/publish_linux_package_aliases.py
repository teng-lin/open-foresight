#!/usr/bin/env python3
"""Publish readable Linux aliases from qualified descriptors for current main."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import ci_registry as registry  # noqa: E402
from tools.linux_sdk_artifacts import COMPONENTS, record  # noqa: E402


def require_main(repository, head):
    main = json.loads(
        subprocess.check_output(
            ["gh", "api", f"repos/{repository}/commits/main"], text=True, timeout=300
        )
    )["sha"]
    if main != head:
        raise RuntimeError("Main advanced; refusing to publish stale aliases")


def publish(repository):
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, timeout=30
    ).strip()
    require_main(repository, head)
    for component in COMPONENTS:
        identity = artifacts.fingerprint(component)
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory) / "descriptor"
            if not artifacts.pull(
                repository, component, identity, prefix, own_head=head
            ):
                raise RuntimeError(
                    f"Qualified {component} descriptor unavailable; run dependency CI"
                )
            descriptor = record(prefix, component)
        image = descriptor.get("image", "")
        expected = f"ghcr.io/{repository.lower()}/{component}"
        if descriptor.get(
            "transport", "registry"
        ) != "registry" or not image.startswith(expected + "@sha256:"):
            raise ValueError(
                "Alias source must be this package's immutable registry image"
            )
        require_main(repository, head)
        alias = expected + ":current"
        subprocess.run(
            [
                "docker",
                "buildx",
                "imagetools",
                "create",
                "--prefer-index=false",
                "--tag",
                alias,
                image,
            ],
            check=True,
            timeout=300,
        )
        if registry.inspect(alias) != image:
            raise RuntimeError(f"Published alias digest mismatch: {alias}")
        print(f"Verified {alias} -> {image}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    publish(args.repository)


if __name__ == "__main__":
    main()
