import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('packaged_model_probe', ROOT / 'tools/test_packaged_model_runtime.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class PackagedModelProtocolTest(unittest.TestCase):
    def peer(self, script, root):
        return probe.Peer([sys.executable, '-u', '-c', script], dict(os.environ), root,
                          root / 'worker.stderr', 5)

    def test_graceful_exit_without_extra_stdout_is_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            peer = self.peer('import sys; print("ready"); sys.stdin.read()', Path(temporary))
            self.assertEqual(peer.receive(), 'ready')
            peer.close()
            self.assertEqual(peer.process.returncode, 0)

    def test_native_teardown_noise_after_last_response_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            peer = self.peer('import sys; print("ready"); sys.stdin.read(); print("native teardown noise")',
                             Path(temporary))
            self.assertEqual(peer.receive(), 'ready')
            with self.assertRaisesRegex(RuntimeError, 'Unexpected trailing worker stdout'):
                peer.close()
            self.assertEqual(peer.process.returncode, 0)


if __name__ == '__main__':
    unittest.main()
