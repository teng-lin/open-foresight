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
                ["git", *args], cwd=self.root, stderr=subprocess.DEVNULL, timeout=30
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
        # Core's operation registry also validates desktop command literals.
        self.assertNotEqual(baseline["core"], self.key("core"))
        self.assertNotEqual(baseline["desktop"], self.key("desktop"))
        self.assertNotEqual(baseline["service"], self.key("service"))
        self.write("apps/desktop/lib/main.dart", "initial\n")
        self.write("packages/foresight_core/lib/app.dart", "core changed")
        self.assertEqual(baseline["native"], self.key("native"))
        for stage in ("core", "desktop", "service"):
            self.assertNotEqual(baseline[stage], self.key(stage))

    def test_registry_and_native_metadata_inputs_are_not_missed(self):
        for path, affected in [
            ("tests/service/contract.dart", {"core", "service"}),
            ("apps/desktop/pubspec.yaml", set(cache.STAGES)),
            ("packages/foresight_core/lib/src/model_pins.dart", set(cache.STAGES)),
            ("apps/desktop/test/widget_test.dart", {"desktop", "service"}),
        ]:
            baseline = {stage: self.key(stage) for stage in cache.STAGES}
            self.write(path, "changed")
            for stage in cache.STAGES:
                with self.subTest(path=path, stage=stage):
                    self.assertEqual(
                        baseline[stage] != self.key(stage), stage in affected
                    )

    def test_dart_test_support_never_invalidates_native(self):
        baseline = {stage: self.key(stage) for stage in cache.STAGES}
        self.write("packages/foresight_test_support/lib/native_fixture.dart", "changed")
        self.assertEqual(baseline["native"], self.key("native"))
        for stage in ("core", "desktop", "service"):
            self.assertNotEqual(baseline[stage], self.key(stage))

    def test_native_pubspec_consumes_version_without_dart_dependencies(self):
        path = "apps/desktop/pubspec.yaml"
        self.write(path, "name: desktop\nversion: 1.2.3+4\ndependencies: old\n")
        self.save()
        before = {stage: self.key(stage) for stage in cache.STAGES}
        self.write(path, "name: desktop\nversion: 1.2.3+4\ndependencies: new\n")
        self.assertEqual(before["native"], self.key("native"))
        self.assertEqual(self.key(), self.key(ref=self.save()))
        for stage in ("core", "desktop", "service"):
            self.assertNotEqual(before[stage], self.key(stage))
        self.write(path, "version: 1.2.3+5\n")
        self.assertNotEqual(before["native"], self.key("native"))
        for malformed in ("version: broken\n", "version: 1.2.3+4\nversion: 9.8.7+6\n"):
            self.write(path, malformed)
            self.assertNotEqual(before["native"], self.key("native"))

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

    def find_work(self, **overrides):
        args = {
            "repository": REPOSITORY,
            "platform": "linux",
            "environment": ENVIRONMENT,
            "root": self.root,
            "own_pr": 110,
            "event": "pull_request",
        }
        args.update(overrides)
        with (
            patch.object(cache.artifacts, "api", side_effect=self.api),
            patch.object(cache.artifacts, "dependency_jobs", return_value=[self.job]),
            patch.object(cache.artifacts, "download_zip", side_effect=self.download),
            patch.object(
                cache,
                "native_work_candidates",
                return_value=[(self.artifact, self.identity)],
            ),
        ):
            return cache.find_native_work(**args)

    def test_native_work_survives_new_sources_but_is_not_a_validation_hit(self):
        self.write("native/main.cpp", "changed implementation")
        self.write("tests/new_validation.py", "new test")
        self.save()
        self.assertFalse(self.find(identity=self.key())["hit"])
        self.assertTrue(self.find_work()["hit"])

    def test_native_work_can_ignore_date_but_no_actual_build_environment(self):
        self.receipt["environment"] = {
            **ENVIRONMENT,
            "utc_validation_date": "2026-10-18",
        }
        self.identity = self.key(environment=self.receipt["environment"])
        self.artifact["name"] = cache.name("linux", "native", self.identity)
        self.receipt["identity"] = self.identity
        current = {**ENVIRONMENT, "utc_validation_date": "2026-10-19"}
        self.assertTrue(self.find_work(environment=current)["hit"])
        for key in (
            "compiler",
            "packages",
            "sdk",
            "cmake_arguments",
            "validation_flags",
            "workspace",
        ):
            with self.subTest(key=key):
                self.assertFalse(
                    self.find_work(environment={**current, key: "different"})["hit"]
                )

    def test_native_work_sdk_key_migration_preserves_actual_content_binding(self):
        sdk = {
            "identity": "1" * 64,
            "content_sha256": "2" * 64,
            "prefix": "/workspace/build/sdk",
        }
        self.receipt["environment"] = {**ENVIRONMENT, "sdk": sdk}
        self.identity = self.key(environment=self.receipt["environment"])
        self.artifact["name"] = cache.name("linux", "native", self.identity)
        self.receipt["identity"] = self.identity
        current_sdk = {**sdk, "identity": "3" * 64}
        current = {**ENVIRONMENT, "sdk": current_sdk}
        self.assertTrue(self.find_work(environment=current)["hit"])
        for change in (
            {"content_sha256": "4" * 64},
            {"content_sha256": "invalid"},
            {"prefix": "/different/sdk"},
            {"abi": "different"},
        ):
            with self.subTest(change=change):
                self.assertFalse(
                    self.find_work(
                        environment={**current, "sdk": {**current_sdk, **change}}
                    )["hit"]
                )
        # A legacy receipt without actual SDK bytes cannot waive its identity.
        self.receipt["environment"]["sdk"] = {
            "identity": "1" * 64,
            "prefix": sdk["prefix"],
        }
        self.identity = self.key(environment=self.receipt["environment"])
        self.receipt["identity"] = self.identity
        self.artifact["name"] = cache.name("linux", "native", self.identity)
        self.assertFalse(self.find_work(environment=current)["hit"])

    def test_native_work_ignores_legacy_language_versions_and_flutter_locator_only(
        self,
    ):
        old_flags = {"CI": "a" * 64, "FORESIGHT_FLUTTER_EXECUTABLE": "b" * 64}
        old = {
            **ENVIRONMENT,
            "dart": "old Dart",
            "flutter": "old Flutter",
            "validation_environment_sha256": old_flags,
        }
        self.receipt["environment"] = old
        self.identity = self.key(environment=old)
        self.receipt["identity"] = self.identity
        self.artifact["name"] = cache.name("linux", "native", self.identity)
        current = {
            **ENVIRONMENT,
            "dart": None,
            "flutter": None,
            "validation_environment_sha256": {"CI": "a" * 64},
        }
        self.assertTrue(self.find_work(environment=current)["hit"])
        changed_flags = {"CI": "a" * 64, "FORESIGHT_REAL_NATIVE_FLAG": "c" * 64}
        self.assertFalse(
            self.find_work(
                environment={**current, "validation_environment_sha256": changed_flags}
            )["hit"]
        )
        self.assertIn("FORESIGHT_FLUTTER_EXECUTABLE", old_flags)
        self.assertEqual(self.receipt["environment"]["dart"], "old Dart")

    def test_native_work_verifies_frozen_legacy_recipe_independently(self):
        self.write("apps/desktop/pubspec.yaml", "version: 1.2.3+4\ndependencies: old\n")
        self.write("packages/foresight_test_support/lib/fixture.dart", "old support")
        producer = self.save()
        legacy_identity = cache.fingerprint(
            "linux", "native", self.root, producer, ENVIRONMENT, {}, recipe=1
        )
        self.identity = legacy_identity
        self.artifact["name"] = cache.name("linux", "native", legacy_identity)
        self.run["head_sha"] = producer
        self.receipt.update(identity=legacy_identity, source_commit=producer)
        self.write("apps/desktop/pubspec.yaml", "version: 1.2.3+4\ndependencies: new\n")
        self.save()
        self.assertTrue(self.find_work()["hit"])
        for recipe in (True, 0, 3, "1", 2):
            self.receipt["identity_recipe"] = recipe
            self.assertFalse(self.find_work()["hit"])

    def test_native_work_rejects_wrong_receipts_attempts_and_failed_producers(self):
        original = deepcopy(self.receipt)
        for change in (
            {"payload_kind": "native-runtime"},
            {"reusable": False},
            {"source_run_attempt": 2},
            {"source_commit": "b" * 40},
            {"parents": {"native": "a" * 64}},
            {"identity": "0" * 64},
            {"sha256": "0" * 64},
            {"identity_recipe": 999},
        ):
            self.receipt = {**original, **change}
            self.assertFalse(self.find_work()["hit"])
        self.receipt = original
        self.job["conclusion"] = "failure"
        self.assertFalse(self.find_work()["hit"])
        self.job["conclusion"] = "success"
        self.run["head_repository"] = {"full_name": "attacker/fork"}
        self.assertFalse(self.find_work()["hit"])

    def test_native_work_rejects_changed_symlink_sources(self):
        (self.root / "native/header.h").symlink_to("first.h")
        self.assertFalse(self.find_work()["hit"])

    def test_native_work_main_and_release_consumers_still_run_fresh(self):
        for overrides in (
            {"event": "push"},
            {"release": True},
            {"branch": "main"},
            {"own_pr": 0},
        ):
            self.assertFalse(self.find_work(**overrides)["hit"])
        self.assertEqual(self.transfers, 0)

    def test_native_work_paginates_and_excludes_runtime_and_expired_payloads(self):
        first = [{"name": "other-output", "expired": False}] * 100
        second = [
            self.artifact,
            {**self.artifact, "name": self.artifact["name"] + "-runtime"},
            {**self.artifact, "expired": True},
        ]
        with patch.object(
            cache.artifacts,
            "api",
            side_effect=[{"artifacts": first}, {"artifacts": second}],
        ) as api:
            self.assertEqual(
                list(cache.native_work_candidates(REPOSITORY, "linux")),
                [(self.artifact, self.identity)],
            )
        self.assertIn("page=2", api.call_args.args[1])

    def test_realistic_large_content_manifest_and_nested_reusable_job(self):
        self.receipt["content"] = {"files": {"native-output": {"data": "x" * 70000}}}
        self.job["name"] = "linux-native / native-linux"
        self.assertTrue(self.find()["hit"])

    def test_derived_distribution_payload_cannot_be_reused(self):
        self.receipt["reusable"] = False
        self.assertFalse(self.find()["hit"])

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
            {"payload_kind": "native-runtime", "reusable": True},
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
