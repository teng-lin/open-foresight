"""Application caches remain usable with qualified local SDK archives."""

import json
from pathlib import Path
import subprocess

import pytest
import yaml

from tools import ci_app_build_transport as transport

ROOT = Path(__file__).resolve().parents[1]


def cli(arguments, **_kwargs):
    if arguments == ["docker", "context", "show"]:
        return "setup-docker-action\n"
    if arguments[:3] == ["docker", "buildx", "inspect"]:
        assert arguments[3] == "setup-docker-action"
        return '{"Driver":"docker"}'
    if arguments[:2] == ["docker", "info"]:
        return '[["driver-type","io.containerd.snapshotter.v1"]]'
    assert arguments == [
        "docker",
        "buildx",
        "imagetools",
        "inspect",
        "ghcr.io/teng-lin/open-foresight/linux-sdk:app-buildcache-x86-64",
        "--raw",
    ]
    return json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": "application/vnd.buildkit.cacheconfig.v0",
                "digest": "sha256:" + "a" * 64,
                "size": 123,
            },
            "layers": [],
        }
    )


def test_current_context_docker_builder_keeps_sdk_archive_visible():
    assert transport.prepare("teng-lin/open-foresight", request=cli) == {
        "builder": "setup-docker-action",
        "cache": "ghcr.io/teng-lin/open-foresight/linux-sdk:app-buildcache-x86-64",
        "cache_available": True,
    }


@pytest.mark.parametrize("wrong", ["builder", "storage"])
def test_missing_registry_support_never_silently_disables_reuse(wrong):
    def request(arguments, **kwargs):
        if wrong == "builder" and arguments[:3] == ["docker", "buildx", "inspect"]:
            return '{"Driver":"docker-container"}'
        if wrong == "storage" and arguments[:2] == ["docker", "info"]:
            return '[["Backing Filesystem","extfs"]]'
        return cli(arguments, **kwargs)

    with pytest.raises(RuntimeError, match="before loading the SDK"):
        transport.prepare("teng-lin/open-foresight", request=request)


def test_registry_failure_is_not_permission_to_compile_uncached():
    def request(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "imagetools"]:
            raise subprocess.CalledProcessError(
                1, arguments, stderr="TLS handshake timeout"
            )
        return cli(arguments, **kwargs)

    with pytest.raises(RuntimeError, match="retry lookup"):
        transport.prepare("teng-lin/open-foresight", request=request)


@pytest.mark.parametrize(
    "name,job",
    [("integration-acceptance.yml", "ubuntu-package"), ("macos.yml", "linux-bundle")],
)
def test_shared_daemon_is_provisioned_before_sdk_load_and_seed_is_always_consumed(
    name, job
):
    workflow = yaml.safe_load((ROOT / ".github/workflows" / name).read_text())
    selected = workflow["jobs"][job]
    steps = selected["steps"]
    setup = next(
        i
        for i, step in enumerate(steps)
        if step.get("uses", "").startswith("docker/setup-docker-action@")
    )
    fetch = next(i for i, step in enumerate(steps) if step.get("id") == "sdk")
    assert setup < fetch
    assert json.loads(steps[setup]["with"]["daemon-config"])["features"][
        "containerd-snapshotter"
    ]
    builders = [
        step
        for step in steps
        if step.get("uses", "").startswith("docker/setup-buildx-action@")
    ]
    assert len(builders) == 1 and builders[0]["with"]["driver"] == "docker"
    seed = next(
        step for step in steps if "ci_app_dependency_seed.py" in step.get("run", "")
    )
    assert seed["env"]["GH_TOKEN"] == "${{ github.token }}"
    builds = [
        step["with"]
        for step in steps
        if step.get("with", {}).get("file") == "packaging/build.Dockerfile"
    ]
    for build in builds:
        assert build["build-contexts"] == "appdeps_seed=./build/app-dependency-seed"
        assert "steps.app-cache.outputs.cache" in build["cache-from"]
        assert "steps.sdk.outputs.cache" not in build["cache-from"]
    exporters = [build for build in builds if "cache-to" in build]
    if job == "ubuntu-package":
        assert not exporters
        assert (
            selected.get("permissions", workflow["permissions"])["packages"] == "read"
        )
    else:
        assert "github.ref == 'refs/heads/main'" in selected["if"]
        assert len(exporters) == 1 and exporters[0]["target"] == "tested"
        assert selected["permissions"]["packages"] == "write"
