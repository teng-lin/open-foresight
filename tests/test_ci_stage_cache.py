"""Stage reuse binds real source trees, producer jobs, and immutable artifacts."""

from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tools import ci_stage_cache as cache

REPOSITORY = "teng-lin/open-foresight"
ENVIRONMENT = {
    "compiler": "clang22",
    "runtime": "Dart3.9.2",
    "system": "Ubuntu24.04",
    "sdk": "a" * 64,
}


class SourceTree(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        for path in (
            "native/main.cpp",
            "tools/ci_stage_cache.py",
            ".github/workflows/macos.yml",
            "packages/foresight_core/lib/app.dart",
            "apps/desktop/lib/main.dart",
            "tests/service/contract.dart",
            "tests/test_support/temp.dart",
            "docs/plan.md",
            "requirements-dev.lock",
            "tools/pins.json",
        ):
            self.write(path, "initial\n")
        self.commit = self.save()

    def git(self, *args):
        return (
            subprocess.check_output(
                ["git", *args], cwd=self.root, stderr=subprocess.DEVNULL
            )
            .decode()
            .strip()
        )

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def save(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def key(self, stage="native", ref=None, environment=None, parents=None):
        if parents is None:
            parents = {} if stage == "native" else {"native": "a" * 64}
        return cache.fingerprint(
            "linux", stage, self.root, ref, environment or ENVIRONMENT, parents
        )


class FingerprintTests(SourceTree):
    def test_worktree_and_git_objects_agree_without_commit_identity_in_key(self):
        key = self.key()
        self.assertEqual(key, self.key(ref=self.commit))
        self.git("commit", "--allow-empty", "-qm", "source identity changes only")
        self.assertEqual(key, self.key(ref=self.git("rev-parse", "HEAD")))

    def test_new_unknown_inputs_mode_changes_deleted_files_and_links_invalidate(self):
        baseline = self.key()
        self.write("new-build-configuration.xyz", "new dependency")
        self.assertNotEqual(baseline, self.key())
        (self.root / "new-build-configuration.xyz").unlink()
        self.assertEqual(baseline, self.key())
        (self.root / "native/main.cpp").chmod(0o755)
        self.assertNotEqual(baseline, self.key())
        (self.root / "native/main.cpp").chmod(0o644)
        (self.root / "native/main.cpp").unlink()
        self.assertNotEqual(baseline, self.key())
        (self.root / "native/main.cpp").symlink_to("first-target")
        first = self.key()
        (self.root / "native/main.cpp").unlink()
        (self.root / "native/main.cpp").symlink_to("second-target")
        self.assertNotEqual(first, self.key())

    def test_stage_roles_preserve_native_on_dart_changes_but_invalidate_consumers(self):
        baseline = {stage: self.key(stage) for stage in cache.STAGES}
        self.write("apps/desktop/lib/main.dart", "desktop changed")
        self.assertEqual(baseline["native"], self.key("native"))
        self.assertEqual(baseline["core"], self.key("core"))
        self.assertNotEqual(baseline["desktop"], self.key("desktop"))
        self.assertNotEqual(baseline["service"], self.key("service"))
        self.write("apps/desktop/lib/main.dart", "initial\n")
        self.write("packages/foresight_core/lib/app.dart", "core changed")
        self.assertEqual(baseline["native"], self.key("native"))
        for stage in ("core", "desktop", "service"):
            self.assertNotEqual(baseline[stage], self.key(stage))

    def test_tools_workflows_locks_pins_and_shared_support_are_common_inputs(self):
        for path in (
            "tools/ci_stage_cache.py",
            ".github/workflows/macos.yml",
            "requirements-dev.lock",
            "tools/pins.json",
            "tests/test_support/temp.dart",
        ):
            for stage in cache.STAGES:
                with self.subTest(path=path, stage=stage):
                    before = self.key(stage)
                    self.write(path, "changed")
                    self.assertNotEqual(before, self.key(stage))
                    self.write(path, "initial\n")

    def test_environment_and_parent_identities_are_required_and_bound(self):
        self.assertNotEqual(
            self.key(), self.key(environment={**ENVIRONMENT, "compiler": "gcc15"})
        )
        self.assertNotEqual(
            self.key("core"), self.key("core", parents={"native": "b" * 64})
        )
        for environment, parents in (
            ({}, {}),
            (ENVIRONMENT, {}),
            (ENVIRONMENT, {"native": "bad"}),
        ):
            with self.assertRaises(ValueError):
                cache.fingerprint(
                    "linux", "core", self.root, environment=environment, parents=parents
                )

    def test_missing_commit_is_fetched_by_sha_without_executing_source(self):
        with (
            patch.object(
                cache,
                "git",
                side_effect=[subprocess.CalledProcessError(1, ["git"]), b""],
            ),
            patch.object(cache.subprocess, "run") as fetch,
        ):
            cache.ensure_commit(self.root, "b" * 40)
        self.assertEqual(
            fetch.call_args.args[0], ["git", "fetch", "--no-tags", "origin", "b" * 40]
        )
        with self.assertRaises(ValueError):
            cache.ensure_commit(self.root, "--upload-pack=untrusted")


class ProducerTests(SourceTree):
    def setUp(self):
        super().setUp()
        self.identity = self.key()
        self.receipt = {
            "schema": 1,
            "platform": "linux",
            "stage": "native",
            "identity": self.identity,
            "source_commit": self.commit,
            "source_run_attempt": 1,
            "environment": ENVIRONMENT,
            "parents": {},
            "sha256": hashlib.sha256(b"payload").hexdigest(),
        }
        self.run = {
            "id": 100,
            "path": cache.WORKFLOW,
            "event": "pull_request",
            "head_branch": "feature",
            "head_sha": self.commit,
            "head_repository": {"full_name": REPOSITORY},
            "pull_requests": [{"number": 110}],
        }
        self.artifact = {
            "id": 101,
            "name": cache.name("linux", "native", self.identity),
            "expired": False,
            "workflow_run": {"id": 100},
            "created_at": "2026-01-01T00:05:00Z",
        }
        self.job = {
            "name": "native-linux",
            "conclusion": "success",
            "run_attempt": 1,
            "started_at": "2026-01-01T00:00:00Z",
            "completed_at": "2026-01-01T00:10:00Z",
        }
        self.payload = b"payload"
        self.members = {}
        self.transfers = 0

    def api(self, repository, route):
        self.assertEqual(repository, REPOSITORY)
        if route.startswith("actions/artifacts?"):
            return {"artifacts": [self.artifact]}
        if route == "actions/runs/100":
            return self.run
        self.fail(route)

    def download(self, repository, artifact, destination):
        self.transfers += 1
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as stream:
            stream.writestr("identity.json", json.dumps(self.receipt))
            stream.writestr("payload.tar.gz", self.payload)
            for name, data in self.members.items():
                stream.writestr(name, data)
        destination.write_bytes(buffer.getvalue())

    def find(self, **overrides):
        args = {
            "repository": REPOSITORY,
            "platform": "linux",
            "stage": "native",
            "identity": self.identity,
            "environment": ENVIRONMENT,
            "parents": {},
            "root": self.root,
            "own_pr": 110,
            "event": "pull_request",
        }
        args.update(overrides)
        with (
            patch.object(cache.artifacts, "api", side_effect=self.api),
            patch.object(cache.artifacts, "dependency_jobs", return_value=[self.job]),
            patch.object(cache.artifacts, "download_zip", side_effect=self.download),
        ):
            return cache.find(**args)

    def test_verified_restore_returns_payload_without_executing_producer(self):
        output = self.root / "download"
        result = self.find(output=output)
        self.assertTrue(result["hit"])
        self.assertEqual(result["artifact_id"], 101)
        self.assertEqual((output / "payload.tar.gz").read_bytes(), self.payload)
        self.assertEqual(result["receipt"], self.receipt)

    def test_main_and_release_consumers_cannot_reuse(self):
        for args in (
            {"event": "push"},
            {"event": "workflow_dispatch"},
            {"branch": "main"},
            {"release": True},
            {"own_pr": 0},
        ):
            with self.subTest(args=args):
                self.assertFalse(self.find(**args)["hit"])
        self.assertEqual(self.transfers, 0)

    def test_foreign_repo_foreign_pr_wrong_workflow_and_wrong_stage_are_rejected(self):
        original = deepcopy(self.run)
        for change in (
            {"head_repository": {"full_name": "attacker/fork"}},
            {"pull_requests": [{"number": 111}]},
            {"path": ".github/workflows/forged.yml"},
            {"event": "workflow_dispatch"},
        ):
            self.run = {**original, **change}
            self.assertFalse(self.find()["hit"])
        self.run = original
        self.job["name"] = "core-linux"
        self.assertFalse(self.find()["hit"])
        self.assertEqual(self.transfers, 0)

    def test_successful_main_stage_reusable_even_if_another_workflow_job_failed(self):
        self.run.update(event="push", head_branch="main", conclusion="failure")
        self.assertTrue(self.find()["hit"])
        self.job["conclusion"] = "failure"
        self.assertFalse(self.find()["hit"])

    def test_exact_successful_attempt_and_upload_window_are_required(self):
        self.receipt["source_run_attempt"] = 2
        self.assertFalse(self.find()["hit"])
        self.receipt["source_run_attempt"] = 1
        self.artifact["created_at"] = "2026-01-01T01:05:00Z"
        self.assertFalse(self.find()["hit"])
        self.assertEqual(self.transfers, 1)

    def test_forged_current_receipt_from_old_workflow_source_is_rejected(self):
        # Even a perfect-looking current receipt cannot hide the producer's
        # changed workflow: read its real Git tree using the current recipe.
        self.write(".github/workflows/macos.yml", "malicious intermediate workflow")
        producer = self.save()
        self.run["head_sha"] = producer
        self.receipt["source_commit"] = producer
        self.assertFalse(self.find()["hit"])
        # Declaring the original clean source instead is independently rejected.
        self.receipt["source_commit"] = self.commit
        self.assertFalse(self.find()["hit"])

    def test_receipt_and_payload_tampering_and_zip_extra_members_are_rejected(self):
        original = deepcopy(self.receipt)
        for change in (
            {"schema": True},
            {"source_run_attempt": True},
            {"environment": {"compiler": "other"}},
            {"parents": {"native": "b" * 64}},
            {"identity": "b" * 64},
            {"sha256": "b" * 64},
            {"source_commit": "b" * 40},
        ):
            with self.subTest(change=change):
                self.receipt = {**original, **change}
                self.assertFalse(self.find()["hit"])
        self.receipt = original
        self.members = {"../../escape": "evil"}
        self.assertFalse(self.find()["hit"])
        self.members = {}
        self.payload = b"changed"
        self.assertFalse(self.find()["hit"])

    def test_github_zip_digest_is_independently_checked(self):
        with patch.object(
            cache.artifacts.subprocess,
            "run",
            side_effect=lambda *a, stdout, **kw: stdout.write(b"changed ZIP"),
        ):
            with self.assertRaisesRegex(ValueError, "ZIP digest"):
                cache.artifacts.download_zip(
                    REPOSITORY,
                    {"id": 101, "digest": "sha256:" + "a" * 64},
                    self.root / "archive.zip",
                )

    def test_zip_symlinks_and_duplicate_members_are_rejected_before_writing(self):
        archive = self.root / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            entry = zipfile.ZipInfo("identity.json")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            stream.writestr(entry, "outside")
            stream.writestr("payload.tar.gz", b"payload")
        with self.assertRaisesRegex(ValueError, "regular"):
            cache.read_zip(archive, self.root / "output")
        self.assertFalse((self.root / "output").exists())

    def test_publish_binds_committed_tree_and_refuses_dirty_inputs(self):
        archive = self.root / "payload.tar.gz"
        archive.write_bytes(b"payload")
        # Output artifacts are ignored by a real checkout, as they must be here.
        self.write(".gitignore", "payload.tar.gz\noutput/\n")
        self.save()
        result = cache.publish(
            "linux",
            "native",
            self.root,
            ENVIRONMENT,
            {},
            archive,
            self.root / "output",
            {"file": "digest"},
        )
        self.assertEqual(result["receipt"]["content"], {"file": "digest"})
        self.assertEqual(
            result["receipt"]["sha256"], hashlib.sha256(b"payload").hexdigest()
        )
        self.write("native/main.cpp", "dirty")
        with self.assertRaisesRegex(ValueError, "uncommitted"):
            cache.publish(
                "linux",
                "native",
                self.root,
                ENVIRONMENT,
                {},
                archive,
                self.root / "output",
            )


if __name__ == "__main__":
    unittest.main()
