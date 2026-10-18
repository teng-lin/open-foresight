"""Dependency-only configuration retains the full application's native objects."""

import json
from pathlib import Path
import shutil
import subprocess

import pytest

from tools.verify_app_dependency_reuse import verify

ROOT = Path(__file__).resolve().parents[1]


def run(*arguments):
    return subprocess.check_output(
        arguments, text=True, stderr=subprocess.STDOUT, timeout=60
    )


@pytest.mark.skipif(
    not shutil.which("cmake") or not shutil.which("c++"),
    reason="CMake/C++ compiler unavailable",
)
@pytest.mark.parametrize("generator", ["Unix Makefiles", "Ninja"])
@pytest.mark.parametrize("change", ["source", "flags"])
def test_dependency_objects_survive_full_application_reconfigure(
    tmp_path, generator, change
):
    if generator == "Ninja" and not shutil.which("ninja"):
        pytest.skip("Ninja unavailable")
    source = tmp_path / "src"
    source.mkdir()
    (source / "cmake").mkdir()
    shutil.copy(ROOT / "cmake/ForesightInferenceDependencies.cmake", source / "cmake")
    shutil.copy(
        ROOT / "packaging/app-dependencies/CMakeLists.txt", source / "CMakeLists.txt"
    )
    # Tiny local dependency projects exercise FetchContent's actual binary paths
    # without downloading or compiling either third-party library.
    for name in ("sentencepiece", "flatbuffers"):
        directory = tmp_path / name
        directory.mkdir()
        (directory / "unit.cpp").write_text("int main() { return 0; }\n")
        definition = (
            "set(CMAKE_CXX_STANDARD 17)\nadd_library(sentencepiece-static STATIC unit.cpp)\n"
            if name == "sentencepiece"
            else "add_executable(flatc unit.cpp)\n"
        )
        (directory / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.22)\n" + definition
        )
    build = source / "build"
    configure = (
        "cmake",
        "-G",
        generator,
        "-S",
        str(source),
        "-B",
        str(build),
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        f"-DFETCHCONTENT_SOURCE_DIR_SENTENCEPIECE={tmp_path / 'sentencepiece'}",
        f"-DFETCHCONTENT_SOURCE_DIR_FLATBUFFERS={tmp_path / 'flatbuffers'}",
    )
    run(*configure)
    run(
        "cmake",
        "--build",
        str(build),
        "--target",
        "flatc",
        "sentencepiece-static",
        "--parallel",
        "2",
    )
    objects = {
        path: (path.stat().st_mtime_ns, path.read_bytes())
        for path in build.glob("_deps/**/*unit.cpp.o")
    }
    assert len(objects) == 2
    commands = json.loads((build / "compile_commands.json").read_text())
    assert any("-std=gnu++17" in row["command"] for row in commands)
    assert any("-std=gnu++20" in row["command"] for row in commands)
    # Match the real root and services/inference inclusion hierarchy. COPY . .
    # replaces only the root project; dependency source and binary paths persist.
    (source / "services/inference").mkdir(parents=True)
    (source / "services/inference/CMakeLists.txt").write_text(
        "include(${PROJECT_SOURCE_DIR}/cmake/ForesightInferenceDependencies.cmake)\n"
    )
    # Use the actual root and all its global-default includes. Only application
    # target subdirectories are stubbed to avoid downloading unrelated libraries.
    shutil.copy(ROOT / "CMakeLists.txt", source / "CMakeLists.txt")
    for include in (
        "OpenForesightVersion.cmake",
        "MacOSDeploymentTarget.cmake",
        "ForesightSanitizers.cmake",
    ):
        shutil.copy(ROOT / "cmake" / include, source / "cmake")
    (source / "apps/desktop").mkdir(parents=True)
    shutil.copy(
        ROOT / "apps/desktop/pubspec.yaml", source / "apps/desktop/pubspec.yaml"
    )
    (source / "services/helper").mkdir()
    (source / "services/helper/CMakeLists.txt").write_text(
        "add_executable(application ../../app.cpp)\n"
        "target_link_libraries(application PRIVATE sentencepiece-static)\n"
    )
    (source / "app.cpp").write_text("int main() { return 0; }\n")
    run(*configure)
    # Actual application compilation/linking is required and remains allowed.
    verify(build)
    run(
        "cmake",
        "--build",
        str(build),
        "--target",
        "flatc",
        "sentencepiece-static",
        "--parallel",
        "2",
    )
    assert {
        path: (path.stat().st_mtime_ns, path.read_bytes()) for path in objects
    } == objects
    after = json.loads((build / "compile_commands.json").read_text())
    assert [row for row in after if row["file"] != str(source / "app.cpp")] == commands
    if change == "source":
        changed = tmp_path / "flatbuffers/unit.cpp"
        changed.write_text("int main() { return 1; }\n")
    else:
        run(*configure, "-DCMAKE_CXX_FLAGS=-DCHANGED_DEPENDENCY_FLAG")
    with pytest.raises(ValueError, match="would compile or relink"):
        verify(build)
    assert {
        path: (path.stat().st_mtime_ns, path.read_bytes()) for path in objects
    } == objects


def test_dependency_recipe_and_layer_exclude_application_revision():
    recipe = (ROOT / "cmake/ForesightInferenceDependencies.cmake").read_text()
    assert "31646a467d2051eb904e0b45de3a73e91fe1c1e3" in recipe
    assert "edbe17738352418245d7228e7fd9f12c3ddc34c4" in recipe
    assert (
        "include(${PROJECT_SOURCE_DIR}/cmake/ForesightInferenceDependencies.cmake)"
        in (ROOT / "services/inference/CMakeLists.txt").read_text()
    )
    dockerfile = (ROOT / "packaging/build.Dockerfile").read_text()
    dependencies = dockerfile.split("AS application-dependencies\n")[1].split(
        "FROM application-dependencies AS tested"
    )[0]
    assert "COPY . ." not in dependencies
    assert "SOURCE_REVISION" not in dependencies
    # Preserve every default dependency target already built by the normal app.
    assert "cmake --build /src/build --parallel 4" in dependencies
    assert "--target" not in dependencies
    assert "COPY --from=appdeps_seed /src/build/_deps /src/build/_deps" in dependencies
