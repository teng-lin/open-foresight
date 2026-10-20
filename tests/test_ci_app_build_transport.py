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
        assert arguments == ["docker", "buildx", "inspect", "setup-docker-action"]
        return (ROOT / "tests/fixtures/buildx/docker-inspect.txt").read_text()
    if arguments[:2] == ["docker", "info"]:
        return '[["driver-type","io.containerd.snapshotter.v1"]]'
    assert arguments[:4] == ["docker", "buildx", "imagetools", "inspect"]
    assert arguments[4] in (
        "ghcr.io/teng-lin/open-foresight/linux-sdk:app-buildcache-x86-64",
        "ghcr.io/teng-lin/open-foresight/linux-sdk:app-deps-buildcache-v1",
        "ghcr.io/teng-lin/open-foresight/linux-sdk:ci-tools-buildcache-v1",
        "ghcr.io/teng-lin/open-foresight/linux-sdk:acceptance-tools-buildcache-v1",
    )
    assert arguments[5] == "--raw"
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


@pytest.mark.parametrize(
    "stage,tag",
    [
        ({}, "app-deps-buildcache-v1"),
        ({"ci": True}, "ci-tools-buildcache-v1"),
        ({"acceptance": True}, "acceptance-tools-buildcache-v1"),
    ],
)
def test_current_context_docker_builder_keeps_sdk_archive_visible(stage, tag):
    assert transport.prepare("teng-lin/open-foresight", request=cli, **stage) == {
        "builder": "setup-docker-action",
        "cache": "ghcr.io/teng-lin/open-foresight/linux-sdk:" + tag,
        "legacy_cache": "ghcr.io/teng-lin/open-foresight/linux-sdk:app-buildcache-x86-64",
        "cache_available": True,
    }


@pytest.mark.parametrize("wrong", ["builder", "storage"])
def test_missing_registry_support_never_silently_disables_reuse(wrong):
    def request(arguments, **kwargs):
        if wrong == "builder" and arguments[:3] == ["docker", "buildx", "inspect"]:
            return "Name: setup-docker-action\nDriver: docker-container\n"
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
    [
        ("integration-acceptance.yml", "ubuntu-application"),
        ("macos.yml", "linux-bundle"),
    ],
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
        assert "steps.app-cache.outputs.legacy_cache" in build["cache-from"]
        assert "steps.sdk.outputs.cache" not in build["cache-from"]
        assert "REQUIRE_DEPENDENCY_REUSE=1" in build["build-args"]
    exporters = [build for build in builds if "cache-to" in build]
    if job == "ubuntu-application":
        assert not exporters
        assert (
            selected.get("permissions", workflow["permissions"])["packages"] == "read"
        )
    else:
        assert "github.ref == 'refs/heads/main'" in selected["if"]
        assert (
            len(exporters) == 1 and exporters[0]["target"] == "application-dependencies"
        )
        assert "legacy_cache" not in exporters[0]["cache-to"]
        assert selected["permissions"]["packages"] == "write"


def test_new_cache_absence_retains_original_seed_and_does_not_republish_it(capsys):
    def request(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "imagetools"] and arguments[
            4
        ].endswith(":app-deps-buildcache-v1"):
            raise subprocess.CalledProcessError(
                1, arguments, stderr=arguments[4] + ": not found"
            )
        return cli(arguments, **kwargs)

    result = transport.prepare("teng-lin/open-foresight", request=request)
    assert result["cache_available"] is False
    assert result["cache"].endswith(":app-deps-buildcache-v1")
    assert result["legacy_cache"].endswith(":app-buildcache-x86-64")
    message = capsys.readouterr().out
    assert "qualified dependency objects remain required" in message
    assert "artifact probe already missed" not in message


def test_legacy_tag_disappearance_requires_recovery_not_dependency_rebuild():
    def request(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "imagetools"] and arguments[
            4
        ].endswith(":app-buildcache-x86-64"):
            raise subprocess.CalledProcessError(
                1, arguments, stderr=arguments[4] + ": not found"
            )
        return cli(arguments, **kwargs)

    with pytest.raises(RuntimeError, match="restore its reviewed manifest"):
        transport.prepare("teng-lin/open-foresight", request=request)


def test_registry_namespace_normalizes_github_repository_case():
    assert transport.reference("Teng-Lin/Open-Foresight") == transport.reference(
        "teng-lin/open-foresight"
    )


@pytest.mark.parametrize("flags", [[], ["--ci"], ["--acceptance"]])
def test_transport_cli_selects_only_one_cache_stage(monkeypatch, flags, capsys):
    import sys

    calls = []
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    monkeypatch.setattr(
        sys, "argv", ["ci_app_build_transport.py", "--repository", "owner/repo", *flags]
    )

    def prepare(repository, **options):
        calls.append((repository, options))
        return {"cache_available": True}

    monkeypatch.setattr(transport, "prepare", prepare)
    transport.main()
    assert calls == [
        ("owner/repo", {"ci": "--ci" in flags, "acceptance": "--acceptance" in flags})
    ]
    assert json.loads(capsys.readouterr().out) == {"cache_available": True}


def test_transport_rejects_combined_ci_and_acceptance(monkeypatch):
    import sys

    with pytest.raises(ValueError, match="Choose one"):
        transport.reference("owner/repo", ci=True, acceptance=True)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ci_app_build_transport.py",
            "--repository",
            "owner/repo",
            "--ci",
            "--acceptance",
        ],
    )
    with pytest.raises(SystemExit) as result:
        transport.main()
    assert result.value.code == 2
