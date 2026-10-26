"""Real-process protocol and ownership controls for the explicit synthetic worker."""

import json
import os
from pathlib import Path
import stat
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = (b"Synthetic embedding fixture; NOT a model.\n" * 512)[:16384]


@pytest.fixture
def worker(tmp_path):
    executable = tmp_path / "synthetic-worker"
    executable.write_bytes(
        (ROOT / "tests/service/first_run_model_worker.py").read_bytes()
    )
    executable.chmod(0o700)
    model = tmp_path / "fixture-embedding.litertlm"
    model.write_bytes(PAYLOAD)
    assert stat.S_IMODE(executable.stat().st_mode) == 0o700
    assert executable.stat().st_uid == os.getuid()
    return executable, model


@pytest.mark.parametrize("gpu", [False, True])
def test_actual_owned_fixture_protocol_and_eof_settlement(worker, tmp_path, gpu):
    executable, model = worker
    report = tmp_path / "worker.jsonl"
    result = subprocess.run(
        [str(executable), "--embedding", str(model), *(["--gpu"] if gpu else [])],
        input='{"op":"encode","text":"é"}\n{"op":"decode","tokens":[195,169]}\n{"op":"embed","text":"synthetic"}\n{"op":"unknown"}\nnot-json\n{"op":"encode","text":5}\n{"op":"embed","text":null}\n',
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
        env={**os.environ, "FORESIGHT_FIRST_RUN_WORKER_REPORT": str(report)},
    )
    assert result.returncode == 0, result.stderr
    messages = [json.loads(line) for line in result.stdout.splitlines()]
    assert messages[0]["ready"] is True and messages[0]["synthetic"] is True
    assert messages[0]["backend"] == f"litert-lm-embedding-{'gpu' if gpu else 'cpu'}"
    assert messages[1:] == [
        {"result": [195, 169]},
        {"result": "é"},
        {"result": [1.0, 0.0, 0.0, 0.0]},
        {"error": "Invalid synthetic worker request"},
        {"error": "Invalid synthetic worker request"},
        {"error": "Invalid synthetic worker request"},
        {"error": "Invalid synthetic worker request"},
    ]
    owner = json.loads(report.read_text())
    assert owner["uid"] == os.getuid() and owner["synthetic"] is True
    assert stat.S_IMODE(report.stat().st_mode) == 0o600
    with pytest.raises(ProcessLookupError):
        os.kill(owner["pid"], 0)


def test_fixture_rejects_unknown_backend_and_nonfixture_bytes(worker):
    executable, model = worker
    for flags in (
        ["--embedding", str(model), "--unreviewed"],
        ["--generation", str(model)],
    ):
        result = subprocess.run(
            [str(executable), *flags], capture_output=True, timeout=10, check=False
        )
        assert result.returncode == 2 and not result.stdout
    model.write_bytes(b"not the declared synthetic payload")
    result = subprocess.run(
        [str(executable), "--embedding", str(model)],
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 2 and not result.stdout
