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
    } == {"macos", "packaging", "dmg", "linux-build", "linux-test"}


def test_current_build_resolves_the_sdk_before_dependency_inspection():
    steps = workflow("macos.yml")["jobs"]["linux-build"]["steps"]
    sdk = next(step for step in steps if step.get("id") == "sdk")
    build = next(
        step
        for step in steps
        if "build_linux_container.sh --build-only" in step.get("run", "")
    )
    assert steps.index(sdk) < steps.index(build)
    assert "ci_linux_shadow_sdk.py" in sdk["run"]
    script = (ROOT / "tools/build_linux_container.sh").read_text()
    assert script.index("ci_app_dependency_seed.py") < script.index(
        "docker buildx build"
    )
    resolver = (ROOT / "tools/ci_linux_shadow_sdk.py").read_text()
    assert "sdk.resolve(prefix, load_registry=True)" in resolver
    assert '(prefix / "image.tar").unlink(missing_ok=True)' in resolver
    assert "sdk.write_outputs(load(prefix))" in resolver


def test_acceptance_dependency_cache_is_read_only_for_prs_and_main_published():
    jobs = workflow("macos.yml")["jobs"]
    consumer_script = (ROOT / "tools/linux_acceptance.sh").read_text()
    assert "--acceptance" in consumer_script
    assert "--cache-from" in consumer_script
    assert "acceptance-tools-buildcache-v1" in consumer_script
    assert "app-buildcache-x86-64" in consumer_script
    assert "--cache-to" not in consumer_script
    assert "packaging/build.Dockerfile" not in consumer_script
    for suite in ("cpu", "audio", "deb"):
        consumer = jobs["acceptance-" + suite]
        assert consumer["permissions"]["packages"] == "read"
        restore = next(
            step
            for step in consumer["steps"]
            if step.get("uses") == "./.github/actions/setup-linux-consumer"
        )
        assert "needs.linux-build.outputs.bundle_id" in restore["with"]["artifact-id"]
        assert (
            "needs.linux-build.outputs.bundle_digest"
            in restore["with"]["artifact-digest"]
        )
        assert "needs.linux-build.outputs.attempt" in restore["with"]["attempt"]
        assert any(
            step.get("run") == "bash tools/linux_acceptance.sh " + suite
            for step in consumer["steps"]
        )
    publisher = jobs["publish-caches"]
    assert publisher["permissions"]["packages"] == "write"
    assert "github.ref == 'refs/heads/main'" in publisher["if"]
    assert "github.event_name" in publisher["if"]
    assert "inputs.source == github.sha" in publisher["if"]
    assert any(
        step.get("run") == "bash tools/publish_linux_ci_caches.sh"
        for step in publisher["steps"]
    )
    publication = (ROOT / "tools/publish_linux_ci_caches.sh").read_text()
    assert "refs/heads/main" in publication
    assert "push|workflow_dispatch|schedule" in publication
    assert "application-dependencies ci acceptance-dependencies" in publication
    assert "acceptance-tools-buildcache-v1" in publication
    assert (
        '--cache-to "type=registry,ref=ghcr.io/$task_repository/linux-sdk:$task_cache'
        in publication
    )
    assert "legacy_cache" not in publication


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
