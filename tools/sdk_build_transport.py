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
CACHE_CONFIG = "application/vnd.buildkit.cacheconfig.v0"
LAYER_TYPES = {
    "application/vnd.oci.image.layer.v1.tar",
    "application/vnd.oci.image.layer.v1.tar+gzip",
    "application/vnd.oci.image.layer.v1.tar+zstd",
}


def confirmed_absent(reference, error):
    """Recognize only registry manifest absence, never generic 'not found'."""
    message = error.strip()
    if re.fullmatch(
        r"(?:ERROR: )?"
        + re.escape(reference)
        + r": (?:not found|manifest unknown|name unknown)",
        message,
    ):
        return True
    repository, tag = reference.removeprefix("ghcr.io/").rsplit(":", 1)
    if re.fullmatch(
        r"(?:ERROR: )?unexpected status from (?:HEAD|GET) request to "
        + re.escape(f"https://ghcr.io/v2/{repository}/manifests/{tag}")
        + r": 404 Not Found",
        message,
    ):
        return True
    try:
        errors = json.loads(message)["errors"]
        return bool(errors) and all(
            item.get("code") in ("MANIFEST_UNKNOWN", "NAME_UNKNOWN") for item in errors
        )
    except (ValueError, TypeError, KeyError, AttributeError):
        return False


def inspect_registry_cache(reference, request):
    """Check remote metadata before BuildKit can warn and compile uncached."""
    try:
        raw = request(
            ["docker", "buildx", "imagetools", "inspect", reference, "--raw"],
            text=True,
            stderr=subprocess.PIPE,
            timeout=60,
        )
    except subprocess.CalledProcessError as error:
        message = error.stderr or ""
        if isinstance(message, bytes):
            message = message.decode(errors="replace")
        if confirmed_absent(reference, message):
            print(
                f"Registry confirms SDK layer cache {reference} is absent. "
                "The qualified artifact probe already missed; no registry layers can be reused.",
                flush=True,
            )
            return False
        raise RuntimeError(
            "SDK registry cache lookup failed (authentication, transport or unknown response). "
            "Preserve existing work and retry lookup; do not start an uncached SDK build."
        ) from error
    except (subprocess.TimeoutExpired, OSError) as error:
        raise RuntimeError(
            "SDK registry cache lookup is unavailable; retry lookup instead of compiling uncached."
        ) from error

    def descriptor(value):
        return (
            isinstance(value, dict)
            and isinstance(value.get("digest"), str)
            and re.fullmatch(r"sha256:[a-f0-9]{64}", value["digest"])
            and type(value.get("size")) is int
            and value["size"] >= 0
            and isinstance(value.get("mediaType"), str)
        )

    try:
        manifest = json.loads(raw)
        kind = manifest["mediaType"]
        if kind == "application/vnd.oci.image.manifest.v1+json":
            valid = (
                descriptor(manifest["config"])
                and manifest["config"]["mediaType"] == CACHE_CONFIG
                and isinstance(manifest["layers"], list)
                and all(
                    descriptor(layer) and layer["mediaType"] in LAYER_TYPES
                    for layer in manifest["layers"]
                )
            )
        elif kind == "application/vnd.oci.image.index.v1+json":
            layers = manifest["manifests"]
            valid = (
                isinstance(layers, list)
                and all(
                    descriptor(layer)
                    and layer["mediaType"] in LAYER_TYPES | {CACHE_CONFIG}
                    for layer in layers
                )
                and any(layer["mediaType"] == CACHE_CONFIG for layer in layers)
            )
        else:
            valid = False
        if (
            type(manifest["schemaVersion"]) is not int
            or manifest["schemaVersion"] != 2
            or not valid
        ):
            raise ValueError("Not a qualified OCI BuildKit cache manifest")
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        raise RuntimeError(
            "SDK registry returned an invalid cache manifest; inspect the existing cache instead of rebuilding."
        ) from error
    return True


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
    inspect_registry_cache(reference, request)
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
