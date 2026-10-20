"""A real tiny CMake project proves warm work never substitutes for validation."""

import json
import os
from pathlib import Path
import shutil
import subprocess
from unittest.mock import patch

import pytest

from tools import run_ci_stage as runner
from tools import ci_native_work as native_work

ROOT = Path(__file__).resolve().parents[1]


def command(root, *args):
    return subprocess.check_output(args, cwd=root, text=True, timeout=60).strip()


def commit(root):
    command(root, "git", "add", ".")
    command(
        root,
        "git",
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.test",
        "commit",
        "-qm",
        "fixture",
    )
    return command(root, "git", "rev-parse", "HEAD")


def project(root):
    root.mkdir()
    command(root, "git", "init", "-q")
    (root / ".gitignore").write_text("build/\n")
    for path in ("tools", "cmake", "apps/desktop"):
        (root / path).mkdir(parents=True)
    for name in ("ForesightBuildIdentity.cmake", "OpenForesightVersion.cmake"):
        shutil.copy2(ROOT / "cmake" / name, root / "cmake" / name)
    shutil.copy2(
        ROOT / "services/helper/build_identity.cpp.in", root / "identity.cpp.in"
    )
    (root / "apps/desktop/pubspec.yaml").write_text("version: 0.1.1+1\n")
    (root / "tools/build.sh").write_text("""#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cmake -S "$root" -B "$root/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build "$root/build" --parallel 2
ctest --test-dir "$root/build" --output-on-failure
""")
    (root / "CMakeLists.txt").write_text("""cmake_minimum_required(VERSION 3.22)
include(cmake/OpenForesightVersion.cmake)
project(tiny_native LANGUAGES CXX)
set(FIXTURE_DEFAULT 0 CACHE STRING "Tiny configuration default")
include(cmake/ForesightBuildIdentity.cmake)
foresight_build_revision(BUILD_REV "${CMAKE_SOURCE_DIR}")
foresight_build_identity_source(identity "${CMAKE_SOURCE_DIR}/identity.cpp.in" "${CMAKE_BINARY_DIR}")
add_executable(ForesightHelper main.cpp stable.cpp changed.cpp "${identity}")
set_source_files_properties(changed.cpp PROPERTIES COMPILE_DEFINITIONS "FIXTURE_DEFAULT=${FIXTURE_DEFAULT}")
set_target_properties(ForesightHelper PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/services/helper")
enable_testing()
add_test(NAME current_native_validation COMMAND ForesightHelper)
""")
    (root / "main.cpp").write_text("""#include <fstream>
#include <iostream>
#include <string>
const char* foresight_helper_build_id();
int stable();
int changed();
int main(int argc, char** argv) {
  if (argc > 1 && std::string(argv[1]) == "--build-id") {
    std::cout << foresight_helper_build_id() << '\\n';
    return 0;
  }
  if (argc == 1)
    std::ofstream("Testing/fixture_runs.txt", std::ios::app) << "validated\\n";
  std::cout << stable() + changed() << '\\n';
}
""")
    (root / "stable.cpp").write_text("int stable() { return 7; }\n")
    (root / "changed.cpp").write_text(
        "int changed() { return 11 + FIXTURE_DEFAULT; }\n"
    )
    (root / "validation.txt").write_text("first test contract")
    return commit(root)


def preserve_artifact(root, destination, legacy=False):
    shutil.copytree(root / "build/ci-stage/linux-native", destination)
    receipt = json.loads((destination / "identity.json").read_text())
    if legacy:
        receipt["content"].pop("output_times")
        (destination / "identity.json").write_text(json.dumps(receipt))
    return {
        "hit": True,
        "download_dir": str(destination),
        "receipt": receipt,
        "run_id": 123,
    }


def validate(root, work=None, generator="Ninja"):
    if work:
        work = {
            **work,
            "configuration_changed": runner.cache.changed_configuration(
                root, work["receipt"]["source_commit"]
            ),
        }
    with (
        patch.object(runner.cache, "find", return_value={"hit": False}),
        patch.object(
            runner.cache, "find_native_work", return_value=work or {"hit": False}
        ),
    ):
        return runner.run(
            root,
            "linux",
            "native",
            {"compiler": "tiny-real-project"},
            {},
            {},
            "fixture/repository",
            112,
            "pull_request",
            False,
            ["-G", generator],
        )


def object_path(root, source):
    return root / "build/CMakeFiles/ForesightHelper.dir" / (source + ".o")


@pytest.mark.skipif(
    not all(shutil.which(tool) for tool in ("cmake", "ninja", "c++", "git")),
    reason="Tiny native cache proof needs a local compiler, CMake and Ninja",
)
@pytest.mark.parametrize("legacy", [False, True])
def test_test_edits_and_old_mtime_source_edits_reuse_objects_and_rerun_ctest(
    tmp_path, legacy
):
    root = tmp_path / "project"
    project(root)
    assert not validate(root)["compilation_cache_hit"]
    stable = object_path(root, "stable.cpp")
    changed = object_path(root, "changed.cpp")
    stable_time = stable.stat().st_mtime_ns
    changed_time = changed.stat().st_mtime_ns
    stable_bytes = stable.read_bytes()
    original = preserve_artifact(root, tmp_path / "first", legacy)

    # A different test contract invalidates qualification, not compiler work.
    (root / "validation.txt").write_text("new required test contract")
    revision = commit(root)
    shutil.rmtree(root / "build")
    result = validate(root, original)
    assert result["cache_hit"] is False
    assert result["compilation_cache_hit"] is True
    assert stable.stat().st_mtime_ns == stable_time
    assert changed.stat().st_mtime_ns == changed_time
    assert stable.read_bytes() == stable_bytes
    helper = root / "build/services/helper/ForesightHelper"
    assert command(root, str(helper), "--build-id").endswith(revision[:12])
    marker = root / "build/Testing/fixture_runs.txt"
    assert marker.read_text().splitlines() == ["validated"] * 2

    second = preserve_artifact(root, tmp_path / "second", legacy)
    (root / "changed.cpp").write_text(
        "int changed() { return 19 + FIXTURE_DEFAULT; }\n"
    )
    os.utime(root / "changed.cpp", ns=(1_000_000_000, 1_000_000_000))
    revision = commit(root)
    shutil.rmtree(root / "build")
    result = validate(root, second)
    assert result["cache_hit"] is False
    assert result["compilation_cache_hit"] is True
    assert stable.stat().st_mtime_ns == stable_time
    assert stable.read_bytes() == stable_bytes
    assert changed.stat().st_mtime_ns > changed_time
    assert command(root / "build", str(helper), "--value") == "26"
    assert command(root, str(helper), "--build-id").endswith(revision[:12])
    # Third CTest execution happened even though compatible native work existed.
    assert marker.read_text().splitlines() == ["validated"] * 3

    # Changed option defaults must not silently retain a producer's old cache.
    third = preserve_artifact(root, tmp_path / "third", legacy)
    configuration = root / "CMakeLists.txt"
    configuration.write_text(
        configuration.read_text().replace(
            "set(FIXTURE_DEFAULT 0", "set(FIXTURE_DEFAULT 5"
        )
    )
    revision = commit(root)
    shutil.rmtree(root / "build")
    result = validate(root, third)
    assert result["compilation_cache_hit"] is True
    assert stable.stat().st_mtime_ns == stable_time
    assert stable.read_bytes() == stable_bytes
    assert command(root / "build", str(helper), "--value") == "31"
    assert command(root, str(helper), "--build-id").endswith(revision[:12])
    assert marker.read_text().splitlines() == ["validated"] * 4


@pytest.mark.skipif(
    not all(shutil.which(tool) for tool in ("cmake", "ninja", "c++", "git")),
    reason="Tiny native cache proof needs a local compiler, CMake and Ninja",
)
def test_pin_changes_refresh_consumed_cmake_defaults_and_keep_unrelated_objects(
    tmp_path,
):
    root = tmp_path / "project"
    project(root)
    pins = root / "tools/pins.json"
    pins.write_text(json.dumps({"native_default": 0, "ubuntu_snapshot": "old"}))
    cmake = root / "CMakeLists.txt"
    cmake.write_text(
        cmake.read_text().replace(
            'set(FIXTURE_DEFAULT 0 CACHE STRING "Tiny configuration default")',
            'file(READ "${CMAKE_SOURCE_DIR}/tools/pins.json" pins)\n'
            'string(JSON native_default GET "${pins}" native_default)\n'
            'set(FIXTURE_DEFAULT "${native_default}" CACHE STRING "Tiny configuration default")',
        )
    )
    commit(root)
    validate(root)
    stable = object_path(root, "stable.cpp")
    changed = object_path(root, "changed.cpp")
    stable_time, changed_time = stable.stat().st_mtime_ns, changed.stat().st_mtime_ns
    original = preserve_artifact(root, tmp_path / "first")
    pins.write_text(json.dumps({"native_default": 0, "ubuntu_snapshot": "new"}))
    commit(root)
    shutil.rmtree(root / "build")
    assert validate(root, original)["compilation_cache_hit"]
    assert stable.stat().st_mtime_ns == stable_time
    assert changed.stat().st_mtime_ns == changed_time
    second = preserve_artifact(root, tmp_path / "second")
    pins.write_text(json.dumps({"native_default": 5, "ubuntu_snapshot": "new"}))
    commit(root)
    shutil.rmtree(root / "build")
    assert validate(root, second)["compilation_cache_hit"]
    assert stable.stat().st_mtime_ns == stable_time
    assert changed.stat().st_mtime_ns > changed_time
    helper = root / "build/services/helper/ForesightHelper"
    assert command(root / "build", str(helper), "--value") == "23"
    assert (root / "build/Testing/fixture_runs.txt").read_text().splitlines() == [
        "validated"
    ] * 3


@pytest.mark.skipif(
    not all(shutil.which(tool) for tool in ("cmake", "ninja", "make", "c++", "git")),
    reason="Tiny compiler-only restore proof needs CMake, Make, Ninja and compiler",
)
@pytest.mark.parametrize("generator", ["Ninja", "Unix Makefiles"])
def test_compiler_only_restore_keeps_objects_and_always_runs_current_build_and_tests(
    tmp_path, generator
):
    root = tmp_path / "project"
    project(root)
    script = root / "tools/build.sh"
    script.write_text(script.read_text().replace("-G Ninja", '-G "' + generator + '"'))
    commit(root)
    validate(root, generator=generator)
    stable = object_path(root, "stable.cpp")
    stable_time, stable_bytes = stable.stat().st_mtime_ns, stable.read_bytes()
    original = preserve_artifact(root, tmp_path / "original")
    if generator == "Ninja":
        configuration = root / "CMakeLists.txt"
        configuration.write_text(
            configuration.read_text().replace(
                "set(FIXTURE_DEFAULT 0", "set(FIXTURE_DEFAULT 5"
            )
        )
    else:
        (root / "validation.txt").write_text("current validation contract")
    revision = commit(root)
    original["configuration_changed"] = native_work.cache.changed_configuration(
        root, original["receipt"]["source_commit"]
    )
    shutil.rmtree(root / "build")
    with (
        patch.object(native_work.cache, "find_native_work", return_value=original),
        patch.object(
            native_work.cache, "find", side_effect=AssertionError("result reuse")
        ),
        patch.object(
            native_work.cache, "publish", side_effect=AssertionError("publication")
        ),
    ):
        result = native_work.restore(
            root,
            "linux",
            {},
            ["-G", generator],
            "fixture/repository",
            event="schedule",
            branch="main",
        )
    assert result["run_id"] == 123
    assert (root / "build/CMakeCache.txt").exists() == (generator != "Ninja")
    assert stable.stat().st_mtime_ns == stable_time
    # Restoration cannot stand in for current configure, compilation and CTest.
    print(command(root, "bash", str(script)))
    assert stable.stat().st_mtime_ns == stable_time
    assert stable.read_bytes() == stable_bytes
    helper = root / "build/services/helper/ForesightHelper"
    assert command(root, str(helper), "--build-id").endswith(revision[:12])
    assert command(root / "build", str(helper), "--value") == (
        "23" if generator == "Ninja" else "18"
    )
    assert (root / "build/Testing/fixture_runs.txt").read_text().splitlines() == [
        "validated"
    ] * 2
