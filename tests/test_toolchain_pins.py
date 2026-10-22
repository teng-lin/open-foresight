import json
import subprocess
from types import SimpleNamespace
import sys

import pytest

from tools import verify_toolchain_pins as pins


def tools(monkeypatch, *, dart=None, flutter=None, protoc=None):
    replies = {
        "dart": dart
        if dart is not None
        else f"Dart SDK version: {pins.PINS['dart']} (stable)",
        "flutter": json.dumps(
            flutter
            if flutter is not None
            else {
                "frameworkVersion": pins.PINS["flutter"]["version"],
                "frameworkRevision": pins.PINS["flutter"]["commit"],
                "dartSdkVersion": pins.PINS["dart"],
            }
        ),
        "protoc": protoc if protoc is not None else f"libprotoc {pins.PINS['protoc']}",
    }
    seen = []

    def run(command, **kwargs):
        assert kwargs == {
            "check": True,
            "capture_output": True,
            "text": True,
            "timeout": 30,
        }
        seen.append(command)
        return SimpleNamespace(stdout=replies[command[0]], stderr="")

    monkeypatch.setattr(pins.subprocess, "run", run)
    return seen


@pytest.mark.parametrize("stage", ["core", "desktop", "protoc"])
def test_actual_stage_tool_versions_match_reviewed_pins(monkeypatch, stage):
    seen = tools(monkeypatch)
    monkeypatch.setattr(sys, "argv", ["verify_toolchain_pins.py", stage])
    pins.main()
    assert (
        seen
        == (
            {
                "core": [["dart", "--version"]],
                "desktop": [
                    ["dart", "--version"],
                    ["flutter", "--version", "--machine"],
                ],
                "protoc": [["protoc", "--version"]],
            }[stage]
        )
    )


@pytest.mark.parametrize("value", ["Dart SDK version: 0.0.1", "not a Dart SDK"])
def test_dart_mismatch_refuses_without_compiling(monkeypatch, value):
    seen = tools(monkeypatch, dart=value)
    with pytest.raises(ValueError, match="Use the qualified toolchain"):
        pins.verify("desktop")
    assert seen == [["dart", "--version"]]


@pytest.mark.parametrize(
    "key", ["frameworkVersion", "frameworkRevision", "dartSdkVersion"]
)
def test_flutter_version_revision_and_embedded_dart_are_all_checked(monkeypatch, key):
    value = {
        "frameworkVersion": pins.PINS["flutter"]["version"],
        "frameworkRevision": pins.PINS["flutter"]["commit"],
        "dartSdkVersion": pins.PINS["dart"],
    }
    value[key] = "wrong"
    tools(monkeypatch, flutter=value)
    with pytest.raises(ValueError, match="tools/pins.json requires"):
        pins.verify("desktop")


def test_protoc_mismatch_and_subprocess_failures_do_not_authorize_rebuild(monkeypatch):
    tools(monkeypatch, protoc="libprotoc wrong")
    with pytest.raises(ValueError, match="protoc is"):
        pins.verify("protoc")

    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(9, args[0], stderr="tool failed")

    monkeypatch.setattr(pins.subprocess, "run", fail)
    with pytest.raises(subprocess.CalledProcessError):
        pins.verify("core")


def test_machine_json_ignores_stderr_diagnostics_and_accepts_dart_stderr(monkeypatch):
    def run(command, **kwargs):
        if command[0] == "dart":
            return SimpleNamespace(
                stdout="", stderr=f"Dart SDK version: {pins.PINS['dart']}"
            )
        return SimpleNamespace(
            stdout=json.dumps(
                {
                    "frameworkVersion": pins.PINS["flutter"]["version"],
                    "frameworkRevision": pins.PINS["flutter"]["commit"],
                    "dartSdkVersion": pins.PINS["dart"],
                }
            ),
            stderr="SDK initialization diagnostic\n",
        )

    monkeypatch.setattr(pins.subprocess, "run", run)
    pins.verify("desktop")
