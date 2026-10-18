"""Exercise dependency invalidation, artifact provenance and promotion failures."""

import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tools import ci_artifacts as artifacts
from tools import ci_changes as changes
from tools import ci_registry as registry


class FingerprintTests(unittest.TestCase):
    def test_litert_change_does_not_invalidate_core_or_whisper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for files in artifacts.FILES.values():
                for name in files:
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(name)
            before = {
                name: artifacts.fingerprint(name, root) for name in artifacts.FILES
            }
            (root / "tools/build_litert_extensions.py").write_text("new LiteRT recipe")
            after = {
                name: artifacts.fingerprint(name, root) for name in artifacts.FILES
            }
            self.assertEqual(before["linux-core"], after["linux-core"])
            self.assertEqual(before["linux-whisper"], after["linux-whisper"])
            self.assertNotEqual(before["linux-litert"], after["linux-litert"])
            self.assertNotEqual(before["linux-sdk"], after["linux-sdk"])
            self.assertNotEqual(before["macos-runtime"], after["macos-runtime"])
            self.assertEqual(before["macos-sdk"], after["macos-sdk"])
            (root / "requirements-dev.lock").write_text("new toolchain dependencies")
            for name in ("linux-core", "linux-litert", "linux-whisper", "linux-sdk"):
                self.assertNotEqual(after[name], artifacts.fingerprint(name, root))


class ArchiveTests(unittest.TestCase):
    def test_relocated_prefix_preserves_executable_and_relative_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            executable = source / "tool"
            executable.write_text("#!/bin/sh\necho relocated\n")
            executable.chmod(0o755)
            (source / "alias").symlink_to("tool")
            artifacts.pack("macos-sdk", "a" * 64, source, root / "upload")
            artifacts.unpack("macos-sdk", "a" * 64, root / "upload", root / "restored")
            self.assertTrue((root / "restored/alias").is_symlink())
            self.assertEqual(
                subprocess.check_output(
                    [root / "restored/alias"], text=True, timeout=300
                ),
                "relocated\n",
            )
            with self.assertRaisesRegex(ValueError, "already exists"):
                artifacts.unpack(
                    "macos-sdk", "a" * 64, root / "upload", root / "restored"
                )

    def test_tampering_wrong_identity_and_escape_fail_without_installing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            artifacts.pack("macos-sdk", "a" * 64, source, root / "upload")
            with self.assertRaisesRegex(ValueError, "identity mismatch"):
                artifacts.unpack(
                    "macos-sdk", "b" * 64, root / "upload", root / "destination"
                )
            archive = root / "upload/payload.tar.gz"
            archive.write_bytes(b"corrupt")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                artifacts.unpack(
                    "macos-sdk", "a" * 64, root / "upload", root / "destination"
                )
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("payload/../../escape")
                member.size = 3
                stream.addfile(member, io.BytesIO(b"bad"))
            record = json.loads((root / "upload/identity.json").read_text())
            record["sha256"] = artifacts.digest(archive)
            (root / "upload/identity.json").write_text(json.dumps(record))
            with self.assertRaises(tarfile.FilterError):
                artifacts.unpack(
                    "macos-sdk", "a" * 64, root / "upload", root / "destination"
                )
            self.assertFalse((root / "destination").exists())
            self.assertFalse((root / "escape").exists())


class ProvenanceTests(unittest.TestCase):
    def run_record(self, **kwargs):
        return {
            "id": 123,
            "path": ".github/workflows/ci-dependencies.yml",
            "event": "push",
            "head_branch": "main",
            "head_sha": "a" * 40,
            "conclusion": None,
            "head_repository": {"full_name": "teng-lin/open-foresight"},
            **kwargs,
        }

    def test_only_qualified_repository_and_workflow_are_trusted(self):
        run = self.run_record()
        self.assertTrue(artifacts.trusted_run(run, "macos-sdk"))
        for change in (
            {"head_repository": {"full_name": "other/fork"}},
            {"path": ".github/workflows/unrelated.yml"},
            {"event": "pull_request_target"},
            {"head_branch": "unreviewed"},
        ):
            self.assertFalse(artifacts.trusted_run({**run, **change}, "macos-sdk"))
        pr = self.run_record(
            event="pull_request", head_branch="feature", pull_requests=[{"number": 23}]
        )
        self.assertTrue(artifacts.trusted_run(pr, "macos-sdk", own_pr=23))
        self.assertFalse(artifacts.trusted_run(pr, "macos-sdk", own_pr=24))
        manual = self.run_record(event="workflow_dispatch", head_branch="feature")
        self.assertTrue(artifacts.trusted_run(manual, "macos-sdk", own_head="a" * 40))
        self.assertFalse(artifacts.trusted_run(manual, "macos-sdk", own_head="b" * 40))

    def test_candidates_require_successful_main_workflow(self):
        run = self.run_record(path=".github/workflows/macos.yml", conclusion="success")
        self.assertTrue(artifacts.trusted_run(run, "macos-app"))
        for change in (
            {"conclusion": None},
            {"conclusion": "failure"},
            {"head_branch": "feature"},
            {"event": "pull_request"},
        ):
            self.assertFalse(artifacts.trusted_run({**run, **change}, "macos-app"))

    def test_merged_source_must_be_reachable_from_main(self):
        for status, expected in [
            ("ahead", True),
            ("identical", True),
            ("behind", False),
            ("diverged", False),
        ]:
            with patch.object(artifacts, "api", return_value={"status": status}):
                self.assertEqual(
                    artifacts.merged_source(
                        "teng-lin/open-foresight", self.run_record()
                    ),
                    expected,
                )

    def test_partial_run_can_supply_completed_dependency_but_not_failed_job(self):
        for conclusion, expected in [
            ("success", True),
            ("failure", False),
            (None, False),
        ]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prefix = root / "original"
                prefix.mkdir()
                artifacts.pack("macos-sdk", "a" * 64, prefix, root / "upload")
                run = self.run_record()
                listed = {
                    "artifacts": [
                        {
                            "id": 5,
                            "name": artifacts.name("macos-sdk", "a" * 64),
                            "expired": False,
                            "workflow_run": {"id": 123},
                        }
                    ]
                }

                def api(repo, route):
                    if route.startswith("actions/artifacts?"):
                        return listed  # noqa: B023 - Fixture callbacks are consumed within this iteration.
                    if route.endswith("/jobs?per_page=100"):
                        return {
                            "jobs": [
                                {"name": "Build macOS sdk", "conclusion": conclusion}  # noqa: B023 - Fixture callbacks are consumed within this iteration.
                            ]
                        }
                    return run  # noqa: B023 - Fixture callbacks are consumed within this iteration.

                def download(args, stdout, check, timeout):
                    with zipfile.ZipFile(stdout, "w") as archive:
                        for name in ("identity.json", "payload.tar.gz"):
                            archive.write(root / "upload" / name, name)  # noqa: B023 - Fixture callbacks are consumed within this iteration.

                with (
                    patch.object(artifacts, "api", side_effect=api),
                    patch.object(artifacts.subprocess, "run", side_effect=download),
                ):
                    self.assertEqual(
                        artifacts.pull(
                            "teng-lin/open-foresight",
                            "macos-sdk",
                            "a" * 64,
                            root / "restored",
                        ),
                        expected,
                    )
                    self.assertEqual((root / "restored").exists(), expected)

    def test_release_rejects_candidate_for_another_commit(self):
        run = self.run_record(
            path=".github/workflows/macos.yml", conclusion="success", head_sha="b" * 40
        )
        listed = {
            "artifacts": [
                {
                    "id": 5,
                    "name": artifacts.name("macos-app", "a" * 40),
                    "expired": False,
                    "workflow_run": {"id": 123},
                }
            ]
        }
        with (
            patch.object(artifacts, "api", side_effect=[listed, run]),
            patch.object(artifacts.subprocess, "run") as download,
        ):
            self.assertFalse(
                artifacts.pull(
                    "teng-lin/open-foresight", "macos-app", "a" * 40, Path("/unused")
                )
            )
            download.assert_not_called()


class SelectionTests(unittest.TestCase):
    def test_documentation_only_selection(self):
        self.assertFalse(
            changes.requires_build(["README.md", "docs/platforms/ci-performance.md"])
        )
        self.assertFalse(changes.requires_build([]))
        for path in (
            "tools/build_macos_sdk.py",
            ".github/workflows/macos.yml",
            "requirements-dev.lock",
            "LICENSE",
        ):
            self.assertTrue(changes.requires_build(["README.md", path]))

    def test_selected_skipped_or_failed_jobs_cannot_pass(self):
        for build, main in ((False, True), (True, False), (True, True)):
            jobs = {
                name: {"result": value}
                for name, value in {
                    "changes": "success",
                    "macos": "success" if build else "skipped",
                    "linux-native": "success" if build else "skipped",
                    "linux-bundle": "success" if build and main else "skipped",
                }.items()
            }
            changes.check_gates(jobs, build, main)
            for name in jobs:
                for result in ("cancelled", "failure", "skipped"):
                    if result != jobs[name]["result"]:
                        with self.assertRaises(ValueError):
                            changes.check_gates(
                                {**jobs, name: {"result": result}}, build, main
                            )


class RegistryTests(unittest.TestCase):
    def test_only_missing_tags_allow_build(self):
        image = "ghcr.io/teng-lin/open-foresight/linux-core:key"
        for error in ("manifest unknown", image + ": not found"):
            with patch.object(
                registry.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 1, "", error),
            ):
                self.assertIsNone(registry.inspect(image))
                with self.assertRaises(RuntimeError):
                    registry.inspect(image.split(":")[0] + "@sha256:" + "a" * 64)
        for error in (
            "unauthorized: manifest unknown",
            "403 forbidden",
            "connection reset",
            "timeout",
            "credential helper not found",
            "proxy returned HTTP 404",
        ):
            with patch.object(
                registry.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 1, "", error),
            ):
                with self.assertRaises(RuntimeError):
                    registry.inspect(image)
        for reference in (image, image.split(":")[0] + "@sha256:" + "b" * 64):
            with patch.object(
                registry.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    [], 0, json.dumps({"digest": "sha256:" + "a" * 64}), ""
                ),
            ):
                self.assertEqual(
                    registry.inspect(reference),
                    image.split(":")[0] + "@sha256:" + "a" * 64,
                )


if __name__ == "__main__":
    unittest.main()
