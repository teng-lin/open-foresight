"""A Flutter launcher must identify its VM before worker receipt verification."""

from pathlib import Path
import subprocess
import sys
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import integration_gates as gates  # noqa: E402


def test_missing_command_does_not_launch_probe(tmp_path, monkeypatch):
    launch = Mock()
    monkeypatch.setattr(gates.subprocess, "run", launch)
    with pytest.raises(RuntimeError, match="Dart is required"):
        gates._worker_sdk("dart", {"PATH": str(tmp_path)})
    launch.assert_not_called()


def test_failed_probe_preserves_complete_stdout_and_stderr(monkeypatch, capsys):
    monkeypatch.setattr(gates.shutil, "which", lambda *args, **kwargs: "/fixture/dart")
    launch = Mock(
        return_value=subprocess.CompletedProcess(
            [], 7, "fixture stdout\n", "fixture stderr\n"
        )
    )
    monkeypatch.setattr(gates.subprocess, "run", launch)
    with pytest.raises(RuntimeError, match="SDK probe failed"):
        gates._worker_sdk("dart", {})
    assert capsys.readouterr().err == "fixture stdout\nfixture stderr\n"
    assert launch.call_args.kwargs["timeout"] == 30
    assert launch.call_args.kwargs["check"] is False


@pytest.mark.parametrize(
    "output", ["relative/path", "", "/nonexistent/worker-sdk/bin/dart"]
)
def test_invalid_vm_path_is_refused(monkeypatch, output):
    monkeypatch.setattr(gates.shutil, "which", lambda *args, **kwargs: "/fixture/dart")
    monkeypatch.setattr(
        gates.subprocess,
        "run",
        Mock(return_value=subprocess.CompletedProcess([], 0, output, "")),
    )
    with pytest.raises(RuntimeError, match="Invalid integration worker SDK probe"):
        gates._worker_sdk("dart", {})


@pytest.mark.parametrize("binary", [True, False])
def test_timed_out_probe_keeps_output_and_original_failure(monkeypatch, capsys, binary):
    monkeypatch.setattr(gates.shutil, "which", lambda *args, **kwargs: "/fixture/dart")
    stdout = b"fixture stdout\n" if binary else "fixture stdout\n"
    stderr = b"fixture stderr\n" if binary else "fixture stderr\n"
    failure = subprocess.TimeoutExpired(["fixture"], 30, output=stdout, stderr=stderr)
    monkeypatch.setattr(gates.subprocess, "run", Mock(side_effect=failure))
    with pytest.raises(subprocess.TimeoutExpired) as caught:
        gates._worker_sdk("dart", {})
    assert caught.value is failure
    assert capsys.readouterr().err == "fixture stdout\nfixture stderr\n"
