"""Quality-only edits preserve Ubuntu binaries and trusted tooling cache layers."""

from pathlib import Path
import subprocess

import pytest
import yaml

from tools import ci_app_build_transport as transport
from tools import ci_changes as changes
from test_ci_app_build_transport import cli

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())


@pytest.mark.parametrize(
    "path",
    [
        "tests/test_new_offline_regression.py",
        "tests/test_build_environment_guards.py",
        "tests/test_profile_migration_failure_paths.py",
        ".coveragerc",
        "pytest.ini",
        "pytest-exclusions.json",
        "pyproject.toml",
        "tools/evaluate_pipeline.py",
    ],
)
def test_quality_only_changes_do_not_select_application_builds(path):
    assert not any(changes.select_gates([path]).values())
    assert all(changes.select_gates([path], force=True).values())


@pytest.mark.parametrize(
    "path",
    [
        "tests/native/new.cpp",
        "tests/inference/test_new.py",
        "tests/service/test_new.py",
        "tests/conftest.py",
        "tests/new-platform/test_new.py",
        "new/unknown.py",
        "apps/desktop/test/new_test.dart",
        "packages/foresight_core/test/new_test.dart",
    ],
)
def test_runtime_suites_and_unknown_inputs_keep_platform_validation(path):
    assert all(changes.select_gates([path]).values())


def test_mixed_changes_preserve_packaging_and_apple_runtime_gates():
    assert {
        gate
        for gate, needed in changes.select_gates(
            [
                "tests/test_new_offline_regression.py",
                "tests/test_macos_tools.py",
                "tests/test_linux_packages.py",
            ]
        ).items()
        if needed
    } == {"macos", "packaging"}


def test_main_sdk_is_loaded_before_dependency_inspection():
    steps = workflow("macos.yml")["jobs"]["linux-bundle"]["steps"]
    sdk = next(step for step in steps if step.get("id") == "sdk")
    seed = next(
        step for step in steps if "ci_app_dependency_seed.py" in step.get("run", "")
    )
    assert (
        "resolve --prefix build/sdk-descriptor --load --discard-archive" in sdk["run"]
    )
    assert steps.index(sdk) < steps.index(seed)
    assert "ci_dependency_wait.py --component linux-sdk" in sdk["run"]


def test_acceptance_dependency_cache_is_read_only_for_prs_and_main_published():
    consumer = workflow("integration-acceptance.yml")["jobs"]["ubuntu-package"]
    publisher = workflow("macos.yml")["jobs"]["linux-bundle"]
    build = next(
        step["with"]
        for step in consumer["steps"]
        if step.get("id") == "acceptance-image"
    )
    assert "steps.acceptance-cache.outputs.cache" in build["cache-from"]
    assert "steps.acceptance-cache.outputs.legacy_cache" in build["cache-from"]
    assert "cache-to" not in build
    assert (
        consumer.get(
            "permissions", workflow("integration-acceptance.yml")["permissions"]
        )["packages"]
        == "read"
    )
    exports = [
        step["with"]
        for step in publisher["steps"]
        if step.get("with", {}).get("file") == "packaging/acceptance.Dockerfile"
    ]
    assert len(exports) == 1
    assert exports[0]["target"] == "acceptance-dependencies"
    assert "steps.acceptance-cache.outputs.cache" in exports[0]["cache-to"]
    assert "legacy_cache" not in exports[0]["cache-to"]
    assert "github.ref == 'refs/heads/main'" in publisher["if"]
    assert publisher["permissions"]["packages"] == "write"
    cache_steps = [
        step
        for step in publisher["steps"]
        if step.get("id") == "acceptance-cache"
        or step.get("with", {}).get("file") == "packaging/acceptance.Dockerfile"
        or "cache-to" in step.get("with", {})
    ]
    assert all(
        step["if"] == "github.ref == 'refs/heads/main' && inputs.source == ''"
        for step in cache_steps
    )


def test_acceptance_dependencies_bind_sdk_and_all_path_dependency_manifests():
    text = (ROOT / "packaging/acceptance.Dockerfile").read_text()
    dependencies, source = text.split("FROM acceptance-dependencies AS acceptance\n")
    assert "FROM ${SDK_IMAGE} AS acceptance-dependencies" in dependencies
    assert "COPY . ." not in dependencies
    for package in ("packages/foresight_core", "apps/desktop"):
        assert f"{package}/pubspec.yaml {package}/pubspec.lock" in dependencies
    assert "COPY packages/foresight_test_support/pubspec.yaml" in dependencies
    assert dependencies.index("pubspec.lock") < dependencies.index(
        "dart pub get --enforce-lockfile"
    )
    assert "COPY . ." in source
    assert "cmake --build" not in text and "./tools/build.sh" not in text


@pytest.mark.parametrize("missing", [False, True])
def test_acceptance_cache_reuses_registry_transport_without_touching_sdk(
    missing, capsys
):
    cache = "ghcr.io/teng-lin/open-foresight/linux-sdk:acceptance-tools-buildcache-v1"
    commands = []

    def request(args, **kwargs):
        commands.append(args)
        if (
            args[:4] == ["docker", "buildx", "imagetools", "inspect"]
            and args[4] == cache
        ):
            if missing:
                raise subprocess.CalledProcessError(
                    1, args, stderr=cache + ": not found"
                )
            return cli(
                args[:4] + [transport.reference("teng-lin/open-foresight")] + args[5:],
                **kwargs,
            )
        return cli(args, **kwargs)

    result = transport.prepare(
        "teng-lin/open-foresight", request=request, acceptance=True
    )
    assert result["cache"] == cache
    assert result["cache_available"] is not missing
    assert all(args[1] in ("context", "info", "buildx") for args in commands)
    if missing:
        assert "only package/tool setup" in capsys.readouterr().out


def test_acceptance_cache_network_errors_cannot_become_cache_misses():
    def request(args, **kwargs):
        if args[:4] == ["docker", "buildx", "imagetools", "inspect"]:
            raise subprocess.CalledProcessError(1, args, stderr="HTTP 403")
        return cli(args, **kwargs)

    with pytest.raises(RuntimeError, match="retry lookup"):
        transport.prepare("teng-lin/open-foresight", request=request, acceptance=True)
