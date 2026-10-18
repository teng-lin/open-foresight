"""Installer transaction and MCP transport tests; no release/signing claims."""

import json
import os
import shutil
import subprocess
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_macos_sdk as sdk
import install_macos as installer
import test_gemma_models as gemma_probe
from smoke_macos_bundle import (
    McpPeer,
    stop_desktop,
    parser_probe,
    source_graph_probe,
    verify_source_graph_restart,
    service_command,
    wait_stopped,
)

SIGNATURE = {"team": "test-team", "adhoc": False}


class MacModelProbeTests(unittest.TestCase):
    def test_default_embedding_worker_is_rejected_as_generation_runner(self):
        with (
            patch.object(sys, "platform", "darwin"),
            patch.object(sys, "argv", ["test_gemma_models.py"]),
            patch.object(gemma_probe.subprocess, "run") as run,
            patch("sys.stderr") as stderr,
        ):
            with self.assertRaises(SystemExit) as error:
                gemma_probe.main()
            self.assertEqual(error.exception.code, 2)
            self.assertIn("LiteRT generation runner", str(stderr.write.call_args_list))
            run.assert_not_called()

    def test_bundle_missing_generation_or_python_entries_reports_setup_error(self):
        keys = (
            "FORESIGHT_NATIVE",
            "FORESIGHT_HELPER",
            "FORESIGHT_LITERT_RUNNER",
            "FORESIGHT_MODEL_WORKER",
            "FORESIGHT_LITERT_EMBEDDING_ADAPTER",
            "FORESIGHT_MODEL_PYTHON",
            "FORESIGHT_LITERT_PYTHON",
        )
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Open Foresight.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            for missing in (
                "FORESIGHT_LITERT_RUNNER",
                "FORESIGHT_MODEL_PYTHON",
                "FORESIGHT_LITERT_PYTHON",
            ):
                with self.subTest(missing=missing):
                    (resources / "runtime.json").write_text(
                        json.dumps(
                            {key: "runtime/" + key for key in keys if key != missing}
                        )
                    )
                    with (
                        patch.object(sys, "platform", "darwin"),
                        patch.object(sys, "argv", ["probe", "--bundle", str(app)]),
                        patch.object(gemma_probe.subprocess, "run") as run,
                        patch("sys.stderr") as stderr,
                    ):
                        with self.assertRaises(SystemExit) as error:
                            gemma_probe.main()
                        self.assertEqual(error.exception.code, 2)
                        self.assertIn(missing, str(stderr.write.call_args_list))
                        run.assert_not_called()

    def test_explicit_generation_runner_keeps_separate_embedding_worker(self):
        with tempfile.TemporaryDirectory(prefix="model probe ") as temporary:
            runner = Path(temporary) / "generation runner"
            with (
                patch.object(sys, "platform", "darwin"),
                patch.object(
                    sys,
                    "argv",
                    [
                        "probe",
                        "--runner",
                        str(runner),
                        "--report",
                        temporary + "/report.json",
                    ],
                ),
                patch.object(gemma_probe.subprocess, "run") as run,
            ):
                gemma_probe.main()
                env = run.call_args.kwargs["env"]
                self.assertEqual(env["FORESIGHT_LITERT_RUNNER"], str(runner.resolve()))
                self.assertEqual(
                    env["FORESIGHT_MODEL_WORKER"],
                    str(gemma_probe.ROOT / "build/services/inference/foresight-model"),
                )


class MacModelWorkerTests(unittest.TestCase):
    def test_worker_dispatch_preserves_relocated_paths_and_gpu_argument(self):
        with tempfile.TemporaryDirectory(prefix="mac worker ") as temporary:
            root = Path(temporary)
            worker = root / "foresight-model"
            shutil.copy2(
                Path(__file__).resolve().parents[1]
                / "services/inference/macos/foresight-model",
                worker,
            )
            python = root / "selected python"
            python.write_text(
                "#!"
                + sys.executable
                + "\nimport json,sys; print(json.dumps(sys.argv[1:]))\n"
            )
            python.chmod(0o755)
            model = root / "embedding model.litertlm"
            model.touch()
            directory = root / "model directory"
            directory.mkdir()
            env = {**os.environ, "FORESIGHT_LITERT_PYTHON": str(python)}
            env.pop("FORESIGHT_LITERT_EMBEDDING_ADAPTER", None)
            actual = json.loads(
                subprocess.check_output(
                    [str(worker), "--embedding", str(model), "--gpu"],
                    env=env,
                    cwd="/",
                    text=True,
                    timeout=300,
                )
            )
            self.assertEqual(
                actual,
                [
                    "-I",
                    "-B",
                    str(root / "litert_embedding_adapter.py"),
                    str(model),
                    "--gpu",
                ],
            )
            for asset in (directory, root / "wrong-format.bin"):
                result = subprocess.run(
                    [str(worker), "--embedding", str(asset)],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("Unsupported model format", result.stderr)
            invalid = subprocess.run(
                [str(worker), "--invalid"], capture_output=True, timeout=300
            )
            self.assertEqual(invalid.returncode, 2)


def bundle(path, version, identifier=installer.IDENTIFIER):
    (path / "Contents").mkdir(parents=True)
    with (path / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": identifier}, stream)
    (path / "version").write_text(version)
    return path


def portable_swap(first, second):
    # Test transaction logic on Linux too; production uses one Darwin RENAME_SWAP.
    temporary = first.parent / "swap-backup"
    os.replace(first, temporary)
    os.replace(second, first)
    os.replace(temporary, second)


class SdkSourceTests(unittest.TestCase):
    def test_fresh_pinned_checkout_without_a_head(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "origin"
            repository.mkdir()

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(repository), *args],
                    text=True,
                    stderr=subprocess.DEVNULL,
                    timeout=300,
                ).strip()

            git("init")
            (repository / "source.c").write_text("pinned")
            git("add", "source.c")
            git(
                "-c",
                "user.name=SDK test",
                "-c",
                "user.email=sdk@example.invalid",
                "commit",
                "-m",
                "Pinned source",
            )
            commit = git("rev-parse", "HEAD")
            destination = root / "fresh"
            sdk.checkout(destination, str(repository), commit)
            self.assertEqual((destination / "source.c").read_text(), "pinned")
            sdk.require_clean_sources(destination)

    def test_pinned_checkout_rejects_staged_and_unstaged_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-C", str(root), *args],
                    text=True,
                    stderr=subprocess.DEVNULL,
                    timeout=300,
                ).strip()

            git("init")
            git("remote", "add", "origin", "https://example.invalid/sdk.git")
            source = root / "source.c"
            source.write_text("original")
            git("add", "source.c")
            git(
                "-c",
                "user.name=SDK test",
                "-c",
                "user.email=sdk@example.invalid",
                "commit",
                "-m",
                "Pinned source",
            )
            commit = git("rev-parse", "HEAD")
            for staged in (False, True):
                with self.subTest(staged=staged):
                    git("reset", "--hard", "HEAD")
                    source.write_text("modified")
                    if staged:
                        git("add", "source.c")
                    with self.assertRaisesRegex(ValueError, "modified SDK sources"):
                        sdk.checkout(root, "https://example.invalid/sdk.git", commit)
                    with self.assertRaisesRegex(ValueError, "modified SDK sources"):
                        sdk.require_clean_sources(root)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = bundle(self.root / "Source.app", "new")
        self.destination = bundle(self.root / "Installed.app", "old")
        self.options = {
            "verify": lambda _: SIGNATURE,
            "active": lambda _: {},
            "swap": portable_swap,
        }

    def tearDown(self):
        self.temporary.cleanup()
        shutil.rmtree(
            installer.installation_lock_path(self.destination).parent,
            ignore_errors=True,
        )

    def test_foreign_application_is_never_replaced(self):
        with (self.destination / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.google.foresight"}, stream)
        with self.assertRaisesRegex(ValueError, "different application"):
            installer.install(self.source, self.destination, **self.options)
        self.assertEqual((self.destination / "version").read_text(), "old")

    def test_live_process_defers_without_modifying_bundle(self):
        self.options["active"] = lambda _: {42: "/installed/service"}
        with self.assertRaises(installer.Deferred):
            installer.install(self.source, self.destination, **self.options)
        self.assertEqual((self.destination / "version").read_text(), "old")
        self.assertEqual(list(self.root.glob(".open-foresight-install-*")), [])

    def test_upgrade_stages_swaps_and_preserves_source(self):
        result = installer.install(self.source, self.destination, **self.options)
        self.assertTrue(result["upgraded"])
        self.assertEqual((self.destination / "version").read_text(), "new")
        self.assertEqual((self.source / "version").read_text(), "new")
        self.assertEqual(list(self.root.glob(".open-foresight-install-*")), [])

    def test_staged_signature_failure_preserves_old_app(self):
        def verify(path):
            if path.parent.name.startswith(".open-foresight-install-"):
                raise ValueError("corrupted staging signature")
            return SIGNATURE

        self.options["verify"] = verify
        with self.assertRaisesRegex(ValueError, "corrupted staging"):
            installer.install(self.source, self.destination, **self.options)
        self.assertEqual((self.destination / "version").read_text(), "old")

    def test_post_swap_signature_failure_rolls_back(self):
        def verify(path):
            if path == self.destination and (path / "version").read_text() == "new":
                raise ValueError("post-swap failure")
            return SIGNATURE

        self.options["verify"] = verify
        with self.assertRaisesRegex(ValueError, "post-swap"):
            installer.install(self.source, self.destination, **self.options)
        self.assertEqual((self.destination / "version").read_text(), "old")

    def test_failed_rollback_retains_old_bundle_for_recovery(self):
        def verify(path):
            if path == self.destination and (path / "version").read_text() == "new":
                raise ValueError("post-swap failure")
            return SIGNATURE

        swaps = []

        def swap(first, second):
            swaps.append((first, second))
            if len(swaps) > 1:
                raise OSError("rollback disk failure")
            portable_swap(first, second)

        self.options.update(verify=verify, swap=swap)
        with self.assertRaisesRegex(RuntimeError, "preserved recovery bundle"):
            installer.install(self.source, self.destination, **self.options)
        recovery = list(self.root.glob(".open-foresight-install-*/Installed.app"))
        self.assertEqual(len(recovery), 1)
        self.assertEqual((recovery[0] / "version").read_text(), "old")

    def test_running_app_during_staging_defers(self):
        self.options["active"] = Mock(
            side_effect=[{}, {}, {43: "newly launched service"}]
        )
        with self.assertRaisesRegex(installer.Deferred, "while staging"):
            installer.install(self.source, self.destination, **self.options)
        self.assertEqual((self.destination / "version").read_text(), "old")

    def test_explicit_stop_requires_no_remaining_processes(self):
        stopper = Mock()
        self.options.update(
            active=Mock(side_effect=[{42: "service"}, {}, {}, {}]), stopper=stopper
        )
        installer.install(
            self.source,
            self.destination,
            stop_services=True,
            profiles=["profile"],
            **self.options,
        )
        stopper.assert_called_once_with(self.destination, {42: "service"}, ["profile"])

    def lock_attempt(self, exclusive):
        code = """import sys
from install_macos import installation_lock,Deferred
try:
 with installation_lock(sys.argv[1],exclusive=sys.argv[2]=='true'):
  print('acquired')
except Deferred:
 print('deferred')
 sys.exit(3)
"""
        return subprocess.run(
            [
                sys.executable,
                "-c",
                code,
                str(self.destination),
                "true" if exclusive else "false",
            ],
            env={**os.environ, "PYTHONPATH": str(Path(installer.__file__).parent)},
            capture_output=True,
            text=True,
            timeout=300,
        )

    def test_live_service_shared_lock_defers_concurrent_installer_subprocess(self):
        with installer.installation_lock(self.destination, exclusive=False):
            outcome = self.lock_attempt(True)
            self.assertEqual(outcome.returncode, 3, outcome.stderr)
            self.assertEqual(outcome.stdout.strip(), "deferred")
            # Independent profiles can concurrently hold shared service locks.
            self.assertEqual(self.lock_attempt(False).returncode, 0)
        self.assertEqual(self.lock_attempt(True).returncode, 0)

    def test_installer_exclusive_lock_blocks_new_service_subprocess(self):
        with installer.installation_lock(self.destination):
            self.assertEqual(self.lock_attempt(False).returncode, 3)
            self.assertEqual(self.lock_attempt(True).returncode, 3)
        self.assertEqual(self.lock_attempt(False).returncode, 0)

    def test_lock_rejects_symlink_and_public_mode(self):
        path = installer.installation_lock_path(self.destination)
        path.parent.mkdir(mode=0o700)
        other = self.root / "unrelated"
        other.write_text("preserve")
        path.symlink_to(other)
        with self.assertRaises(OSError):
            with installer.installation_lock(self.destination):
                pass
        self.assertEqual(other.read_text(), "preserve")
        path.unlink()
        path.parent.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "private"):
            with installer.installation_lock(self.destination):
                pass
        path.parent.chmod(0o700)

    def test_signature_team_cannot_change_during_upgrade(self):
        self.options["verify"] = lambda path: dict(
            SIGNATURE, team="foreign" if path == self.destination else "test-team"
        )
        with self.assertRaisesRegex(ValueError, "signing team"):
            installer.install(self.source, self.destination, **self.options)
        self.assertEqual((self.destination / "version").read_text(), "old")

    def test_profile_reporting_arbitrary_pid_is_never_stopped(self):
        executable = (self.destination / installer.SERVICE).resolve()
        response = SimpleNamespace(
            returncode=0, stdout=json.dumps({"pid": 999}), stderr=""
        )
        with patch.object(installer.subprocess, "run", return_value=response) as run:
            with self.assertRaisesRegex(installer.Deferred, "not owned"):
                installer.stop_owned_services(
                    self.destination, {42: str(executable)}, ["profile"]
                )
        self.assertEqual(
            [call.args[0][-1] for call in run.call_args_list], ["--status"]
        )

    def test_recording_upgrade_defers_before_stopping_any_profile(self):
        executable = (self.destination / installer.SERVICE).resolve()
        responses = [
            SimpleNamespace(
                returncode=0,
                stdout=json.dumps({"pid": 42, "capture": {"active": False}}),
                stderr="",
            ),
            SimpleNamespace(
                returncode=0,
                stdout=json.dumps({"pid": 43, "capture": {"active": True}}),
                stderr="",
            ),
        ]
        with (
            patch.object(installer.subprocess, "run", side_effect=responses) as run,
            patch.object(installer, "process_path", return_value=executable),
        ):
            with self.assertRaisesRegex(installer.Deferred, "final transcript"):
                installer.stop_owned_services(
                    self.destination,
                    {42: str(executable), 43: str(executable)},
                    ["first", "recording"],
                )
        self.assertEqual(
            [call.args[0][-1] for call in run.call_args_list], ["--status", "--status"]
        )
        self.assertEqual((self.destination / "version").read_text(), "old")

    def test_idle_shutdown_acknowledgement_is_mandatory_and_recording_race_defers(self):
        executable = (self.destination / installer.SERVICE).resolve()
        status = SimpleNamespace(
            returncode=0,
            stdout=json.dumps({"pid": 42, "capture": {"active": False}}),
            stderr="",
        )
        for response in [
            SimpleNamespace(returncode=1, stdout="", stderr="Recording became active"),
            SimpleNamespace(returncode=0, stdout="", stderr=""),
            SimpleNamespace(
                returncode=0, stdout=json.dumps({"stopped": True}), stderr=""
            ),
            SimpleNamespace(
                returncode=2, stdout="", stderr="Unsupported --stop-if-idle"
            ),
        ]:
            with (
                self.subTest(response=response),
                patch.object(
                    installer.subprocess, "run", side_effect=[status, response]
                ) as run,
                patch.object(
                    installer.subprocess, "check_output", return_value="42 1\n"
                ),
                patch.object(installer, "process_path", return_value=executable),
            ):
                with self.assertRaises(installer.Deferred):
                    installer.stop_owned_services(
                        self.destination, {42: str(executable)}, ["profile"]
                    )
                self.assertEqual(
                    [call.args[0][-1] for call in run.call_args_list],
                    ["--status", "--stop-if-idle=42"],
                )
                self.assertEqual((self.destination / "version").read_text(), "old")

    def test_verified_idle_shutdown_waits_for_owned_process_exit(self):
        executable = (self.destination / installer.SERVICE).resolve()
        status = SimpleNamespace(
            returncode=0,
            stdout=json.dumps({"pid": 42, "capture": {"active": False}}),
            stderr="",
        )
        acknowledgement = SimpleNamespace(
            returncode=0,
            stdout=json.dumps({"stopped": True, "shutdown_verified": True}),
            stderr="",
        )
        with (
            patch.object(
                installer.subprocess, "run", side_effect=[status, acknowledgement]
            ) as run,
            patch.object(installer.subprocess, "check_output", return_value="42 1\n"),
            patch.object(
                installer,
                "process_path",
                side_effect=[executable, executable, None, None],
            ),
        ):
            installer.stop_owned_services(
                self.destination, {42: str(executable)}, ["profile"]
            )
        self.assertEqual(
            [call.args[0][-1] for call in run.call_args_list],
            ["--status", "--stop-if-idle=42"],
        )

    def test_failed_service_shutdown_never_reaches_staging_or_swap(self):
        self.options.update(
            active=lambda _: {42: "service"},
            stopper=Mock(side_effect=subprocess.TimeoutExpired("service --stop", 1800)),
        )
        with self.assertRaises(subprocess.TimeoutExpired):
            installer.install(
                self.source,
                self.destination,
                stop_services=True,
                profiles=["profile"],
                **self.options,
            )
        self.assertEqual((self.destination / "version").read_text(), "old")
        self.assertEqual(list(self.root.glob(".open-foresight-install-*")), [])

    def test_unowned_worker_is_never_treated_as_service_descendant(self):
        executable = (self.destination / installer.SERVICE).resolve()
        response = SimpleNamespace(
            returncode=0, stdout=json.dumps({"pid": 42}), stderr=""
        )
        with (
            patch.object(installer.subprocess, "run", return_value=response) as run,
            patch.object(
                installer.subprocess, "check_output", return_value="42 1\n43 1\n"
            ),
            patch.object(installer, "process_path", return_value=executable),
        ):
            with self.assertRaisesRegex(installer.Deferred, "unrelated worker"):
                installer.stop_owned_services(
                    self.destination,
                    {42: str(executable), 43: str(self.destination / "worker")},
                    ["profile"],
                )
        self.assertEqual(
            [call.args[0][-1] for call in run.call_args_list], ["--status"]
        )

    @unittest.skipUnless(sys.platform == "darwin", "Darwin metadata copy")
    def test_app_copy_preserves_extended_attributes_and_quarantine(self):
        subprocess.run(
            [
                "/usr/bin/xattr",
                "-w",
                "com.openforesight.test",
                "retained",
                str(self.source),
            ],
            check=True,
            timeout=300,
        )
        subprocess.run(
            [
                "/usr/bin/xattr",
                "-w",
                "com.apple.quarantine",
                "0081;12345678;OpenForesightTest;",
                str(self.source),
            ],
            check=True,
            timeout=300,
        )
        copied = self.root / "Copied.app"
        installer.copy_application(self.source, copied)
        self.assertEqual(
            subprocess.check_output(
                ["/usr/bin/xattr", "-p", "com.openforesight.test", str(copied)],
                text=True,
                timeout=300,
            ).strip(),
            "retained",
        )
        quarantine = subprocess.check_output(
            ["/usr/bin/xattr", "-p", "com.apple.quarantine", str(copied)],
            text=True,
            timeout=300,
        ).strip()
        # macOS may normalize provenance/time fields when propagating quarantine.
        self.assertTrue(int(quarantine.split(";")[0], 16) & 1, quarantine)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin atomic exchange")
    def test_real_darwin_atomic_exchange_of_nonempty_apps(self):
        installer.atomic_swap(self.source, self.destination)
        self.assertEqual((self.destination / "version").read_text(), "new")
        self.assertEqual((self.source / "version").read_text(), "old")


class McpTransportTests(unittest.TestCase):
    def runner(self, root, trailing_noise=False):
        path = root / "mcp fixture"
        code = """import sys,json
for line in sys.stdin:
 request=json.loads(line)
 if 'id' in request:
  result={'protocolVersion':'2025-11-25','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}} if request['method']=='initialize' else {'structuredContent':{'result':request['params']['arguments']}}
  print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
"""
        if trailing_noise:
            code += 'print("accidental diagnostic on MCP stdout",flush=True)\n'
        path.write_text("#!" + sys.executable + "\n" + code)
        path.chmod(0o755)
        return path

    def test_real_subprocess_transport_closes_cleanly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peer = McpPeer(self.runner(root), installer.minimal_environment(root))
            self.assertEqual(peer.tool("echo", {"key": "value"}), {"key": "value"})
            peer.close()
            self.assertEqual(peer.process.returncode, 0)

    def test_trailing_stdout_pollution_fails_even_after_successful_reply(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peer = McpPeer(self.runner(root, True), installer.minimal_environment(root))
            self.assertEqual(peer.tool("echo"), {})
            with self.assertRaisesRegex(RuntimeError, "Non-protocol"):
                peer.close()

    def test_owned_desktop_cleanup_reaps_process_ignoring_sigterm(self):
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)",
            ],
            stdout=subprocess.PIPE,
        )
        try:
            self.assertEqual(process.stdout.readline(), b"ready\n")
            self.assertEqual(stop_desktop(process, timeout=0.1), -9)
            self.assertIsNotNone(process.poll())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=30)
            process.stdout.close()

    def test_optimized_python_cannot_skip_smoke_assertions(self):
        result = subprocess.run(
            [
                sys.executable,
                "-O",
                "-c",
                "from smoke_macos_bundle import smoke; smoke(None,None)",
            ],
            env={**os.environ, "PYTHONPATH": str(Path(installer.__file__).parent)},
            capture_output=True,
            text=True,
            timeout=300,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("run Python without -O", result.stderr)

    def test_minimal_environment_has_no_developer_runtime_leaks(self):
        env = installer.minimal_environment("/tmp/home", "/tmp/profile")
        self.assertEqual(set(env), {"HOME", "PATH", "FORESIGHT_DATA"})
        self.assertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")


class CompiledMacComponentTests(unittest.TestCase):
    """Actual executable probes when built components are supplied; no bundle claim."""

    @unittest.skipUnless(sys.platform == "darwin", "macOS executable adapter")
    def test_real_compiled_document_adapter_with_generated_fixtures(self):
        root = Path(__file__).resolve().parents[1]
        executable = Path(
            os.environ.get(
                "FORESIGHT_FILE_PARSER_EXECUTABLE",
                root / "build/macos/foresight-file-parser",
            )
        )
        if not executable.is_file():
            self.skipTest(
                "Build the native file parser or set FORESIGHT_FILE_PARSER_EXECUTABLE"
            )
        with tempfile.TemporaryDirectory(
            prefix="of-parser-test-", dir="/tmp"
        ) as temporary:
            work = Path(temporary)
            app = work / "Probe.app"
            resources = app / "Contents/Resources"
            (resources / "bin").mkdir(parents=True)
            shutil.copy2(executable, resources / "bin/foresight-file-parser")
            (resources / "runtime.json").write_text(
                json.dumps({"FORESIGHT_FILE_PARSER": "bin/foresight-file-parser"})
            )
            result = parser_probe(
                app, work / "fixtures", installer.minimal_environment(work)
            )
            self.assertEqual(result["invalid_documents"], "rejected_with_stderr")
            self.assertEqual(result["fixture_creation"], "stdlib_only_outside_app")

    def test_document_probe_refuses_extractor_outside_relocated_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            app = work / "Probe.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            foreign = work / "foreign-extractor"
            foreign.write_text("not invoked")
            (resources / "runtime.json").write_text(
                json.dumps({"FORESIGHT_FILE_PARSER": str(foreign)})
            )
            with self.assertRaisesRegex(RuntimeError, "not inside"):
                parser_probe(
                    app, work / "fixtures", installer.minimal_environment(work)
                )
            self.assertFalse((work / "fixtures").exists())

    @unittest.skipUnless(sys.platform == "darwin", "macOS AOT component probe")
    def test_real_aot_source_revision_labels_and_graph_survive_service_restart(self):
        root = Path(__file__).resolve().parents[1]
        service = Path(
            os.environ.get(
                "FORESIGHT_SERVICE_EXECUTABLE",
                root / "build/application/foresight-service",
            )
        )
        mcp = Path(
            os.environ.get(
                "FORESIGHT_MCP_EXECUTABLE", root / "build/application/foresight-mcp"
            )
        )
        if not service.is_file() or not mcp.is_file():
            self.skipTest(
                "Build AOT service/MCP or supply FORESIGHT_SERVICE_EXECUTABLE and FORESIGHT_MCP_EXECUTABLE"
            )
        with tempfile.TemporaryDirectory(
            prefix="of-source-test-", dir="/tmp"
        ) as temporary:
            work = Path(temporary)
            env = installer.minimal_environment(work, work / "data")
            env.update(
                FORESIGHT_RUNTIME=str(work / "run"),
                FORESIGHT_SERVICE=str(service),
                FORESIGHT_HELPER="",
            )
            peer = None
            owner = None
            try:
                peer = McpPeer(mcp, env)
                owner = peer.tool("get_status")["pid"]
                evidence = source_graph_probe(
                    work / "run/application.sock", peer, work / "data/application.db"
                )
                peer.close()
                peer = None
                service_command(service, env, "--stop")
                wait_stopped(owner, service)
                owner = None
                peer = McpPeer(mcp, env)
                owner = peer.tool("get_status")["pid"]
                verify_source_graph_restart(
                    peer, work / "data/application.db", evidence
                )
                self.assertEqual(len(evidence["graph_rows"]), 2)
            finally:
                if peer is not None:
                    peer.close()
                if owner is None:
                    try:
                        owner = service_command(service, env, "--status")["pid"]
                    except (subprocess.SubprocessError, ValueError, OSError):
                        pass
                if (
                    owner is not None
                    and installer.process_path(owner) == service.resolve()
                ):
                    service_command(service, env, "--stop")
                    wait_stopped(owner, service)


if __name__ == "__main__":
    unittest.main()
