"""Oracle orchestration uses synthetic owned images, never an installed original."""

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from unittest.mock import Mock

import pytest
import test_original_query_prepare as preparation_fixture

oracle = preparation_fixture.module


@pytest.mark.parametrize("result", ["passed", "malformed", "wrong", "exit"])
def test_isolation_retains_canary_evidence_and_removes_outside_file(
    tmp_path, monkeypatch, result
):
    harness = tmp_path / "original-query-harness"
    harness.write_bytes(b"synthetic harness")
    canaries = []

    def run(command, **kwargs):
        assert command[0] == "/usr/bin/sandbox-exec"
        assert set(kwargs["env"]) == {"TMPDIR", "CFFIXED_USER_HOME", "PATH", "LANG"}
        canary = Path(command[-1])
        assert canary.exists() and canary.parent == tmp_path.parent
        canaries.append(canary)
        kwargs["stdout"].write(
            "broken {"
            if result == "malformed"
            else json.dumps(
                {
                    "isolation": True,
                    "metal": result != "wrong",
                    "original_loaded": False,
                }
            )
        )
        kwargs["stderr"].write("retained diagnostics")
        return subprocess.CompletedProcess(command, 1 if result == "exit" else 0)

    monkeypatch.setattr(oracle.subprocess, "run", run)
    if result == "passed":
        assert oracle.isolation(tmp_path)["passed"] is True
    else:
        with pytest.raises(RuntimeError, match="remains blocked"):
            oracle.isolation(tmp_path)
    report = json.loads((tmp_path / "isolation-report.json").read_text())
    assert report["original_loaded"] is False
    assert report["stderr"] == "retained diagnostics"
    assert report["passed"] == (result == "passed")
    assert report["harness_sha256"] == hashlib.sha256(harness.read_bytes()).hexdigest()
    assert all(not canary.exists() for canary in canaries)


def test_isolation_requires_owned_regular_harness_before_launch(tmp_path):
    with pytest.raises(ValueError, match="Build harness"):
        oracle.isolation(tmp_path)
    (tmp_path / "original-query-harness").symlink_to(oracle.__file__)
    with pytest.raises(ValueError, match="Build harness"):
        oracle.isolation(tmp_path)


@pytest.mark.parametrize("problem", [None, "app", "model", "existing"])
def test_prepare_copies_only_synthetic_image_after_isolation(
    tmp_path, monkeypatch, problem
):
    root, app, model = (
        tmp_path / "private",
        tmp_path / "Synthetic.app",
        tmp_path / "model",
    )
    root.mkdir(mode=0o700)
    (root / "original-query-harness").write_bytes(b"harness")
    source = app / "Contents/MacOS/Foresight"
    source.parent.mkdir(parents=True)
    source.write_bytes(preparation_fixture.PreparationTest().fixture())
    framework = app / "Contents/Frameworks/FlutterMacOS.framework"
    framework.mkdir(parents=True)
    (framework / "fixture").write_bytes(b"synthetic framework")
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "wrong"
                if problem == "app"
                else "com.google.AIEdgeForesight"
            }
        )
    )
    # Sparse synthetic input has the format's fixed size and a real checksum.
    with model.open("wb") as stream:
        stream.truncate(179437568 if problem != "model" else 1)
    monkeypatch.setattr(oracle, "APP", app)
    monkeypatch.setattr(oracle, "APP_SHA", oracle.sha(source))
    monkeypatch.setattr(oracle, "MODEL_SHA", oracle.sha(model))
    isolated = Mock(return_value={"passed": True})
    monkeypatch.setattr(oracle, "isolation", isolated)
    commands = Mock()
    monkeypatch.setattr(oracle.subprocess, "run", commands)
    if problem == "existing":
        (root / "receipt.json").write_text("preserve me")
    if problem:
        with pytest.raises(ValueError):
            oracle.prepare(root, model)
        commands.assert_not_called()
    else:
        receipt = oracle.prepare(root, model)
        assert receipt["original_loaded"] is False
        assert receipt["model_sha256"] == oracle.sha(root / "detector.tflite")
        assert (root / "detector.tflite").stat().st_mode & 0o777 == 0o600
        assert source.read_bytes() == preparation_fixture.PreparationTest().fixture()
        assert (
            root / "image/MacOS/Foresight.bundle"
        ).read_bytes() != source.read_bytes()
        assert commands.call_count == 2
    isolated.assert_called_once_with(root)


@pytest.mark.parametrize("problem", [None, "identity", "harness", "exit"])
def test_oracle_run_rechecks_receipt_isolation_and_retains_failure_report(
    tmp_path, monkeypatch, problem
):
    harness = tmp_path / "original-query-harness"
    harness.write_bytes(b"synthetic harness")
    receipt = {
        "original_sha256": oracle.APP_SHA,
        "model_sha256": oracle.MODEL_SHA,
        "owned_image_sha256": "fixture",
        "harness_sha256": oracle.sha(harness),
        "profile_sha256": oracle.sha(oracle.HERE / "isolation.sb"),
    }
    if problem == "identity":
        receipt["model_sha256"] = "wrong"
    elif problem == "harness":
        receipt["harness_sha256"] = "wrong"
    (tmp_path / "receipt.json").write_text(json.dumps(receipt))
    monkeypatch.setattr(oracle, "isolation", Mock())
    canaries = []

    def run(command, **kwargs):
        assert command[-1] == str(tmp_path / "prompt.txt")
        canaries.append(Path(command[-5]))
        kwargs["stdout"].write("synthetic answer")
        kwargs["stderr"].write("diagnostics")
        return subprocess.CompletedProcess(command, 1 if problem == "exit" else 0)

    monkeypatch.setattr(oracle.subprocess, "run", run)
    if problem:
        with pytest.raises((ValueError, RuntimeError)):
            oracle.run(tmp_path, "controlled fixture prompt")
    else:
        oracle.run(tmp_path, "controlled fixture prompt")
    assert all(not canary.exists() for canary in canaries)
    if problem in (None, "exit"):
        report = json.loads((tmp_path / "run-report.json").read_text())
        assert report["exit"] == (1 if problem else 0)
        assert (
            report["answer_sha256"] == hashlib.sha256(b"synthetic answer").hexdigest()
        )
        assert (tmp_path / "prompt.txt").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("command", ["build", "check-isolation", "prepare", "run"])
def test_oracle_cli_dispatches_only_explicit_command(tmp_path, monkeypatch, command):
    monkeypatch.setattr(oracle.os, "umask", Mock())
    monkeypatch.setattr(oracle, "private_root", lambda path: tmp_path)
    calls = {}
    for name in ("build", "isolation", "prepare", "run"):
        calls[name] = Mock()
        monkeypatch.setattr(oracle, name, calls[name])
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "oracle",
            command,
            "--root",
            str(tmp_path),
            "--model",
            str(tmp_path / "model"),
            "--prompt",
            "fixture",
        ],
    )
    oracle.main()
    expected = "isolation" if command == "check-isolation" else command
    assert [name for name, call in calls.items() if call.called] == [expected]
    monkeypatch.setattr(sys, "argv", ["oracle", "prepare", "--root", str(tmp_path)])
    with pytest.raises(SystemExit, match="2"):
        oracle.main()
