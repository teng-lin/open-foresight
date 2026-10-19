"""The shadow runners retain exact bytes/timestamps and never rebuild dependencies."""

import json
from pathlib import Path
import shutil
import subprocess
from unittest.mock import patch

import pytest

from tools import ci_linux_handoff as handoff
from tools import verify_application_no_build as idle


@pytest.fixture
def compiled(tmp_path):
    root = tmp_path / "src"
    dep = root / "build/_deps/vendor-src"
    dep.mkdir(parents=True)
    (dep / "dep.c").write_text("int dep(void) { return 0; }\n")
    (dep / "CMakeLists.txt").write_text("add_library(dep STATIC dep.c)\n")
    (root / "main.c").write_text("int dep(void); int main(void) { return dep(); }\n")
    (root / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\nproject(handoff C)\n"
        'add_subdirectory("${CMAKE_BINARY_DIR}/_deps/vendor-src" "${CMAKE_BINARY_DIR}/_deps/vendor-build")\n'
        "add_executable(app main.c)\ntarget_link_libraries(app PRIVATE dep)\n"
        "enable_testing()\nadd_test(NAME native COMMAND app)\n"
    )
    subprocess.run(
        ["cmake", "-G", "Unix Makefiles", "-S", str(root), "-B", str(root / "build")],
        check=True,
        capture_output=True,
        timeout=60,
    )
    subprocess.run(
        ["cmake", "--build", str(root / "build")],
        check=True,
        capture_output=True,
        timeout=60,
    )
    inputs = tmp_path / "inputs.json"
    inputs.write_text(json.dumps({"identity": "verified"}))
    return root, inputs


def test_real_make_handoff_between_runner_filesystems_is_idle(compiled, tmp_path):
    root, inputs = compiled
    original = root / "build/app"
    checksum = handoff.digest(original)
    stamp = original.stat().st_mtime_ns
    (root / "native-link").symlink_to("build/app")
    (root / ".git").mkdir()
    (root / ".git/config").write_text("not exported")
    seed = tmp_path / "verified-seed"
    shutil.copytree(root / "build/_deps", seed, copy_function=shutil.copy2)
    archive = tmp_path / "handoff"
    manifest = handoff.pack(root, archive, "a" * 40, inputs)
    assert not any(
        name.startswith((".git", "build/_deps")) for name in manifest["files"]
    )
    # Both isolated runners mount their independent tree at /src. Replace this
    # entire filesystem with the dependency-only image, preserving that path.
    shutil.rmtree(root)
    shutil.copytree(seed, root / "build/_deps", copy_function=shutil.copy2)
    retained = handoff.digest(root / "build/_deps/vendor-build/libdep.a")
    handoff.restore(archive, root, "a" * 40, inputs)
    assert handoff.digest(original) == checksum
    assert original.stat().st_mtime_ns == stamp
    assert handoff.digest(root / "build/_deps/vendor-build/libdep.a") == retained
    assert (root / "native-link").readlink() == Path("build/app")
    idle.verify(root / "build")
    subprocess.run(
        ["ctest", "--test-dir", str(root / "build"), "--output-on-failure"],
        check=True,
        capture_output=True,
        timeout=30,
    )
    (root / "main.c").write_text("int main(void) { return 1; }\n")
    with pytest.raises(ValueError, match="not idle"):
        idle.verify(root / "build")
    assert "main.c" in (root / "build/application-no-build-plan.log").read_text()
    assert handoff.digest(root / "build/_deps/vendor-build/libdep.a") == retained


@pytest.mark.parametrize("change", ["archive", "source", "inputs"])
def test_handoff_mismatches_preserve_the_seed(compiled, tmp_path, change):
    root, inputs = compiled
    directory = tmp_path / "handoff"
    handoff.pack(root, directory, "a" * 40, inputs)
    if change == "archive":
        with (directory / "source-build.tar.gz").open("ab") as stream:
            stream.write(b"invalid")
    elif change == "inputs":
        inputs.write_text('{"identity":"other"}')
    retained = handoff.digest(root / "build/_deps/vendor-build/libdep.a")
    with pytest.raises(ValueError, match="mismatch"):
        handoff.restore(
            directory, root, "b" * 40 if change == "source" else "a" * 40, inputs
        )
    assert handoff.digest(root / "build/_deps/vendor-build/libdep.a") == retained


@pytest.mark.parametrize(
    "target", ["/etc/passwd", "../../outside", "/opt/../etc/passwd"]
)
def test_archive_rejects_untrusted_source_links(tmp_path, target):
    root = tmp_path / "src"
    root.mkdir()
    (root / "link").symlink_to(target)
    inputs = tmp_path / "inputs"
    inputs.write_text("{}")
    with pytest.raises(ValueError, match="link"):
        handoff.pack(root, tmp_path / "out", "a" * 40, inputs)


def test_ci_identity_is_input_based_and_does_not_hash_a_rebuilt_ci_image(tmp_path):
    recipe = tmp_path / "Dockerfile"
    recipe.write_text(
        "FROM sdk AS application-base\nFROM application-base AS application-dependencies\nFROM application-dependencies AS ci\nRUN tools\nFROM application-dependencies AS tested\nRUN app\n"
    )
    qualification = tmp_path / "qualification.json"
    qualification.write_text('{"original_producer":42}')
    with patch.object(
        handoff.subprocess, "check_output", return_value="sha256:" + "a" * 64
    ):
        first = handoff.input_identity(
            "verified-sdk", qualification, recipe, "20261001T000000Z"
        )
        recipe.write_text(recipe.read_text().replace("RUN app", "RUN different app"))
        assert (
            handoff.input_identity(
                "verified-sdk", qualification, recipe, "20261001T000000Z"
            )
            == first
        )
        recipe.write_text(recipe.read_text().replace("RUN tools", "RUN new tools"))
        assert (
            handoff.input_identity(
                "verified-sdk", qualification, recipe, "20261001T000000Z"
            )
            != first
        )


@pytest.mark.parametrize(
    "output",
    [
        "cc -c native.c -o native.o",
        "/usr/bin/cmake -E touch generated.h",
        "protoc schema.proto",
        "ninja: error: failed",
    ],
)
def test_idle_guard_rejects_all_planned_generation_compilation_and_failure(output):
    assert idle.planned_work(output) == output
