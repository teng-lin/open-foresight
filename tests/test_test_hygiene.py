"""Regression coverage for test-harness requirements and shared model metadata."""

import copy
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from model_pins import TABLE, model_pins, release_models  # noqa: E402
from service_ui_report import REQUIRED_EXPECTATIONS, verify_service_ui_report  # noqa: E402


@pytest.mark.parametrize(
    "requirement", [{"CI": "true"}, {"FORESIGHT_REQUIRE_DART_GATES": "1"}]
)
@pytest.mark.parametrize("missing", ["dart", "flutter"])
def test_build_fails_before_native_work_when_a_required_sdk_is_missing(
    tmp_path, requirement, missing
):
    for command in ["dirname", "uname"]:
        target = shutil.which(command)
        assert target
        (tmp_path / command).symlink_to(target)
    if missing == "flutter":
        dart = tmp_path / "dart"
        dart.write_text("#!/bin/sh\nexit 0\n")
        dart.chmod(0o700)
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "tools/build.sh")],
        env={**os.environ, **requirement, "PATH": str(tmp_path)},
        text=True,
        capture_output=True,
        timeout=5,
    )
    assert result.returncode != 0
    assert f"Required {missing} SDK is missing" in result.stderr


def test_shared_pin_table_drives_all_python_release_consumers():
    pins = model_pins()
    selected = release_models()
    assert len(pins) == 9
    assert selected["speech"][3] == pins["ggml-tiny.bin"]["sha256"]
    assert selected["generation"][3] == pins["gemma-4-E2B-it.litertlm"]["sha256"]
    for name, source in [
        ("test_macos_release_models", ROOT / "tools/test_macos_release_models.py"),
        ("test_packaged_model_runtime", ROOT / "tools/test_packaged_model_runtime.py"),
        ("smoke_installed", ROOT / "packaging/smoke_installed.py"),
    ]:
        spec = importlib.util.spec_from_file_location(name, source)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if name == "test_macos_release_models":
            assert module.MODELS == selected
        elif name == "smoke_installed":
            assert module.SPEECH_PIN == selected["speech"]
        else:
            assert module.GENERATION_SHA256 == selected["generation"][3]
            assert module.EMBEDDING_SHA256 == selected["embedding"][3]


@pytest.mark.parametrize("malformed", ["missing", "duplicate", "changed-json"])
def test_pin_parser_rejects_missing_or_ambiguous_fences(tmp_path, malformed):
    source = TABLE.read_text()
    if malformed == "missing":
        source = source.replace("// BEGIN FORESIGHT MODEL PINS", "// removed")
    elif malformed == "duplicate":
        source += "\n// BEGIN FORESIGHT MODEL PINS\n"
    else:
        source = source.replace("const modelPinsJson = r'''", "const other = r'''")
    table = tmp_path / "pins.dart"
    table.write_text(source)
    with pytest.raises(ValueError):
        model_pins(table)


@pytest.mark.parametrize("removed", sorted(REQUIRED_EXPECTATIONS))
def test_deleting_a_ui_expectation_fails_external_validation(removed):
    report = {
        "schema": 1,
        "expectations": [
            {"name": name, "actual": True, "expected": True, "passed": True}
            for name in sorted(REQUIRED_EXPECTATIONS)
        ],
    }
    verify_service_ui_report(report)
    mutated = copy.deepcopy(report)
    mutated["expectations"] = [
        item for item in mutated["expectations"] if item["name"] != removed
    ]
    with pytest.raises(ValueError, match=removed):
        verify_service_ui_report(mutated)
    with pytest.raises(ValueError):
        verify_service_ui_report({name: True for name in REQUIRED_EXPECTATIONS})


def test_repeated_ui_protocol_observations_preserve_unique_semantic_checks():
    observations = [
        {"name": name, "actual": True, "expected": True, "passed": True}
        for name in sorted(REQUIRED_EXPECTATIONS)
    ]
    protocol = next(item for item in observations if item["name"] == "mcp-envelope")
    observations.append(dict(protocol))
    report = {"schema": 1, "expectations": observations}
    verify_service_ui_report(report)
    semantic = next(
        item for item in observations if item["name"] == "transcript_persisted"
    )
    observations.append(dict(semantic))
    with pytest.raises(ValueError, match="transcript_persisted"):
        verify_service_ui_report(report)


def verify_python_collection(root, collected):
    """Require an explicit, reasoned exception for each uncollected module."""
    import configparser
    import json

    config = configparser.ConfigParser()
    config.read(root / "pytest.ini")
    assert config["pytest"]["testpaths"].split() == ["tests"]
    exclusions = json.loads((root / "pytest-exclusions.json").read_text())
    ignored = config["pytest"]["norecursedirs"].split()
    ignored += [
        arg.removeprefix("--ignore=")
        for arg in config["pytest"].get("addopts", "").split()
        if arg.startswith("--ignore=")
    ]
    modules = {
        str(path.relative_to(root)) for path in (root / "tests").rglob("test_*.py")
    }
    assert all(
        path in modules and reason.strip() for path, reason in exclusions.items()
    )
    assert all(
        any(Path(path).is_relative_to(folder) for folder in ignored)
        for path in exclusions
    )
    missing = modules - collected - exclusions.keys()
    assert not missing, (
        f"Uncollected Python tests need an explicit reason: {sorted(missing)}"
    )


def test_every_python_module_is_collected_or_explicitly_excluded(request):
    # Explicit targeted runs intentionally collect fewer modules. Check the
    # complete discovery invariant during the default suite only.
    if request.config.args != ["tests"]:
        return
    collected = {
        str(Path(item.path).relative_to(ROOT)) for item in request.session.items
    }
    reporter = request.config.pluginmanager.getplugin("terminalreporter")
    collected.update(
        str(Path(report.fspath)) for report in reporter.stats.get("skipped", [])
    )
    verify_python_collection(ROOT, collected)


def test_collection_guard_rejects_a_new_uncollected_module(tmp_path):
    import json

    (tmp_path / "tests/integration").mkdir(parents=True)
    (tmp_path / "pytest.ini").write_text(
        "[pytest]\ntestpaths = tests\nnorecursedirs = tests/integration\n"
    )
    (tmp_path / "pytest-exclusions.json").write_text(json.dumps({}))
    (tmp_path / "tests/integration/test_new.py").write_text("def test_new(): pass\n")
    with pytest.raises(AssertionError, match="test_new.py"):
        verify_python_collection(tmp_path, set())


def test_stale_python_cache_fails_before_cmake_or_native_work(tmp_path):
    cache = tmp_path / "build/CMakeCache.txt"
    cache.parent.mkdir()
    cache.write_text("Python3_EXECUTABLE:FILEPATH=/definitely-missing/old-python\n")
    result = subprocess.run(
        ["bash", str(ROOT / "tools/build.sh")],
        env={
            **os.environ,
            "CI": "false",
            "FORESIGHT_REQUIRE_DART_GATES": "0",
            "FORESIGHT_BUILD_DIR": str(cache.parent),
            "FORESIGHT_PYTHON": sys.executable,
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode != 0
    assert "Cached Python interpreter no longer exists" in result.stderr
    assert "native configure" not in result.stdout
