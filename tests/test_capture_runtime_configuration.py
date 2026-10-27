"""Capture installation paths are explicit build inputs, never runtime PATH lookups."""

from pathlib import Path
import json
import subprocess
import shutil
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]


def test_capture_poll_gate_holds_both_public_exports_and_forwards_after_release(
    tmp_path,
):
    compiler = shutil.which("c++")
    assert compiler, "The capture ABI fixture requires the supported C++ toolchain"
    source = tmp_path / "controlled_native.cpp"
    source.write_text(
        "#include <cstdint>\n"
        'extern "C" char *fs_event_poll(void *, int) { return const_cast<char *>("legacy"); }\n'
        'extern "C" char *fs_owned_event_poll(uint64_t, int) { return const_cast<char *>("owned"); }\n'
    )
    apple = sys.platform == "darwin"
    suffix = ".dylib" if apple else ".so"
    native = tmp_path / ("controlled_native" + suffix)
    shim = tmp_path / ("capture_gate" + suffix)
    flags = (
        ["-std=c++17", "-dynamiclib"] if apple else ["-std=c++17", "-shared", "-fPIC"]
    )
    subprocess.run(
        [compiler, *flags, str(source), "-o", str(native)],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    link = [str(native)] if apple else ["-Wl,--no-as-needed", str(native), "-ldl"]
    subprocess.run(
        [
            compiler,
            *flags,
            str(ROOT / "tests/fixtures/capture_poll_gate.cpp"),
            *link,
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            str(tmp_path),
            "-o",
            str(shim),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    probe = r"""
import ctypes, os, pathlib, sys
shim, native, folder = sys.argv[1:]
folder = pathlib.Path(folder)
gate, ready = folder / 'hold', folder / 'ready'
os.environ.update(FORESIGHT_TEST_REAL_NATIVE=native,
    FORESIGHT_TEST_CAPTURE_POLL_GATE=str(gate), FORESIGHT_TEST_CAPTURE_READY=str(ready))
library = ctypes.CDLL(shim)
legacy = library.fs_event_poll
legacy.argtypes, legacy.restype = [ctypes.c_void_p, ctypes.c_int], ctypes.c_char_p
owned = library.fs_owned_event_poll
owned.argtypes, owned.restype = [ctypes.c_uint64, ctypes.c_int], ctypes.c_char_p
assert legacy(None, 0) == b'legacy' and owned(7, 0) == b'owned'
gate.touch()
assert legacy(None, 0) is None, 'legacy poll escaped the capture gate'
assert owned(7, 0) is None, 'owned poll escaped the capture gate'
ready.touch()
assert legacy(None, 0) == b'legacy' and owned(7, 0) == b'owned'
ready.unlink(); gate.unlink()
assert legacy(None, 0) == b'legacy' and owned(7, 0) == b'owned'
print('both exports held and forwarded after release')
"""
    result = subprocess.run(
        [sys.executable, "-c", probe, str(shim), str(native), str(tmp_path)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "both exports held and forwarded after release" in result.stdout


def test_capture_installation_path_must_be_absolute(tmp_path):
    configured = subprocess.run(
        [
            "cmake",
            "-G",
            "Unix Makefiles",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(tmp_path / "build"),
            "-DBUILD_TESTING=OFF",
            "-DFORESIGHT_PW_RECORD_EXECUTABLE=relative/pw-record",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert configured.returncode != 0
    assert "must be an absolute installation path" in configured.stderr


@pytest.mark.parametrize("inherited_generator", ["Xcode", "Visual Studio 17 2022"])
def test_capture_installation_path_enters_native_compile_definition(
    tmp_path, monkeypatch, inherited_generator
):
    # Compile-command export is supported only by Makefile/Ninja generators;
    # a developer's inherited IDE generator must not change this fixture.
    monkeypatch.setenv("CMAKE_GENERATOR", inherited_generator)
    installed = tmp_path / "trusted installation" / "bin" / "pw-record"
    build = tmp_path / "build"
    subprocess.run(
        [
            "cmake",
            "-G",
            "Unix Makefiles",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(build),
            "-DBUILD_TESTING=OFF",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
            "-DFORESIGHT_PW_RECORD_EXECUTABLE=" + str(installed),
        ],
        capture_output=True,
        check=True,
        timeout=60,
    )
    commands = json.loads((build / "compile_commands.json").read_text())
    native = next(
        item for item in commands if item["file"].endswith("foresight_native.cpp")
    )
    assert "FORESIGHT_PW_RECORD_EXECUTABLE" in native["command"]
    assert str(installed) in native["command"]
