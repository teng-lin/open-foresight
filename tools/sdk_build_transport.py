"""Read-only registry layer reuse, separate from the SDK compiler recipe.

Call prepare() after the qualified-artifact probe misses and BEFORE loading any
parent images. The workflow must already have enabled Docker's containerd image
store. The current context's default docker-driver builder shares its daemon
with docker image load; a docker-container builder cannot see those parents.
"""

import json
import re
import subprocess

COMPONENTS = {"linux-core", "linux-litert", "linux-whisper", "linux-sdk"}


def cache_reference(repository, component, *, expected_repository):
    """Use only the fixed main-writable cache of this same GitHub repository."""
    repository = repository.lower()
    if (
        component not in COMPONENTS
        or not re.fullmatch(r"[a-z0-9_.-]+/[a-z0-9_.-]+", repository)
        or repository != expected_repository.lower()
    ):
        raise ValueError("SDK layer cache must belong to this repository and component")
    return f"ghcr.io/{repository}/{component}:buildcache"


def prepare(repository, component, *, expected_repository, check_output=None):
    """Validate registry-cache support before parent loads or SDK compilation.

    Return a transport command prefix. Never silently fall back to an expensive
    uncached compile when provisioning or builder selection is incorrect.
    """
    reference = cache_reference(
        repository, component, expected_repository=expected_repository
    )
    request = subprocess.check_output if check_output is None else check_output

    def output(arguments):
        return request(arguments, text=True, timeout=60)

    context = output(["docker", "context", "show"]).strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", context):
        raise RuntimeError("Invalid Docker context for SDK layer reuse")
    builder = json.loads(
        output(["docker", "buildx", "inspect", context, "--format", "{{json .}}"])
    )
    storage = json.loads(
        output(["docker", "info", "--format", "{{json .DriverStatus}}"])
    )
    if (
        builder.get("Driver") != "docker"
        or ["driver-type", "io.containerd.snapshotter.v1"] not in storage
    ):
        raise RuntimeError(
            "SDK registry layer reuse requires the current context's docker-driver "
            "builder and containerd image store, provisioned before parent image loads. "
            "Fix provisioning; do not start an uncached SDK build."
        )
    return [
        "docker",
        "buildx",
        "build",
        "--builder",
        context,
        "--load",
        "--cache-from",
        f"type=registry,ref={reference}",
    ]


def command(recipe_command, transport):
    """Preserve the reviewed compiler arguments; add only read-only transport."""
    if recipe_command[:2] != ["docker", "build"] or any(
        value == option or value.startswith(option + "=")
        for value in recipe_command[2:]
        for option in ("--push", "--cache-to", "--output")
    ):
        raise ValueError("SDK PR build command must not publish images or caches")
    return [*transport, *recipe_command[2:]]
