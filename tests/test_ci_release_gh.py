"""Release verifier bootstrapping authenticates bytes before executing or exporting."""

import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
from unittest.mock import Mock
from urllib.error import URLError

import pytest
import yaml

from tools import ci_release_gh as gh


@pytest.fixture
def archive(monkeypatch):
    def make(kind="regular"):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as bundle:
            member = tarfile.TarInfo(gh.MEMBER if kind != "missing" else "other/gh")
            payload = b"verified fake executable"
            member.size = len(payload)
            if kind == "symlink":
                member.type = tarfile.SYMTYPE
                member.linkname = "/outside"
                member.size = 0
            bundle.addfile(member, io.BytesIO(payload))
            if kind == "duplicate":
                bundle.addfile(member, io.BytesIO(payload))
        data = output.getvalue()
        monkeypatch.setattr(gh, "SIZE", len(data))
        monkeypatch.setattr(gh, "SHA256", hashlib.sha256(data).hexdigest())
        return data
    return make


@pytest.fixture
def job(tmp_path, monkeypatch):
    path = tmp_path / "github-path"
    path.write_text("existing\n")
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
    monkeypatch.setenv("GITHUB_PATH", str(path))
    execute = Mock()
    monkeypatch.setattr(gh.subprocess, "run", execute)
    return tmp_path, path, execute


def test_verified_download_is_executed_before_path_export(archive, job, monkeypatch):
    directory, path, execute = job
    request = Mock(return_value=io.BytesIO(archive()))
    monkeypatch.setattr(gh, "urlopen", request)
    binary = directory / "release-evidence-gh/bin/gh"
    def check(command, **kwargs):
        assert command == [str(binary), "--version"]
        assert kwargs == {"check": True, "timeout": 30}
        assert binary.read_bytes() == b"verified fake executable"
        assert binary.stat().st_mode & 0o777 == 0o755
        assert path.read_text() == "existing\n"
    execute.side_effect = check
    gh.main()
    request.assert_called_once_with(gh.URL, timeout=60)
    assert path.read_text() == "existing\n" + str(binary.parent) + "\n"


@pytest.mark.parametrize("damage", ["checksum", "truncated", "oversized"])
def test_bad_bytes_never_execute_or_export(archive, job, monkeypatch, damage):
    directory, path, execute = job
    data = archive()
    if damage == "checksum":
        data = bytes([data[0] ^ 1]) + data[1:]
    elif damage == "truncated":
        data = data[:-1]
    else:
        data += b"x"
    monkeypatch.setattr(gh, "urlopen", Mock(return_value=io.BytesIO(data)))
    with pytest.raises(ValueError, match="size/checksum"):
        gh.main()
    execute.assert_not_called()
    assert path.read_text() == "existing\n"
    assert not (directory / "release-evidence-gh").exists()


@pytest.mark.parametrize("kind", ["symlink", "duplicate", "missing"])
def test_even_verified_archive_requires_one_regular_member(archive, job, monkeypatch, kind):
    _, path, execute = job
    monkeypatch.setattr(gh, "urlopen", Mock(return_value=io.BytesIO(archive(kind))))
    with pytest.raises(ValueError, match="regular executable"):
        gh.main()
    execute.assert_not_called()
    assert path.read_text() == "existing\n"


@pytest.mark.parametrize("error", [URLError("offline"), TimeoutError("read timed out")])
def test_network_failure_is_bounded_and_fail_closed(job, monkeypatch, error):
    _, path, execute = job
    request = Mock(side_effect=error)
    pause = Mock()
    monkeypatch.setattr(gh, "urlopen", request)
    monkeypatch.setattr(gh.time, "sleep", pause)
    with pytest.raises(type(error)):
        gh.main()
    assert request.call_count == 3
    assert pause.call_args_list == [((1,),), ((2,),)]
    execute.assert_not_called()
    assert path.read_text() == "existing\n"


def test_transient_download_failure_recovers_before_verification(archive, job, monkeypatch):
    request = Mock(side_effect=[URLError("transient"), io.BytesIO(archive())])
    monkeypatch.setattr(gh, "urlopen", request)
    monkeypatch.setattr(gh.time, "sleep", Mock())
    gh.main()
    assert request.call_count == 2
    job[2].assert_called_once()


@pytest.mark.parametrize("error", [subprocess.CalledProcessError(1, "gh"), subprocess.TimeoutExpired("gh", 30)])
def test_failed_executable_is_not_exported(archive, job, monkeypatch, error):
    _, path, execute = job
    monkeypatch.setattr(gh, "urlopen", Mock(return_value=io.BytesIO(archive())))
    execute.side_effect = error
    with pytest.raises(type(error)):
        gh.main()
    assert path.read_text() == "existing\n"


def test_only_release_evidence_and_publish_install_pinned_cli_before_consumers():
    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/release.yml").read_text())
    installers = {}
    for name, job in workflow["jobs"].items():
        steps = job.get("steps", [])
        matching = [i for i, step in enumerate(steps) if "tools/ci_release_gh.py" in step.get("run", "")]
        if matching:
            assert job["runs-on"] == "ubuntu-24.04"
            assert len(matching) == 1
            consumers = [i for i, step in enumerate(steps) if "tools.ci_release_evidence" in step.get("run", "")]
            assert consumers and matching[0] < min(consumers)
            installers[name] = matching[0]
    assert set(installers) == {"evidence", "publish"}
