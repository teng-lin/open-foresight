"""Transport uses published layers without losing verified local parents."""

import json

import pytest

from tools import sdk_build_transport as transport


def docker_queries(*, driver="docker", containerd=True, context="setup-docker-action"):
    calls = []

    def query(arguments, **kwargs):
        calls.append(arguments)
        assert kwargs == {"text": True, "timeout": 60}
        if arguments == ["docker", "context", "show"]:
            return context + "\n"
        if arguments[:3] == ["docker", "buildx", "inspect"]:
            return json.dumps({"Driver": driver})
        return json.dumps(
            [["driver-type", "io.containerd.snapshotter.v1"]]
            if containerd
            else [["Backing Filesystem", "extfs"]]
        )

    return query, calls


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
        "--format",
        "{{json .}}",
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
