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
    for name in ["test_macos_release_models", "test_packaged_model_runtime"]:
        spec = importlib.util.spec_from_file_location(
            name, ROOT / "tools" / f"{name}.py"
        )
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if name == "test_macos_release_models":
            assert module.MODELS == selected
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
