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
            "tools/ci_stage_artifacts.py",
            "tools/build_service_gate.sh",
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
            "tools/ci_stage_artifacts.py",
            "tools/build_service_gate.sh",
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
        self.downloaded_ids = []
        self.additional_runs = {}
        self.approval_routes = {}
        self.metadata = []
        self.metadata_receipts = {}
        self.payload_receipts = {}

    def api(self, repository, route):
        self.assertEqual(repository, REPOSITORY)
        if route in self.approval_routes:
            value = self.approval_routes[route]
            if isinstance(value, Exception):
                raise value
            return value
        if route.startswith("pulls/") and "/commits?" not in route:
            return {"merged_at": None}
        if route.startswith("actions/artifacts?name=receipt-ci-stage-"):
            return {"artifacts": self.metadata}
        if route.startswith("actions/artifacts?"):
            return {"artifacts": [self.artifact]}
        if route == "actions/runs/100":
            return self.run
        if (
            route.startswith("actions/runs/")
            and int(route.rsplit("/", 1)[-1]) in self.additional_runs
        ):
            return self.additional_runs[int(route.rsplit("/", 1)[-1])]
        self.fail(route)

    def download(self, repository, artifact, destination):
        self.transfers += 1
        self.downloaded_ids.append(artifact["id"])
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as stream:
            metadata = artifact["id"] in self.metadata_receipts
            receipt = (
                self.metadata_receipts[artifact["id"]]
                if metadata
                else self.payload_receipts.get(artifact["id"], self.receipt)
            )
            stream.writestr("identity.json", json.dumps(receipt))
            if not metadata:
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

    def find_work(self, candidates=None, **overrides):
        jobs_api = overrides.pop("jobs_api", lambda *args: [self.job])
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
            patch.object(cache.artifacts, "dependency_jobs", side_effect=jobs_api),
            patch.object(cache.artifacts, "download_zip", side_effect=self.download),
            patch.object(
                cache,
                "native_work_candidates",
                return_value=[(self.artifact, self.identity)]
                if candidates is None
                else candidates,
            ),
        ):
            return cache.find_native_work(**args)

    def unavailable_producer(self):
        self.additional_runs[99] = {**self.run, "id": 99}
        return [
            ({**self.artifact, "id": number, "workflow_run": {"id": 99}}, self.identity)
            for number in (201, 202)
        ] + [(self.artifact, self.identity)]

    def test_native_work_server_error_uses_an_independently_verified_producer(self):
        candidates = self.unavailable_producer()
        queried = []
        failure = subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 502\n")

        def jobs(repository, run_id):
            queried.append(run_id)
            if run_id == 99:
                raise failure
            return [self.job]

        result = self.find_work(candidates=candidates, jobs_api=jobs)
        self.assertTrue(result["hit"])
        self.assertEqual(result["run_id"], 100)
        self.assertEqual(result["artifact_id"], self.artifact["id"])
        self.assertEqual(result["receipt"], self.receipt)
        # A second artifact from the unavailable producer must not repeat all
        # exhausted HTTP retries. Its bytes have never been trusted/downloaded.
        self.assertEqual(queried, [99, 100])
        self.assertEqual(self.downloaded_ids, [self.artifact["id"]])

    def test_native_work_run_metadata_server_error_can_use_another_producer(self):
        candidates = self.unavailable_producer()
        original_api = self.api

        def query(repository, route):
            if route == "actions/runs/99":
                raise subprocess.CalledProcessError(1, "gh", stderr="gh: HTTP 503")
            return original_api(repository, route)

        self.api = query
        result = self.find_work(candidates=candidates)
        self.assertTrue(result["hit"])
        self.assertEqual(result["run_id"], 100)
        self.assertEqual(self.downloaded_ids, [self.artifact["id"]])

    def test_native_work_auth_and_protocol_failures_still_stop_lookup(self):
        candidates = self.unavailable_producer()
        for failure in (
            subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 401"),
            subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 403"),
            subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 404"),
            subprocess.CalledProcessError(1, "gh"),
            json.JSONDecodeError("Malformed GitHub response", "{", 1),
        ):
            queried = []

            def jobs(repository, run_id, queried=queried, failure=failure):
                queried.append(run_id)
                raise failure

            with self.subTest(failure=failure), self.assertRaises(type(failure)) as caught:
                self.find_work(candidates=candidates, jobs_api=jobs)
            self.assertIs(caught.exception, failure)
            self.assertEqual(queried, [99])
        self.assertEqual(self.downloaded_ids, [])

    def test_native_work_server_error_search_is_bounded_and_fails_closed(self):
        candidates = []
        queried = []
        failure = subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 502")
        for run_id in (97, 98, 99):
            self.additional_runs[run_id] = {**self.run, "id": run_id}
            candidates.append(
                ({**self.artifact, "workflow_run": {"id": run_id}}, self.identity)
            )
        candidates.append((self.artifact, self.identity))

        def jobs(repository, run_id):
            queried.append(run_id)
            if run_id != 100:
                raise failure
            return [self.job]

        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.find_work(candidates=candidates, jobs_api=jobs)
        self.assertIs(caught.exception, failure)
        self.assertEqual(queried, [97, 98, 99])
        self.assertEqual(self.downloaded_ids, [])

    def test_native_work_unresolved_server_error_never_becomes_a_cold_build(self):
        candidates = self.unavailable_producer()
        failure = subprocess.CalledProcessError(1, "gh", stderr=b"gh: HTTP 502\n")

        def jobs(repository, run_id):
            if run_id == 99:
                raise failure
            return [self.job]

        original_receipt = deepcopy(self.receipt)
        original_run = deepcopy(self.run)
        for rejection in ("environment", "receipt", "checksum", "failed-job", "untrusted"):
            self.receipt = deepcopy(original_receipt)
            self.run = deepcopy(original_run)
            self.job["conclusion"] = "success"
            self.payload = b"payload"
            if rejection == "environment":
                self.receipt["environment"] = {**ENVIRONMENT, "compiler": "incompatible"}
            elif rejection == "receipt":
                self.receipt["source_run_attempt"] = 2
            elif rejection == "checksum":
                self.payload = b"tampered bytes"
            elif rejection == "failed-job":
                self.job["conclusion"] = "failure"
            else:
                self.run["pull_requests"] = [{"number": 999}]
            with self.subTest(rejection=rejection), self.assertRaises(
                subprocess.CalledProcessError
            ) as caught:
                self.find_work(candidates=candidates, jobs_api=jobs)
            self.assertIs(caught.exception, failure)

    def add_metadata(self, artifact, receipt):
        metadata = {
            **artifact,
            "id": artifact["id"] + 1000,
            "name": "receipt-" + artifact["name"],
            "size_in_bytes": 1000,
        }
        self.metadata.append(metadata)
        self.metadata_receipts[metadata["id"]] = deepcopy(receipt)
        return metadata

    def test_metadata_rejects_many_incompatible_environments_without_full_downloads(
        self,
    ):
        candidates = []
        for number in range(101, 109):
            artifact = {**self.artifact, "id": number, "workflow_run": {"id": number}}
            self.additional_runs[number] = {**self.run, "id": number}
            self.add_metadata(artifact, self.receipt)
            candidates.append((artifact, self.identity))
        result = self.find_work(
            candidates=candidates, environment={**ENVIRONMENT, "compiler": "different"}
        )
        self.assertFalse(result["hit"])
        self.assertEqual(self.downloaded_ids, list(range(1101, 1109)))

    def test_metadata_can_select_older_compatible_work_after_many_cheap_mismatches(
        self,
    ):
        current = {**ENVIRONMENT, "compiler": "new compiler"}
        identity = self.key(environment=current)
        compatible = {**self.receipt, "environment": current, "identity": identity}
        candidates = []
        for number in range(101, 107):
            use_identity = identity if number == 106 else self.identity
            receipt = compatible if number == 106 else self.receipt
            artifact = {
                **self.artifact,
                "id": number,
                "name": cache.name("linux", "native", use_identity),
                "workflow_run": {"id": number},
            }
            self.additional_runs[number] = {**self.run, "id": number}
            self.add_metadata(artifact, receipt)
            self.payload_receipts[number] = receipt
            candidates.append((artifact, use_identity))
        self.assertTrue(
            self.find_work(candidates=candidates, environment=current)["hit"]
        )
        self.assertEqual(self.downloaded_ids, list(range(1101, 1107)) + [106])

    def test_metadata_cannot_launder_a_different_embedded_payload_receipt(self):
        self.add_metadata(self.artifact, self.receipt)
        self.payload_receipts[self.artifact["id"]] = {
            **self.receipt,
            "unexpected": "changed",
        }
        self.assertFalse(self.find_work()["hit"])
        self.assertEqual(self.downloaded_ids, [1101, 101])

    def test_metadata_requires_exact_source_attempt_and_successful_upload_window(self):
        original = deepcopy(self.receipt)
        for change in (
            {"source_commit": "b" * 40},
            {"source_run_attempt": 2},
            {"identity": "0" * 64},
            {"payload_kind": "native-runtime"},
        ):
            self.metadata.clear()
            self.metadata_receipts.clear()
            self.downloaded_ids.clear()
            self.add_metadata(self.artifact, {**original, **change})
            self.assertFalse(self.find_work()["hit"])
            self.assertEqual(self.downloaded_ids, [1101])
        self.metadata.clear()
        self.metadata_receipts.clear()
        self.downloaded_ids.clear()
        metadata = self.add_metadata(self.artifact, original)
        metadata["created_at"] = "2026-01-01T01:00:00Z"
        self.assertFalse(self.find_work()["hit"])
        self.assertEqual(self.downloaded_ids, [])

    def test_metadata_api_protocol_auth_and_network_errors_never_authorize_build(self):
        original_api = self.api
        errors = (
            json.JSONDecodeError("Malformed GitHub response", "{", 1),
            subprocess.CalledProcessError(1, ["gh", "api"], output=b"HTTP 401"),
            subprocess.CalledProcessError(
                1, ["gh", "api"], output=b"network unavailable"
            ),
        )
        for error in errors:

            def query(repository, route, error=error):
                if route.startswith("actions/artifacts?name=receipt-ci-stage-"):
                    raise error
                return original_api(repository, route)

            self.api = query
            with self.assertRaises(type(error)):
                self.find_work()
        self.assertEqual(self.downloaded_ids, [])

    def test_malformed_cached_metadata_is_rejected_without_masking_api_errors(self):
        self.add_metadata(self.artifact, self.receipt)
        original_download = self.download

        def download(repository, artifact, destination):
            if artifact["id"] == 1101:
                self.downloaded_ids.append(artifact["id"])
                with zipfile.ZipFile(destination, "w") as stream:
                    stream.writestr("identity.json", "{")
            else:
                original_download(repository, artifact, destination)

        self.download = download
        self.assertFalse(self.find_work()["hit"])
        self.assertEqual(self.downloaded_ids, [1101])

    def test_native_work_survives_new_sources_but_is_not_a_validation_hit(self):
        self.write("native/main.cpp", "changed implementation")
        self.write("tests/new_validation.py", "new test")
        self.save()
        self.assertFalse(self.find(identity=self.key())["hit"])
        self.assertTrue(self.find_work()["hit"])

    def test_runtime_contract_change_invalidates_slim_identity_but_reuses_native_work(
        self,
    ):
        self.write("tools/ci_stage_artifacts.py", "include service worker in runtime")
        self.write("tools/build_service_gate.sh", "check executable worker")
        self.save()
        self.assertNotEqual(self.identity, self.key())
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

    def test_native_work_reuses_across_host_kernel_and_irrelevant_pin_changes(self):
        old = {
            **ENVIRONMENT,
            "system": "Linux-old-host-kernel",
            "pins": {"flutter": "old", "ubuntu_snapshot": "old"},
        }
        self.receipt["environment"] = old
        self.identity = self.key(environment=old)
        self.receipt["identity"] = self.identity
        self.artifact["name"] = cache.name("linux", "native", self.identity)
        current = {
            **old,
            "system": "Linux-new-host-kernel",
            "pins": {"flutter": "new", "ubuntu_snapshot": "new"},
        }
        self.assertFalse(
            self.find(identity=self.key(environment=current), environment=current)[
                "hit"
            ]
        )
        self.assertTrue(self.find_work(environment=current)["hit"])
        for key in (
            "compiler",
            "packages",
            "machine",
            "platform",
            "apple_sdk",
            "xcode",
            "base_image",
        ):
            with self.subTest(key=key):
                self.assertFalse(
                    self.find_work(environment={**current, key: "changed"})["hit"]
                )

    def test_native_work_download_limit_never_authorizes_cold_build_with_older_work(
        self,
    ):
        current = {**ENVIRONMENT, "compiler": "new compiler"}
        compatible_identity = self.key(environment=current)
        compatible_receipt = {
            **self.receipt,
            "environment": current,
            "identity": compatible_identity,
        }
        candidates = []
        for artifact_id in (101, 102, 103, 104):
            identity = compatible_identity if artifact_id == 104 else self.identity
            artifact = {
                **self.artifact,
                "id": artifact_id,
                "name": cache.name("linux", "native", identity),
            }
            candidates.append((artifact, identity))
        foreign = (
            {**self.artifact, "id": 99, "workflow_run": {"id": 99}},
            self.identity,
        )
        candidates = [foreign] * 10 + candidates
        original_api, original_download = self.api, self.download
        downloaded = []

        def query(repository, route):
            if route == "actions/runs/99":
                return {
                    **self.run,
                    "id": 99,
                    "head_repository": {"full_name": "attacker/fork"},
                }
            return original_api(repository, route)

        def download(repository, artifact, destination):
            downloaded.append(artifact["id"])
            previous = self.receipt
            try:
                if artifact["id"] == 104:
                    self.receipt = compatible_receipt
                original_download(repository, artifact, destination)
            finally:
                self.receipt = previous

        self.api, self.download = query, download
        # Establish that the older fourth candidate really contains compatible
        # verified work, even after unrelated/untrusted candidates were skipped.
        with patch.object(cache, "MAX_NATIVE_WORK_DOWNLOADS", 4):
            self.assertTrue(
                self.find_work(candidates=candidates, environment=current)["hit"]
            )
        self.assertEqual(downloaded, [101, 102, 103, 104])
        downloaded.clear()
        with self.assertRaisesRegex(
            RuntimeError, "search is incomplete.*Do not start a cold build"
        ):
            self.find_work(candidates=candidates, environment=current)
        self.assertEqual(downloaded, [101, 102, 103])

    def test_native_work_exhausted_three_candidates_is_a_real_miss(self):
        candidates = [
            ({**self.artifact, "id": i}, self.identity) for i in range(101, 104)
        ]
        self.assertFalse(
            self.find_work(
                candidates=candidates,
                environment={**ENVIRONMENT, "compiler": "different"},
            )["hit"]
        )
        self.assertEqual(self.transfers, 3)

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

    def approved_other_pr(self, native_change=False, rebase=False):
        self.run["pull_requests"] = [{"number": 112}]
        self.write(
            "packages/foresight_core/lib/app.dart", "reviewed Dart-only follow-up"
        )
        self.write("CHANGELOG.md", "editorial final fix")
        if native_change:
            self.write("native/main.cpp", "different reviewed native code")
        final = self.save()
        merge = self.git(
            "commit-tree", final + "^{tree}", "-p", self.commit, "-m", "approved rebase"
        )
        pull = {
            "number": 112,
            "merged_at": "2026-01-02T00:00:00Z",
            "merge_commit_sha": merge,
            "head": {"sha": final, "repo": {"full_name": REPOSITORY}},
            "base": {"repo": {"full_name": REPOSITORY}},
        }
        self.approval_routes.update(
            {
                "pulls/112": pull,
                f"compare/{self.commit}...{final}": {"status": "ahead"},
                f"compare/{final}...main": {
                    "status": "diverged" if rebase else "ahead"
                },
                f"compare/{merge}...main": {"status": "ahead"},
                f"git/commits/{final}": {
                    "sha": final,
                    "tree": {"sha": self.git("rev-parse", final + "^{tree}")},
                },
                f"git/commits/{merge}": {
                    "sha": merge,
                    "tree": {"sha": self.git("rev-parse", merge + "^{tree}")},
                },
            }
        )
        return final, merge, pull

    def test_merged_pr_dart_only_final_fix_promotes_objects_not_test_results(self):
        self.approved_other_pr(rebase=True)
        result = self.find_work(own_pr=119)
        self.assertTrue(result["hit"])
        self.assertEqual(result["receipt"], self.receipt)
        self.assertFalse(self.find(own_pr=119)["hit"])
        # Main/release also builds and validates current inputs instead of
        # inheriting the historical PR's successful test qualification.
        self.assertTrue(
            self.find_work(event="push", branch="main", own_pr=0, release=True)["hit"]
        )
        self.assertFalse(
            self.find(event="push", branch="main", own_pr=0, release=True)["hit"]
        )

    def test_merged_pr_changed_native_source_does_not_promote(self):
        self.approved_other_pr(native_change=True)
        self.assertFalse(self.find_work(own_pr=119)["hit"])
        self.assertEqual(self.transfers, 0)

    def test_merged_pr_approval_rejects_unmerged_fork_and_nonfinal_tree(self):
        final, merge, pull = self.approved_other_pr(rebase=True)
        for change in (
            "unmerged",
            "fork-head",
            "fork-base",
            "nonfinal-tree",
            "unreachable-merge",
        ):
            with self.subTest(change=change):
                original = deepcopy(pull)
                old_tree = deepcopy(self.approval_routes[f"git/commits/{merge}"])
                old_comparison = deepcopy(
                    self.approval_routes[f"compare/{merge}...main"]
                )
                if change == "unmerged":
                    pull["merged_at"] = None
                elif change == "fork-head":
                    pull["head"]["repo"]["full_name"] = "fork/repository"
                elif change == "fork-base":
                    pull["base"]["repo"]["full_name"] = "fork/repository"
                elif change == "nonfinal-tree":
                    self.approval_routes[f"git/commits/{merge}"]["tree"]["sha"] = (
                        self.git("rev-parse", self.commit + "^{tree}")
                    )
                else:
                    self.approval_routes[f"compare/{merge}...main"]["status"] = "behind"
                self.assertFalse(self.find_work(own_pr=119)["hit"])
                self.assertEqual(self.transfers, 0)
                pull.clear()
                pull.update(original)
                self.approval_routes[f"git/commits/{merge}"] = old_tree
                self.approval_routes[f"compare/{merge}...main"] = old_comparison

    def test_merged_pr_unrelated_producer_is_rejected_but_commit_membership_is_supported(
        self,
    ):
        final, _, _ = self.approved_other_pr()
        route = f"compare/{self.commit}...{final}"
        self.approval_routes[route] = {"status": "diverged"}
        self.approval_routes["pulls/112/commits?per_page=100&page=1"] = []
        self.assertFalse(self.find_work(own_pr=119)["hit"])
        self.assertEqual(self.transfers, 0)
        self.approval_routes["pulls/112/commits?per_page=100&page=1"] = [
            {"sha": self.commit}
        ]
        self.assertTrue(self.find_work(own_pr=119)["hit"])

    def test_native_approval_bounds_full_commit_pages_without_authorizing_reuse(self):
        final, _, _ = self.approved_other_pr()
        self.approval_routes[f"compare/{self.commit}...{final}"] = {
            "status": "diverged"
        }
        for page in range(1, 4):
            self.approval_routes[f"pulls/112/commits?per_page=100&page={page}"] = [
                {"sha": "f" * 40}
            ] * 100
        # There is deliberately no page 4 fixture: a full terminal page must
        # fail closed rather than request unbounded pages or download objects.
        self.assertFalse(self.find_work(own_pr=119)["hit"])
        self.assertEqual(self.transfers, 0)

    def test_merged_pr_api_or_missing_git_proof_is_not_permission_to_compile(self):
        _, _, pull = self.approved_other_pr()
        self.approval_routes["pulls/112"] = subprocess.CalledProcessError(
            1, ["gh", "api"], b"API unavailable"
        )
        with self.assertRaises(subprocess.CalledProcessError):
            self.find_work(own_pr=119)
        self.approval_routes["pulls/112"] = pull
        with patch.object(
            cache,
            "ensure_commit",
            side_effect=subprocess.CalledProcessError(1, ["git", "fetch"]),
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                self.find_work(own_pr=119)
        self.assertEqual(self.transfers, 0)

    def test_merged_approval_keeps_failed_attempt_and_derived_payload_rejection(self):
        self.approved_other_pr()
        self.job["conclusion"] = "failure"
        self.assertFalse(self.find_work(own_pr=119)["hit"])
        self.assertEqual(self.transfers, 0)
        self.job["conclusion"] = "success"
        self.receipt["source_run_attempt"] = 2
        self.assertFalse(self.find_work(own_pr=119)["hit"])
        self.receipt["source_run_attempt"] = 1
        self.receipt["reusable"] = False
        self.assertFalse(self.find_work(own_pr=119)["hit"])

    def test_merged_source_qualification_is_computed_once_per_producer(self):
        self.approved_other_pr()
        self.receipt["reusable"] = False
        with patch.object(
            cache, "trusted_native_work_run", wraps=cache.trusted_native_work_run
        ) as qualify:
            self.assertFalse(
                self.find_work(
                    candidates=[(self.artifact, self.identity)] * 3, own_pr=119
                )["hit"]
            )
        self.assertEqual(qualify.call_count, 1)

    def test_native_work_main_consumers_retain_verified_main_objects(self):
        self.run.update(event="push", head_branch="main")
        result = self.find_work(event="push", branch="main", own_pr=0, release=True)
        self.assertTrue(result["hit"])
        self.assertEqual(result["receipt"], self.receipt)
        # A compiler-work hit is not permission to reuse successful test results.
        self.assertFalse(
            self.find(event="push", branch="main", own_pr=0, release=True)["hit"]
        )

    def test_native_work_main_cannot_take_another_pr_or_derived_payload(self):
        self.assertFalse(
            self.find_work(event="push", branch="main", own_pr=0, release=True)["hit"]
        )
        self.assertEqual(self.transfers, 0)
        self.run.update(event="push", head_branch="main")
        self.receipt["reusable"] = False
        self.assertFalse(
            self.find_work(event="push", branch="main", own_pr=0, release=True)["hit"]
        )

    def test_dispatch_and_schedule_retain_objects_but_never_passed_validation(self):
        self.run.update(event="push", head_branch="main")
        for event in ("workflow_dispatch", "schedule"):
            self.assertTrue(
                self.find_work(event=event, branch="main", own_pr=0, release=True)[
                    "hit"
                ]
            )
            self.assertFalse(
                self.find(event=event, branch="main", own_pr=0, release=True)["hit"]
            )

    def test_native_work_other_main_and_release_contexts_remain_restricted(self):
        for overrides in (
            {"event": "push"},
            {"release": True},
            {"branch": "main"},
            {"own_pr": 0},
            {"event": "push", "branch": "topic", "own_pr": 0},
            {"event": "push", "branch": "main", "own_pr": 110},
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


class SubmoduleInputsTests(SourceTree):
    def test_gitlink_tracks_checked_out_commit_without_reading_nested_worktree(self):
        nested = self.root / "native/vendor"
        nested.mkdir(parents=True)

        def module_git(*args):
            return (
                subprocess.check_output(
                    ["git", *args], cwd=nested, stderr=subprocess.DEVNULL, timeout=30
                )
                .decode()
                .strip()
            )

        module_git("init", "-q")
        module_git("config", "user.name", "Fixture")
        module_git("config", "user.email", "fixture@example.invalid")
        (nested / "source.cpp").write_text("verified vendor source")
        module_git("add", ".")
        module_git("commit", "-qm", "vendor fixture")
        first = module_git("rev-parse", "HEAD")
        self.git(
            "update-index", "--add", "--cacheinfo", f"160000,{first},native/vendor"
        )
        self.git("commit", "-qm", "bind vendor commit")
        before = cache.source_inputs(self.root, "native")
        self.assertEqual(before["native/vendor"], ["160000", "commit", first])
        self.assertEqual(
            before,
            cache.source_inputs(self.root, "native", self.git("rev-parse", "HEAD")),
        )
        (nested / "untracked.o").write_bytes(b"preserve compiler output")
        self.assertEqual(before, cache.source_inputs(self.root, "native"))
        module_git("commit", "--allow-empty", "-qm", "changed vendor checkout")
        second = module_git("rev-parse", "HEAD")
        after = cache.source_inputs(self.root, "native")
        self.assertEqual(after["native/vendor"], ["160000", "commit", second])
        self.assertNotEqual(before, after)
        self.assertEqual(
            (nested / "untracked.o").read_bytes(), b"preserve compiler output"
        )
