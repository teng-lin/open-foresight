import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from build_macos_runtimes import download
from verify_macos_release_runtime import runtime_paths


class ReleaseRuntimeTest(unittest.TestCase):
    def test_corrupt_download_does_not_replace_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime'
            path.write_bytes(b'previous')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                download('data:application/octet-stream,bad', path, '0' * 64)
            self.assertEqual(path.read_bytes(), b'previous')
            self.assertFalse(path.with_suffix('.download').exists())
            download('data:application/octet-stream,good', path,
                     hashlib.sha256(b'good').hexdigest())
            self.assertEqual(path.read_bytes(), b'good')

    def test_native_only_app_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'App.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            (resources / 'runtime.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'lacks bundled'):
                runtime_paths(app)

    def test_symlink_to_external_python_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'App.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            external = root / 'external-python'
            external.write_bytes(b'external')
            (resources / 'python').symlink_to(external)
            (resources / 'runtime.json').write_text(json.dumps({'FORESIGHT_MODEL_PYTHON': 'python'}))
            with self.assertRaisesRegex(ValueError, 'escapes bundle'):
                runtime_paths(app)


if __name__ == '__main__':
    unittest.main()
