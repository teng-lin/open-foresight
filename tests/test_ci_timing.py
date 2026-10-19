"""Observability must preserve reuse decisions and the original failure."""

import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

import pytest

from tools import ci_stage_cache as cache
from tools import ci_timing


@pytest.mark.parametrize("fails", [False, True])
def test_phase_reports_elapsed_time_and_preserves_exception(capsys, fails):
    failure = RuntimeError("original failure")
    with patch.object(ci_timing.time, "monotonic", side_effect=[10, 12.125]):
        try:
            with ci_timing.phase("fixture"):
                if fails:
                    raise failure
        except RuntimeError as error:
            assert error is failure
    captured = capsys.readouterr()
    assert captured.out == ""
    record = json.loads(captured.err.removeprefix("CI phase: "))
    assert record == {
        "phase": "fixture",
        "seconds": 2.125,
        "status": "error" if fails else "ok",
    }


def test_timed_api_failure_cannot_become_a_cache_miss(capsys):
    failure = RuntimeError("transport unavailable")
    with patch.object(cache.artifacts, "api", side_effect=failure):
        with pytest.raises(RuntimeError) as raised:
            cache.lookup_api("owner/repo", "actions/artifacts")
    assert raised.value is failure
    assert '"status": "error"' in capsys.readouterr().err


def test_timed_transfer_preserves_checksum_failure(tmp_path, capsys):
    with patch.object(
        cache.artifacts, "download_zip", side_effect=ValueError("ZIP digest mismatch")
    ):
        with pytest.raises(ValueError, match="ZIP digest mismatch"):
            cache.lookup_download("owner/repo", {"id": 1}, tmp_path / "artifact.zip")
    assert '"status": "error"' in capsys.readouterr().err


def test_probe_stdout_remains_one_json_document_with_timing_on_stderr(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, timeout=30)
    script = Path(__file__).resolve().parents[1] / "tools/ci_stage_cache.py"
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "probe",
            "--platform",
            "linux",
            "--stage",
            "native",
            "--root",
            str(tmp_path),
            "--environment-json",
            json.dumps(
                {
                    "compiler": "fixture",
                    "runtime": "fixture",
                    "system": "fixture",
                    "sdk": "a" * 64,
                }
            ),
            "--event",
            "push",
            "--branch",
            "main",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["hit"] is False
    assert "CI phase:" in result.stderr
