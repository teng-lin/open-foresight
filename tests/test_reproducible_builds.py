"""Supply-chain gates must reject tampering even with optimized Python."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]


class OptimizedVerificationTests(unittest.TestCase):
    def test_installed_smoke_rejects_tampering_under_optimization(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "installed-runtime"
            path.write_bytes(b"expected")
            code = f"""import runpy
from pathlib import Path
verify = runpy.run_path({str(ROOT / "packaging/smoke_installed.py")!r})['verify_sha256']
verify(Path({str(path)!r}), {hashlib.sha256(b"expected").hexdigest()!r})
"""
            accepted = subprocess.run(
                [sys.executable, "-O", "-c", code],
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            path.write_bytes(b"tampered")
            result = subprocess.run(
                [sys.executable, "-O", "-c", code],
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA256 checksum mismatch", result.stderr)

    def test_live_speech_rejects_tampering_before_launch_under_optimization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / "speech.bin"
            model.write_bytes(b"tampered")
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "speech": {
                            "model": str(model),
                            "sha256": hashlib.sha256(b"expected").hexdigest(),
                            "runtime": "unused",
                        }
                    }
                )
            )
            result = subprocess.run(
                [
                    sys.executable,
                    "-O",
                    str(ROOT / "tools/test_live_transcription_gap.py"),
                    "--manifest",
                    str(manifest),
                    "--report",
                    str(root / "report.json"),
                    "--log",
                    str(root / "flutter.log"),
                    "--flutter",
                    "must-not-execute-flutter",
                ],
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Speech model checksum mismatch", result.stderr)
            self.assertFalse((root / "flutter.log").exists())

    def test_package_rejects_corrupt_litert_under_optimization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build, flutter = root / "build", root / "flutter"
            flutter.mkdir()
            for name in (
                "services/helper/ForesightHelper",
                "native/libforesight_native.so",
                "application/foresight-service",
                "application/foresight-mcp",
                "services/inference/foresight-model",
                "lib/liblitert-lm.so",
            ):
                path = build / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"tampered")
            code = f"""import sys
sys.path.insert(0, {str(ROOT / "tools")!r})
import package
package.LIBRARY_SHA256 = {hashlib.sha256(b"expected").hexdigest()!r}
package.main()
"""
            result = subprocess.run(
                [
                    sys.executable,
                    "-O",
                    "-c",
                    code,
                    "--build",
                    str(build),
                    "--flutter-bundle",
                    str(flutter),
                    "--output",
                    str(root / "dist"),
                    "--litert-library",
                    str(build / "lib/liblitert-lm.so"),
                    "--revision",
                    "a" * 40,
                ],
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Native LiteRT-LM library checksum mismatch", result.stderr)
            self.assertFalse((root / "dist").exists())

    def test_descriptor_rejects_altered_identity_under_optimization(self):
        code = f"""import sys
sys.path.insert(0, {str(ROOT / "tools")!r})
import verify_descriptor
verify_descriptor.PACKAGE = 'tampered.package'
verify_descriptor.verify('must-not-execute-protoc')
"""
        result = subprocess.run(
            [sys.executable, "-O", "-c", code],
            capture_output=True,
            text=True,
            timeout=300,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Validation failed: recovered.package == PACKAGE", result.stderr)
        self.assertNotIn("FileNotFoundError", result.stderr)


class BuildPolicyTests(unittest.TestCase):
    def test_macos_runtime_checks_versions_from_the_hashed_lock(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import package_macos

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "bin").mkdir()
            (source / "bin/python3").touch()
            checked = {}

            def query(*args):
                if "sys.base_prefix" in args[3]:
                    return json.dumps([str(source), str(source / "lib")])
                checked.update(dict.fromkeys(args[4:]))
                # Stop after the metadata check; no macOS runtime is needed.
                return json.dumps([[3, 12], {}])

            with patch.object(package_macos, "run", side_effect=query):
                with self.assertRaisesRegex(ValueError, "Use Python 3.13"):
                    package_macos.copy_python(source, source / "resources", {})
            self.assertIn("litert-lm", checked)
            self.assertIn("numpy", checked)
            self.assertTrue(
                all(re.fullmatch(r"[A-Za-z0-9_.-]+", name) for name in checked)
            )

    def test_every_python_lock_requirement_has_hashes(self):
        for path in ROOT.glob("requirements-*.lock"):
            text = re.sub(r"\\\n\s*", " ", path.read_text())
            requirements = [
                line
                for line in text.splitlines()
                if line.strip() and not line.lstrip().startswith("#")
            ]
            self.assertTrue(requirements, path)
            for requirement in requirements:
                self.assertRegex(
                    requirement, r"^\S+==\S+ .*--hash=sha256:[0-9a-f]{64}", str(path)
                )

    def test_quality_jobs_install_only_hashed_locks(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/quality.yml").read_text())
        for name, lock in (
            ("python", "requirements-dev.lock"),
            ("format", "requirements-format.lock"),
        ):
            steps = workflow["jobs"][name]["steps"]
            installs = [
                step["run"] for step in steps if "pip install" in step.get("run", "")
            ]
            self.assertEqual(
                installs, [f"python -m pip install --require-hashes -r {lock}"]
            )

    def test_publication_jobs_are_unreachable_from_pull_requests(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            workflow = yaml.safe_load(path.read_text())
            jobs = workflow.get("jobs", {})
            for name, job in jobs.items():
                if job.get("permissions", {}).get("packages") == "write":
                    self.assertTrue(
                        "github.event_name != 'pull_request'" in job.get("if", "")
                        or "github.ref == 'refs/heads/main'" in job.get("if", ""),
                        f"{path.name}: {name} can publish PR packages",
                    )
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/ci-dependencies.yml").read_text()
        )
        validation = workflow["jobs"]["linux-pr"]
        self.assertEqual(validation["permissions"], {"contents": "read"})
        self.assertEqual(validation["if"], "github.event_name == 'pull_request'")
        commands = "\n".join(step.get("run", "") for step in validation["steps"])
        self.assertNotIn("--push", commands)
        self.assertIn("tools/build_linux_sdk_local.sh", commands)
        local_build = (ROOT / "tools/build_linux_sdk_local.sh").read_text()
        self.assertNotIn("--push", local_build)
        for component in ("sdk-core", "sdk-litert", "sdk-whisper", "sdk"):
            self.assertIn(f"packaging/{component}.Dockerfile", local_build)

    def test_monthly_builds_bypass_descriptor_and_layer_caches(self):
        text = (ROOT / ".github/workflows/ci-dependencies.yml").read_text()
        workflow = yaml.safe_load(text)
        for name in ("core", "litert", "whisper", "sdk"):
            job = workflow["jobs"][name]
            reuse = next(step for step in job["steps"] if step.get("id") == "shared")
            self.assertEqual(reuse["if"], "github.event_name != 'schedule'")
            build = next(
                step for step in job["steps"] if step.get("with", {}).get("push")
            )
            self.assertEqual(
                build["with"]["no-cache"], "${{ github.event_name == 'schedule' }}"
            )
            tag = next(step for step in job["steps"] if step.get("id") == "tag")["run"]
            self.assertIn("refresh-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT", tag)

    def test_pr_consumers_can_use_unpublished_dependency_changes(self):
        for name, job in (
            ("integration-acceptance.yml", "linux"),
            ("linux-packages.yml", "ubuntu-package"),
        ):
            with self.subTest(workflow=name):
                workflow = yaml.safe_load(
                    (ROOT / ".github/workflows" / name).read_text()
                )
                steps = workflow["jobs"][job]["steps"]
                resolve = next(step for step in steps if step.get("id") == "sdk")["run"]
                self.assertIn("tools/build_linux_sdk_local.sh", resolve)
                self.assertIn("image=foresight-sdk:pr", resolve)
                self.assertIn("--optional", resolve)
                self.assertIn('test "$task_result" = 4', resolve)
                driver = next(
                    step
                    for step in steps
                    if "docker/setup-buildx-action@" in step.get("uses", "")
                )
                self.assertEqual(
                    driver["with"]["driver"],
                    "${{ steps.sdk.outputs.cache && 'docker-container' || 'docker' }}",
                )
                build = next(
                    step
                    for step in steps
                    if "docker/build-push-action@" in step.get("uses", "")
                )
                self.assertIn("|| ''", build["with"]["cache-from"])

    def test_dart_auth_and_model_revisions_are_pinned(self):
        auth = [
            yaml.safe_load((ROOT / name / "pubspec.lock").read_text())["packages"][
                "googleapis_auth"
            ]
            for name in ("apps/desktop", "packages/foresight_core")
        ]
        self.assertEqual(auth[0], auth[1])
        registry = json.loads((ROOT / "native/model_registry.json").read_text())
        for kind in ("generation", "speech"):
            self.assertRegex(registry[kind]["download"], r"/resolve/[a-f0-9]{40}/")
            self.assertRegex(registry[kind]["runtime_revision"], r"^[a-f0-9]{40}$")


if __name__ == "__main__":
    unittest.main()
