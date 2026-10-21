"""Characterize real helper database startup before versioned migrations.

Run explicitly with the current compiled helper; this is not an offline unit
suite and never substitutes a mocked SQLite implementation for the subprocess.
"""

from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = None


class LegacyHelperDatabases(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="of-db-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.run = self.root / "run"
        self.run.mkdir(mode=0o700)
        with sqlite3.connect(self.root / "agent_metadata.db") as db:
            db.executescript(
                "CREATE TABLE documents(id TEXT PRIMARY KEY,content TEXT,userId TEXT,"
                "maxTokensPerChunk INTEGER,chunkOverlap INTEGER,mimeType TEXT,imageBytes BLOB);"
                "CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT);"
                "INSERT INTO documents VALUES('kept','private body','user',100,20,'text/plain',NULL);"
                "INSERT INTO settings VALUES('fixture','unchanged');"
            )
        with sqlite3.connect(self.root / "linux_state.db") as db:
            db.executescript(
                "CREATE TABLE source_revisions(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,"
                "tombstone INTEGER NOT NULL);"
                "CREATE TABLE journal(sequence INTEGER PRIMARY KEY,operation TEXT,"
                "document_id TEXT,revision INTEGER,generation INTEGER,status TEXT);"
                "INSERT INTO source_revisions VALUES('kept',7,0);"
            )
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            db.executescript(
                "CREATE TABLE chunks(generation INTEGER,document_id TEXT,revision INTEGER,"
                "ordinal INTEGER,text TEXT,mime TEXT,embedding BLOB,"
                "PRIMARY KEY(generation,document_id,revision,ordinal));"
                "CREATE TABLE generations(id INTEGER PRIMARY KEY,model_digest TEXT,status TEXT);"
                "INSERT INTO generations VALUES(1,'fixture','active');"
            )

    def vector(self, ordinal, embedding, *, generation=1, revision=7):
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            db.execute(
                "INSERT INTO chunks VALUES(?,'kept',?,?,?,'text/plain',?)",
                (generation, revision, ordinal, f"chunk {ordinal}", embedding),
            )

    def start(self, *, succeeds=True):
        log = self.root / "helper.log"
        with log.open("w") as output:
            process = subprocess.Popen(
                [str(HELPER), str(self.run / "helper.sock"), str(self.root)],
                stdout=output,
                stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 15
                while process.poll() is None:
                    if " ready " in log.read_text():
                        self.assertTrue(succeeds, log.read_text())
                        return
                    if time.monotonic() >= deadline:
                        self.fail("Helper startup timed out:\n" + log.read_text())
                    time.sleep(0.01)
                self.assertFalse(succeeds, log.read_text())
                self.assertNotEqual(process.returncode, 0, log.read_text())
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)

    def vectors(self):
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            return db.execute(
                "SELECT ordinal,typeof(embedding),embedding FROM chunks ORDER BY ordinal"
            ).fetchall()

    def test_legacy_json_conversion_keeps_binary_bytes_and_runtime_recovery(self):
        binary = b"FSV1" + struct.pack("<dd", 3.5, -4.25)
        self.vector(0, "[1.5,-2.0]")
        self.vector(1, binary)
        self.vector(2, "[9.0]", revision=6)
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            db.execute("INSERT INTO generations VALUES(2,'unfinished','building')")
        self.vector(3, "[10.0]", generation=2)
        self.start()
        self.assertEqual(
            self.vectors(),
            [(0, "blob", b"FSV1" + struct.pack("<dd", 1.5, -2.0)), (1, "blob", binary)],
        )
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            self.assertEqual(
                db.execute("SELECT id FROM generations").fetchall(), [(1,)]
            )
            db.execute(
                "CREATE TRIGGER preserve_binary BEFORE UPDATE OF embedding ON chunks "
                "BEGIN SELECT RAISE(ABORT,'binary data must not be rewritten'); END"
            )
        self.start()
        self.assertEqual(self.vectors()[1], (1, "blob", binary))
        with sqlite3.connect(self.root / "agent_metadata.db") as db:
            self.assertEqual(
                db.execute("SELECT content FROM documents").fetchall(),
                [("private body",)],
            )
            self.assertEqual(
                db.execute("SELECT value FROM settings WHERE key='fixture'").fetchone(),
                ("unchanged",),
            )

    def test_bad_legacy_json_rolls_back_prior_embedding_conversion_then_retries(self):
        self.vector(0, "[1.5,-2.0]")
        self.vector(1, "{broken JSON")
        before = self.vectors()
        self.start(succeeds=False)
        self.assertEqual(self.vectors(), before)
        for name in ("agent_metadata.db", "linux_state.db", "rag_vector.db"):
            with sqlite3.connect(self.root / name) as db:
                self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (0,))
                self.assertEqual(db.execute("PRAGMA quick_check").fetchone(), ("ok",))
        with sqlite3.connect(self.root / "rag_vector.db") as db:
            db.execute("UPDATE chunks SET embedding='[5.0]' WHERE ordinal=1")
        self.start()
        self.assertEqual(
            self.vectors(),
            [
                (0, "blob", b"FSV1" + struct.pack("<dd", 1.5, -2.0)),
                (1, "blob", b"FSV1" + struct.pack("<d", 5.0)),
            ],
        )

    def test_hot_attached_journals_recover_before_serving_original_data(self):
        self.vector(0, "[1.5]")
        # Force dirty pages out of SQLite's small cache, then simulate abrupt
        # process death. Normal connection cleanup would erase this fixture.
        crash = """
import os, sqlite3, sys
from pathlib import Path
root = Path(sys.argv[1])
db = sqlite3.connect(root / 'agent_metadata.db')
db.execute('ATTACH DATABASE ? AS linux', [str(root / 'linux_state.db')])
db.execute('ATTACH DATABASE ? AS vectors', [str(root / 'rag_vector.db')])
for member in ('main', 'linux', 'vectors'):
    db.execute(f'PRAGMA {member}.cache_size=1')
    db.execute(f'PRAGMA {member}.cache_spill=ON')
db.execute('BEGIN IMMEDIATE')
db.execute('UPDATE documents SET content=?', ['uncommitted ' * 50000])
db.execute('UPDATE linux.source_revisions SET revision=99')
db.execute('UPDATE vectors.chunks SET embedding=?', ['[9,' + '9,' * 100000 + '9]'])
os._exit(0)
"""
        subprocess.run(
            [sys.executable, "-c", crash, str(self.root)], check=True, timeout=10
        )
        self.assertTrue((self.root / "agent_metadata.db-journal").is_file())
        self.assertTrue((self.root / "rag_vector.db-journal").is_file())
        self.start()
        self.assertEqual(
            self.vectors(), [(0, "blob", b"FSV1" + struct.pack("<d", 1.5))]
        )
        with sqlite3.connect(self.root / "agent_metadata.db") as db:
            self.assertEqual(
                db.execute("SELECT content FROM documents").fetchall(),
                [("private body",)],
            )
        with sqlite3.connect(self.root / "linux_state.db") as db:
            self.assertEqual(
                db.execute("SELECT revision FROM source_revisions").fetchall(), [(7,)]
            )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: legacy_schema.py HELPER_EXECUTABLE")
    HELPER = Path(sys.argv.pop()).resolve(strict=True)
    unittest.main()
