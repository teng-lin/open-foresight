"""Process-level checks for overlapping gates and preserving failed results."""

import importlib.util
from pathlib import Path
import signal
import sys
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "parallel_build_gates",
    Path(__file__).resolve().parents[1] / "tools/parallel_build_gates.py",
)
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


class ParallelBuildGatesTest(unittest.TestCase):
    def test_later_failure_is_printed_once_before_held_gate_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, release = root / "ready", root / "release"
            held = (
                "from pathlib import Path; import time; "
                f"Path({str(ready)!r}).touch(); end=time.monotonic()+5\n"
                f"while not Path({str(release)!r}).exists():\n"
                " if time.monotonic()>end: raise RuntimeError('release missing')\n"
                " time.sleep(.01)\n"
                "print('held complete')\n"
            )
            failed = (
                "from pathlib import Path; import sys,time; end=time.monotonic()+3\n"
                f"while not Path({str(ready)!r}).exists():\n"
                " if time.monotonic()>end: raise RuntimeError('held owner not ready')\n"
                " time.sleep(.01)\n"
                "sys.stdout.buffer.write('later failure café\\n'.encode()); raise SystemExit(7)"
            )
            program = (
                "import importlib.util; from pathlib import Path; "
                f"spec=importlib.util.spec_from_file_location('gates',{gates.__file__!r}); "
                "g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g); "
                "g.PROGRESS_INTERVAL_SECONDS=.02; "
                f"raise SystemExit(g.run_gates({[('held', [sys.executable, '-c', held]), ('later', [sys.executable, '-c', failed])]!r},Path({str(root / 'logs')!r})))"
            )
            output = root / "combined.log"
            with output.open("wb") as stream:
                process = subprocess.Popen(
                    [sys.executable, "-c", program],
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                )
                try:
                    deadline = time.monotonic() + 4
                    while b"::group::later gate (exit 7)" not in output.read_bytes():
                        self.assertIsNone(process.poll(), output.read_text())
                        self.assertLess(time.monotonic(), deadline, output.read_text())
                        time.sleep(0.01)
                    self.assertTrue(ready.exists())
                    self.assertFalse(release.exists())
                    self.assertNotIn(b"held complete", output.read_bytes())
                    release.touch()
                    self.assertEqual(process.wait(timeout=5), 1)
                finally:
                    release.touch()
                    if process.poll() is None:
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
            self.assertEqual(
                (root / "logs/later.log").read_bytes(), "later failure café\n".encode()
            )
            self.assertEqual((root / "logs/held.log").read_bytes(), b"held complete\n")
            raw = output.read_bytes()
            self.assertEqual(raw.count(b"::group::later gate (exit 7)"), 1)
            self.assertEqual(raw.count("later failure café\n".encode()), 1)
            self.assertEqual(raw.count(b"::group::held gate (exit 0)"), 1)

    def test_progress_slices_do_not_reset_original_wait_deadline(self):
        clock = [0.0]
        waits = []

        class Owner:
            pid = 10001
            args = ["controlled fixture"]
            exited = False

            def poll(self):
                return 0 if self.exited else None

            def wait(self, timeout):
                if self.exited:
                    return 0
                waits.append(timeout)
                clock[0] += timeout
                raise subprocess.TimeoutExpired(self.args, timeout)

        owner = Owner()

        def stop(_pid, _signal):
            owner.exited = True

        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(gates, "WAIT_TIMEOUT_SECONDS", 0.07),
                patch.object(gates, "PROGRESS_INTERVAL_SECONDS", 0.02),
                patch.object(gates.time, "monotonic", side_effect=lambda: clock[0]),
                patch.object(gates.subprocess, "Popen", return_value=owner),
                patch.object(gates.os, "killpg", side_effect=stop) as signal_group,
            ):
                with self.assertRaises(subprocess.TimeoutExpired) as failure:
                    gates.run_gates([("held", owner.args)], Path(directory))
            self.assertAlmostEqual(clock[0], 0.07)
            self.assertEqual(len(waits), 4)
            self.assertAlmostEqual(sum(waits), 0.07)
            self.assertEqual(failure.exception.timeout, 0.07)
            self.assertEqual(
                [c.args[1] for c in signal_group.call_args_list],
                [signal.SIGTERM, signal.SIGKILL],
            )
            self.assertTrue(owner.exited)

    def test_denied_first_group_does_not_leave_other_owned_gates_running(self):
        original_launch = gates.subprocess.Popen
        original_signal = gates.os.killpg
        owners = []

        def launch(*args, **kwargs):
            if len(owners) == 2:
                raise OSError("Fixture launch failure")
            owner = original_launch(*args, **kwargs)
            owners.append(owner)
            return owner

        def send(pid, sig):
            if pid == owners[0].pid:
                raise PermissionError("First group denied")
            return original_signal(pid, sig)

        with tempfile.TemporaryDirectory() as directory:
            try:
                with (
                    patch.object(gates.subprocess, "Popen", side_effect=launch),
                    patch.object(gates.os, "killpg", side_effect=send),
                ):
                    with self.assertRaisesRegex(PermissionError, "First group denied"):
                        gates.run_gates(
                            [
                                (
                                    str(index),
                                    [
                                        sys.executable,
                                        "-c",
                                        "import time; time.sleep(60)",
                                    ],
                                )
                                for index in range(3)
                            ],
                            Path(directory),
                        )
                self.assertIsNone(owners[0].poll())
                self.assertIsNotNone(owners[1].poll())
            finally:
                for owner in owners:
                    if owner.poll() is None:
                        original_signal(owner.pid, signal.SIGKILL)
                    owner.wait(timeout=5)

    def test_darwin_exited_leader_waits_for_orphan_group_to_disappear(self):
        owner = unittest.mock.Mock(pid=10001)
        owner.poll.return_value = 0
        with (
            patch.object(gates.sys, "platform", "darwin"),
            patch.object(gates.time, "sleep"),
            patch.object(
                gates.os,
                "killpg",
                side_effect=[
                    PermissionError("orphan zombie"),
                    PermissionError("orphan zombie"),
                    ProcessLookupError("group retired"),
                ],
            ) as send,
        ):
            gates.signal_owned_group(owner, signal.SIGKILL)
        self.assertEqual(send.call_count, 3)

    def test_darwin_exited_leader_permission_denial_still_fails(self):
        owner = unittest.mock.Mock(pid=10001)
        owner.poll.return_value = 0
        with (
            patch.object(gates.sys, "platform", "darwin"),
            patch.object(gates.time, "monotonic", side_effect=[0, 0, 1]),
            patch.object(gates.time, "sleep"),
            patch.object(
                gates.os, "killpg", side_effect=PermissionError("still denied")
            ),
        ):
            with self.assertRaisesRegex(PermissionError, "still denied"):
                gates.signal_owned_group(owner, signal.SIGKILL)

    def test_command_timings_preserve_failed_status_and_stop_following_work(self):
        helper = Path(__file__).resolve().parents[1] / "tools/ci_timing.sh"
        for code in (0, 7):
            script = 'source "$1"; ci_timed fixture bash -c "exit $2"; echo continued'
            result = subprocess.run(
                ["bash", "-e", "-c", script, "timing", str(helper), str(code)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(result.returncode, code)
            self.assertIn(f"(exit {code})", result.stdout)
            self.assertEqual("continued" in result.stdout, code == 0)

    def test_tasks_overlap_and_logs_remain_separate(self):
        """Each child must observe the other child before either can exit."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tasks = []
            for name, other in [("core", "desktop"), ("desktop", "core")]:
                program = (
                    "from pathlib import Path; import time; "
                    f"root=Path({str(root)!r}); (root/{name!r}).touch(); "
                    "deadline=time.monotonic()+5\n"
                    f"while not (root/{other!r}).exists():\n"
                    ' if time.monotonic()>deadline: raise RuntimeError("Not concurrent")\n'
                    " time.sleep(0.01)\n"
                    f"print({name!r})\n"
                )
                tasks.append((name, [sys.executable, "-c", program]))
            self.assertEqual(gates.run_gates(tasks, root / "logs"), 0)
            self.assertEqual((root / "logs/core.log").read_text(), "core\n")
            self.assertEqual((root / "logs/desktop.log").read_text(), "desktop\n")

    def test_any_failed_gate_fails_after_other_gate_finishes(self):
        """A later passing gate cannot hide the first gate's failure."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = gates.run_gates(
                [
                    ("core", [sys.executable, "-c", "raise SystemExit(7)"]),
                    (
                        "desktop",
                        [
                            sys.executable,
                            "-c",
                            f"from pathlib import Path; Path({str(root / 'finished')!r}).touch()",
                        ],
                    ),
                ],
                root / "logs",
            )
            self.assertEqual(result, 1)
            self.assertTrue((root / "finished").exists())

    def test_launch_failure_reaps_started_gate(self):
        """A partial launch failure must not leave an owned task running."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = None
            original = gates.subprocess.Popen

            def launch(*args, **kwargs):
                nonlocal process
                if process is not None:
                    raise OSError("Fixture launch failure")
                process = original(*args, **kwargs)
                return process

            with patch.object(gates.subprocess, "Popen", side_effect=launch):
                with self.assertRaisesRegex(OSError, "Fixture launch failure"):
                    gates.run_gates(
                        [
                            (
                                "core",
                                [sys.executable, "-c", "import time; time.sleep(60)"],
                            ),
                            ("desktop", [sys.executable, "-c", "pass"]),
                        ],
                        root / "logs",
                    )
            self.assertIsNotNone(process.poll())

    def test_cleanup_reaps_zombies_and_signals_descendants_of_exited_leaders(self):
        """Model Darwin's zombie-only EPERM without hiding live descendants."""

        class Owner:
            def __init__(self, pid, *, exited, descendant=False):
                self.pid = pid
                self.exited = exited
                self.descendant = descendant
                self.reaped = False
                self.signals = []

            def poll(self):
                if self.exited:
                    self.reaped = True
                    return 0
                return None

            def wait(self, timeout):
                assert self.exited
                self.reaped = True
                return 0

        owners = [
            Owner(10001, exited=True),
            Owner(10002, exited=True, descendant=True),
            Owner(10003, exited=False),
        ]
        streams = []

        def launch(*args, **kwargs):
            streams.append(kwargs["stdout"])
            if len(streams) > len(owners):
                raise OSError("Fixture launch failure")
            return owners[len(streams) - 1]

        def signal_group(pid, sig):
            owner = next(owner for owner in owners if owner.pid == pid)
            if owner.exited and not owner.descendant:
                if not owner.reaped:
                    raise PermissionError("Darwin zombie-only process group")
                raise ProcessLookupError("Group has no members")
            owner.signals.append(sig)
            owner.exited = True
            if sig == signal.SIGKILL:
                owner.descendant = False

        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(gates.subprocess, "Popen", side_effect=launch),
                patch.object(gates.os, "killpg", side_effect=signal_group),
            ):
                with self.assertRaisesRegex(OSError, "Fixture launch failure"):
                    gates.run_gates(
                        [(str(i), ["fixture"]) for i in range(4)], Path(directory)
                    )
        self.assertTrue(all(owner.reaped for owner in owners))
        self.assertFalse(any(owner.descendant for owner in owners))
        self.assertEqual(owners[1].signals, [signal.SIGTERM, signal.SIGKILL])
        self.assertIn(signal.SIGTERM, owners[2].signals)
        self.assertTrue(all(stream.closed for stream in streams))

    def test_cleanup_does_not_suppress_real_permission_failure(self):
        owner = unittest.mock.Mock(pid=10001)
        owner.poll.return_value = None
        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.object(gates.sys, "platform", "darwin"),
                patch.object(
                    gates.subprocess,
                    "Popen",
                    side_effect=[owner, OSError("Fixture launch failure")],
                ) as launch,
                patch.object(
                    gates.os, "killpg", side_effect=PermissionError("Live group denied")
                ),
            ):
                with self.assertRaisesRegex(PermissionError, "Live group denied"):
                    gates.run_gates(
                        [("first", ["fixture"]), ("second", ["fixture"])],
                        Path(directory),
                    )
            self.assertTrue(
                all(call.kwargs["stdout"].closed for call in launch.call_args_list)
            )


def test_all_stages_collect_test_failures_and_still_run_compiled_boundary(
    tmp_path, monkeypatch
):
    import json

    tools = tmp_path / "tools"
    tools.mkdir()
    log = tmp_path / "commands.jsonl"
    fake = tools / "fake.py"
    fake.write_text("""import json,os,sys
from pathlib import Path
name=sys.argv[1];phase=os.environ.get('FORESIGHT_BUILD_MODE','service')
with open(os.environ['FIXTURE_LOG'],'a') as f:f.write(json.dumps([name,phase])+'\\n')
print(name+' '+phase+' diagnostics')
raise SystemExit(7 if phase=='test-only' else 0)
""")
    for name in ("build_dart_gates.sh", "build_service_gate.sh"):
        argument = '"$1"' if name == "build_dart_gates.sh" else "service"
        (tools / name).write_text(
            f'#!/bin/bash\nexec "{sys.executable}" "{fake}" {argument}\n'
        )
    monkeypatch.setattr(gates, "ROOT", tmp_path)
    monkeypatch.setattr(gates.shutil, "which", lambda _: "/controlled/tool")
    monkeypatch.setenv("FIXTURE_LOG", str(log))
    monkeypatch.setenv("FORESIGHT_BUILD_MODE", "all")
    assert (
        gates.run_application_gates("macos", tmp_path / "build", sys.executable, "all")
        == 1
    )
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    assert set(map(tuple, commands)) == {
        ("core", "build-only"),
        ("desktop", "build-only"),
        ("core", "test-only"),
        ("desktop", "test-only"),
        ("service", "all"),
    }
    assert commands[-1][0] == "service"
    for phase in ["core-checks", "desktop-checks", "service-checks"]:
        assert (
            "diagnostics"
            in (tmp_path / "test-results/build-gates" / f"{phase}.log").read_text()
        )


def test_failed_build_blocks_its_checks_and_stale_service_but_not_other_gate(
    tmp_path, monkeypatch
):
    import json

    tools = tmp_path / "tools"
    tools.mkdir()
    log = tmp_path / "commands.jsonl"
    fake = tools / "fake.py"
    fake.write_text("""import json,os,sys
name=sys.argv[1];phase=os.environ['FORESIGHT_BUILD_MODE']
with open(os.environ['FIXTURE_LOG'],'a') as f:f.write(json.dumps([name,phase])+'\\n')
print('controlled '+name+' '+phase)
raise SystemExit(17 if name=='core' and phase=='build-only' else 0)
""")
    (tools / "build_dart_gates.sh").write_text(
        f'#!/bin/bash\nexec "{sys.executable}" "{fake}" "$1"\n'
    )
    (tools / "build_service_gate.sh").write_text("exit 99\n")
    monkeypatch.setattr(gates, "ROOT", tmp_path)
    monkeypatch.setattr(gates.shutil, "which", lambda _: "/controlled/tool")
    monkeypatch.setenv("FIXTURE_LOG", str(log))
    monkeypatch.setenv("FORESIGHT_BUILD_MODE", "all")
    assert (
        gates.run_application_gates(
            "linux", tmp_path / "build", sys.executable, "all", sequential=True
        )
        == 1
    )
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    assert commands == [
        ["core", "build-only"],
        ["desktop", "build-only"],
        ["desktop", "test-only"],
    ]
    assert not (tmp_path / "test-results/build-gates/service-checks.log").exists()
