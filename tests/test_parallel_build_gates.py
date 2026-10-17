"""Process-level checks for overlapping gates and preserving failed results."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'parallel_build_gates', Path(__file__).resolve().parents[1] / 'tools/parallel_build_gates.py')
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


class ParallelBuildGatesTest(unittest.TestCase):
    def test_tasks_overlap_and_logs_remain_separate(self):
        """Each child must observe the other child before either can exit."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tasks = []
            for name, other in [('core', 'desktop'), ('desktop', 'core')]:
                program = (
                    'from pathlib import Path; import time; '
                    f'root=Path({str(root)!r}); (root/{name!r}).touch(); '
                    'deadline=time.monotonic()+5\n'
                    f'while not (root/{other!r}).exists():\n'
                    ' if time.monotonic()>deadline: raise RuntimeError("Not concurrent")\n'
                    ' time.sleep(0.01)\n'
                    f'print({name!r})\n')
                tasks.append((name, [sys.executable, '-c', program]))
            self.assertEqual(gates.run_gates(tasks, root / 'logs'), 0)
            self.assertEqual((root / 'logs/core.log').read_text(), 'core\n')
            self.assertEqual((root / 'logs/desktop.log').read_text(), 'desktop\n')

    def test_any_failed_gate_fails_after_other_gate_finishes(self):
        """A later passing gate cannot hide the first gate's failure."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = gates.run_gates([
                ('core', [sys.executable, '-c', 'raise SystemExit(7)']),
                ('desktop', [sys.executable, '-c',
                             f'from pathlib import Path; Path({str(root / "finished")!r}).touch()']),
            ], root / 'logs')
            self.assertEqual(result, 1)
            self.assertTrue((root / 'finished').exists())

    def test_launch_failure_reaps_started_gate(self):
        """A partial launch failure must not leave an owned task running."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = None
            original = gates.subprocess.Popen

            def launch(*args, **kwargs):
                nonlocal process
                if process is not None:
                    raise OSError('Fixture launch failure')
                process = original(*args, **kwargs)
                return process

            from unittest.mock import patch
            with patch.object(gates.subprocess, 'Popen', side_effect=launch):
                with self.assertRaisesRegex(OSError, 'Fixture launch failure'):
                    gates.run_gates([
                        ('core', [sys.executable, '-c', 'import time; time.sleep(60)']),
                        ('desktop', [sys.executable, '-c', 'pass']),
                    ], root / 'logs')
            self.assertIsNotNone(process.poll())
