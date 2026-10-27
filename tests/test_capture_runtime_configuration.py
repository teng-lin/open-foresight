"""Capture installation paths are explicit build inputs, never runtime PATH lookups."""

from pathlib import Path
import os
import json
import subprocess
import shutil
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def configuration_dependencies(tmp_path, monkeypatch):
    # These tests configure targets and inspect compile commands; they do not
    # compile JSON or PipeWire consumers. Declare dependencies explicitly without using
    # a developer's SDK installation or manufacturing a compiled-library proof.
    package = tmp_path / "configuration-only-json"
    package.mkdir()
    (package / "nlohmann_jsonConfig.cmake").write_text(
        "add_library(nlohmann_json::nlohmann_json INTERFACE IMPORTED)\n"
    )
    for name in ("CMAKE_PREFIX_PATH", "CMAKE_MODULE_PATH", "nlohmann_json_ROOT"):
        monkeypatch.delenv(name, raising=False)
    pkgconfig = tmp_path / "configuration-only-pkgconfig"
    pkgconfig.mkdir()
    (pkgconfig / "libpipewire-0.3.pc").write_text(
        "Name: configuration-only PipeWire\n"
        "Description: Imported target fixture; never compiled or shipped\n"
        "Version: 1.0.5\nLibs:\nCflags:\n"
    )
    monkeypatch.delenv("PKG_CONFIG_PATH", raising=False)
    monkeypatch.setenv("PKG_CONFIG_LIBDIR", str(pkgconfig))
    return [
        f"-Dnlohmann_json_DIR={package}",
        "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF",
        "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF",
    ]


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
import ctypes, os, pathlib, subprocess, sys
shim, native, folder, injection = sys.argv[1:]
folder = pathlib.Path(folder)
gate, ready = folder / 'hold', folder / 'ready'
os.environ.update(FORESIGHT_TEST_REAL_NATIVE=native,
    FORESIGHT_TEST_CAPTURE_POLL_GATE=str(gate), FORESIGHT_TEST_CAPTURE_READY=str(ready))
if sys.platform == 'darwin':
    os.environ['DYLD_INSERT_LIBRARIES'] = shim if injection == 'own' else shim + '.other'
library = ctypes.CDLL(shim)
if sys.platform == 'darwin':
    getenv = ctypes.CDLL(None).getenv
    getenv.argtypes, getenv.restype = [ctypes.c_char_p], ctypes.c_char_p
    actual = getenv(b'DYLD_INSERT_LIBRARIES')
    if injection == 'own':
        assert actual is None, 'loaded fixture injection escaped into descendants'
        child = subprocess.run([sys.executable, '-c',
            'import os; assert "DYLD_INSERT_LIBRARIES" not in os.environ'],
            capture_output=True, text=True, timeout=5)
        assert child.returncode == 0, child.stdout + child.stderr
    else:
        assert actual == (shim + '.other').encode(), 'unrelated injection was changed'
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
    for injection in ("own", "other") if apple else ("own",):
        result = subprocess.run(
            [sys.executable, "-c", probe, str(shim), str(native), str(tmp_path), injection],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert "both exports held and forwarded after release" in result.stdout

    if apple:
        ownership_probe = tmp_path / "capture-ownership-parent"
        subprocess.run(
            [compiler, "-std=c++17",
             str(ROOT / "tests/fixtures/capture_ownership_probe.cpp"),
             "-o", str(ownership_probe)],
            capture_output=True, text=True, check=True, timeout=30,
        )
        injected = dict(os.environ, DYLD_INSERT_LIBRARIES=str(shim))
        for command in (["/usr/bin/stat", "-f", "%u", str(tmp_path)], ["/usr/bin/id", "-u"]):
            result = subprocess.run(
                [str(ownership_probe), str(shim), *command],
                env=injected, capture_output=True, text=True, timeout=10,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            assert result.stdout.strip() == str(os.getuid())

        # A clean environment alone is not a witness that injection worked.
        uninjected = dict(os.environ)
        uninjected.pop("DYLD_INSERT_LIBRARIES", None)
        result = subprocess.run(
            [str(ownership_probe), str(shim), "/usr/bin/id", "-u"],
            env=uninjected, capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 21
        assert "not inserted before main" in result.stderr

        # A loaded image that leaves insertion armed must fail before it can
        # inject this architecture into Apple's protected child executables.
        unretired_source = tmp_path / "unretired.cpp"
        unretired_source.write_text('extern "C" int fixture_loaded() { return 1; }\n')
        unretired = tmp_path / "unretired.dylib"
        subprocess.run(
            [compiler, *flags, str(unretired_source), "-o", str(unretired)],
            capture_output=True, text=True, check=True, timeout=30,
        )
        result = subprocess.run(
            [str(ownership_probe), str(unretired), "/usr/bin/id", "-u"],
            env=dict(os.environ, DYLD_INSERT_LIBRARIES=str(unretired)),
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 22
        assert "left descendant injection armed" in result.stderr


def test_capture_installation_path_must_be_absolute(
    tmp_path, configuration_dependencies
):
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
            *configuration_dependencies,
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
    tmp_path, monkeypatch, inherited_generator, configuration_dependencies
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
            *configuration_dependencies,
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


def test_native_configuration_still_requires_json_dependency(
    tmp_path, configuration_dependencies
):
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
            *configuration_dependencies,
            "-DCMAKE_DISABLE_FIND_PACKAGE_nlohmann_json=ON",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert configured.returncode != 0
    assert "nlohmann_json" in configured.stderr
    assert "REQUIRED package cannot be disabled" in " ".join(configured.stderr.split())


@pytest.mark.skipif(
    sys.platform != "linux", reason="Linux direct PipeWire configuration contract"
)
@pytest.mark.parametrize("version", [None, "0.3.65"])
def test_native_linux_configuration_refuses_missing_or_old_pipewire(
    tmp_path, configuration_dependencies, version
):
    pkgconfig = Path(os.environ["PKG_CONFIG_LIBDIR"])
    package = pkgconfig / "libpipewire-0.3.pc"
    if version is None:
        package.unlink()
    else:
        package.write_text(package.read_text().replace("1.0.5", version))
    configured = subprocess.run(
        [
            "cmake",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(tmp_path / "build"),
            "-DBUILD_TESTING=OFF",
            *configuration_dependencies,
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert configured.returncode != 0, configured.stdout + configured.stderr
    assert "libpipewire-0.3" in configured.stdout + configured.stderr
    error = " ".join(configured.stderr.split())
    assert (
        "A required package was not found" in error
        or "The following required packages were not found" in error
    )


@pytest.mark.skipif(
    sys.platform != "linux", reason="Linux direct PipeWire configuration contract"
)
def test_native_linux_configuration_requires_pkgconfig(
    tmp_path, configuration_dependencies
):
    configured = subprocess.run(
        [
            "cmake",
            "-S",
            str(ROOT / "native"),
            "-B",
            str(tmp_path / "build"),
            "-DBUILD_TESTING=OFF",
            *configuration_dependencies,
            "-DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert configured.returncode != 0
    assert "PkgConfig" in configured.stderr
    assert "REQUIRED package cannot be disabled" in " ".join(configured.stderr.split())
