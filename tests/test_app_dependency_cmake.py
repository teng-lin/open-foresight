"""Dependency-only configuration retains the full application's native objects."""

import json
import os
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
@pytest.mark.parametrize("change", ["source", "flags", "train", "tool"])
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
        (directory / "train.cpp").write_text("int train_value() { return 0; }\n")
        (directory / "tool.cpp").write_text("int main() { return 0; }\n")
        definition = (
            "set(CMAKE_CXX_STANDARD 17)\nadd_library(sentencepiece-static STATIC unit.cpp)\n"
            "add_library(sentencepiece_train-static STATIC train.cpp)\n"
            "foreach(tool spm_train spm_encode spm_decode spm_normalize spm_export_vocab)\n"
            " add_executable(${tool} tool.cpp)\n"
            " target_link_libraries(${tool} PRIVATE sentencepiece_train-static)\n"
            "endforeach()\n"
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
        "sentencepiece_train-static",
        "spm_train",
        "spm_encode",
        "spm_decode",
        "spm_normalize",
        "spm_export_vocab",
        "--parallel",
        "2",
    )
    objects = {
        path: (path.stat().st_mtime_ns, path.read_bytes())
        for path in build.glob("_deps/**/*.cpp.o")
    }
    assert len(objects) == 8
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
    # Exercise the real root's new application-owned SQLite include without
    # downloading the amalgamation. This target is application work outside
    # _deps, so it may compile while the retained SDK outputs stay unchanged.
    (source / "sqlite_stub.c").write_text("int sqlite_fixture(void) { return 0; }\n")
    (source / "cmake/ForesightSqlite.cmake").write_text(
        'add_library(foresight_sqlite3 SHARED "${PROJECT_SOURCE_DIR}/sqlite_stub.c")\n'
        'set_target_properties(foresight_sqlite3 PROPERTIES SUFFIX ".dylib"\n'
        ' LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/macos")\n'
    )
    (source / "apps/desktop").mkdir(parents=True)
    shutil.copy(
        ROOT / "apps/desktop/pubspec.yaml", source / "apps/desktop/pubspec.yaml"
    )
    (source / "services/helper").mkdir()
    (source / "services/helper/CMakeLists.txt").write_text(
        'add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated.cpp"\n'
        ' COMMAND ${CMAKE_COMMAND} -E copy "${PROJECT_SOURCE_DIR}/app.cpp" "${CMAKE_CURRENT_BINARY_DIR}/generated.cpp"\n'
        ' DEPENDS "${PROJECT_SOURCE_DIR}/app.cpp")\n'
        'add_library(protocol STATIC "${CMAKE_CURRENT_BINARY_DIR}/generated.cpp")\n'
        "add_executable(application ../../app.cpp)\n"
        "target_link_libraries(application PRIVATE protocol sentencepiece-static)\n"
    )
    # The actual root declares these Apple ALL targets. Keep their real inputs
    # available to the dry run without adding native/CMakeLists.txt or building
    # any Swift target in this dependency-only fixture.
    (source / "native").mkdir()
    for name in ("notifications.swift", "file_parser.swift", "model_crypto.swift"):
        shutil.copy(ROOT / "native" / name, source / "native" / name)
    (source / "app.cpp").write_text("int main() { return 0; }\n")
    run(*configure)
    # Make's complete dry run cannot materialize the new application archive:
    # its next recursive target fails, although all dependency work is reusable.
    if generator == "Unix Makefiles":
        full = subprocess.run(
            ["cmake", "--build", str(build), "--verbose", "--", "-n"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert full.returncode != 0
        assert "libprotocol.a" in full.stdout + full.stderr
    # Dependency ALL dry runs cover training/tools without traversing those app
    # generation edges. Neither the generated source nor archive is built.
    verify(build)
    assert not (build / "services/helper/generated.cpp").exists()
    assert not (build / "services/helper/libprotocol.a").exists()
    assert not (build / "macos/libforesight_sqlite3.dylib").exists()
    run(
        "cmake",
        "--build",
        str(build),
        "--target",
        "flatc",
        "sentencepiece-static",
        "sentencepiece_train-static",
        "spm_train",
        "spm_encode",
        "spm_decode",
        "spm_normalize",
        "spm_export_vocab",
        "--parallel",
        "2",
    )
    assert {
        path: (path.stat().st_mtime_ns, path.read_bytes()) for path in objects
    } == objects
    after = json.loads((build / "compile_commands.json").read_text())
    dependency_sources = {row["file"] for row in commands}
    assert [row for row in after if row["file"] in dependency_sources] == commands
    # Build both newly generated application sources and the new application
    # SQLite target. Existing dependency outputs must remain byte-identical,
    # and the reuse guard must also pass with application outputs present.
    run(
        "cmake",
        "--build",
        str(build),
        "--target",
        "application",
        "foresight_sqlite3",
        "--parallel",
        "2",
    )
    assert (build / "services/helper/generated.cpp").is_file()
    assert (build / "services/helper/libprotocol.a").is_file()
    assert (build / "macos/libforesight_sqlite3.dylib").is_file()
    verify(build)
    assert {
        path: (path.stat().st_mtime_ns, path.read_bytes()) for path in objects
    } == objects
    if change == "source":
        changed = tmp_path / "flatbuffers/unit.cpp"
        changed.write_text("int main() { return 1; }\n")
        changed_inputs = [changed]
    elif change == "flags":
        run(*configure, "-DCMAKE_CXX_FLAGS=-DCHANGED_DEPENDENCY_FLAG")
        changed_inputs = list(build.glob("_deps/**/flags.make"))
        if generator == "Unix Makefiles":
            assert changed_inputs
    else:
        changed = (
            tmp_path
            / "sentencepiece"
            / ("train.cpp" if change == "train" else "tool.cpp")
        )
        changed.write_text("int main() { return 1; }\n")
        changed_inputs = [changed]
    # macOS Make compares whole seconds. The changed tiny fixture inputs must
    # be newer than the retained objects even when the test runs within a second.
    # Leave every dependency output's bytes and timestamp unchanged.
    newest_object = max(timestamp for timestamp, _ in objects.values())
    for changed in changed_inputs:
        metadata = changed.stat()
        os.utime(
            changed,
            ns=(
                metadata.st_atime_ns,
                max(metadata.st_mtime_ns, newest_object + 2_000_000_000),
            ),
        )
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
        "FROM application-dependencies AS ci"
    )[0]
    assert "COPY . ." not in dependencies
    assert "SOURCE_REVISION" not in dependencies
    # Preserve every default dependency target already built by the normal app.
    assert "cmake --build /src/build --parallel 4" in dependencies
    assert "--target" not in dependencies
    assert "COPY --from=appdeps_seed /src/build/_deps /src/build/_deps" in dependencies
