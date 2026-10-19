"""Offline profile checks reject live owners and tolerate disappearing proc FDs."""

import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from tools import migrate_profile as migration


@pytest.mark.parametrize("failure", ["status", "stderr"])
def test_macos_open_file_scan_errors_never_authorize_profile_move(
    tmp_path, monkeypatch, failure
):
    monkeypatch.setattr(migration.sys, "platform", "darwin")
    monkeypatch.setattr(
        migration.subprocess,
        "run",
        lambda *a, **kw: SimpleNamespace(
            returncode=2 if failure == "status" else 1,
            stdout="",
            stderr="cannot inspect process" if failure == "stderr" else "",
        ),
    )
    with pytest.raises(RuntimeError, match="Cannot verify offline profile"):
        migration.check_open_profile(tmp_path)


@pytest.mark.parametrize("live_owner", [False, True])
def test_linux_open_file_scan_ignores_own_handles_and_racing_descriptors(
    tmp_path, monkeypatch, live_owner
):
    proc = tmp_path / "proc"
    (proc / "self/fd").mkdir(parents=True)
    own = proc / str(os.getpid()) / "fd"
    own.mkdir(parents=True)
    (own / "1").symlink_to(tmp_path / "profile/application.db")
    foreign = proc / "999999/fd"
    foreign.mkdir(parents=True)
    # The numeric process can disappear between globbing /proc and reading fd.
    (proc / "999998").mkdir()
    for descriptor in ("1", "2", "3", "4"):
        (foreign / descriptor).symlink_to("unused")

    def readlink(path):
        if path.name == "1":
            raise FileNotFoundError("descriptor closed")
        if path.name == "2":
            raise PermissionError("descriptor became inaccessible")
        if path.name == "3":
            return str(tmp_path / "profile-other/application.db")
        return str(
            tmp_path / ("profile" if live_owner else "unrelated") / "application.db"
        )

    def proc_path(value):
        if str(value) == "/proc":
            return proc
        if str(value).startswith("/proc/"):
            return proc / str(value).removeprefix("/proc/")
        return Path(value)

    monkeypatch.setattr(migration.sys, "platform", "linux")
    monkeypatch.setattr(migration, "Path", proc_path)
    monkeypatch.setattr(migration.os, "readlink", readlink)
    if live_owner:
        with pytest.raises(RuntimeError, match="process 999999"):
            migration.check_open_profile(tmp_path / "profile")
    else:
        migration.check_open_profile(tmp_path / "profile")


def test_host_without_proc_cannot_authorize_offline_profile(tmp_path, monkeypatch):
    monkeypatch.setattr(migration.sys, "platform", "unsupported")
    monkeypatch.setattr(migration, "Path", lambda value: tmp_path / "no-proc")
    with pytest.raises(
        RuntimeError, match="Cannot verify offline profile on this platform"
    ):
        migration.check_open_profile(tmp_path)


def test_missing_database_preserves_source_and_never_creates_backup(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    precious = source / "model.bin"
    precious.write_bytes(b"existing model")
    destination, backup = tmp_path / "destination", tmp_path / "backup"
    with pytest.raises(ValueError, match="application.db is missing"):
        migration.migrate(source, destination, backup, "/old", "/new")
    assert precious.read_bytes() == b"existing model"
    assert not destination.exists()
    assert not backup.exists()
