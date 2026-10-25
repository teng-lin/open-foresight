"""Legacy profile migration works through both supported launch interfaces."""

from contextlib import closing
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("mode", ["module", "direct"])
def test_profile_cli_keeps_data_in_git_free_export_and_hostile_import_path(
    tmp_path, mode
):
    export = tmp_path / "export"
    tools = export / "tools"
    tools.mkdir(parents=True)
    names = ["migrate_profile.py", "sqlite_preflight.py"]
    if mode == "module":
        names.append("__init__.py")
    for name in names:
        shutil.copy2(ROOT / "tools" / name, tools / name)
    unrelated = tmp_path / "unrelated"
    (unrelated / "tools").mkdir(parents=True)
    (unrelated / "tools/__init__.py").write_text(
        "raise RuntimeError('ambient tools package was executed')\n"
    )
    (unrelated / "sqlite_preflight.py").write_text(
        "raise RuntimeError('ambient preflight module was executed')\n"
    )
    old = tmp_path / "legacy"
    old.mkdir()
    new = tmp_path / "current"
    backup = tmp_path / "backup"
    asset = tmp_path / "shared-model.bin"
    asset.write_bytes(b"known fixture model")
    literal = f"Keep user-authored {old} unchanged"
    with closing(sqlite3.connect(old / "application.db")) as db, db:
        db.executescript(
            "PRAGMA user_version=17;"
            "CREATE TABLE meetings(state TEXT);"
            "CREATE TABLE models(kind TEXT,path TEXT,runtime TEXT,digest TEXT);"
            "CREATE TABLE source_details(source_id TEXT,source_uri TEXT);"
            "CREATE TABLE notes(body TEXT);"
        )
        db.execute("INSERT INTO notes VALUES(?)", (literal,))
        db.execute(
            "INSERT INTO source_details VALUES(?,?)",
            ("local", (old / "attachment.pdf").as_uri()),
        )
        db.execute(
            "INSERT INTO models VALUES(?,?,?,?)",
            ("embedding", str(asset), "/old-bundle/runner", "unchanged-digest"),
        )
    (old / "attachment.pdf").write_bytes(b"attachment fixture")
    environment = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    environment["PYTHONPATH"] = str(unrelated)
    if mode == "module":
        command = [sys.executable, "-m", "tools.migrate_profile"]
        cwd = export
    else:
        command = [sys.executable, str(tools / "migrate_profile.py")]
        cwd = unrelated
    command += [
        str(old),
        str(new),
        "--backup",
        str(backup),
        "--old-bundle",
        "/old-bundle",
        "--new-bundle",
        "/new-bundle",
        "--copy-external-models",
    ]
    result = subprocess.run(
        command, cwd=cwd, env=environment, capture_output=True, text=True, timeout=30
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == str(new)
    assert not old.exists()
    assert not (export / ".git").exists()
    assert (new / "attachment.pdf").read_bytes() == b"attachment fixture"
    assert (
        new / "models/imported/embedding/shared-model.bin"
    ).read_bytes() == asset.read_bytes()
    with closing(sqlite3.connect(new / "application.db")) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 17
        assert db.execute("SELECT body FROM notes").fetchone()[0] == literal
        assert (
            db.execute("SELECT source_uri FROM source_details").fetchone()[0]
            == (new / "attachment.pdf").as_uri()
        )
        assert db.execute("SELECT path,runtime,digest FROM models").fetchone() == (
            str(new / "models/imported/embedding/shared-model.bin"),
            "/new-bundle/runner",
            "unchanged-digest",
        )
    with closing(sqlite3.connect(backup / "application.db")) as db:
        assert db.execute("PRAGMA user_version").fetchone()[0] == 17
        assert db.execute("SELECT path,runtime,digest FROM models").fetchone() == (
            str(asset),
            "/old-bundle/runner",
            "unchanged-digest",
        )
