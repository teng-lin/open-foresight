import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import reference_distribution_config as config


class ReferenceDistributionTest(unittest.TestCase):
    def test_different_reference_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'Foresight'
            binary.write_bytes(b'different release')
            with self.assertRaisesRegex(ValueError, 'Reference build differs'):
                config.read_configuration(binary)
            with self.assertRaisesRegex(ValueError, 'Reference build differs'):
                config.read_google_configuration(binary)

    def test_google_configuration_reads_only_verified_application_bytes(self):
        client_id = b'123456789012-abcdefghijklmnopqrstuvwxyz123456.apps.googleusercontent.com'
        self.assertEqual(len(client_id), 72)
        secret = b'GOCSPX-' + b'x' * 28
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'Foresight'
            binary.write_bytes(client_id + secret)
            with patch.object(config, 'reference_bytes', return_value=binary.read_bytes()), \
                 patch.object(config, 'GOOGLE_CLIENT_ID_OFFSET', 0), \
                 patch.object(config, 'GOOGLE_CLIENT_SECRET_OFFSET', 72):
                result = config.read_google_configuration(binary)
            self.assertEqual(result['installed']['client_id'], client_id.decode())
            self.assertEqual(result['installed']['client_secret'], secret.decode())

    def test_private_output_is_exclusive_and_not_world_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private/runtime.json'
            config.write_private(path, {'fixture': 'not-a-real-key'})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(FileExistsError):
                config.write_private(path, {'replacement': 'must-not-replace'})
            self.assertEqual(json.loads(path.read_text()), {'fixture': 'not-a-real-key'})

    def test_github_values_use_stdin_and_failure_body_is_not_exposed(self):
        with patch.dict(os.environ, {'GH_DEBUG': 'api'}), patch.object(
            subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'fixture-private')
        ) as run:
            with self.assertRaisesRegex(RuntimeError, 'GitHub secret update failed') as error:
                config.store_github({'SETTING': 'fixture-private'}, 'owner/repo', 'gh')
            self.assertNotIn('fixture-private', str(error.exception))
            self.assertNotIn('fixture-private', str(run.call_args.args))
            self.assertEqual(run.call_args.kwargs['input'], 'fixture-private')
            self.assertNotIn('GH_DEBUG', run.call_args.kwargs['env'])


if __name__ == '__main__':
    unittest.main()
