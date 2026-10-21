"""Real SQLite qualification/recovery contracts; run with freshly built targets.

No journal recovery is mocked. sqlite_commit_boundary delegates SQLite's VFS
and crashes on its real superjournal deletion, on both sides of the commit point.
"""

import hashlib
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import unittest

import legacy_schema

CHECKER = CRASH = None
MEMBERS = ("agent_metadata.db", "linux_state.db", "rag_vector.db")


class SchemaPreflight(legacy_schema.LegacyHelperDatabases):
    def setUp(self):
        super().setUp()
        scratch = tempfile.TemporaryDirectory(prefix="of-qual-scratch-")
        self.addCleanup(scratch.cleanup)
        self.scratch_root = Path(scratch.name)
        self.scratch_root.chmod(0o700)

    def snapshot(self):
        return {
            path.name: (
                path.stat().st_ino,
                path.stat().st_size,
                path.stat().st_mtime_ns,
                hashlib.sha256(path.read_bytes()).hexdigest(),
            )
            for path in self.root.iterdir()
            if path.is_file()
        }

    def qualify(self, *, succeeds=True):
        before = self.snapshot()
        result = subprocess.run(
            [str(CHECKER), str(self.root)],
            capture_output=True,
            text=True,
            env={**os.environ, "TMPDIR": str(self.scratch_root)},
            timeout=15,
        )
        self.assertEqual(
            result.returncode == 0, succeeds, result.stdout + result.stderr
        )
        self.assertEqual(
            self.snapshot(), before, "qualification mutated live originals"
        )
        self.assertEqual(
            list(self.scratch_root.iterdir()), [], "private preflight scratch leaked"
        )
        return result.stderr

    def crash(self, *, boundary=None, original=0):
        self.vector(0, "[1.5]")
        if boundary:
            result = subprocess.run(
                [str(CRASH), str(self.root), boundary, str(original)],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(
                result.returncode, {"before": 41, "after": 42}[boundary], result.stderr
            )
        else:
            script = next(
                value
                for value in legacy_schema.LegacyHelperDatabases.test_hot_attached_journals_recover_before_serving_original_data.__code__.co_consts
                if isinstance(value, str) and "os._exit" in value
            )
            subprocess.run(
                [sys.executable, "-c", script, str(self.root)], check=True, timeout=10
            )

    def test_healthy_legacy_set_is_nonmutating(self):
        self.qualify()
        (self.root / "rag_vector.db").unlink()
        self.qualify()
        self.assertFalse((self.root / "rag_vector.db").exists())

    def test_future_member_each_position_refuses_without_any_live_change(self):
        for name in MEMBERS:
            with self.subTest(member=name):
                with sqlite3.connect(self.root / name) as db:
                    db.execute("PRAGMA user_version=2")
                diagnostic = self.qualify(succeeds=False)
                self.assertIn(name, diagnostic)
                self.assertIn("maximum 1", diagnostic)
                with sqlite3.connect(self.root / name) as db:
                    db.execute("PRAGMA user_version=0")

    def test_real_hot_attached_journals_qualify_then_sqlite_recovers(self):
        self.crash()
        self.qualify()
        self.start()
        self.assertEqual(
            self.vectors(), [(0, "blob", b"FSV1" + struct.pack("<d", 1.5))]
        )
        with sqlite3.connect(self.root / "agent_metadata.db") as db:
            self.assertEqual(
                db.execute("SELECT content FROM documents").fetchone(),
                ("private body",),
            )

    def test_live_helper_refuses_future_member_before_creating_lock_or_sidecars(self):
        for name in MEMBERS:
            with self.subTest(member=name):
                with sqlite3.connect(self.root / name) as db:
                    db.execute("PRAGMA user_version=2")
                before = self.snapshot()
                self.start(succeeds=False)
                after = self.snapshot()
                after.pop("helper.log", None)
                before.pop("helper.log", None)
                self.assertEqual(after, before)
                self.assertIn(
                    "unsupported newer schema version",
                    (self.root / "helper.log").read_text(),
                )
                with sqlite3.connect(self.root / name) as db:
                    db.execute("PRAGMA user_version=0")

    def test_successful_upgrade_sets_all_versions_and_reopen_keeps_vectors(self):
        self.vector(0, "[1.5]")
        self.start()
        expected = self.vectors()
        for name in MEMBERS:
            with sqlite3.connect(self.root / name) as db:
                self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (1,))
        self.start()
        self.assertEqual(self.vectors(), expected)

    def test_mixed_partially_upgraded_sets_preserve_existing_binary_vectors(self):
        binary = b"FSV1" + struct.pack("<d", 1.5)
        self.vector(0, binary)
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            db.execute("PRAGMA user_version=1")
        self.start()
        self.assertEqual(self.vectors(), [(0, "blob", binary)])
        for name in MEMBERS:
            with sqlite3.connect(self.root / name) as db:
                self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (1,))

    def test_future_last_member_never_creates_missing_first_member(self):
        (self.root / "agent_metadata.db").unlink()
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            db.execute("PRAGMA user_version=2")
        self.qualify(succeeds=False)
        self.start(succeeds=False)
        self.assertFalse((self.root / "agent_metadata.db").exists())
        self.assertFalse((self.root / ".helper.lock").exists())

    def test_real_superjournal_commit_boundaries_preserve_correct_content(self):
        for boundary in ("before", "after"):
            with self.subTest(boundary=boundary):
                # Fresh independent real profile for each attached commit.
                nested = SchemaPreflight()
                nested.setUp()
                try:
                    nested.crash(boundary=boundary)
                    nested.qualify()
                    nested.start()
                    expected = (
                        "private body"
                        if boundary == "before"
                        else "committed boundary body"
                    )
                    with sqlite3.connect(nested.root / "agent_metadata.db") as db:
                        self.assertEqual(
                            db.execute("SELECT content FROM documents").fetchone(),
                            (expected,),
                        )
                    expected_vector = 1.5 if boundary == "before" else 2.5
                    self.assertEqual(
                        nested.vectors(),
                        [(0, "blob", b"FSV1" + struct.pack("<d", expected_vector))],
                    )
                finally:
                    nested.doCleanups()

    def test_hidden_future_original_page_one_at_both_real_commit_boundaries(self):
        for boundary in ("before", "after"):
            with self.subTest(boundary=boundary):
                nested = SchemaPreflight()
                nested.setUp()
                try:
                    nested.crash(boundary=boundary, original=2)
                    for name in MEMBERS:
                        self.assertEqual(
                            struct.unpack_from(
                                ">I", (nested.root / name).read_bytes(), 60
                            )[0],
                            0,
                        )
                    diagnostic = nested.qualify(succeeds=False)
                    self.assertIn("schema version 2", diagnostic)
                finally:
                    nested.doCleanups()

    def wal(self, name, version):
        # os._exit preserves committed WAL frames and avoids close/checkpoint.
        script = """
import os, sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute('PRAGMA journal_mode=WAL')
connection.execute('PRAGMA wal_autocheckpoint=0')
connection.execute('PRAGMA user_version=' + sys.argv[2])
connection.commit()
os._exit(0)
"""
        subprocess.run(
            [sys.executable, "-c", script, str(self.root / name), str(version)],
            check=True,
            timeout=10,
        )

    def test_wal_only_future_member_with_existing_or_absent_shm(self):
        for name in MEMBERS:
            for shm in (True, False):
                with self.subTest(member=name, shm=shm):
                    nested = SchemaPreflight()
                    nested.setUp()
                    try:
                        nested.wal(name, 2)
                        self.assertEqual(
                            struct.unpack_from(
                                ">I", (nested.root / name).read_bytes(), 60
                            )[0],
                            0,
                        )
                        if not shm:
                            (nested.root / (name + "-shm")).unlink()
                        nested.qualify(succeeds=False)
                    finally:
                        nested.doCleanups()

    def test_supported_wal_rebuilds_only_private_shm(self):
        self.wal("agent_metadata.db", 1)
        (self.root / "agent_metadata.db-shm").unlink()
        self.qualify()
        self.assertFalse((self.root / "agent_metadata.db-shm").exists())

    def test_unknown_or_corrupt_journal_fails_closed_without_source_writes(self):
        self.crash()
        journal = self.root / "agent_metadata.db-journal"
        original = journal.read_bytes()
        for offset, replacement in (
            (24, struct.pack(">I", 333)),
            (512 + 4096 + 4, b"\xff\xff\xff\xff"),
        ):
            with self.subTest(offset=offset):
                value = bytearray(original)
                value[offset : offset + len(replacement)] = replacement
                journal.write_bytes(value)
                self.qualify(succeeds=False)
        journal.write_bytes(original)
        self.qualify()

    def test_source_change_after_whole_set_qualification_is_rejected(self):
        log = self.root / "qualification.log"
        with log.open("w") as output:
            process = subprocess.Popen(
                [str(CHECKER), str(self.root), "--wait"],
                stdin=subprocess.PIPE,
                stdout=output,
                stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                deadline = time.monotonic() + 15
                while "qualified" not in log.read_text():
                    self.assertIsNone(process.poll(), log.read_text())
                    if time.monotonic() >= deadline:
                        self.fail("qualification wait timed out: " + log.read_text())
                    time.sleep(0.01)
                with sqlite3.connect(self.root / "linux_state.db") as db:
                    db.execute("PRAGMA user_version=2")
                process.communicate("continue\n", timeout=5)
                self.assertNotEqual(process.returncode, 0, log.read_text())
                self.assertIn("changed during qualification", log.read_text())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(
            "Usage: schema_preflight.py CHECKER SQLITE_COMMIT_FIXTURE HELPER"
        )
    CHECKER, CRASH, legacy_schema.HELPER = (
        Path(item).resolve(strict=True) for item in sys.argv[1:]
    )
    sys.argv[1:] = []
    unittest.main()
