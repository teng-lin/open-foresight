"""Actual standalone CMake recipes; synthetic public metadata is never attestation."""

import json
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(
    not shutil.which("cmake") or not shutil.which("cc"), reason="CMake/C compiler required"
)


def fixture(tmp_path):
    source = tmp_path / "source"
    (source / "cmake").mkdir(parents=True)
    (source / "tools").mkdir()
    (source / "native").mkdir()
    shutil.copy(ROOT / "cmake/ForesightDiagnostics.cmake", source / "cmake")
    for name in ("diagnostic_build_identity.py", "diagnostic_build_inputs.json"):
        shutil.copy(ROOT / "tools" / name, source / "tools")
    for path in (ROOT / "native").glob("diagnostic_*"):
        if path.suffix in {".c", ".h"}:
            shutil.copy(path, source / "native")
    # This deliberate synthetic metadata isolates CMake identity/plumbing from
    # the independently tested actual selected-system metadata recipe.
    (source / "tools/diagnostic_toolchain_metadata.py").write_text(
        'import json\nprint(json.dumps({"fingerprint":"' + "b" * 64
        + '","record":{"compiler":{"sha256":"' + "a" * 64 + '"}}}))\n'
    )
    (source / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\n"
        "if(APPLE)\nset(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)\nendif()\n"
        "project(diagnostic_identity_fixture LANGUAGES C)\n"
        "find_package(Threads REQUIRED)\n"
        'include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/ForesightDiagnostics.cmake")\n'
    )
    return source, tmp_path / "build"


def configure(source, build, *arguments):
    return subprocess.run(
        ["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
         f"-DPython3_EXECUTABLE={sys.executable}", *arguments],
        capture_output=True, text=True, timeout=60, check=False,
    )


def test_actual_targets_and_identity_reconfigure_fail_closed_without_deleting_old_bytes(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build, "-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON")
    assert result.returncode == 0, result.stdout + result.stderr
    state = json.loads((build / "diagnostic-products.json").read_text())
    record = json.loads((build / "diagnostic-native-inputs.json").read_text())
    assert state == {"schema": 1, "available": True, "native_id": record["native_id"]}
    result = subprocess.run(
        ["cmake", "--build", str(build), "--target", "foresight_diagnostic_support",
         "foresight-diagnostic-launcher", "--parallel", "2"],
        capture_output=True, text=True, timeout=90, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    launcher = build / "foresight-diagnostic-launcher"
    before = launcher.read_bytes()
    assert record["native_id"].encode() in before
    support = build / ("libforesight_diagnostic_support.dylib" if sys.platform == "darwin"
                       else "libforesight_diagnostic_support.so")
    assert record["native_id"].encode() in support.read_bytes()
    result = configure(source, build, "-DCMAKE_C_FLAGS=-DFOREIGN_RECIPE=1")
    assert result.returncode != 0
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False
    assert launcher.read_bytes() == before  # Refuse stale products; never erase them.


@pytest.mark.parametrize("setting", ["-DCMAKE_C_FLAGS=-DFOREIGN_RECIPE=1",
                                     "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--as-needed"])
def test_optional_unreviewed_recipe_is_explicitly_unavailable(tmp_path, setting):
    source, build = fixture(tmp_path)
    result = configure(source, build, setting)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text()) == {
        "schema": 1, "available": False,
    }
    assert not (build / "diagnostic-native-inputs.json").exists()


def test_selected_public_fingerprint_mismatch_refuses_products(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build, "-DFORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256=" + "c" * 64)
    assert result.returncode != 0
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False
