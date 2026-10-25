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
    shutil.copy(ROOT / "cmake/VerifyDiagnosticToolchain.cmake", source / "cmake")
    shutil.copy(ROOT / "cmake/PublishDiagnosticProducts.cmake", source / "cmake")
    for name in ("diagnostic_build_identity.py", "diagnostic_build_inputs.json"):
        shutil.copy(ROOT / "tools" / name, source / "tools")
    for path in (ROOT / "native").glob("diagnostic_*"):
        if path.suffix in {".c", ".h"}:
            shutil.copy(path, source / "native")
    # This deliberate synthetic metadata isolates CMake identity/plumbing from
    # the independently tested actual selected-system metadata recipe.
    (source / "tools/fixture-metadata.json").write_text(json.dumps({
        "fingerprint": "b" * 64, "record": {"compiler": {"sha256": "a" * 64}}
    }))
    (source / "tools/diagnostic_toolchain_metadata.py").write_text(
        "from pathlib import Path\n"
        "print(Path(__file__).with_name('fixture-metadata.json').read_text())\n"
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
    assert state == {"schema": 1, "available": False}
    result = subprocess.run(
        ["cmake", "--build", str(build), "--target", "foresight_diagnostic_products", "--parallel", "2"],
        capture_output=True, text=True, timeout=90, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text()) == {
        "schema": 1, "available": True, "native_id": record["native_id"],
    }
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


def test_optional_missing_interpreter_keeps_native_configure_available(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build, "-DPython3_EXECUTABLE=/bin/false")
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text()) == {
        "schema": 1, "available": False,
    }
    assert "Python3_EXECUTABLE:UNINITIALIZED=/bin/false" in (build / "CMakeCache.txt").read_text()


def test_metadata_change_refuses_even_when_objects_need_no_rebuild(tmp_path):
    source, build = fixture(tmp_path)
    configured = configure(source, build, "-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON")
    assert configured.returncode == 0, configured.stdout + configured.stderr
    command = ["cmake", "--build", str(build), "--target", "foresight_diagnostic_products"]
    first = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    assert first.returncode == 0, first.stdout + first.stderr
    metadata = source / "tools/fixture-metadata.json"
    value = json.loads(metadata.read_text())
    value["fingerprint"] = "c" * 64
    metadata.write_text(json.dumps(value))
    second = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    assert second.returncode != 0
    assert "toolchain changed" in second.stderr
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False


@pytest.mark.parametrize("late", [
    "add_compile_definitions(UNREVIEWED_RECIPE=1)",
    'include_directories("${CMAKE_CURRENT_SOURCE_DIR}/foreign")',
    'set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUNREVIEWED_RECIPE=1")',
    'target_link_libraries(foresight_diagnostic_support PRIVATE m)',
    'target_sources(foresight_diagnostic_support PRIVATE foreign.c)',
    'set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/native/diagnostic_protocol.c" PROPERTIES COMPILE_OPTIONS -fno-builtin)',
    'set_target_properties(foresight_diagnostic_support PROPERTIES C_VISIBILITY_PRESET hidden)',
    'set_target_properties(foresight_diagnostic_support PROPERTIES BUILD_RPATH /foreign)',
    'target_link_directories(foresight_diagnostic_support PRIVATE /foreign)',
    'set_property(TARGET Threads::Threads APPEND PROPERTY INTERFACE_COMPILE_OPTIONS -fno-builtin)',
    'set_property(DIRECTORY PROPERTY RULE_LAUNCH_COMPILE foreign)',
    'set_target_properties(foresight_diagnostic_support PROPERTIES INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)',
])
def test_late_effective_product_recipe_changes_refuse(tmp_path, late):
    source, build = fixture(tmp_path)
    project = source / "CMakeLists.txt"
    project.write_text(project.read_text() + late + "\n")
    result = configure(source, build)
    assert result.returncode != 0
    assert "effective product recipe changed" in result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False


def test_ambient_ipo_is_not_silently_added_to_native_identity(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build, "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON")
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False


@pytest.mark.parametrize("setting", [
    "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON",
    "-DCMAKE_C_VISIBILITY_PRESET=hidden",
    "-DCMAKE_BUILD_RPATH=/foreign",
    "-DCMAKE_INSTALL_RPATH=/foreign",
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
    "-DCMAKE_LINKER_TYPE=DEFAULT",
])
def test_unbound_codegen_initializers_refuse(tmp_path, setting):
    source, build = fixture(tmp_path)
    result = configure(source, build, setting)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False


def test_failed_compile_after_reconfigure_cannot_advertise_old_products(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = ["cmake", "--build", str(build), "--target", "foresight_diagnostic_products"]
    first = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    assert first.returncode == 0, first.stdout + first.stderr
    launcher = build / "foresight-diagnostic-launcher"
    before = launcher.read_bytes()
    path = source / "native/diagnostic_support.c"
    path.write_text(path.read_text() + "\n#error deliberate_product_failure\n")
    failed = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    assert failed.returncode != 0
    assert "deliberate_product_failure" in failed.stdout + failed.stderr
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False
    assert launcher.read_bytes() == before


def test_aggregate_refuses_linked_product_with_stale_embedded_identity(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = ["cmake", "--build", str(build), "--target", "foresight_diagnostic_products"]
    first = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    assert first.returncode == 0, first.stdout + first.stderr
    state = json.loads((build / "diagnostic-products.json").read_text())
    launcher = build / "foresight-diagnostic-launcher"
    marker = b"\0FORESIGHT_DIAGNOSTIC_NATIVE_ID:v1:" + state["native_id"].encode() + b":end\0"
    data = launcher.read_bytes()
    assert data.count(marker) == 1
    launcher.write_bytes(data.replace(marker, marker.replace(state["native_id"].encode(), b"0" * 64)))
    second = subprocess.run(command, capture_output=True, text=True, timeout=90, check=False)
    assert second.returncode != 0
    assert "product identity mismatch" in second.stderr
    assert json.loads((build / "diagnostic-products.json").read_text())["available"] is False
