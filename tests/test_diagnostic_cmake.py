"""Actual standalone CMake recipes; synthetic public metadata is never attestation."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(
    not shutil.which("cmake") or not shutil.which("cc"),
    reason="CMake/C compiler required",
)


def fixture(tmp_path, *, sql=False):
    source = tmp_path / "source"
    (source / "cmake").mkdir(parents=True)
    (source / "tools").mkdir()
    (source / "native").mkdir()
    (source / "cmake/DiagnosticProducts").mkdir()
    shutil.copy(
        ROOT / "cmake/DiagnosticProducts/CMakeLists.txt",
        source / "cmake/DiagnosticProducts",
    )
    shutil.copy(ROOT / "cmake/ForesightDiagnostics.cmake", source / "cmake")
    shutil.copy(ROOT / "cmake/VerifyDiagnosticToolchain.cmake", source / "cmake")
    shutil.copy(ROOT / "cmake/PublishDiagnosticProducts.cmake", source / "cmake")
    for name in ("diagnostic_build_identity.py", "diagnostic_build_inputs.json"):
        shutil.copy(ROOT / "tools" / name, source / "tools")
    for path in (ROOT / "native").glob("diagnostic_*"):
        if path.suffix in {".c", ".h"}:
            shutil.copy(path, source / "native")
    for name in (
        "cmake/NormalizeRuntimeSupport.cmake",
        "cmake/ProduceRuntimeSupport.cmake",
    ):
        shutil.copy(ROOT / name, source / name)
    # This deliberate synthetic metadata isolates CMake identity/plumbing from
    # the independently tested actual selected-system metadata recipe.
    metadata_record = {
        "target": "darwin-arm64" if sys.platform == "darwin" else "linux-x86_64",
        "compiler": {"sha256": "a" * 64},
        "fixture": "synthetic",
    }
    fingerprint = hashlib.sha256(
        json.dumps(metadata_record, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    (source / "tools/fixture-metadata.json").write_text(
        json.dumps(
            {
                "fingerprint": fingerprint,
                "record": metadata_record,
            }
        )
    )
    (source / "tools/diagnostic_toolchain_metadata.py").write_text(
        "from pathlib import Path\n"
        "print(Path(__file__).with_name('fixture-metadata.json').read_text())\n"
    )
    if sql:
        for name in (
            "native/sql_support.c",
            "native/sql_support.h",
            "cmake/ForesightSqlSupport.cmake",
            "cmake/ForesightSqlIdentity.cmake",
            "cmake/SqlSupportProduct/CMakeLists.txt",
            "cmake/NormalizeRuntimeSupport.cmake",
            "cmake/ProduceRuntimeSupport.cmake",
            "tools/sql_support_identity.py",
            "tools/diagnostic_product_receipt.py",
            "tools/__init__.py",
        ):
            (source / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / name, source / name)
    (source / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\n"
        "if(APPLE)\nset(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)\nendif()\n"
        "project(diagnostic_identity_fixture LANGUAGES C)\n"
        'set(BUILD_TESTING OFF CACHE BOOL "" FORCE)\n'
        "find_package(Threads REQUIRED)\n"
        "add_compile_options(-Wall -Wextra)\n"
        + (
            'include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/ForesightSqlSupport.cmake")\n'
            if sql
            else ""
        )
        + 'include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/ForesightDiagnostics.cmake")\n'
    )
    return source, tmp_path / "build"


def configure(source, build, *arguments):
    return subprocess.run(
        [
            "cmake",
            "-S",
            str(source),
            "-B",
            str(build),
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DPython3_EXECUTABLE={sys.executable}",
            *arguments,
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )


@pytest.mark.parametrize(
    "generator",
    [
        "Unix Makefiles",
        pytest.param(
            "Ninja",
            marks=pytest.mark.skipif(
                not shutil.which("ninja"), reason="Ninja required"
            ),
        ),
    ],
)
def test_actual_targets_and_identity_reconfigure_fail_closed_without_deleting_old_bytes(
    tmp_path,
    generator,
):
    source, build = fixture(tmp_path)
    result = configure(
        source, build, "-G", generator, "-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON"
    )
    assert result.returncode == 0, result.stdout + result.stderr
    state = json.loads((build / "diagnostic-products.json").read_text())
    record = json.loads((build / "diagnostic-native-inputs.json").read_text())
    assert state == {"schema": 1, "available": False}
    result = subprocess.run(
        [
            "cmake",
            "--build",
            str(build),
            "--target",
            "foresight_diagnostic_products",
            "--parallel",
            "2",
        ],
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text()) == {
        "schema": 1,
        "available": True,
        "native_id": record["native_id"],
    }
    launcher = build / "foresight-diagnostic-launcher"
    before = launcher.read_bytes()
    assert record["native_id"].encode() in before
    support = build / (
        "libforesight_diagnostic_support.dylib"
        if sys.platform == "darwin"
        else "libforesight_diagnostic_support.so"
    )
    assert record["native_id"].encode() in support.read_bytes()
    result = configure(source, build, "-DCMAKE_C_FLAGS=-DFOREIGN_RECIPE=1")
    assert result.returncode != 0
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )
    assert launcher.read_bytes() == before  # Refuse stale products; never erase them.


@pytest.mark.parametrize(
    "setting",
    [
        "-DCMAKE_C_FLAGS=-DFOREIGN_RECIPE=1",
        "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--as-needed",
    ],
)
def test_optional_unreviewed_recipe_is_explicitly_unavailable(tmp_path, setting):
    source, build = fixture(tmp_path)
    result = configure(source, build, setting)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text()) == {
        "schema": 1,
        "available": False,
    }
    assert not (build / "diagnostic-native-inputs.json").exists()


def test_selected_public_fingerprint_mismatch_refuses_products(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(
        source, build, "-DFORESIGHT_DIAGNOSTIC_TOOLCHAIN_SHA256=" + "c" * 64
    )
    assert result.returncode != 0
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )


def test_optional_missing_interpreter_keeps_native_configure_available(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build, "-DPython3_EXECUTABLE=/bin/false")
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-products.json").read_text()) == {
        "schema": 1,
        "available": False,
    }
    assert (
        "Python3_EXECUTABLE:UNINITIALIZED=/bin/false"
        in (build / "CMakeCache.txt").read_text()
    )


def test_metadata_change_refuses_even_when_objects_need_no_rebuild(tmp_path):
    source, build = fixture(tmp_path)
    configured = configure(source, build, "-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON")
    assert configured.returncode == 0, configured.stdout + configured.stderr
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_diagnostic_products",
    ]
    first = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert first.returncode == 0, first.stdout + first.stderr
    metadata = source / "tools/fixture-metadata.json"
    value = json.loads(metadata.read_text())
    value["fingerprint"] = "c" * 64
    metadata.write_text(json.dumps(value))
    second = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert second.returncode != 0
    assert "toolchain changed" in second.stderr
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )


@pytest.mark.parametrize(
    "late",
    [
        "add_compile_definitions(UNREVIEWED_RECIPE=1)",
        'include_directories("${CMAKE_CURRENT_SOURCE_DIR}/foreign")',
        'set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUNREVIEWED_RECIPE=1")',
        "target_link_libraries(foresight_diagnostic_support PRIVATE m)",
        "target_sources(foresight_diagnostic_support PRIVATE foreign.c)",
        'set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/native/diagnostic_protocol.c" PROPERTIES COMPILE_OPTIONS -fno-builtin)',
        "set_target_properties(foresight_diagnostic_support PROPERTIES C_VISIBILITY_PRESET hidden)",
        "set_target_properties(foresight_diagnostic_support PROPERTIES BUILD_RPATH /foreign)",
        "target_link_directories(foresight_diagnostic_support PRIVATE /foreign)",
        "set_property(TARGET Threads::Threads APPEND PROPERTY INTERFACE_COMPILE_OPTIONS -fno-builtin)",
        "set_property(DIRECTORY PROPERTY RULE_LAUNCH_COMPILE foreign)",
        'set_property(DIRECTORY PROPERTY RULE_LAUNCH_CUSTOM "OFF")',
        'set_property(GLOBAL PROPERTY RULE_LAUNCH_CUSTOM "0")',
        'set_property(TARGET foresight_diagnostic_identity_check PROPERTY RULE_LAUNCH_CUSTOM "OFF")',
        'set_property(TARGET foresight_diagnostic_compile PROPERTY RULE_LAUNCH_CUSTOM "foreign")',
        'set_property(TARGET foresight_diagnostic_compile PROPERTY RULE_LAUNCH_CUSTOM "custom-NOTFOUND")',
        'set_property(TARGET foresight_diagnostic_products PROPERTY RULE_LAUNCH_CUSTOM "foreign")',
        'set_property(TARGET foresight_diagnostic_support PROPERTY RULE_LAUNCH_CUSTOM "foreign")',
        'set_property(TARGET foresight_diagnostic_launcher PROPERTY RULE_LAUNCH_CUSTOM "foreign")',
        "set_target_properties(foresight_diagnostic_support PROPERTIES INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)",
        'set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/native/diagnostic_inherited.c" PROPERTIES HEADER_FILE_ONLY ON)',
        "set_property(TARGET Threads::Threads APPEND PROPERTY INTERFACE_SOURCES foreign.c)",
        "set(CMAKE_BUILD_TYPE Debug)",
    ],
)
def test_late_effective_product_recipe_changes_refuse(tmp_path, late):
    source, build = fixture(tmp_path)
    project = source / "CMakeLists.txt"
    project.write_text(project.read_text() + late + "\n")
    result = configure(source, build)
    assert result.returncode != 0
    expected = (
        'Utility target "foresight_diagnostic_support"'
        if late.startswith("target_link_libraries")
        else "non-compilable target type"
        if late.startswith("target_link_directories")
        else "effective product recipe changed"
    )
    assert expected in result.stderr
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )


def test_ambient_ipo_is_not_silently_added_to_native_identity(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build, "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )


@pytest.mark.parametrize(
    "setting",
    [
        "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON",
        "-DCMAKE_C_VISIBILITY_PRESET=hidden",
        "-DCMAKE_BUILD_RPATH=/foreign",
        "-DCMAKE_INSTALL_RPATH=/foreign",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        "-DCMAKE_LINKER_TYPE=DEFAULT",
    ],
)
def test_unbound_codegen_initializers_refuse(tmp_path, setting):
    source, build = fixture(tmp_path)
    result = configure(source, build, setting)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )


def test_failed_compile_after_reconfigure_cannot_advertise_old_products(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_diagnostic_products",
    ]
    first = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert first.returncode == 0, first.stdout + first.stderr
    launcher = build / "foresight-diagnostic-launcher"
    support = build / (
        "libforesight_diagnostic_support.dylib"
        if sys.platform == "darwin"
        else "libforesight_diagnostic_support.so"
    )
    before = support.read_bytes()
    path = source / "native/diagnostic_support.c"
    path.write_text(path.read_text() + "\n#error deliberate_product_failure\n")
    failed = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert failed.returncode != 0
    assert "deliberate_product_failure" in failed.stdout + failed.stderr
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )
    assert launcher.exists()
    assert support.read_bytes() == before


def test_aggregate_refuses_linked_product_with_stale_embedded_identity(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_diagnostic_products",
    ]
    first = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert first.returncode == 0, first.stdout + first.stderr
    state = json.loads((build / "diagnostic-products.json").read_text())
    launcher = build / "foresight-diagnostic-launcher"
    marker = (
        b"\0FORESIGHT_DIAGNOSTIC_NATIVE_ID:v1:"
        + state["native_id"].encode()
        + b":end\0"
    )
    data = launcher.read_bytes()
    assert data.count(marker) == 1
    launcher.write_bytes(
        data.replace(marker, marker.replace(state["native_id"].encode(), b"0" * 64))
    )
    support = build / (
        "libforesight_diagnostic_support.dylib"
        if sys.platform == "darwin"
        else "libforesight_diagnostic_support.so"
    )
    publish = [
        "cmake",
        f"-DDIAGNOSTIC_STATE={build / 'diagnostic-products.json'}",
        f"-DDIAGNOSTIC_NATIVE_ID={state['native_id']}",
        f"-DDIAGNOSTIC_SUPPORT={support}",
        f"-DDIAGNOSTIC_LAUNCHER={launcher}",
        "-P",
        str(source / "cmake/PublishDiagnosticProducts.cmake"),
    ]
    second = subprocess.run(
        publish, capture_output=True, text=True, timeout=90, check=False
    )
    assert second.returncode != 0
    assert "product identity mismatch" in second.stderr
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is False
    )


@pytest.mark.parametrize(
    "late",
    [
        'set(CMAKE_C_COMPILE_OBJECT "/bin/false")',
        'set(CMAKE_C_CREATE_SHARED_LIBRARY "/bin/false")',
        'set(CMAKE_C_LINK_EXECUTABLE "/bin/false")',
        "set(CMAKE_INCLUDE_CURRENT_DIR ON)",
        "set(CMAKE_C_CLANG_TIDY /bin/false)",
        "set(CMAKE_ENABLE_EXPORTS ON)",
        "set_property(TARGET foresight_diagnostic_support PROPERTY DEFINE_SYMBOL FOREIGN_RECIPE)",
    ],
)
def test_parent_rules_and_properties_cannot_change_isolated_products(tmp_path, late):
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_diagnostic_products",
    ]
    first = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert first.returncode == 0, first.stdout + first.stderr
    launcher = build / "foresight-diagnostic-launcher"
    support = build / (
        "libforesight_diagnostic_support.dylib"
        if sys.platform == "darwin"
        else "libforesight_diagnostic_support.so"
    )
    before = (launcher.read_bytes(), support.read_bytes())
    project = source / "CMakeLists.txt"
    project.write_text(project.read_text() + late + "\n")
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    second = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert (launcher.read_bytes(), support.read_bytes()) == before
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is True
    )


def test_fresh_products_are_private_code_even_with_group_writable_umask(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_diagnostic_products",
    ]
    result = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False, umask=0o002
    )
    assert result.returncode == 0, result.stdout + result.stderr
    suffix = "dylib" if sys.platform == "darwin" else "so"
    for name in (
        "foresight-diagnostic-launcher",
        f"libforesight_diagnostic_support.{suffix}",
    ):
        assert (build / name).stat().st_mode & 0o777 == 0o755


def test_parent_export_initializer_is_not_an_isolated_link_option(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build, "-DCMAKE_ENABLE_EXPORTS=ON")
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run(
        ["cmake", "--build", str(build), "--target", "foresight_diagnostic_products"],
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    command = (
        build
        / "diagnostic-product-build/CMakeFiles/foresight-diagnostic-launcher.dir/link.txt"
    ).read_text()
    assert "-rdynamic" not in command and "-export_dynamic" not in command


def test_inner_cache_cannot_retain_an_unbound_cocompile_command(tmp_path):
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_diagnostic_products",
    ]
    first = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert first.returncode == 0, first.stdout + first.stderr
    cache = build / "diagnostic-product-build/CMakeCache.txt"
    cache.write_text(cache.read_text() + "\nCMAKE_C_CLANG_TIDY:STRING=/bin/false\n")
    second = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert "CMAKE_C_CLANG_TIDY:STRING=/bin/false" not in cache.read_text()
    assert (
        json.loads((build / "diagnostic-products.json").read_text())["available"]
        is True
    )


@pytest.mark.parametrize(
    "variable",
    [
        "CMAKE_C_COMPILER_LAUNCHER",
        "MAKEFILES",
        "MAKEFLAGS",
        "LD_RUN_PATH",
        "CCC_OVERRIDE_OPTIONS",
    ],
)
def test_ambient_recipe_environment_cannot_reach_isolated_compile(tmp_path, variable):
    if variable == "LD_RUN_PATH" and sys.platform == "darwin":
        pytest.skip("LD_RUN_PATH is a GNU ld input; Darwin uses ld64")
    source, build = fixture(tmp_path)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    if variable == "CCC_OVERRIDE_OPTIONS":
        banner = subprocess.run(
            ["cc", "--version"], capture_output=True, text=True, timeout=30, check=False
        )
        if "clang" not in banner.stdout.lower():
            pytest.skip(
                "CCC_OVERRIDE_OPTIONS is a Clang driver input; selected compiler is GNU"
            )
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_diagnostic_products",
    ]
    first = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert first.returncode == 0, first.stdout + first.stderr
    suffix = "dylib" if sys.platform == "darwin" else "so"
    paths = [
        build / "foresight-diagnostic-launcher",
        build / f"libforesight_diagnostic_support.{suffix}",
    ]
    before = [path.read_bytes() for path in paths]
    values = {
        "CMAKE_C_COMPILER_LAUNCHER": "/bin/false",
        "MAKEFLAGS": "C_DEFINES=-DFOREIGN_RECIPE=1",
        "LD_RUN_PATH": "/foreign",
        "CCC_OVERRIDE_OPTIONS": "+-O0",
    }
    if variable == "MAKEFILES":
        injected = tmp_path / "injected.make"
        injected.write_text(
            "override C_FLAGS = -O0\noverride C_DEFINES = -DFOREIGN_RECIPE=1\n"
        )
        value = str(injected)
    else:
        value = values[variable]
    second = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
        env={**os.environ, variable: value},
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert [path.read_bytes() for path in paths] == before


def test_runtime_receipt_tracks_actual_sql_target_instead_of_stale_output(tmp_path):
    source, build = fixture(tmp_path, sql=True)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    command = [
        "cmake",
        "--build",
        str(build),
        "--target",
        "foresight_runtime_support_products",
    ]
    first = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert first.returncode == 0, first.stdout + first.stderr
    suffix = "dylib" if sys.platform == "darwin" else "so"
    old_sql = build / f"libforesight_sql_support.{suffix}"
    old_bytes = old_sql.read_bytes()
    assert (build / "runtime-support-build.json").exists()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / old_sql.name).write_bytes(old_bytes)
    project = source / "CMakeLists.txt"
    project.write_text(
        project.read_text()
        + f'\nset_property(TARGET foresight_sql_support PROPERTY FORESIGHT_SQL_SUPPORT_FILE "{elsewhere / old_sql.name}")\n'
    )
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    second = subprocess.run(
        command, capture_output=True, text=True, timeout=90, check=False
    )
    assert second.returncode == 0, second.stdout + second.stderr
    assert (elsewhere / old_sql.name).exists()
    assert old_sql.read_bytes() == old_bytes
    assert not (build / "runtime-support-build.json").exists()


@pytest.mark.parametrize("required", [False, True])
def test_unavailable_sql_identity_does_not_break_optional_all(tmp_path, required):
    source, build = fixture(tmp_path, sql=True)
    arguments = ["-DCMAKE_C_FLAGS=-fvisibility=default"]
    if required:
        arguments.append("-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON")
    result = configure(source, build, *arguments)
    if required:
        assert result.returncode != 0
        assert "Runtime SQL product identity unavailable" in result.stderr
        return
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run(
        ["cmake", "--build", str(build), "--parallel", "2"],
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-sql-inputs.json").read_text()) == {
        "schema": 1,
        "available": False,
    }
    assert not (build / "runtime-support-build.json").exists()


def test_combined_sql_product_is_normalized_before_receipt_under_umask002(tmp_path):
    source, build = fixture(tmp_path, sql=True)
    result = configure(source, build, "-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON")
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run(
        [
            "cmake",
            "--build",
            str(build),
            "--target",
            "foresight_runtime_support_products",
        ],
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
        umask=0o002,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    receipt = json.loads((build / "runtime-support-build.json").read_text())
    assert len(receipt["artifacts"]) == 3
    assert all(artifact["mode"] == 0o755 for artifact in receipt["artifacts"].values())


def test_sql_and_native_metadata_probes_share_the_isolated_environment(tmp_path):
    source, build = fixture(tmp_path, sql=True)
    tool = source / "tools/diagnostic_toolchain_metadata.py"
    tool.write_text(
        "import hashlib,json,os\nfrom pathlib import Path\n"
        "value=json.loads(Path(__file__).with_name('fixture-metadata.json').read_text())\n"
        "if os.environ.get('FIXTURE_TOOLCHAIN_SELECTOR'):\n"
        " value['record']['fixture_selector']='ambient'\n"
        " value['fingerprint']=hashlib.sha256(json.dumps(value['record'],sort_keys=True,separators=(',',':')).encode()).hexdigest()\n"
        "print(json.dumps(value))\n"
    )
    environment = {**os.environ, "FIXTURE_TOOLCHAIN_SELECTOR": "ambient"}
    result = subprocess.run(
        [
            "cmake",
            "-S",
            str(source),
            "-B",
            str(build),
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DPython3_EXECUTABLE={sys.executable}",
        ],
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    result = subprocess.run(
        ["cmake", "--build", str(build), "--parallel", "2"],
        env=environment,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    receipt = json.loads((build / "runtime-support-build.json").read_text())
    assert len(receipt["artifacts"]) == 3
    sql = json.loads((build / "diagnostic-sql-inputs.json").read_text())
    assert "fixture_selector" not in sql["record"]["toolchain"]["record"]


@pytest.mark.parametrize("scope", ["GLOBAL", "DIRECTORY"])
@pytest.mark.parametrize("rule", ["CUSTOM", "COMPILE", "LINK"])
def test_preexisting_launcher_keeps_optional_native_unavailable(tmp_path, scope, rule):
    source, build = fixture(tmp_path)
    project = source / "CMakeLists.txt"
    body = project.read_text()
    body = body.replace(
        'include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/ForesightDiagnostics.cmake")',
        f'set_property({scope} PROPERTY RULE_LAUNCH_{rule} "OFF")\ninclude("${{CMAKE_CURRENT_SOURCE_DIR}}/cmake/ForesightDiagnostics.cmake")',
    )
    assert "RULE_LAUNCH_" in body
    project.write_text(body)
    result = configure(source, build)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        json.loads((build / "diagnostic-products.json").read_bytes())["available"]
        is False
    )


def test_public_provenance_has_safe_modes_under_umask002(tmp_path):
    source, build = fixture(tmp_path, sql=True)
    build.mkdir(mode=0o700)
    previous = os.umask(0o002)
    try:
        configured = configure(source, build)
        assert configured.returncode == 0, configured.stdout + configured.stderr
        completed = subprocess.run(
            [
                "cmake",
                "--build",
                str(build),
                "--target",
                "foresight_runtime_support_products",
            ],
            text=True,
            capture_output=True,
            timeout=90,
        )
        assert completed.returncode == 0, completed.stdout + completed.stderr
    finally:
        os.umask(previous)
    for name in [
        "diagnostic-products.json",
        "diagnostic-native-inputs.json",
        "diagnostic-toolchain-metadata.json",
        "diagnostic-sql-inputs.json",
        "sql-toolchain-metadata.json",
        "runtime-support-build.json",
    ]:
        assert (build / name).stat().st_mode & 0o777 == 0o644, name


@pytest.mark.parametrize("generator", ["Unix Makefiles", "Ninja"])
@pytest.mark.parametrize("tamper", ["bytes", "mode", "receipt"])
def test_qualified_consumer_has_no_product_commands_and_refuses_tampering(
    tmp_path, generator, tamper
):
    if generator == "Ninja" and not shutil.which("ninja"):
        pytest.skip("Ninja required")
    source, build = fixture(tmp_path, sql=True)
    configured = configure(
        source, build, "-G", generator, "-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON"
    )
    assert configured.returncode == 0, configured.stdout + configured.stderr
    produced = subprocess.run(
        ["cmake", "--build", str(build), "--parallel", "2"],
        capture_output=True,
        check=False,
        text=True,
        timeout=90,
    )
    assert produced.returncode == 0, produced.stdout + produced.stderr
    receipt = build / "runtime-support-build.json"
    before = receipt.read_bytes()
    suffix = "dylib" if sys.platform == "darwin" else "so"
    names = [
        "diagnostic-products.json",
        "diagnostic-native-inputs.json",
        "diagnostic-toolchain-metadata.json",
        "diagnostic-sql-inputs.json",
        "sql-toolchain-metadata.json",
        "runtime-support-build.json",
        f"libforesight_sql_support.{suffix}",
        f"libforesight_diagnostic_support.{suffix}",
        "foresight-diagnostic-launcher",
    ]
    unchanged = {
        name: ((build / name).read_bytes(), (build / name).stat().st_mode)
        for name in names
    }
    consumed = configure(source, build, "-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=ON")
    assert consumed.returncode == 0, consumed.stdout + consumed.stderr
    plan = subprocess.run(
        ["cmake", "--build", str(build), "--", "-n"],
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
    )
    assert plan.returncode == 0, plan.stdout + plan.stderr
    for forbidden in (
        "VerifyDiagnosticToolchain.cmake",
        "--fresh",
        "PublishDiagnosticProducts.cmake",
        "ProduceRuntimeSupport.cmake",
        "VerifyGlobs.cmake",
        "--regenerate-during-build",
    ):
        assert forbidden not in plan.stdout + plan.stderr
    assert receipt.read_bytes() == before
    assert unchanged == {
        name: ((build / name).read_bytes(), (build / name).stat().st_mode)
        for name in names
    }
    launcher = build / "foresight-diagnostic-launcher"
    if tamper == "bytes":
        before_stat = launcher.stat()
        data = launcher.read_bytes()
        launcher.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
        os.utime(launcher, ns=(before_stat.st_atime_ns, before_stat.st_mtime_ns))
    elif tamper == "mode":
        launcher.chmod(0o700)
    else:
        record = json.loads(receipt.read_text())
        record["native_id"] = "0" * 64
        receipt.write_text(json.dumps(record))
    tampered_receipt = receipt.read_bytes()
    refused = configure(source, build)
    assert refused.returncode != 0
    assert (
        "Consumer runtime product verification failed"
        in refused.stdout + refused.stderr
    )
    assert receipt.read_bytes() == tampered_receipt


@pytest.mark.parametrize(
    "mutation", ["sql", "native", "toolchain", "recipe", "missing"]
)
def test_qualified_consumer_refuses_changed_inputs_without_rebuilding(
    tmp_path, mutation
):
    source, build = fixture(tmp_path, sql=True)
    configured = configure(source, build, "-DFORESIGHT_REQUIRE_DIAGNOSTIC_PRODUCTS=ON")
    assert configured.returncode == 0, configured.stdout + configured.stderr
    produced = subprocess.run(
        ["cmake", "--build", str(build), "--parallel", "2"],
        capture_output=True,
        check=False,
        text=True,
        timeout=90,
    )
    assert produced.returncode == 0, produced.stdout + produced.stderr
    extra = []
    if mutation in {"sql", "native"}:
        name = "sql_support.c" if mutation == "sql" else "diagnostic_protocol.c"
        path = source / "native" / name
        previous = path.stat()
        path.write_text(path.read_text() + "\n/* changed controlled input */\n")
        os.utime(path, ns=(previous.st_atime_ns, previous.st_mtime_ns))
    elif mutation == "toolchain":
        path = source / "tools/fixture-metadata.json"
        record = json.loads(path.read_text())
        record["record"]["fixture"] = "changed"
        record["fingerprint"] = hashlib.sha256(
            json.dumps(record["record"], sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        path.write_text(json.dumps(record))
    elif mutation == "recipe":
        extra.append("-DCMAKE_C_FLAGS=-g")
    else:
        (build / "foresight-diagnostic-launcher").unlink()
    refused = configure(
        source, build, "-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=ON", *extra
    )
    assert refused.returncode != 0
