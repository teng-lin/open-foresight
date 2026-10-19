"""Capture installation paths are explicit build inputs, never runtime PATH lookups."""

from pathlib import Path
import json
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def test_capture_installation_path_must_be_absolute(tmp_path):
    configured = subprocess.run(
        [
            "cmake",
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


def test_capture_installation_path_enters_native_compile_definition(tmp_path):
    installed = tmp_path / "trusted installation" / "bin" / "pw-record"
    build = tmp_path / "build"
    subprocess.run(
        [
            "cmake",
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
