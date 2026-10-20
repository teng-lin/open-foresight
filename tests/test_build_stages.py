"""Independent build stages must preserve their prerequisite and failure boundaries."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def build_tree(tmp_path):
    root = tmp_path / "repo"
    tools = root / "tools"
    tools.mkdir(parents=True)
    for name in (
        "build.sh",
        "build_service_gate.sh",
        "ci_timing.sh",
        "check_build_cache.py",
    ):
        shutil.copy2(ROOT / "tools" / name, tools / name)
    (tools / "verify_descriptor.py").write_text("print('descriptor checked')\n")
    for name in ("build_dart_gates.sh",):
        (tools / name).write_text('#!/bin/bash\necho "dart-stage:$1"\n')
    binary = tmp_path / "bin"
    binary.mkdir()
    for name, body in {
        "cmake": 'echo "cmake:$*"; mkdir -p "$FORESIGHT_BUILD_DIR"',
        "ctest": 'echo "ctest:$*"; exit "${FIXTURE_CTEST_EXIT:-0}"',
    }.items():
        script = binary / name
        script.write_text("#!/bin/bash\n" + body + "\n")
        script.chmod(0o700)
    build = root / "build"
    build.mkdir()
    return root, {
        **os.environ,
        "CI": "true",
        "PATH": f"{binary}:/usr/bin:/bin",
        "FORESIGHT_BUILD_DIR": str(build),
        "FORESIGHT_PYTHON": shutil.which("python3"),
        # This miniature tree has no dependency seed or reuse verifier. Real
        # dependency-reuse fixtures exercise that production guard separately.
        "FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE": "0",
    }


def run_stage(build_tree, stage, extra=None):
    root, environment = build_tree
    return subprocess.run(
        [
            "/bin/bash",
            str(root / "tools/build.sh"),
            "--platform",
            "linux",
            "--stage",
            stage,
        ],
        env={**environment, **(extra or {})},
        text=True,
        capture_output=True,
        timeout=10,
    )


def test_native_stage_needs_no_dart_or_flutter_and_runs_no_dart_gate(build_tree):
    result = run_stage(build_tree, "native")
    assert result.returncode == 0, result.stderr
    assert "native configure" in result.stdout
    assert "native compile" in result.stdout
    assert "native tests" in result.stdout
    assert "dart-stage" not in result.stdout


def test_native_failure_cannot_be_reported_as_success(build_tree):
    result = run_stage(build_tree, "native", {"FIXTURE_CTEST_EXIT": "7"})
    assert result.returncode == 7
    assert "dart-stage" not in result.stdout


def test_native_reuse_guard_can_be_enabled_and_blocks_compilation(build_tree):
    root, _ = build_tree
    (root / "tools/verify_app_dependency_reuse.py").write_text(
        "import sys\nprint('fixture reuse guard rejected dependency rebuild')\nsys.exit(19)\n"
    )
    result = run_stage(
        build_tree, "native", {"FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE": "1"}
    )
    assert result.returncode == 19, result.stdout + result.stderr
    assert "fixture reuse guard rejected dependency rebuild" in result.stdout
    assert "native compile" not in result.stdout


@pytest.mark.parametrize("stage", ["core", "desktop", "service"])
def test_language_stages_require_their_sdk_before_using_artifacts(build_tree, stage):
    result = run_stage(build_tree, stage)
    assert result.returncode != 0
    assert "Required dart SDK is missing" in result.stderr
    assert "cmake:" not in result.stdout


def test_unknown_stage_is_rejected(build_tree):
    result = run_stage(build_tree, "misspelled")
    assert result.returncode == 2
    assert "Stage must be" in result.stderr


@pytest.mark.parametrize("stage", ["core", "desktop"])
def test_language_stages_do_not_rebuild_native_prerequisites(build_tree, stage):
    _, environment = build_tree
    binary = Path(environment["PATH"].split(":")[0])
    for name in ("dart", "flutter"):
        executable = binary / name
        executable.write_text("#!/bin/bash\nexit 0\n")
        executable.chmod(0o700)
    result = run_stage(build_tree, stage)
    assert result.returncode == 0, result.stderr
    assert f"dart-stage:{stage}" in result.stdout
    assert "cmake:" not in result.stdout
    assert "ctest:" not in result.stdout


def test_service_stage_fails_on_missing_compiled_prerequisites(build_tree):
    _, environment = build_tree
    binary = Path(environment["PATH"].split(":")[0])
    dart = binary / "dart"
    dart.write_text("#!/bin/bash\nexit 0\n")
    dart.chmod(0o700)
    result = run_stage(build_tree, "service")
    assert result.returncode != 0
    assert "Missing stage prerequisite" in result.stderr
    assert "cmake:" not in result.stdout


@pytest.mark.parametrize("state", ["missing", "not-executable"])
def test_service_stage_rejects_missing_or_non_executable_worker_before_tests(
    build_tree, state
):
    root, environment = build_tree
    binary = Path(environment["PATH"].split(":")[0])
    dart = binary / "dart"
    dart.write_text("#!/bin/bash\nexit 0\n")
    dart.chmod(0o700)
    for relative in (
        "application/foresight-service",
        "application/foresight-mcp",
        "services/helper/ForesightHelper",
    ):
        executable = root / "build" / relative
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
    native = root / "build/native/libforesight_native.so"
    native.parent.mkdir(parents=True)
    native.write_bytes(b"native-library")
    worker = root / "build/services/helper/model_worker_fixture"
    if state == "not-executable":
        worker.write_text("#!/bin/sh\nexit 0\n")
        worker.chmod(0o644)
    result = run_stage(build_tree, "service")
    assert result.returncode != 0
    assert str(worker) in result.stderr
    expected = "Missing stage prerequisite" if state == "missing" else "not executable"
    assert expected in result.stderr
    assert "service and MCP integration" not in result.stdout
    assert not (root / "test-results").exists()
