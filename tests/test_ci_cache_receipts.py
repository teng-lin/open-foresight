"""Verify cheap producer cache hits still bind original trusted payload uploads."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tools import ci_artifacts as artifacts

REPOSITORY = "teng-lin/open-foresight"
COMPONENT = "linux-sdk"
IDENTITY = "a" * 64


class CacheReceiptTests(unittest.TestCase):
    def setUp(self):
        self.receipt = {
            "schema": 1,
            "component": COMPONENT,
            "identity": IDENTITY,
            "sha256": "b" * 64,
            "source_run_attempt": 1,
            "source_commit": "c" * 40,
        }
        self.reference = {
            "schema": 1,
            "component": COMPONENT,
            "identity": IDENTITY,
            "artifact_id": 400,
            "artifact_digest": "sha256:" + "d" * 64,
            "source_receipt": self.receipt,
        }
        self.payload = {
            "id": 400,
            "name": artifacts.name(COMPONENT, IDENTITY),
            "digest": self.reference["artifact_digest"],
            "expired": False,
            "workflow_run": {"id": 123},
            "created_at": "2026-01-01T00:05:00Z",
            "expires_at": (datetime.now(timezone.utc) + timedelta(days=2)).isoformat(),
        }
        self.sidecar = {
            "id": 401,
            "name": artifacts.receipt_name(COMPONENT, IDENTITY),
            "size_in_bytes": 1000,
            "expired": False,
            "workflow_run": {"id": 123},
            "created_at": "2026-01-01T00:06:00Z",
        }
        self.run = {
            "id": 123,
            "path": ".github/workflows/ci-dependencies.yml",
            "event": "pull_request",
            "head_branch": "feature",
            "head_sha": "c" * 40,
            "head_repository": {"full_name": REPOSITORY},
            "pull_requests": [{"number": 104}],
        }
        self.jobs = [
            {
                "name": artifacts.JOBS[COMPONENT],
                "conclusion": "success",
                "run_attempt": 1,
                "started_at": "2026-01-01T00:00:00Z",
                "completed_at": "2026-01-01T00:10:00Z",
            }
        ]
        self.downloaded = []

    def api(self, repository, route):
        self.assertEqual(repository, REPOSITORY)
        if route.startswith("actions/artifacts?"):
            self.assertIn("receipt-ci-linux-sdk", route)
            return {"artifacts": [self.sidecar]}
        if route == "actions/artifacts/400":
            return self.payload
        if route == "actions/artifacts/401":
            return self.sidecar
        if route == "actions/runs/123":
            return self.run
        if route == "pulls/105":
            # Cross-PR qualification must inspect the authoritative merge state.
            return {"merged_at": None}
        if "/jobs?" in route:
            return {"jobs": self.jobs}
        self.fail(route)

    def download(self, command, stdout, check, timeout, stderr):
        self.downloaded.append(command[-1])
        self.assertTrue(command[-1].endswith("/401/zip"))
        stdout.write(self.zip_bytes)

    def probe(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as stream:
            stream.writestr("receipt.json", json.dumps(self.reference))
            if getattr(self, "extra_member", False):
                stream.writestr("../../outside", "not a receipt")
        self.zip_bytes = buffer.getvalue()
        self.sidecar["digest"] = "sha256:" + hashlib.sha256(self.zip_bytes).hexdigest()
        with (
            patch.object(artifacts, "api", side_effect=self.api),
            patch.object(artifacts, "merged_source", return_value=False),
            patch.object(artifacts, "source_fingerprint_at", return_value=IDENTITY),
            patch.object(artifacts, "qualified_producer_control", return_value=True),
            patch.object(artifacts.subprocess, "run", side_effect=self.download),
        ):
            return artifacts.probe(REPOSITORY, COMPONENT, IDENTITY, own_pr=104)

    def test_success_downloads_only_small_receipt_not_payload(self):
        self.assertTrue(self.probe())
        self.assertEqual(len(self.downloaded), 1)

    def test_main_and_merged_sources_preserve_existing_trust(self):
        self.run.update(event="push", head_branch="main")
        self.assertTrue(self.probe())
        self.run.update(
            event="pull_request", head_branch="feature", pull_requests=[{"number": 105}]
        )
        with patch.object(artifacts, "merged_source", return_value=True):
            # Invoke directly because probe()'s fixture otherwise deliberately
            # makes all other source commits unmerged.
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as stream:
                stream.writestr("receipt.json", json.dumps(self.reference))
            self.zip_bytes = buffer.getvalue()
            self.sidecar["digest"] = (
                "sha256:" + hashlib.sha256(self.zip_bytes).hexdigest()
            )
            with (
                patch.object(artifacts, "api", side_effect=self.api),
                patch.object(artifacts, "source_fingerprint_at", return_value=IDENTITY),
                patch.object(artifacts.subprocess, "run", side_effect=self.download),
            ):
                self.assertTrue(
                    artifacts.probe(REPOSITORY, COMPONENT, IDENTITY, own_pr=104)
                )

    def test_same_sha_other_unmerged_pr_and_fork_are_not_reused(self):
        self.run["pull_requests"] = [{"number": 105}]
        self.assertFalse(self.probe())
        self.assertFalse(self.downloaded)
        self.run["pull_requests"] = [{"number": 104}]
        self.run["head_repository"] = {"full_name": "attacker/fork"}
        self.assertFalse(self.probe())
        self.assertFalse(self.downloaded)

    def test_expired_missing_and_short_lived_originals_are_cache_misses(self):
        original = deepcopy(self.payload)
        for change in (
            {"expired": True},
            {
                "expires_at": (
                    datetime.now(timezone.utc) + timedelta(hours=1)
                ).isoformat()
            },
            {"expires_at": "not-a-date"},
            {"name": "receipt-" + original["name"]},
            {"workflow_run": {"id": 999}},
            {"digest": "sha256:" + "e" * 64},
        ):
            with self.subTest(change=change):
                self.payload = {**original, **change}
                self.assertFalse(self.probe())
        self.payload = None
        self.assertFalse(self.probe())

    def test_failed_attempt_cannot_be_qualified_by_successful_earlier_attempt(self):
        self.jobs.append({**self.jobs[0], "run_attempt": 2, "conclusion": "failure"})
        self.receipt["source_run_attempt"] = 2
        self.assertFalse(self.probe())
        self.receipt["source_run_attempt"] = 1
        self.assertTrue(self.probe())
        self.payload["created_at"] = "2026-01-01T01:05:00Z"
        self.assertFalse(self.probe())

    def test_both_original_and_sidecar_must_be_in_exact_successful_attempt(self):
        self.sidecar["created_at"] = "2026-01-01T01:06:00Z"
        self.assertFalse(self.probe())
        self.sidecar["created_at"] = "2026-01-01T00:06:00Z"
        self.jobs[0]["conclusion"] = "failure"
        self.assertFalse(self.probe())

    def test_tampered_binding_and_receipt_cycles_are_rejected(self):
        original = deepcopy(self.reference)
        for change in (
            {"schema": 2},
            {"schema": True},
            {"component": "linux-core"},
            {"identity": "f" * 64},
            {"artifact_id": 401},
            {"artifact_digest": "sha256:" + "e" * 64},
            {"source_receipt": {**self.receipt, "sha256": "invalid"}},
            {"source_receipt": {**self.receipt, "sha256": 123}},
            {"artifact_digest": 123},
            {"source_receipt": None},
            {"source_receipt": {**self.receipt, "schema": True}},
            {"source_receipt": {**self.receipt, "sha256": None}},
            {"source_receipt": {**self.receipt, "sha256": []}},
            {"artifact_digest": []},
            {"artifact_digest": None},
            {"source_receipt": {**self.receipt, "source_run_attempt": True}},
        ):
            with self.subTest(change=change):
                self.reference = {**original, **change}
                self.assertFalse(self.probe())

    def test_receipt_arrays_extra_members_and_large_sidecars_are_misses(self):
        original = self.reference
        self.reference = []
        self.assertFalse(self.probe())
        self.reference = original
        self.extra_member = True
        self.assertFalse(self.probe())
        self.extra_member = False
        self.sidecar["size_in_bytes"] = 65537
        self.downloaded.clear()
        self.assertFalse(self.probe())
        self.assertFalse(self.downloaded)

    def test_zip_tampering_and_non_receipt_members_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(
                artifacts.subprocess,
                "run",
                side_effect=lambda command, stdout, **kw: stdout.write(b"tampered"),
            ):
                with self.assertRaisesRegex(ValueError, "ZIP digest"):
                    artifacts.download_zip(
                        REPOSITORY,
                        {"id": 1, "digest": "sha256:" + "a" * 64},
                        Path(directory) / "download.zip",
                    )

    def test_deleted_original_api_is_an_optional_miss_but_auth_errors_propagate(self):
        for status, expected in ((404, None), (403, "error")):
            error = subprocess.CalledProcessError(
                1, ["gh"], output=json.dumps({"status": str(status)}).encode()
            )
            with patch.object(artifacts, "api", side_effect=error):
                if expected is None:
                    self.assertIsNone(
                        artifacts.optional_api(REPOSITORY, "actions/artifacts/400")
                    )
                else:
                    with self.assertRaises(subprocess.CalledProcessError):
                        artifacts.optional_api(REPOSITORY, "actions/artifacts/400")

    def test_published_sidecar_binds_current_job_original_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "identity.json").write_text(json.dumps(self.receipt))
            with (
                patch.object(artifacts, "api", return_value=self.payload),
                patch.dict(
                    "os.environ", {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
                ),
            ):
                artifacts.publish_receipt(
                    REPOSITORY, COMPONENT, IDENTITY, source, 400, root / "output"
                )
                value = json.loads((root / "output/receipt.json").read_text())
                self.assertEqual(value, self.reference)
                self.payload["workflow_run"] = {"id": 999}
                with self.assertRaisesRegex(ValueError, "current producer"):
                    artifacts.publish_receipt(
                        REPOSITORY, COMPONENT, IDENTITY, source, 400, root / "bad"
                    )
