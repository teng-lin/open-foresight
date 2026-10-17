"""A changed patch must not be published as the source used by a build."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('litert_builder', ROOT / 'tools/build_litert_extensions.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


@unittest.skipUnless(shutil.which('git'), 'Git required')
class BuildSnapshotTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Snapshot test')
        self.git('config', 'user.email', 'snapshot@example.invalid')
        self.file = self.source / 'input.txt'
        self.file.write_text('original\n')
        self.git('add', 'input.txt')
        self.git('commit', '-qm', 'Fixture')
        self.commit = self.git('rev-parse', 'HEAD').decode().strip()
        self.first = self.make_patch('first patch\n')
        self.second = self.make_patch('second patch\n')
        self.patch_path = self.root / 'source.patch'
        self.patch_path.write_bytes(self.first)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.source, stderr=subprocess.PIPE)

    def make_patch(self, value):
        self.file.write_text(value)
        result = self.git('diff', 'HEAD', '--binary')
        self.git('checkout', '--', 'input.txt')
        return result

    def invoke(self):
        with patch.object(builder, 'COMMIT', self.commit), patch.object(builder, 'PATCH', self.patch_path), \
                patch('sys.argv', ['builder', str(self.source), '--apply-only']):
            builder.main()

    def test_applied_source_matches_the_captured_patch(self):
        self.invoke()
        self.assertEqual(self.file.read_text(), 'first patch\n')
        self.assertEqual(self.git('diff', 'HEAD', '--binary'), self.first)

    def test_patch_changed_between_read_and_apply_is_rejected(self):
        original_run = builder.run

        def mutate(source, *args, **kwargs):
            if args[:3] == ('git', 'apply', '--check'):
                self.patch_path.write_bytes(self.second)
            return original_run(source, *args, **kwargs)

        with patch.object(builder, 'run', side_effect=mutate):
            with self.assertRaisesRegex(RuntimeError, 'changed from the verified'):
                self.invoke()
        self.assertEqual(self.file.read_text(), 'second patch\n')


if __name__ == '__main__':
    unittest.main()
