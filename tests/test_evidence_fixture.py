"""Evidence provisioning verifies tiny controlled bytes without network or Git."""

import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import urllib.request

import pytest

from tools import ci_acceptance_plan as acceptance
from tools import evidence_fixture as fixture

ORIGINAL_RUN = subprocess.run
ORIGINAL_POPEN = subprocess.Popen
ROOT = Path(__file__).resolve().parents[1]
TINY = b"tiny controlled evidence bytes\n"


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    def refuse(*args, **kwargs):
        raise OSError("network and subprocesses are disabled in provider tests")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)
    monkeypatch.setattr(subprocess, "run", refuse)
    monkeypatch.setattr(subprocess, "Popen", refuse)
    monkeypatch.setattr(subprocess, "check_output", refuse)
    monkeypatch.delenv(fixture.CACHE_ENV, raising=False)


class Response(io.BytesIO):
    def __init__(self, raw, status=200):
        super().__init__(raw)
        self.status = status


def export(tmp_path, archive=None, payload=TINY):
    """A Git-free export containing only a checksum-pinned baseline."""
    root = tmp_path / "export"
    path = root / acceptance.FAILURE_BASELINE
    path.parent.mkdir(parents=True)
    value = {
        "schema": 1,
        "repository": "teng-lin/open-foresight",
        "since": "2026-10-12T00:00:00Z",
        "complete": True,
        "failures": [{"id": "tiny"}],
        "evidence_archive": archive
        or {
            "path": "tiny.evidence.tar.gz",
            "sha256": hashlib.sha256(payload).hexdigest(),
        },
    }
    path.write_text(json.dumps(value))
    path.with_suffix(".sha256").write_text(
        hashlib.sha256(path.read_bytes()).hexdigest() + "  baseline\n"
    )
    return root


def source(tmp_path, raw=TINY):
    path = tmp_path / "downloaded.tar.gz"
    path.write_bytes(raw)
    return path


def test_real_pin_reuses_baseline_digest_and_immutable_commit_url():
    pinned = fixture.pin()
    baseline, _ = acceptance.failure_baseline()
    assert pinned["sha256"] == baseline["evidence_archive"]["sha256"]
    assert pinned["sha256"] == (
        "39e70f101711a070518c821343b951d53e89b10af7553fdbf4b9efe66a85c650"
    )
    assert pinned["url"] == (
        "https://raw.githubusercontent.com/teng-lin/open-foresight/"
        "053673dd9cf05d0df174cfbf9a1a01bfdef1eab3/tests/fixtures/"
        "ci-acceptance-failures-20261020.evidence.tar.gz"
    )
    committed = ROOT / "tests/fixtures" / pinned["name"]
    assert fixture.asset_path(pinned, committed.parent) != committed


@pytest.mark.parametrize(
    "archive",
    [
        {"path": "../escape.tar.gz", "sha256": "a" * 64},
        {"path": "nested/x.tar.gz", "sha256": "a" * 64},
        {"path": "x.tar.gz", "sha256": "short"},
        {"path": "x.zip", "sha256": "a" * 64},
    ],
)
def test_baseline_without_safe_pin_is_rejected(tmp_path, archive):
    with pytest.raises(fixture.EvidenceError, match="pinned evidence archive"):
        fixture.pin(export(tmp_path, archive))


def test_missing_asset_fails_with_actionable_command(tmp_path):
    root = export(tmp_path)
    with pytest.raises(fixture.EvidenceError) as error:
        fixture.verified_bytes(root, tmp_path / "cache")
    message = str(error.value)
    assert "python -m tools.evidence_fixture --fetch" in message
    assert "--archive PATH" in message and fixture.CACHE_ENV in message
    assert fixture.pin(root)["url"] in message
    (tmp_path / "cache").mkdir(mode=0o700)
    with pytest.raises(fixture.EvidenceError, match="not provisioned"):
        fixture.resolve(root, tmp_path / "cache")


def test_local_archive_is_published_atomically_read_only_and_verified(tmp_path):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    target = fixture.provision_archive(source(tmp_path), root, cache)
    assert target == fixture.asset_path(fixture.pin(root), cache)
    assert fixture.resolve(root, cache) == target
    assert fixture.verified_bytes(root, cache) == TINY
    assert stat.S_IMODE(target.stat().st_mode) & 0o222 == 0
    assert stat.S_IMODE(cache.stat().st_mode) & 0o077 == 0
    assert sorted(path.name for path in cache.iterdir()) == [target.name]


def test_tampered_source_publishes_nothing(tmp_path):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    with pytest.raises(fixture.EvidenceError, match="nothing was published"):
        fixture.provision_archive(source(tmp_path, TINY + b"x"), root, cache)
    assert list(cache.iterdir()) == []


def test_tampered_cached_asset_is_rejected_then_replaced(tmp_path):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    target = fixture.provision_archive(source(tmp_path), root, cache)
    target.chmod(0o644)
    target.write_bytes(TINY[:-1] + b"!")
    with pytest.raises(fixture.EvidenceError, match="SHA-256") as error:
        fixture.verified_bytes(root, cache)
    assert "tools.evidence_fixture --fetch" in str(error.value)
    fixture.provision_archive(source(tmp_path), root, cache)
    assert fixture.verified_bytes(root, cache) == TINY


def test_oversized_cached_asset_is_rejected(tmp_path, monkeypatch):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    fixture.provision_archive(source(tmp_path), root, cache)
    monkeypatch.setattr(fixture, "MAX_BYTES", 4)
    with pytest.raises(fixture.EvidenceError, match="SHA-256"):
        fixture.verified_bytes(root, cache)


def test_symlinked_assets_sources_and_caches_are_rejected(tmp_path):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    cache.mkdir(mode=0o700)
    real = source(tmp_path)
    target = fixture.asset_path(fixture.pin(root), cache)
    os.symlink(real, target)
    with pytest.raises(fixture.EvidenceError, match="regular file"):
        fixture.verified_bytes(root, cache)
    link = tmp_path / "link.tar.gz"
    os.symlink(real, link)
    with pytest.raises(fixture.EvidenceError, match="regular file"):
        fixture.provision_archive(link, root, tmp_path / "other")
    linked_cache = tmp_path / "linked-cache"
    os.symlink(cache, linked_cache)
    with pytest.raises(fixture.EvidenceError, match="symlink"):
        fixture.verified_bytes(root, linked_cache)
    with pytest.raises(fixture.EvidenceError, match="symlink"):
        fixture.provision_archive(real, root, linked_cache)


def test_shared_writable_cache_is_rejected(tmp_path):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    cache.mkdir()
    cache.chmod(0o770)
    with pytest.raises(fixture.EvidenceError, match="writable"):
        fixture.provision_archive(source(tmp_path), root, cache)


def test_fetch_uses_only_pinned_url_and_replaces_unsafe_asset(tmp_path):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    cache.mkdir(mode=0o700)
    os.symlink(source(tmp_path), fixture.asset_path(fixture.pin(root), cache))
    requested = []

    def opener(url, timeout):
        requested.append((url, timeout))
        return Response(TINY)

    target = fixture.provision_fetch(root, cache, opener)
    assert requested == [(fixture.pin(root)["url"], fixture.FETCH_TIMEOUT)]
    assert not target.is_symlink() and fixture.verified_bytes(root, cache) == TINY


def test_fetch_reuses_verified_asset_without_network(tmp_path):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    fixture.provision_archive(source(tmp_path), root, cache)

    def opener(url, timeout):
        raise AssertionError("verified asset must not be fetched again")

    assert fixture.provision_fetch(root, cache, opener) == fixture.resolve(root, cache)


@pytest.mark.parametrize(
    "response,match",
    [
        (Response(TINY[:5]), "nothing was published"),
        (Response(TINY + b"tail"), "nothing was published"),
        (Response(TINY, status=404), "HTTP 404"),
    ],
)
def test_partial_tampered_or_failed_download_publishes_nothing(
    tmp_path, response, match
):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    with pytest.raises(fixture.EvidenceError, match=match):
        fixture.provision_fetch(root, cache, lambda url, timeout: response)
    assert not cache.exists() or list(cache.iterdir()) == []


def test_interrupted_and_oversized_downloads_leave_no_partial(tmp_path, monkeypatch):
    root = export(tmp_path)
    cache = tmp_path / "cache"

    class Interrupted(Response):
        def read(self, size=-1):
            if self.tell():
                raise ConnectionResetError("reset mid-transfer")
            return super().read(3)

    with pytest.raises(ConnectionResetError):
        fixture.provision_fetch(root, cache, lambda url, timeout: Interrupted(TINY))
    assert list(cache.iterdir()) == []
    monkeypatch.setattr(fixture, "MAX_BYTES", 4)
    with pytest.raises(fixture.EvidenceError, match="exceeds"):
        fixture.provision_fetch(root, cache, lambda url, timeout: Response(TINY))
    assert list(cache.iterdir()) == []


def test_cache_location_is_explicit_env_or_private_user_cache(tmp_path, monkeypatch):
    assert fixture.cache_dir(tmp_path) == tmp_path
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg"))
    assert fixture.cache_dir() == tmp_path / "xdg/open-foresight/evidence"
    monkeypatch.setenv(fixture.CACHE_ENV, str(tmp_path / "env"))
    assert fixture.cache_dir() == tmp_path / "env"


def test_cli_requires_an_explicit_mode_and_reports_failures(tmp_path, capsys):
    root = export(tmp_path)
    cache = tmp_path / "cache"
    with pytest.raises(SystemExit) as error:
        fixture.main(["--root", str(root)])
    assert error.value.code == 2
    with pytest.raises(SystemExit, match="tools.evidence_fixture --fetch"):
        fixture.main(["--check", "--root", str(root), "--cache-dir", str(cache)])
    # The autouse guard proves --fetch reaches only the (disabled) network.
    with pytest.raises(SystemExit, match="disabled"):
        fixture.main(["--fetch", "--root", str(root), "--cache-dir", str(cache)])
    with pytest.raises(SystemExit, match="evidence_fixture"):
        fixture.main(["--archive", str(tmp_path / "absent"), "--root", str(root)])
    capsys.readouterr()
    fixture.main(
        [
            "--archive",
            str(source(tmp_path)),
            "--root",
            str(root),
            "--cache-dir",
            str(cache),
        ]
    )
    published = capsys.readouterr().out.strip()
    fixture.main(["--check", "--root", str(root), "--cache-dir", str(cache)])
    assert capsys.readouterr().out.strip() == published
    assert Path(published).read_bytes() == TINY


def cli_export(tmp_path):
    root = export(tmp_path)
    (root / "tools").mkdir()
    (root / "tools/__init__.py").write_text("")
    for name in ("evidence_fixture.py", "ci_acceptance_plan.py"):
        (root / "tools" / name).write_bytes((ROOT / "tools" / name).read_bytes())
    (root / "sitecustomize.py").write_text(
        "import urllib.request, subprocess\n"
        "def refuse(*args, **kwargs): raise RuntimeError('network and Git disabled')\n"
        "urllib.request.urlopen = refuse\n"
        "subprocess.run = refuse\n"
        "subprocess.Popen = refuse\n"
        "subprocess.check_output = refuse\n"
    )
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    env = dict(os.environ, PATH=str(empty_bin), PYTHONPATH=str(root))
    return root, env


def test_git_free_export_cli_provisions_local_bytes_and_checks_them(
    tmp_path, monkeypatch
):
    root, env = cli_export(tmp_path)
    cache = tmp_path / "cache"
    archive = source(tmp_path)
    with monkeypatch.context() as context:
        context.setattr(subprocess, "Popen", ORIGINAL_POPEN)
        for mode in (["--archive", str(archive)], ["--check"]):
            result = ORIGINAL_RUN(
                [
                    sys.executable,
                    "-m",
                    "tools.evidence_fixture",
                    *mode,
                    "--cache-dir",
                    str(cache),
                ],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            assert Path(result.stdout.strip()).read_bytes() == TINY
    assert not (root / ".git").exists()


def test_git_free_export_cli_missing_asset_fails_without_fetch(tmp_path, monkeypatch):
    root, env = cli_export(tmp_path)
    cache = tmp_path / "missing-cache"
    with monkeypatch.context() as context:
        context.setattr(subprocess, "Popen", ORIGINAL_POPEN)
        result = ORIGINAL_RUN(
            [
                sys.executable,
                "-m",
                "tools.evidence_fixture",
                "--check",
                "--cache-dir",
                str(cache),
            ],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    assert result.returncode != 0
    assert "tools.evidence_fixture --fetch" in result.stderr
    assert "network and Git disabled" not in result.stderr
    assert not cache.exists()
