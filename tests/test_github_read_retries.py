"""Transient GitHub transport failures preserve verified artifact reuse."""

import hashlib
import json
import subprocess
from unittest.mock import Mock

import pytest

from tools import ci_artifacts as artifacts


@pytest.fixture(autouse=True)
def sleep(monkeypatch):
    pause = Mock()
    monkeypatch.setattr(artifacts.time, "sleep", pause)
    return pause


@pytest.mark.parametrize(
    "failure",
    [
        subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 503\n"),
        subprocess.CalledProcessError(
            1, "gh", stderr="unexpected end of JSON input\n"
        ),
        subprocess.TimeoutExpired("gh", 300),
        b'{"truncated":',
    ],
)
def test_api_retries_transient_reads_and_returns_only_complete_json(
    monkeypatch, sleep, failure
):
    output = Mock(side_effect=[failure, b'{"id": 42}'])
    monkeypatch.setattr(artifacts.subprocess, "check_output", output)
    monkeypatch.setenv("GH_DEBUG", "api")
    assert artifacts.api("owner/repo", "actions/artifacts/42") == {"id": 42}
    assert output.call_count == 2
    assert "GH_DEBUG" not in output.call_args.kwargs["env"]
    assert output.call_args.kwargs["stderr"] == subprocess.PIPE
    sleep.assert_called_once_with(2)


@pytest.mark.parametrize("status", [401, 403, 404])
def test_permanent_http_errors_propagate_without_retry(monkeypatch, sleep, status):
    failure = subprocess.CalledProcessError(
        1, "gh", output=json.dumps({"status": status}), stderr=f"gh: HTTP {status}"
    )
    output = Mock(side_effect=failure)
    monkeypatch.setattr(artifacts.subprocess, "check_output", output)
    if status == 404:
        assert artifacts.optional_api("owner/repo", "actions/artifacts/42") is None
    else:
        with pytest.raises(subprocess.CalledProcessError) as caught:
            artifacts.api("owner/repo", "actions/artifacts/42")
        assert caught.value is failure
    assert output.call_count == 1
    sleep.assert_not_called()


@pytest.mark.parametrize(
    "failure",
    [
        subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 502\n"),
        json.JSONDecodeError("truncated", "{", 1),
    ],
)
def test_exhausted_reads_fail_closed_with_original_error(
    monkeypatch, sleep, failure, capsys
):
    output = Mock(side_effect=failure)
    monkeypatch.setattr(artifacts.subprocess, "check_output", output)
    with pytest.raises(type(failure)) as caught:
        artifacts.api("owner/repo", "actions/artifacts/42")
    assert caught.value is failure
    assert output.call_count == 3
    assert [call.args[0] for call in sleep.call_args_list] == [2, 4]
    diagnostic = capsys.readouterr().err
    assert "retrying in 4s (3/3)" in diagnostic
    if isinstance(failure, subprocess.CalledProcessError):
        assert diagnostic.count("HTTP 502") == 3


@pytest.mark.parametrize("tamper", [False, True])
def test_download_retry_truncates_partial_bytes_and_still_checks_digest(
    tmp_path, monkeypatch, sleep, tamper
):
    payload = b"complete verified ZIP bytes"
    artifact = {"id": 42, "digest": "sha256:" + hashlib.sha256(payload).hexdigest()}
    calls = []

    def download(command, *, stdout, stderr, check, timeout):
        assert check and timeout == 300 and stderr == subprocess.PIPE
        calls.append(command)
        if len(calls) == 1:
            stdout.write(b"partial transfer longer than the final payload" * 4)
            raise subprocess.CalledProcessError(1, command, stderr=b"gh: HTTP 503\n")
        stdout.write(b"tampered" if tamper else payload)

    monkeypatch.setattr(artifacts.subprocess, "run", download)
    destination = tmp_path / "artifact.zip"
    if tamper:
        with pytest.raises(ValueError, match="ZIP digest mismatch"):
            artifacts.download_zip("owner/repo", artifact, destination)
    else:
        artifacts.download_zip("owner/repo", artifact, destination)
        assert destination.read_bytes() == payload
    assert calls == [["gh", "api", "repos/owner/repo/actions/artifacts/42/zip"]] * 2
    sleep.assert_called_once_with(2)


def test_download_exhaustion_never_claims_a_cache_miss(tmp_path, monkeypatch, sleep):
    failure = subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 503\n")
    download = Mock(side_effect=failure)
    monkeypatch.setattr(artifacts.subprocess, "run", download)
    with pytest.raises(subprocess.CalledProcessError) as caught:
        artifacts.download_zip("owner/repo", {"id": 42}, tmp_path / "artifact.zip")
    assert caught.value is failure
    assert download.call_count == 3
