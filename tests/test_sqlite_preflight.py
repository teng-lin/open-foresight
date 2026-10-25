"""Real SQLite profile-copy preflight, including WAL and crash-journal states."""

from contextlib import closing
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
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
        with closing(sqlite3.connect(root / name)) as db, db:
            db.execute("CREATE TABLE payload(body TEXT)")
    return root


def snapshot(root):
    def metadata(path):
        value = path.stat()
        return (
            value.st_dev,
            value.st_ino,
            value.st_size,
            value.st_mode,
            value.st_uid,
            value.st_gid,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )

    return {
        str(path.relative_to(root)): (
            metadata(path),
            hashlib.sha256(path.read_bytes()).hexdigest(),
        )
        for path in root.rglob("*")
        if path.is_file()
    }


@pytest.mark.parametrize("member", MEMBERS)
def test_future_member_refusal_preserves_complete_original_set(profile, member):
    with closing(sqlite3.connect(profile / member)) as db, db:
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


def test_empty_rollback_journals_preserve_nanosecond_metadata(profile):
    for member in MEMBERS:
        Path(str(profile / member) + "-journal").write_bytes(b"")
    before = snapshot(profile)
    gate = preflight.qualify_profile(profile)
    preflight.verify_profile_unchanged(profile, gate)
    assert snapshot(profile) == before


def test_real_hot_journal_is_qualified_without_recovery_or_metadata_changes(profile):
    path = profile / "helper/agent_metadata.db"
    with closing(sqlite3.connect(path)) as db, db:
        db.execute("INSERT INTO payload VALUES ('committed')")
    subprocess.run(
        [
            sys.executable,
            "-c",
            """
import os,sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute('PRAGMA cache_size=1')
db.execute('PRAGMA cache_spill=ON')
db.execute('BEGIN IMMEDIATE')
db.execute('UPDATE payload SET body=?', ['uncommitted ' * 50000])
os._exit(0)
""",
            str(path),
        ],
        check=True,
        timeout=10,
    )
    journal = Path(str(path) + "-journal")
    assert journal.read_bytes()[:8] == bytes.fromhex("d9d505f920a163d7")
    before = snapshot(profile)
    gate = preflight.qualify_profile(profile)
    preflight.verify_profile_unchanged(profile, gate)
    assert snapshot(profile) == before
    # SQLite, rather than qualification, still performs the original recovery.
    with closing(sqlite3.connect(path)) as db, db:
        assert db.execute("SELECT body FROM payload").fetchall() == [("committed",)]
    assert not journal.exists()


def metadata_only_change(path):
    before, digest = snapshot(path.parent)[path.name]
    info = path.stat()
    deadline = time.monotonic() + 5
    while True:
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
        if path.stat().st_ctime_ns != before[7]:
            break
        if time.monotonic() >= deadline:
            pytest.fail("Filesystem did not report a metadata rewrite")
        time.sleep(0.01)
    after, current_digest = snapshot(path.parent)[path.name]
    assert after[7] != before[7]
    assert after[:7] + after[8:] == before[:7] + before[8:]
    assert current_digest == digest


def test_journal_copy_rejects_metadata_only_source_change(profile, monkeypatch):
    path = profile / "application.db"
    Path(str(path) + "-journal").write_bytes(b"")
    original_content = path.read_bytes()
    copyfile = preflight.shutil.copyfile

    def changing_copy(source, destination):
        result = copyfile(source, destination)
        if source == path:
            metadata_only_change(path)
        return result

    def unexpected_probe(_):
        pytest.fail("SQLite must not probe a source set changed during copying")

    monkeypatch.setattr(preflight.shutil, "copyfile", changing_copy)
    monkeypatch.setattr(preflight, "readonly_version", unexpected_probe)
    with pytest.raises(RuntimeError, match="changed during"):
        preflight.qualify_profile(profile)
    assert path.read_bytes() == original_content


def test_final_gate_rejects_metadata_only_source_change(profile):
    gate = preflight.qualify_profile(profile)
    path = profile / "helper/linux_state.db"
    original_content = path.read_bytes()
    metadata_only_change(path)
    assert path.read_bytes() == original_content
    with pytest.raises(RuntimeError, match="changed during"):
        preflight.verify_profile_unchanged(profile, gate)


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
    with closing(sqlite3.connect(profile / "helper/linux_state.db")) as db, db:
        db.execute("PRAGMA user_version=2")
    with pytest.raises(RuntimeError, match="changed during"):
        preflight.verify_profile_unchanged(profile, gate)
