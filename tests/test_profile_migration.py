import importlib.util
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('migration', Path(__file__).parents[1] / 'tools/migrate_profile.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class ProfileMigrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old, self.new, self.backup = (self.root / name for name in ('old', 'open-foresight', 'backup'))
        self.old.mkdir()
        self.asset = self.root / 'shared/model.bin'
        self.asset.parent.mkdir()
        self.asset.write_bytes(b'unchanged shared embedding')
        with sqlite3.connect(self.old / 'application.db') as db:
            db.executescript('CREATE TABLE meetings(state TEXT); CREATE TABLE models(kind TEXT,path TEXT,runtime TEXT,digest TEXT); CREATE TABLE source_details(source_id TEXT,source_uri TEXT); CREATE TABLE notes(body TEXT);')
            db.execute("INSERT INTO meetings VALUES('completed')")
            db.execute('INSERT INTO models VALUES(?,?,?,?)', ('embedding', str(self.asset), '', 'same-digest'))
            db.execute('INSERT INTO models VALUES(?,?,?,?)', ('generation', str(self.old / 'models/gemma.bin'), '/old/bundle/runner', 'same-generation'))
            db.execute('INSERT INTO source_details VALUES(?,?)', ('local', 'file://' + str(self.old / 'attachment.pdf')))
            db.execute('INSERT INTO notes VALUES(?)', ('Keep literal ' + str(self.old),))
        (self.old / 'models').mkdir()
        (self.old / 'models/gemma.bin').write_bytes(b'gemma')
        (self.old / 'google').mkdir()
        (self.old / 'google/tokens.json').write_text('fixture-secret')
        (self.old / 'helper').mkdir()
        with sqlite3.connect(self.old / 'helper/agent_metadata.db') as db:
            db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)')
            db.execute('INSERT INTO settings VALUES(?,?)', ('embedding_model_path', str(self.asset)))

    def migrate(self):
        return migration.migrate(self.old, self.new, self.backup, '/old/bundle', '/new/bundle', True)

    def test_preserves_data_models_and_private_backup(self):
        self.migrate()
        self.assertFalse(self.old.exists())
        self.assertEqual((self.new / 'google/tokens.json').read_text(), 'fixture-secret')
        self.assertEqual(self.backup.stat().st_mode & 0o777, 0o700)
        with sqlite3.connect(self.new / 'application.db') as db:
            models = db.execute('SELECT * FROM models ORDER BY kind').fetchall()
            self.assertEqual(Path(models[0][1]).read_bytes(), self.asset.read_bytes())
            self.assertNotEqual(Path(models[0][1]).stat().st_ino, self.asset.stat().st_ino)
            self.assertEqual(models[1][1:3], (str(self.new / 'models/gemma.bin'), '/new/bundle/runner'))
            self.assertEqual(db.execute('SELECT source_uri FROM source_details').fetchone()[0], 'file://' + str(self.new / 'attachment.pdf'))
            self.assertEqual(db.execute('SELECT body FROM notes').fetchone()[0], 'Keep literal ' + str(self.old))
        with sqlite3.connect(self.backup / 'application.db') as db:
            self.assertEqual(db.execute("SELECT path FROM models WHERE kind='embedding'").fetchone()[0], str(self.asset))
        with sqlite3.connect(self.new / 'helper/agent_metadata.db') as db:
            self.assertEqual(db.execute('SELECT value FROM settings').fetchone()[0], models[0][1])

    def test_refuses_live_process_with_open_profile(self):
        process = subprocess.Popen([sys.executable, '-c',
            "import sys; f=open(sys.argv[1],'rb'); print('ready',flush=True); sys.stdin.read()",
            str(self.old / 'application.db')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), 'ready')
            with self.assertRaisesRegex(RuntimeError, 'Profile is open'):
                self.migrate()
            self.assertTrue(self.old.exists())
        finally:
            process.communicate('', timeout=5)

    def test_refuses_conflict_and_active_meeting(self):
        self.new.mkdir()
        with self.assertRaises(ValueError):
            self.migrate()
        self.new.rmdir()
        with sqlite3.connect(self.old / 'application.db') as db:
            db.execute("UPDATE meetings SET state='recording'")
        with self.assertRaises(RuntimeError):
            self.migrate()
        self.assertTrue(self.old.exists())
        self.assertFalse(self.backup.exists())


if __name__ == '__main__':
    unittest.main()
