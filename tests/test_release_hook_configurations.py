"""Release binaries stay hook-free across generator and cached option changes."""

from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
RELEASE_CONFIGURATIONS = ("Release", "RelWithDebInfo", "MinSizeRel")
MARKER = "FORESIGHT_CRASH_AT"


@pytest.fixture
def configuration_fixture(tmp_path):
    if not shutil.which("cmake") or not shutil.which("c++"):
        pytest.skip("CMake and C++ compiler required")
    source = tmp_path / "source"
    source.mkdir()
    module = ROOT / "cmake/ForesightTestHooks.cmake"
    (source / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\n"
        "project(hook_configuration LANGUAGES CXX)\n"
        f'include("{module}")\n'
        "add_executable(production main.cpp)\n"
        "target_compile_definitions(production PRIVATE FORESIGHT_ENABLE_TEST_HOOKS=${FORESIGHT_PRODUCTION_TEST_HOOKS})\n"
        "add_executable(instrumented main.cpp)\n"
        "target_compile_definitions(instrumented PRIVATE FORESIGHT_ENABLE_TEST_HOOKS=1)\n"
    )
    (source / "main.cpp").write_text(
        "#include <iostream>\n"
        "int main() {\n"
        "#if FORESIGHT_ENABLE_TEST_HOOKS\n"
        f' std::cout << "{MARKER}";\n'
        "#else\n"
        ' std::cout << "disabled";\n'
        "#endif\n"
        "}\n"
    )
    return source, tmp_path / "build"


def configure(source, build, *arguments):
    subprocess.run(
        ["cmake", "-S", str(source), "-B", str(build), *arguments],
        capture_output=True,
        check=True,
        timeout=60,
    )


def verify(build, configuration, multi=False):
    subprocess.run(
        ["cmake", "--build", str(build), "--config", configuration, "--parallel", "2"],
        capture_output=True,
        check=True,
        timeout=60,
    )
    prefix = build / configuration if multi else build
    for target, expected in (("production", "disabled"), ("instrumented", MARKER)):
        binary = prefix / target
        output = subprocess.check_output([str(binary)], text=True, timeout=5)
        assert output == expected
        assert (MARKER.encode() in binary.read_bytes()) == (target == "instrumented")


@pytest.mark.parametrize("configuration", (*RELEASE_CONFIGURATIONS, "release"))
def test_switching_debug_to_release_cannot_keep_cached_hooks(
    configuration_fixture, configuration
):
    source, build = configuration_fixture
    configure(source, build, "-DCMAKE_BUILD_TYPE=Debug")
    subprocess.run(
        ["cmake", "--build", str(build)], capture_output=True, check=True, timeout=60
    )
    assert (
        subprocess.check_output([str(build / "production")], text=True, timeout=5)
        == MARKER
    )
    configure(source, build, f"-DCMAKE_BUILD_TYPE={configuration}")
    # The stale option deliberately remains ON; only the actual configuration
    # expression prevents this established release-build regression.
    assert (
        "FORESIGHT_ENABLE_TEST_HOOKS:BOOL=ON" in (build / "CMakeCache.txt").read_text()
    )
    verify(build, configuration)


@pytest.mark.parametrize("configuration", RELEASE_CONFIGURATIONS)
def test_multi_config_release_ignores_enabled_debug_hooks(
    configuration_fixture, configuration
):
    if not shutil.which("ninja"):
        pytest.skip("Ninja Multi-Config requires Ninja")
    source, build = configuration_fixture
    configure(
        source,
        build,
        "-G",
        "Ninja Multi-Config",
        "-DFORESIGHT_ENABLE_TEST_HOOKS=ON",
        "-DCMAKE_CONFIGURATION_TYPES=Debug;Release;RelWithDebInfo;MinSizeRel",
    )
    verify(build, configuration, multi=True)


def test_both_production_targets_use_the_configuration_gate():
    for relative, target in (
        ("native/CMakeLists.txt", "foresight_native"),
        ("services/helper/CMakeLists.txt", "ForesightHelper"),
    ):
        source = (ROOT / relative).read_text()
        assert (
            f"target_compile_definitions({target} PRIVATE FORESIGHT_ENABLE_TEST_HOOKS=${{FORESIGHT_PRODUCTION_TEST_HOOKS}})"
            in source
        )
