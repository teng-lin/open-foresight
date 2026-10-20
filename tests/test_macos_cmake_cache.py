"""Qualify resolved packages using real CMake find-package behavior, without builds."""

from pathlib import Path
import subprocess
import sys

import pytest

from tools.verify_macos_cmake_cache import verify

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def configured(tmp_path):
    sdk = tmp_path / "verified-sdk"
    icu = tmp_path / "brew-cellar/icu4c/78.3"
    for package in ("Protobuf", "gRPC"):
        directory = sdk / "lib/cmake" / package
        directory.mkdir(parents=True)
        (directory / f"{package}Config.cmake").write_text("")
    (icu / "include/unicode").mkdir(parents=True)
    (icu / "include/unicode/utypes.h").write_text("")
    (icu / "include/unicode/uvernum.h").write_text('#define U_ICU_VERSION "78.3"\n')
    (icu / "lib").mkdir()
    for component in ("uc", "i18n"):
        (icu / f"lib/libicu{component}.a").touch()
    project = tmp_path / "source"
    project.mkdir()
    (project / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\n"
        "project(qualified_packages NONE)\n"
        "find_package(Protobuf CONFIG REQUIRED)\n"
        "find_package(gRPC CONFIG REQUIRED)\n"
        "find_package(ICU REQUIRED COMPONENTS uc i18n)\n"
    )
    build = tmp_path / "build"
    result = subprocess.run(
        [
            "cmake",
            "-S",
            str(project),
            "-B",
            str(build),
            "-G",
            "Ninja",
            f"-DCMAKE_PREFIX_PATH={sdk}",
            f"-DICU_ROOT={icu}",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_OSX_ARCHITECTURES=arm64",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return build / "CMakeCache.txt", sdk, icu


def rewrite(cache, key, value):
    lines = cache.read_text().splitlines()
    found = False
    for index, line in enumerate(lines):
        if line.startswith(key + ":"):
            lines[index] = line.split("=", 1)[0] + "=" + value
            found = True
    assert found, key
    cache.write_text("\n".join(lines) + "\n")


def test_real_find_package_cache_passes_and_brew_symlink_is_qualified(
    configured, tmp_path
):
    cache, sdk, icu = configured
    verify(cache, sdk=sdk, icu=icu)
    opt = tmp_path / "brew-opt-icu4c"
    opt.symlink_to(icu, target_is_directory=True)
    verify(cache, sdk=sdk, icu=opt)


@pytest.mark.parametrize(
    "key",
    [
        "Protobuf_DIR",
        "gRPC_DIR",
        "ICU_INCLUDE_DIR",
        "ICU_UC_LIBRARY_RELEASE",
        "ICU_I18N_LIBRARY_RELEASE",
    ],
)
def test_present_host_package_does_not_count_as_qualified_sdk(
    configured, tmp_path, key
):
    cache, sdk, icu = configured
    host = tmp_path / "unverified-host-package"
    host.mkdir()
    rewrite(cache, key, str(host))
    with pytest.raises(ValueError, match=key):
        verify(cache, sdk=sdk, icu=icu)


@pytest.mark.parametrize("value", ["missing-NOTFOUND", "relative/path", ""])
def test_unresolved_package_fails(configured, value):
    cache, sdk, icu = configured
    rewrite(cache, "Protobuf_DIR", value)
    with pytest.raises(ValueError, match="Protobuf_DIR"):
        verify(cache, sdk=sdk, icu=icu)


def test_symlink_inside_sdk_cannot_escape_to_unverified_packages(configured, tmp_path):
    cache, sdk, icu = configured
    outside = tmp_path / "unverified-package"
    outside.mkdir()
    link = sdk / "escaped"
    link.symlink_to(outside, target_is_directory=True)
    rewrite(cache, "gRPC_DIR", str(link))
    with pytest.raises(ValueError, match="gRPC_DIR"):
        verify(cache, sdk=sdk, icu=icu)


@pytest.mark.parametrize(
    "key,value",
    [
        ("CMAKE_GENERATOR", "Unix Makefiles"),
        ("CMAKE_BUILD_TYPE", "Debug"),
        ("CMAKE_OSX_ARCHITECTURES", "x86_64"),
        ("CMAKE_OSX_DEPLOYMENT_TARGET", "14.0"),
        ("CMAKE_IGNORE_PREFIX_PATH", ""),
    ],
)
def test_output_affecting_configuration_fails_before_build(configured, key, value):
    cache, sdk, icu = configured
    rewrite(cache, key, value)
    with pytest.raises(ValueError, match=key):
        verify(cache, sdk=sdk, icu=icu)


def test_missing_component_library_and_unqualified_optional_library_fail(
    configured, tmp_path
):
    cache, sdk, icu = configured
    original = cache.read_text()
    rewrite(cache, "ICU_UC_LIBRARY_RELEASE", "ICU_UC_LIBRARY_RELEASE-NOTFOUND")
    with pytest.raises(ValueError, match="Missing resolved ICU UC"):
        verify(cache, sdk=sdk, icu=icu)
    outside = tmp_path / "unverified-debug.a"
    outside.touch()
    cache.write_text(original + f"\nICU_UC_LIBRARY_DEBUG:FILEPATH={outside}\n")
    with pytest.raises(ValueError, match="ICU_UC_LIBRARY_DEBUG"):
        verify(cache, sdk=sdk, icu=icu)


def test_cli_reports_missing_cache_without_traceback(tmp_path):
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "tools/verify_macos_cmake_cache.py"),
            str(tmp_path / "missing"),
            "--sdk",
            str(tmp_path),
            "--icu",
            str(tmp_path),
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 1
    assert "Unqualified macOS CMake configuration" in result.stderr
    assert "Traceback" not in result.stderr


def test_cli_accepts_qualified_cache_and_rejects_bad_cache(configured):
    cache, sdk, icu = configured
    command = [
        sys.executable,
        str(ROOT / "tools/verify_macos_cmake_cache.py"),
        str(cache),
        "--sdk",
        str(sdk),
        "--icu",
        str(icu),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    rewrite(cache, "gRPC_DIR", str(sdk / "missing"))
    result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    assert result.returncode == 1
    assert "gRPC_DIR must resolve inside" in result.stderr
    assert "Traceback" not in result.stderr


def test_main_parses_paths_and_reports_validation_errors(
    configured, monkeypatch, capsys
):
    from tools import verify_macos_cmake_cache as verifier

    cache, sdk, icu = configured
    cache.write_text(cache.read_text() + "\nnot-a-cache-entry=ignored\n")
    monkeypatch.setattr(
        sys,
        "argv",
        ["verify_macos_cmake_cache", str(cache), "--sdk", str(sdk), "--icu", str(icu)],
    )
    verifier.main()
    rewrite(cache, "CMAKE_GENERATOR", "Unix Makefiles")
    with pytest.raises(SystemExit) as error:
        verifier.main()
    assert error.value.code == 1
    assert "CMAKE_GENERATOR must be 'Ninja'" in capsys.readouterr().err
