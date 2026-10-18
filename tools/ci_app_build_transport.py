#!/usr/bin/env python3
"""Share secret-free Ubuntu application layers with local qualified SDK images.

The Docker driver and containerd image store support both registry cache import
and SDK archives loaded into the same daemon. PR consumers never export caches;
only the existing main-only linux-bundle job publishes its tested stage.
"""

import argparse
from contextlib import redirect_stdout
import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.sdk_build_transport import inspect_registry_cache  # noqa: E402


def reference(repository, *, legacy=False):
    repository = repository.lower()
    if not re.fullmatch(r"[a-z0-9_.-]+/[a-z0-9_.-]+", repository):
        raise ValueError(
            "Application cache repository must be an explicit GitHub repository"
        )
    tag = "app-buildcache-x86-64" if legacy else "app-deps-buildcache-v1"
    return f"ghcr.io/{repository}/linux-sdk:{tag}"


def prepare(repository, *, request=subprocess.check_output):
    """Fail on broken transport instead of silently compiling without the cache."""
    cache = reference(repository)
    legacy_cache = reference(repository, legacy=True)
    context = request(["docker", "context", "show"], text=True, timeout=60).strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", context):
        raise RuntimeError("Invalid current Docker context")
    builder = json.loads(
        request(
            ["docker", "buildx", "inspect", context, "--format", "{{json .}}"],
            text=True,
            timeout=60,
        )
    )
    storage = json.loads(
        request(
            ["docker", "info", "--format", "{{json .DriverStatus}}"],
            text=True,
            timeout=60,
        )
    )
    if (
        builder.get("Driver") != "docker"
        or ["driver-type", "io.containerd.snapshotter.v1"] not in storage
    ):
        raise RuntimeError(
            "Application layer reuse needs the current Docker context's docker driver "
            "and containerd image store, configured before loading the SDK archive"
        )
    # Reuse the strict OCI/error parser without its SDK-specific miss message:
    # application builds still require the separately qualified dependency seed.
    with redirect_stdout(io.StringIO()):
        available = inspect_registry_cache(cache, request)
        legacy_available = inspect_registry_cache(legacy_cache, request)
    if not available:
        print(
            "Registry confirms the application cache is absent; retained qualified "
            "dependency objects remain required before application compilation.",
            flush=True,
        )
    if not legacy_available:
        raise RuntimeError(
            "The retained legacy application-cache tag is missing; restore its reviewed "
            "manifest instead of discarding the existing dependency objects"
        )
    return {
        "builder": context,
        "cache": cache,
        "legacy_cache": legacy_cache,
        "cache_available": available,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    outputs = prepare(args.repository)
    if destination := os.environ.get("GITHUB_OUTPUT"):
        with open(destination, "a") as stream:
            for name, value in outputs.items():
                stream.write(
                    f"{name}={str(value).lower() if isinstance(value, bool) else value}\n"
                )
    print(json.dumps(outputs, sort_keys=True))


if __name__ == "__main__":
    main()
