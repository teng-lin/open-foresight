"""Real SQLite profile-copy preflight, including WAL and crash-journal states."""

import base64
import gzip
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import pytest
from tools import sqlite_preflight as preflight

MEMBERS = (
    "application.db",
    "helper/agent_metadata.db",
    "helper/linux_state.db",
    "helper/rag_vector.db",
)


@pytest.fixture
def profile(tmp_path):
    root = tmp_path / "profile"
    (root / "helper").mkdir(parents=True)
    for name in MEMBERS:
        with sqlite3.connect(root / name) as db:
            db.execute("CREATE TABLE payload(body TEXT)")
    return root


def snapshot(root):
    return {
        str(path.relative_to(root)): (
            preflight.identity(path),
            hashlib.sha256(path.read_bytes()).hexdigest(),
        )
        for path in root.rglob("*")
        if path.is_file()
    }


@pytest.mark.parametrize("member", MEMBERS)
def test_future_member_refusal_preserves_complete_original_set(profile, member):
    with sqlite3.connect(profile / member) as db:
        db.execute(
            "PRAGMA user_version=" + ("18" if member == "application.db" else "2")
        )
    before = snapshot(profile)
    with pytest.raises(RuntimeError, match="Unsupported newer"):
        preflight.qualify_profile(profile)
    assert snapshot(profile) == before


def test_healthy_missing_members_are_not_created(profile):
    (profile / MEMBERS[-1]).unlink()
    before = snapshot(profile)
    gate = preflight.qualify_profile(profile)
    preflight.verify_profile_unchanged(profile, gate)
    assert snapshot(profile) == before


def wal(path, version):
    subprocess.run(
        [
            sys.executable,
            "-c",
            """
import os,sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA wal_autocheckpoint=0')
db.execute('PRAGMA user_version='+sys.argv[2])
db.commit()
os._exit(0)
""",
            str(path),
            str(version),
        ],
        check=True,
        timeout=10,
    )


@pytest.mark.parametrize("member", MEMBERS)
@pytest.mark.parametrize("shm", [True, False])
def test_wal_only_future_does_not_change_live_shm(
    profile, tmp_path, monkeypatch, member, shm
):
    wal(profile / member, 18 if member == "application.db" else 2)
    if not shm:
        Path(str(profile / member) + "-shm").unlink()
    scratch = tmp_path / "scratch"
    scratch.mkdir(mode=0o700)
    monkeypatch.setattr(preflight.tempfile, "tempdir", str(scratch))
    before = snapshot(profile)
    with pytest.raises(RuntimeError, match="Unsupported newer"):
        preflight.qualify_profile(profile)
    assert snapshot(profile) == before
    assert list(scratch.iterdir()) == []


def test_supported_wal_recreates_shm_only_in_private_scratch(
    profile, tmp_path, monkeypatch
):
    wal(profile / "application.db", 17)
    Path(str(profile / "application.db") + "-shm").unlink()
    scratch = tmp_path / "scratch"
    scratch.mkdir(mode=0o700)
    monkeypatch.setattr(preflight.tempfile, "tempdir", str(scratch))
    before = snapshot(profile)
    preflight.qualify_profile(profile)
    assert snapshot(profile) == before
    assert list(scratch.iterdir()) == []


@pytest.mark.parametrize("boundary", ["before", "after"])
def test_genuine_attached_commit_journal_future_page_one_is_refused(profile, boundary):
    corpus = json.loads(
        (
            Path(__file__).parents[1]
            / "packages/foresight_core/test/fixtures/sqlite-hot-future.json"
        ).read_text()
    )
    for name, metadata in corpus["fixtures"][boundary].items():
        content = gzip.decompress(base64.b64decode(metadata["gzip_base64"]))
        assert hashlib.sha256(content).hexdigest() == metadata["sha256"]
        (profile / "helper" / name).write_bytes(content)
    assert (profile / "helper/agent_metadata.db").read_bytes()[60:64] == bytes(4)
    before = snapshot(profile)
    with pytest.raises(RuntimeError, match="Unsupported newer"):
        preflight.qualify_profile(profile)
    assert snapshot(profile) == before


def test_final_gate_rejects_external_writer(profile):
    gate = preflight.qualify_profile(profile)
    with sqlite3.connect(profile / "helper/linux_state.db") as db:
        db.execute("PRAGMA user_version=2")
    with pytest.raises(RuntimeError, match="changed during"):
        preflight.verify_profile_unchanged(profile, gate)
