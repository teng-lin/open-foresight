"""Exercise Bazel-style directory cleanup without modifying linked artifacts."""
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'runtime_cleanup', Path(__file__).resolve().parents[1] / 'tools/clean_macos_runtime_sources.py')
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class RuntimeCleanupTest(unittest.TestCase):
    def test_read_only_bazel_tree_is_removed_and_external_target_preserved(self):
        """Reproduce rm failure and prove linked payloads remain unchanged."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root / 'verified-runtime'
            external.mkdir()
            artifact = external / 'library.dylib'
            artifact.write_bytes(b'verified artifact')
            artifact.chmod(0o444)
            external.chmod(0o555)
            source = root / 'compiler-scratch'
            output = source / 'bazel-out/crate/_bs.out_dir'
            output.mkdir(parents=True)
            (output / 'object.o').write_bytes(b'build object')
            (output / 'object.o').chmod(0o444)
            (source / 'linked-runtime').symlink_to(external, target_is_directory=True)
            for path in [output, output.parent, output.parent.parent, source]:
                path.chmod(0o555)
            try:
                if os.geteuid() != 0:  # Root can bypass directory permissions.
                    with self.assertRaises(PermissionError):
                        shutil.rmtree(source)
                cleanup.remove_sources(source)
                self.assertFalse(source.exists())
                self.assertEqual(artifact.read_bytes(), b'verified artifact')
                self.assertEqual(external.stat().st_mode & 0o777, 0o555)
                self.assertEqual(artifact.stat().st_mode & 0o777, 0o444)
                cleanup.remove_sources(source)  # A warm cache has no sources.
            finally:
                external.chmod(0o755)

    def test_symlink_root_is_rejected_without_deleting_target(self):
        """A source-root link must never redirect recursive cleanup."""
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'payload'
            target.mkdir()
            source = Path(directory) / 'sources'
            source.symlink_to(target, target_is_directory=True)
            with self.assertRaises(ValueError):
                cleanup.remove_sources(source)
            self.assertTrue(target.is_dir())
            self.assertTrue(source.is_symlink())
