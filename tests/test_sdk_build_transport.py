"""Transport uses published layers without losing verified local parents."""

import json
from pathlib import Path
import subprocess

import pytest

from tools import sdk_build_transport as transport


def docker_queries(*, driver="docker", containerd=True, context="setup-docker-action"):
    calls = []

    def query(arguments, **kwargs):
        calls.append(arguments)
        if arguments[:3] == ["docker", "buildx", "imagetools"]:
            assert kwargs == {"text": True, "stderr": subprocess.PIPE, "timeout": 60}
            return cache_manifest()
        assert kwargs == {"text": True, "timeout": 60}
        if arguments == ["docker", "context", "show"]:
            return context + "\n"
        if arguments[:3] == ["docker", "buildx", "inspect"]:
            assert arguments == ["docker", "buildx", "inspect", context]
            return (
                (Path(__file__).parent / "fixtures/buildx/docker-inspect.txt")
                .read_text()
                .replace("Driver: docker", "Driver: " + driver)
            )
        return json.dumps(
            [["driver-type", "io.containerd.snapshotter.v1"]]
            if containerd
            else [["Backing Filesystem", "extfs"]]
        )

    return query, calls


def cache_manifest():
    return json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": transport.CACHE_CONFIG,
                "digest": "sha256:" + "a" * 64,
                "size": 100,
            },
            "layers": [],
        }
    )


def test_oci_cache_index_is_supported_without_downloading_layers():
    manifest = json.loads(cache_manifest())
    index = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [manifest["config"]],
    }
    assert transport.inspect_registry_cache(
        "ghcr.io/example/foresight/linux-core:buildcache",
        lambda *args, **kwargs: json.dumps(index),
    )


@pytest.mark.parametrize(
    "message",
    [
        "ERROR: ghcr.io/example/foresight/linux-core:buildcache: not found",
        '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}',
        "ERROR: unexpected status from HEAD request to https://ghcr.io/v2/example/foresight/linux-core/manifests/buildcache: 404 Not Found",
    ],
)
def test_confirmed_missing_registry_manifest_is_logged(message, capsys):
    def request(*args, **kwargs):
        raise subprocess.CalledProcessError(1, args[0], stderr=message)

    assert not transport.inspect_registry_cache(
        "ghcr.io/example/foresight/linux-core:buildcache", request
    )
    assert "registry layers can be reused" in capsys.readouterr().out


@pytest.mark.parametrize(
    "message",
    [
        "lookup ghcr.io: host not found",
        "manifest not found: 401 Unauthorized",
        "429 Too Many Requests",
        "TLS handshake failed",
        "connection refused",
        "500 Internal Server Error",
        "DNS lookup timed out",
        "unknown error",
    ],
)
def test_network_or_auth_failure_never_permits_uncached_compilation(message):
    def request(*args, **kwargs):
        raise subprocess.CalledProcessError(1, args[0], stderr=message)

    with pytest.raises(RuntimeError, match="do not start an uncached SDK build"):
        transport.inspect_registry_cache(
            "ghcr.io/example/foresight/linux-core:buildcache", request
        )


@pytest.mark.parametrize(
    "error", [subprocess.TimeoutExpired("docker", 60), OSError("unavailable")]
)
def test_unavailable_registry_command_fails_closed(error):
    def request(*args, **kwargs):
        raise error

    with pytest.raises(RuntimeError, match="instead of compiling uncached"):
        transport.inspect_registry_cache(
            "ghcr.io/example/foresight/linux-core:buildcache", request
        )


@pytest.mark.parametrize(
    "raw",
    [
        "{}",
        "[]",
        "not JSON",
        '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{},"layers":[]}',
    ],
)
def test_invalid_registry_cache_manifest_does_not_become_cache_miss(raw):
    with pytest.raises(RuntimeError, match="invalid cache manifest"):
        transport.inspect_registry_cache(
            "ghcr.io/example/foresight/linux-core:buildcache",
            lambda *args, **kwargs: raw,
        )


def prepared(**changes):
    query, calls = docker_queries(**changes)
    return transport.prepare(
        "Example/Foresight",
        "linux-litert",
        expected_repository="example/foresight",
        check_output=query,
    ), calls


def test_registry_cache_preserves_local_parent_arguments_and_loads_result():
    prefix, calls = prepared()
    recipe = [
        "docker",
        "build",
        "-f",
        "/repo/sdk.Dockerfile",
        "-t",
        "foresight-litert:pr",
        "--build-arg",
        "CORE_IMAGE=foresight-core:pr",
        "/repo",
    ]
    assert transport.command(recipe, prefix) == [
        "docker",
        "buildx",
        "build",
        "--builder",
        "setup-docker-action",
        "--load",
        "--cache-from",
        "type=registry,ref=ghcr.io/example/foresight/linux-litert:buildcache",
        *recipe[2:],
    ]
    assert calls[1] == [
        "docker",
        "buildx",
        "inspect",
        "setup-docker-action",
    ]
    assert recipe[:2] == ["docker", "build"]  # Recipe itself is not modified.


@pytest.mark.parametrize(
    "options", [{"driver": "docker-container"}, {"containerd": False}]
)
def test_missing_cache_prerequisite_never_authorizes_uncached_build(options):
    with pytest.raises(RuntimeError, match="do not start an uncached SDK build"):
        prepared(**options)


@pytest.mark.parametrize(
    "repository,component",
    [
        ("foreign/repo", "linux-core"),
        ("example/foresight,mode=max", "linux-core"),
        ("example/foresight", "other"),
    ],
)
def test_no_foreign_namespace_or_cache_parameter_injection(repository, component):
    with pytest.raises(ValueError, match="this repository"):
        transport.prepare(
            repository,
            component,
            expected_repository="example/foresight",
            check_output=lambda *args: pytest.fail("No Docker command should run"),
        )


@pytest.mark.parametrize(
    "option", ["--push", "--cache-to=type=registry,ref=foreign", "--output"]
)
def test_pr_transport_cannot_write_registry_or_other_outputs(option):
    with pytest.raises(ValueError, match="must not publish"):
        transport.command(
            ["docker", "build", option, "."], ["docker", "buildx", "build"]
        )


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "driver: docker\n",
        "prefix Driver: docker\n",
        "Driver: docker\nDriver: docker-container\n",
        "Driver: docker trailing\n",
        "Driver: \n",
        '{"Driver":"docker"}',
    ],
)
def test_builder_driver_requires_one_anchored_plain_field(raw):
    with pytest.raises(RuntimeError, match="exactly one valid anchored Driver"):
        transport.inspect_builder_driver(
            "setup-docker-action", lambda *args, **kwargs: raw
        )
