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

    def test_incomplete_native_app_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'App.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            (resources / 'runtime.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'lacks bundled'):
                runtime_paths(app)

    def test_symlink_to_external_worker_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'App.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            external = root / 'external-worker'
            external.write_bytes(b'external')
            (resources / 'worker').symlink_to(external)
            (resources / 'runtime.json').write_text(json.dumps({'FORESIGHT_MODEL_WORKER': 'worker'}))
            with self.assertRaisesRegex(ValueError, 'escapes bundle'):
                runtime_paths(app)

    def test_complete_native_app_needs_no_python_and_rejects_retired_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'App.app'
            resources = app / 'Contents/Resources'
            resources.mkdir(parents=True)
            config = {'FORESIGHT_MODEL_WORKER': 'bin/foresight-model',
                      'FORESIGHT_LITERT_RUNNER': 'bin/foresight-model',
                      'FORESIGHT_QUERY_RUNTIME': 'bin/foresight-query',
                      'FORESIGHT_QUERY_WORKER': 'bin/foresight-query',
                      'FORESIGHT_LITERT_LIBRARY': 'lib/liblitert-lm.dylib',
                      'FORESIGHT_WHISPER_RUNTIME': 'bin/whisper-cli'}
            for relative in config.values():
                path = resources / relative
                path.parent.mkdir(exist_ok=True)
                path.touch()
            notices = resources / 'licenses'
            notices.mkdir()
            for name in ('LiteRT-LM-extension.json', 'LiteRT-LM-LICENSE', 'sentencepiece-LICENSE', 'whisper-LICENSE'):
                (notices / name).touch()
            (resources / 'runtime.json').write_text(json.dumps(config))
            paths = runtime_paths(app)
            self.assertEqual(paths['FORESIGHT_LITERT_RUNNER'], paths['FORESIGHT_MODEL_WORKER'])
            (resources / 'retired.py').touch()
            with self.assertRaisesRegex(ValueError, 'Python runtime or inference scripts'):
                runtime_paths(app)


if __name__ == '__main__':
    unittest.main()
