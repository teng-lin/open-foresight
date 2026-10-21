"""Frozen API metadata exercises; no local HEAD/history or inherited CI state."""

from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile

from tools import ci_main_evidence as evidence
from tools import ci_main_sweep as sweep
from tools import ci_main_coordinator as coordinator

REPOSITORY = "example/reviewed"
SOURCE, BEFORE, HEAD, TREE = (letter * 40 for letter in "abcd")
STAMP = "2026-10-20T12:00:00Z"


def run(number, path=evidence.PLATFORM, source=HEAD, event="pull_request"):
    return {
        "id": number,
        "path": path,
        "head_sha": source,
        "event": event,
        "head_branch": "feature" if event == "pull_request" else "main",
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
        "check_suite_id": number + 1000,
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 1,
        "run_started_at": STAMP,
        "display_title": "Platform checks",
    }


def job(number, name, conclusion="success", attempt=1):
    return {
        "id": number,
        "name": name,
        "conclusion": conclusion,
        "status": "completed",
        "run_attempt": attempt,
        "started_at": STAMP,
        "completed_at": "2026-10-20T12:10:00Z",
    }


class FixtureReader(evidence.Reader):
    @staticmethod
    def fixture_api(repository, route, *args, **kwargs):
        if route.startswith("actions/artifacts?name=ci-qualification-index"):
            return {"artifacts": []}
        raise AssertionError("Unconfigured fixture API request: " + route)

    def __init__(self):
        super().__init__(REPOSITORY, api=self.fixture_api)
        self.main = SOURCE
        self.origin = run(10)
        self.quality = run(20, ".github/workflows/quality.yml")
        self.origins = [self.origin, self.quality]
        self.selection_record = {
            "superseded": False,
            "sweep_namespace": "production",
            "selection": sweep.application_selection(),
        }
        self.proof = {
            "run": 10,
            "job": 99,
            "attempt": 1,
            "artifact": 50,
            "sha256": "sha256:" + "e" * 64,
        }
        self.job_rows = {
            10: [job(99, "changes")]
            + [
                job(index + 100, name)
                for index, name in enumerate(
                    [
                        child
                        for owner in evidence.APPLICATION
                        for child in evidence.GROUPS.get(owner, (owner,))
                    ]
                    + ["platform-checks", "acceptance-checks", "workflow-lint"]
                )
            ],
            20: [job(201, "python"), job(202, "format"), job(203, "contracts")],
        }
        self.checks = [
            {
                "id": index + 500,
                "name": name,
                "head_sha": HEAD,
                "app": {"id": evidence.APP},
                "status": "completed",
                "conclusion": "success",
                "check_suite": {
                    "id": 1020 if workflow.endswith("quality.yml") else 1010
                },
            }
            for index, (name, workflow) in enumerate(evidence.REQUIRED.items())
        ]
        self.pr = {
            "number": 1,
            "merged_at": STAMP,
            "merge_commit_sha": SOURCE,
            "head": {"sha": HEAD, "repo": {"full_name": REPOSITORY}},
            "base": {"ref": "main", "repo": {"full_name": REPOSITORY}},
            "user": {"login": "developer"},
        }
        self.records = {
            "rules/branches/main": [
                {
                    "type": "required_status_checks",
                    "parameters": {
                        "required_status_checks": [
                            {"context": name, "integration_id": evidence.APP}
                            for name in evidence.REQUIRED
                        ]
                    },
                }
            ],
            f"git/commits/{SOURCE}": {
                "tree": {"sha": TREE},
                "parents": [{"sha": BEFORE}],
            },
            f"git/commits/{HEAD}": {"tree": {"sha": TREE}},
            f"git/trees/{TREE}?recursive=1": {
                "truncated": False,
                "tree": [
                    {
                        "path": "tools/pins.json",
                        "mode": "100644",
                        "type": "blob",
                        "sha": "f" * 40,
                    },
                ],
            },
        }
        self.previous_record = None

    def get(self, route):
        if route == "commits/main":
            return {"sha": self.main}
        if route.startswith("compare/"):
            return {"status": "identical"}
        if route.startswith("actions/runs/"):
            return next(
                row for row in self.origins if row["id"] == int(route.split("/")[2])
            )
        return self.records[route]

    def rows(self, route, key):
        if route.endswith("/pulls"):
            return [self.pr]
        if "/check-runs" in route:
            return self.checks
        raise AssertionError(route)

    def runs(self, workflow, source):
        return sorted(
            [
                row
                for row in self.origins
                if row["path"] == workflow and row["head_sha"] == source
            ],
            key=lambda row: row["id"],
            reverse=True,
        )

    def jobs(self, run_record):
        return self.job_rows[run_record["id"]]

    def artifact(self, run_record, name, member, owner):
        if name.startswith("ci-main-observation-"):
            return self.previous_record, self.proof
        return self.selection_record, self.proof


class MainEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.reader = FixtureReader()
        self.selected = dict.fromkeys(evidence.APPLICATION, True)

    def proposal(self):
        return self.reader.proposal(SOURCE, BEFORE, self.selected)

    def test_complete_same_tree_proposal_is_only_observation(self):
        result = self.proposal()
        self.assertEqual(result["decision"], "validated")
        self.assertEqual(result["mode"], "observation")
        self.assertEqual(set(result["jobs"]), set(evidence.APPLICATION))
        self.assertEqual(len(result["jobs"]["linux-native"]["executions"]), 4)

    def test_arch_owner_retirement_requires_independently_verified_current_proof(self):
        self.reader.selection_record["arch_retired"] = True
        with patch.object(self.reader, "arch_retired", return_value=False):
            self.assertEqual(self.proposal()["decision"], "sweep")
        self.reader.job_rows[10] = [
            row for row in self.reader.job_rows[10]
            if not row["name"].startswith("linux-native / ")
        ]
        with patch.object(self.reader, "arch_retired", return_value=True):
            result = self.proposal()
        self.assertEqual(result["decision"], "validated")
        self.assertNotIn("linux-native", result["jobs"])
        self.assertEqual(set(result["owners"]), set(evidence.APPLICATION) - {"linux-native"})
        self.reader.selection_record["arch_retired"] = False
        with patch.object(self.reader, "arch_retired", return_value=False):
            # Revoked/unavailable proof restores the owner and fresh validation.
            self.assertEqual(self.proposal()["decision"], "sweep")

    def test_arch_retirement_capability_is_verified_with_reader_repository_and_api(self):
        verifier = Mock(return_value={"eligible": True})
        module = SimpleNamespace(capability=verifier)
        with patch.dict("sys.modules", {"tools.ci_qualification_index": module}):
            self.assertTrue(self.reader.arch_retired(SOURCE))
            self.assertTrue(self.reader.arch_retired(SOURCE))
        verifier.assert_called_once_with(
            "arch_retirement", SOURCE,
            repository=REPOSITORY, api=self.reader.api,
        )
        for error in (ValueError("missing"), KeyError("expired"), TypeError("invalid")):
            with self.subTest(error=error):
                reader = FixtureReader()
                verifier.side_effect = error
                with patch.dict("sys.modules", {"tools.ci_qualification_index": module}):
                    self.assertFalse(reader.arch_retired(SOURCE))

    def test_arch_retirement_marker_is_strict_and_false_keeps_original_owner(self):
        for marker in (None, 1, "true"):
            with self.subTest(marker=marker), self.assertRaisesRegex(ValueError, "boolean"):
                evidence.selection_jobs({**self.reader.selection_record, "arch_retired": marker})
        self.assertTrue(evidence.selection_jobs(self.reader.selection_record)["linux-native"])

    def test_different_main_tree_and_bad_pr_metadata_require_sweep(self):
        edits = [
            lambda: self.reader.records[f"git/commits/{HEAD}"]["tree"].update(
                sha="f" * 40
            ),
            lambda: self.reader.pr["head"]["repo"].update(full_name="foreign/repo"),
            lambda: self.reader.pr["base"].update(ref="release"),
            lambda: self.reader.pr["user"].update(login="dependabot[bot]"),
            lambda: self.reader.pr.update(merge_commit_sha=BEFORE),
            lambda: self.reader.pr.update(merged_at=None),
        ]
        for edit in edits:
            with self.subTest(edit=edit):
                self.setUp()
                edit()
                self.assertEqual(self.proposal()["decision"], "sweep")

    def test_incompatible_selection_and_skipped_selected_jobs_require_sweep(self):
        for marker in (None, True, "false", 0):
            with self.subTest(marker=marker):
                self.reader.selection_record["superseded"] = marker
                self.assertEqual(self.proposal()["decision"], "sweep")
        self.setUp()
        self.reader.selection_record["selection"]["macos"] = False
        self.assertEqual(self.proposal()["decision"], "sweep")
        self.setUp()
        for outcome in ("skipped", "cancelled", "failure", "timed_out", None):
            self.reader.job_rows[10][2]["conclusion"] = outcome
            self.assertEqual(self.proposal()["decision"], "sweep")

    def test_required_check_app_workflow_suite_head_and_latest_status(self):
        for field, value in (
            ("app", {"id": 1}),
            ("head_sha", BEFORE),
            ("check_suite", {"id": 1}),
            ("conclusion", "failure"),
            ("status", "queued"),
        ):
            with self.subTest(field=field):
                self.setUp()
                self.reader.checks[0][field] = value
                self.assertEqual(self.proposal()["decision"], "sweep")
        self.setUp()
        bad = deepcopy(self.reader.checks[0])
        bad.update(id=9999, conclusion="cancelled")
        self.reader.checks.append(bad)
        self.assertEqual(self.proposal()["decision"], "sweep")

    def test_ruleset_changes_cannot_silently_reuse_old_required_set(self):
        checks = self.reader.records["rules/branches/main"][0]["parameters"][
            "required_status_checks"
        ]
        checks.append({"context": "new-required-gate", "integration_id": evidence.APP})
        self.assertEqual(self.proposal()["decision"], "sweep")
        checks.pop()
        checks[0]["integration_id"] = 1
        self.assertEqual(self.proposal()["decision"], "sweep")
        self.setUp()
        self.reader.quality["path"] = ".github/workflows/renamed.yml"
        self.assertEqual(self.proposal()["decision"], "sweep")

    def test_new_failed_attempt_invalidates_green_original_execution(self):
        original = self.proposal()["jobs"]["macos"]
        self.reader.job_rows[10].append(job(9999, "macos", "failure", attempt=2))
        self.assertEqual(self.proposal()["decision"], "sweep")
        with self.assertRaisesRegex(ValueError, "Latest required job"):
            self.reader.verify_origin(original)

    def test_new_unfinished_or_failed_run_attempt_invalidates_old_green_jobs(self):
        for status, conclusion in (
            ("queued", None),
            ("in_progress", None),
            ("completed", "cancelled"),
            ("completed", "failure"),
        ):
            with self.subTest(status=status, conclusion=conclusion):
                self.setUp()
                self.reader.origin.update(
                    run_attempt=2, status=status, conclusion=conclusion
                )
                self.assertEqual(self.proposal()["decision"], "sweep")
                # Read-only comparison still reports actual incomplete work.
                current = run(40, source=SOURCE, event="push")
                current.update(status=status, conclusion=conclusion)
                self.reader.origins.append(current)
                self.reader.job_rows[40] = self.reader.job_rows[10]
                self.assertEqual(
                    self.reader.actual(SOURCE, self.selected)["status"], status
                )

    def test_missing_gate_and_changed_origin_require_fresh_evidence(self):
        origin = self.proposal()["jobs"]["macos"]
        self.reader.job_rows[10] = [
            row for row in self.reader.job_rows[10] if row["name"] != "macos"
        ]
        self.assertEqual(self.proposal()["decision"], "sweep")
        self.setUp()
        origin["executions"]["macos"]["attempt"] = 99
        with self.assertRaisesRegex(ValueError, "authoritative"):
            self.reader.verify_origin(origin)

    def test_identity_includes_file_modes_and_installed_markdown(self):
        initial = self.reader.input_identity(SOURCE)
        tree = self.reader.records[f"git/trees/{TREE}?recursive=1"]
        tree["tree"].append(
            {"path": "docs/notes.md", "mode": "100644", "type": "blob", "sha": HEAD}
        )
        self.assertEqual(self.reader.input_identity(SOURCE), initial)
        tree["tree"].append(
            {
                "path": "packaging/notices/NOTICE.md",
                "mode": "100644",
                "type": "blob",
                "sha": HEAD,
            }
        )
        self.assertNotEqual(self.reader.input_identity(SOURCE), initial)
        tree["tree"] = tree["tree"][:1]
        tree["tree"][0]["mode"] = "100755"
        self.assertNotEqual(self.reader.input_identity(SOURCE), initial)
        tree["truncated"] = True
        with self.assertRaisesRegex(ValueError, "Complete"):
            self.reader.input_identity(SOURCE)

    def test_invalid_source_and_unreviewed_ancestry(self):
        for value in ("main", "a" * 39, "z" * 40, None):
            with self.assertRaises(ValueError):
                evidence.require_source(value)
        self.reader.records[f"git/commits/{SOURCE}"]["parents"] = [{"sha": HEAD}]
        self.assertEqual(self.proposal()["decision"], "sweep")
        self.setUp()
        original = self.reader.get
        with patch.object(
            self.reader,
            "get",
            side_effect=lambda route: (
                {"status": "diverged"}
                if route.startswith("compare/")
                else original(route)
            ),
        ):
            self.assertEqual(self.proposal()["decision"], "sweep")

    def test_chain_requires_compatible_predecessor_and_revalidates_origins(self):
        previous = self.proposal()
        observer = run(30, evidence.WORKFLOW, BEFORE, "push")
        self.reader.origins.append(observer)
        previous["source"] = BEFORE
        self.reader.previous_record = previous
        actual, locator = self.reader.previous(BEFORE, previous["input_identity"])
        self.assertEqual(actual, previous)
        self.assertEqual(locator["attempt"], 1)
        for field, value in (
            ("mode", "production"),
            ("input_identity", "different"),
            ("decision", "sweep"),
            ("required", {}),
        ):
            with self.subTest(field=field):
                self.reader.previous_record = {**previous, field: value}
                with self.assertRaisesRegex(ValueError, "incompatible"):
                    self.reader.previous(BEFORE, previous["input_identity"])
        self.reader.previous_record = previous
        self.reader.checks[0]["conclusion"] = "failure"
        with self.assertRaises(ValueError):
            self.reader.previous(BEFORE, previous["input_identity"])

    def test_no_predecessor_cannot_launder_docs_on_divergent_main(self):
        self.reader.selection_record["selection"] = dict.fromkeys(
            sweep.application_selection(), False
        )
        self.selected = dict.fromkeys(evidence.APPLICATION, False)
        self.assertEqual(self.proposal()["decision"], "sweep")

    def test_actual_main_preserves_failures_and_pending_state(self):
        main = run(40, source=SOURCE, event="push")
        self.reader.origins.append(main)
        self.reader.job_rows[40] = deepcopy(self.reader.job_rows[10])
        self.reader.job_rows[40][2]["conclusion"] = "failure"
        actual = self.reader.actual(SOURCE, self.selected)
        self.assertEqual(actual["jobs"]["linux-test"]["result"], "unresolved")
        self.assertEqual(actual["jobs"]["macos"]["result"], "success")

    def test_api_pages_and_original_upload_are_verified_independently(self):
        called = []

        def api(repo, route):
            called.append((repo, route))
            return {"workflow_runs": [self.reader.origin]}

        reader = evidence.Reader(REPOSITORY, api=api)
        self.assertEqual(reader.runs(evidence.PLATFORM, HEAD), [self.reader.origin])
        self.assertIn("per_page=100&page=1", called[0][1])
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "selection.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr(
                    "ci-selection.json", json.dumps(self.reader.selection_record)
                )
            checksum = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
            artifact = {
                "id": 1,
                "name": "ci-selection-platform",
                "expired": False,
                "size_in_bytes": archive.stat().st_size,
                "digest": checksum,
                "workflow_run": {"id": 10},
                "created_at": "2026-10-20T12:05:00Z",
                "updated_at": "2026-10-20T12:05:00Z",
            }

            def download(repository, item, destination):
                destination.write_bytes(archive.read_bytes())
                if (
                    "sha256:" + hashlib.sha256(destination.read_bytes()).hexdigest()
                    != item["digest"]
                ):
                    raise ValueError("Artifact ZIP digest mismatch")

            with (
                patch.object(reader, "jobs", return_value=[job(99, "changes")]),
                patch.object(reader, "rows", return_value=[artifact]),
                patch("tools.ci_artifacts.download_zip", side_effect=download),
            ):
                record, proof = reader.selection(self.reader.origin)
                self.assertEqual(record, self.reader.selection_record)
                self.assertEqual(proof["attempt"], 1)
                artifact["digest"] = "sha256:" + "0" * 64
                with self.assertRaisesRegex(ValueError, "digest"):
                    reader.selection(self.reader.origin)
                artifact["expired"] = True
                with self.assertRaisesRegex(ValueError, "uploading attempt"):
                    reader.selection(self.reader.origin)

    def test_original_receipt_attempt_survives_later_successful_readiness(self):
        # Selection was uploaded on attempt 1; a later successful macOS rerun
        # changes readiness while preserving that exact upload's provenance.
        self.reader.job_rows[10].append(job(9999, "macos", "success", attempt=2))
        result = self.proposal()
        self.assertEqual(result["decision"], "validated")
        self.assertEqual(result["jobs"]["macos"]["selection_upload"]["attempt"], 1)
        self.assertEqual(result["jobs"]["macos"]["executions"]["macos"]["attempt"], 2)

    def test_explicit_ci_ref_matrix_cannot_change_fixture_identity(self):
        for ref in ("refs/pull/999/merge", "refs/heads/main", None):
            with (
                self.subTest(ref=ref),
                patch.dict(os.environ, {"GITHUB_REF": ref} if ref else {}, clear=True),
            ):
                self.assertEqual(self.proposal()["decision"], "validated")

    def test_schema_and_missing_checks_are_rejected(self):
        for selection in (
            {"superseded": False, "selection": {}},
            {
                "superseded": False,
                "selection": dict.fromkeys(sweep.application_selection(), "false"),
            },
        ):
            with self.assertRaisesRegex(ValueError, "schema"):
                evidence.selection_jobs(selection)
        self.reader.checks.pop()
        self.assertEqual(self.proposal()["decision"], "sweep")
        with self.assertRaisesRegex(ValueError, "namespace"):
            evidence.Reader(REPOSITORY, mode="preview")

    def test_changed_original_checks_and_selection_upload_are_not_accepted(self):
        origin = self.proposal()["jobs"]["macos"]
        self.reader.checks[0]["id"] += 1
        with self.assertRaisesRegex(ValueError, "readiness changed"):
            self.reader.verify_origin(origin)
        self.setUp()
        self.reader.proof = {**self.reader.proof, "artifact": 999}
        with self.assertRaisesRegex(ValueError, "selection changed"):
            self.reader.verify_origin(origin)

    def test_doc_chain_copies_only_verified_predecessor_jobs(self):
        previous = self.proposal()
        self.reader.selection_record["selection"] = dict.fromkeys(
            sweep.application_selection(), False
        )
        self.selected = dict.fromkeys(evidence.APPLICATION, False)
        with patch.object(
            self.reader, "previous", return_value=(previous, self.reader.proof)
        ):
            result = self.proposal()
        self.assertEqual(result["decision"], "validated")
        self.assertEqual(result["jobs"], previous["jobs"])
        self.assertEqual(result["predecessor"], self.reader.proof)

    def test_reader_get_jobs_artifact_rejects_ambiguous_window(self):
        reader = evidence.Reader(REPOSITORY, api=lambda repo, route: {"jobs": []})
        self.assertEqual(reader.jobs(self.reader.origin), [])
        self.assertEqual(reader.run(10), {"jobs": []})
        items = [
            {
                "id": 1,
                "name": "ci-selection-platform",
                "expired": False,
                "workflow_run": {"id": 10},
                "created_at": "2026-10-20T13:00:00Z",
            }
        ]
        with (
            patch.object(
                reader, "jobs", return_value=[job(98, "ignored"), job(99, "changes")]
            ),
            patch.object(reader, "rows", return_value=items),
        ):
            with self.assertRaisesRegex(ValueError, "uploading attempt"):
                reader.selection(self.reader.origin)

    def test_observer_cli_is_read_only_and_handles_unavailable_main(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "receipt.json"
            summary = Path(temporary) / "summary"
            args = ["evidence", "--source", SOURCE, "--output", str(output)]
            env = {
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_STEP_SUMMARY": str(summary),
            }
            with (
                patch.dict(os.environ, env, clear=True),
                patch("sys.argv", args),
                patch.object(evidence, "Reader", return_value=self.reader),
                patch.object(evidence, "selected_on_push", return_value=self.selected),
            ):
                evidence.main()
            self.assertEqual(
                json.loads(output.read_text())["actual_main"]["status"], "unavailable"
            )
            self.assertIn("Observation only", summary.read_text())
            with (
                patch.dict(
                    os.environ, {**env, "GITHUB_REF": "refs/pull/2/merge"}, clear=True
                ),
                patch("sys.argv", args),
            ):
                with self.assertRaisesRegex(ValueError, "main-only"):
                    evidence.main()

    def test_selection_recomputation_passes_frozen_revisions_not_local_head(self):
        with patch(
            "subprocess.check_output", return_value=b"native/example.cpp\0"
        ) as command:
            selected = evidence.selected_on_push(Path("/fixture"), BEFORE, SOURCE)
        self.assertTrue(all(selected.values()))
        self.assertEqual(command.call_args.args[0][-3:], [BEFORE, SOURCE, "--"])

    def test_observer_qualification_requires_completed_actual_parity(self):
        proposal = {
            "decision": "validated",
            "actual_main": {
                "status": "completed",
                "conclusion": "success",
                "aggregates_success": True,
                "jobs": {},
            },
        }
        self.assertTrue(evidence.observation_qualified(proposal))
        for field, value in (
            ("status", "in_progress"),
            ("conclusion", "failure"),
            ("aggregates_success", False),
        ):
            candidate = deepcopy(proposal)
            candidate["actual_main"][field] = value
            self.assertFalse(evidence.observation_qualified(candidate))
        proposal["decision"] = "sweep"
        self.assertFalse(evidence.observation_qualified(proposal))
        proposal["actual_main"]["jobs"] = {
            name: {"result": "success"} for name in evidence.APPLICATION
        }
        self.assertTrue(evidence.observation_qualified(proposal))
        proposal["actual_main"]["jobs"]["macos"]["result"] = "unresolved"
        self.assertFalse(evidence.observation_qualified(proposal))

    def test_observer_descriptor_is_emitted_only_for_actual_current_source_parity(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = Path(temporary) / "receipt.json"
            qualification = Path(temporary) / "qualification.json"
            github_output = Path(temporary) / "outputs"
            env = {
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_SHA": SOURCE,
                "GITHUB_RUN_ID": "50",
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_OUTPUT": str(github_output),
            }
            args = [
                "evidence",
                "--source",
                SOURCE,
                "--output",
                str(receipt),
                "--qualification-output",
                str(qualification),
            ]
            actual = {
                "status": "completed",
                "conclusion": "success",
                "aggregates_success": True,
                "jobs": {},
            }
            with (
                patch.dict(os.environ, env, clear=True),
                patch("sys.argv", args),
                patch.object(evidence, "Reader", return_value=self.reader),
                patch.object(evidence, "selected_on_push", return_value=self.selected),
                patch.object(self.reader, "actual", return_value=actual),
                patch(
                    "tools.ci_rollout.descriptor", return_value={"schema": 1}
                ) as descriptor,
            ):
                evidence.main()
            self.assertEqual(descriptor.call_args.kwargs["producer_job"], "observe")
            self.assertEqual(
                json.loads(qualification.read_text())["observation"]["decision"],
                "validated",
            )
            self.assertIn("qualified=true", github_output.read_text())

    def test_qualification_cases_derive_from_actual_evidence_not_flags(self):
        actual = {
            "status": "completed",
            "conclusion": "success",
            "aggregates_success": True,
            "jobs": {name: {"result": "success"} for name in evidence.APPLICATION},
        }
        proposal = {
            "source": SOURCE,
            "decision": "validated",
            "actual_main": actual,
            "jobs": {"macos": {"source": SOURCE}},
        }
        self.assertEqual(evidence.observation_case(proposal), "identical")
        proposal["jobs"]["macos"]["source"] = BEFORE
        self.assertEqual(evidence.observation_case(proposal), "partially-selected")
        proposal.update(decision="sweep", reason="API evidence missing")
        self.assertIsNone(evidence.observation_case(proposal))
        proposal["reason"] = "Final PR and reviewed main trees differ"
        self.assertEqual(evidence.observation_case(proposal), "divergent")
        actual["historical_failure"] = True
        self.assertEqual(evidence.observation_case(proposal), "failed-rerun")
        actual["status"] = "in_progress"
        self.assertIsNone(evidence.observation_case(proposal))

    def test_actual_rerun_case_requires_an_observed_earlier_failed_job(self):
        current = run(40, source=SOURCE, event="push")
        current["run_attempt"] = 2
        self.reader.origins.append(current)
        self.reader.job_rows[40] = deepcopy(self.reader.job_rows[10])
        self.assertIs(
            self.reader.actual(SOURCE, self.selected)["historical_failure"], False
        )
        self.reader.job_rows[40].append(job(9999, "historical", "failure", 1))
        self.assertIs(
            self.reader.actual(SOURCE, self.selected)["historical_failure"], True
        )


class SweepTests(unittest.TestCase):
    def setUp(self):
        self.reader = FixtureReader()
        self.current = run(40, source=SOURCE, event="workflow_dispatch")
        self.reader.selection_record["sweep_namespace"] = "exercise"
        self.reader.origins.append(self.current)

    def test_sweep_application_mode_keeps_packaging_unselected(self):
        selected = sweep.application_selection()
        self.assertFalse(selected["packaging"])
        self.assertTrue(
            all(value for name, value in selected.items() if name != "packaging")
        )

    def test_stale_source_and_untrusted_run_do_not_start_sweep(self):
        self.reader.main = BEFORE
        self.assertIn("no longer", sweep.guard(self.reader, SOURCE, 40))
        self.reader.main = SOURCE
        self.current["event"] = "pull_request"
        with self.assertRaises(ValueError):
            sweep.guard(self.reader, SOURCE, 40)

    def test_only_earlier_executing_marked_sweep_supersedes(self):
        duplicate = run(30, source=SOURCE, event="workflow_dispatch")
        duplicate.update(
            display_title=sweep.sweep_title(SOURCE, "exercise"), status="queued"
        )
        self.reader.origins.append(duplicate)
        self.assertEqual(sweep.guard(self.reader, SOURCE, 40), "")
        duplicate["status"] = "in_progress"
        self.reader.selection_record["sweep"] = True
        self.assertIn("earlier", sweep.guard(self.reader, SOURCE, 40))
        self.reader.selection_record["superseded"] = True
        self.assertEqual(sweep.guard(self.reader, SOURCE, 40), "")

    def test_completed_sweep_requires_real_full_job_execution(self):
        duplicate = run(30, source=SOURCE, event="workflow_dispatch")
        duplicate["display_title"] = sweep.sweep_title(SOURCE, "exercise")
        self.reader.origins.append(duplicate)
        self.reader.job_rows[30] = self.reader.job_rows[10]
        self.assertEqual(sweep.guard(self.reader, SOURCE, 40), "")
        self.reader.selection_record["sweep"] = True
        self.assertIn("already validated", sweep.guard(self.reader, SOURCE, 40))
        self.reader.job_rows[30][2]["conclusion"] = "skipped"
        self.assertEqual(sweep.guard(self.reader, SOURCE, 40), "")

    def test_sweep_rejects_failed_or_unfinished_latest_attempt_with_old_green_jobs(
        self,
    ):
        self.reader.job_rows[40] = self.reader.job_rows[10]
        self.reader.selection_record["sweep"] = True
        for status, conclusion in (
            ("queued", None),
            ("in_progress", None),
            ("completed", "cancelled"),
            ("completed", "failure"),
        ):
            self.current.update(status=status, conclusion=conclusion, run_attempt=2)
            with self.assertRaisesRegex(ValueError, "Latest validation run attempt"):
                sweep.qualify(self.reader, self.current)

    def test_production_dispatch_disabled_and_exercise_is_idempotent(self):
        with self.assertRaises(ValueError):
            sweep.dispatch(self.reader, source=SOURCE, index={})
        with patch.object(self.reader, "api") as api:
            result = sweep.dispatch(self.reader, source=SOURCE, exercise=True)
            self.assertEqual(result["status"], "exercise-dispatched")
            self.assertEqual(
                api.call_args.args[3]["inputs"],
                {"source": SOURCE, "sweep": True, "sweep_namespace": "exercise"},
            )
        self.current.update(
            status="queued", display_title=sweep.sweep_title(SOURCE, "exercise")
        )
        self.assertEqual(
            sweep.dispatch(self.reader, source=SOURCE, exercise=True)["status"],
            "already-active",
        )
        self.reader.main = BEFORE
        self.assertEqual(
            sweep.dispatch(self.reader, source=SOURCE, exercise=True)["status"],
            "superseded",
        )

    def test_sweep_cli_writes_false_marker_and_empty_superseded_selection(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "selection.json"
            github_output = Path(temporary) / "outputs"
            env = {
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_RUN_ID": "40",
                "GITHUB_OUTPUT": str(github_output),
            }
            args = ["sweep", "guard", "--source", SOURCE, "--output", str(output)]
            with (
                patch.dict(os.environ, env, clear=True),
                patch("sys.argv", args),
                patch.object(sweep, "Reader", return_value=self.reader),
            ):
                sweep.main()
                self.assertIs(json.loads(output.read_text())["superseded"], False)
                self.reader.main = BEFORE
                sweep.main()
                self.assertFalse(
                    any(json.loads(output.read_text())["selection"].values())
                )
            self.assertIn("linux_build=false", github_output.read_text())
            with patch.dict(os.environ, {}, clear=True), patch("sys.argv", args):
                with self.assertRaisesRegex(ValueError, "reviewed main"):
                    sweep.main()


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.reader = FixtureReader()
        self.reader.mode = "production"

    def test_missing_hosted_qualification_always_denies_activation(self):
        with patch.object(
            coordinator, "authorize", side_effect=ValueError("unqualified")
        ):
            self.assertIs(coordinator.activation(self.reader, SOURCE)["active"], False)
            with self.assertRaises(ValueError):
                coordinator.reconcile(self.reader, SOURCE, BEFORE)
        with patch.object(coordinator, "authorize", return_value={}):
            self.assertIs(coordinator.activation(self.reader, SOURCE)["active"], True)

    def test_qualified_same_tree_receipt_stays_in_production_namespace(self):
        with (
            patch.object(coordinator, "authorize"),
            patch.object(
                coordinator,
                "selected_on_push",
                return_value=dict.fromkeys(evidence.APPLICATION, True),
            ),
        ):
            result = coordinator.reconcile(self.reader, SOURCE, BEFORE)
        self.assertEqual(result["decision"], "validated")
        self.assertEqual(result["mode"], "production")
        self.reader.main = BEFORE
        with patch.object(coordinator, "authorize"):
            self.assertEqual(
                coordinator.reconcile(self.reader, SOURCE, BEFORE)["decision"],
                "superseded",
            )

    def test_failed_sweep_reruns_failed_jobs_once_and_never_restarts_successes(self):
        run_record = run(40, source=SOURCE, event="workflow_dispatch")
        run_record.update(
            display_title=sweep.sweep_title(SOURCE, "production"), conclusion="failure"
        )
        self.reader.origins.append(run_record)
        self.reader.job_rows[40] = [job(99, "changes", "failure")]
        with (
            patch.object(coordinator, "authorize"),
            patch.object(coordinator, "selected_on_push", return_value={}),
            patch.object(self.reader, "proposal", return_value={"decision": "sweep"}),
            patch.object(self.reader, "api") as api,
        ):
            result = coordinator.reconcile(self.reader, SOURCE, BEFORE)
            self.assertEqual(result["decision"], "retry-requested")
            self.assertEqual(api.call_args.args[1], "actions/runs/40/rerun-failed-jobs")
            run_record["run_attempt"] = 2
            self.assertEqual(
                coordinator.reconcile(self.reader, SOURCE, BEFORE)["decision"], "failed"
            )
            run_record["status"] = "in_progress"
            self.assertEqual(
                coordinator.reconcile(self.reader, SOURCE, BEFORE)["decision"],
                "waiting",
            )

    def test_fresh_sweep_receipt_qualifies_actual_jobs(self):
        run_record = run(40, source=SOURCE, event="workflow_dispatch")
        run_record["display_title"] = sweep.sweep_title(SOURCE, "production")
        self.reader.origins.append(run_record)
        self.reader.job_rows[40] = self.reader.job_rows[10]
        self.reader.selection_record["sweep"] = True
        result = coordinator.sweep_receipt(self.reader, run_record, BEFORE)
        self.assertEqual(result["decision"], "validated")
        self.reader.verify_origin(result["jobs"]["macos"])
        result["jobs"]["macos"]["head"] = HEAD
        with self.assertRaisesRegex(ValueError, "source differs"):
            self.reader.verify_origin(result["jobs"]["macos"])

    def test_qualified_retirement_sweep_records_current_owners_without_arch_jobs(self):
        run_record = run(40, source=SOURCE, event="workflow_dispatch")
        run_record["display_title"] = sweep.sweep_title(SOURCE, "production")
        self.reader.origins.append(run_record)
        self.reader.job_rows[40] = [
            row for row in self.reader.job_rows[10]
            if not row["name"].startswith("linux-native / ")
        ]
        self.reader.selection_record.update(sweep=True, arch_retired=True)
        with patch.object(self.reader, "arch_retired", return_value=True):
            receipt = coordinator.sweep_receipt(self.reader, run_record, BEFORE)
            self.reader.verify_origin(receipt["jobs"]["macos"])
        self.assertNotIn("linux-native", receipt["jobs"])
        self.assertEqual(set(receipt["owners"]), set(evidence.APPLICATION) - {"linux-native"})
        with patch.object(self.reader, "arch_retired", return_value=False):
            with self.assertRaisesRegex(ValueError, "verified hosted qualification"):
                coordinator.sweep_receipt(self.reader, run_record, BEFORE)

    def test_chained_sweep_cannot_hide_newer_production_readiness(self):
        for status, conclusion in (
            ("completed", "failure"),
            ("completed", "cancelled"),
            ("in_progress", None),
            ("queued", None),
            ("completed", "success"),
        ):
            with self.subTest(status=status, conclusion=conclusion):
                reader = FixtureReader()
                original = run(40, source=SOURCE, event="workflow_dispatch")
                original["display_title"] = sweep.sweep_title(SOURCE, "production")
                reader.origins.append(original)
                reader.job_rows[40] = reader.job_rows[10]
                reader.selection_record["sweep"] = True
                receipt = coordinator.sweep_receipt(reader, original, BEFORE)
                newer = run(50, source=SOURCE, event="workflow_dispatch")
                newer.update(
                    display_title=sweep.sweep_title(SOURCE, "production"),
                    status=status,
                    conclusion=conclusion,
                )
                reader.origins.append(newer)
                with self.assertRaisesRegex(ValueError, "latest production validation"):
                    reader.verify_origin(receipt["jobs"]["macos"])

    def test_chained_sweep_ignores_newer_exercise_and_unrelated_runs(self):
        original = run(40, source=SOURCE, event="workflow_dispatch")
        original["display_title"] = sweep.sweep_title(SOURCE, "production")
        self.reader.origins.append(original)
        self.reader.job_rows[40] = self.reader.job_rows[10]
        self.reader.selection_record["sweep"] = True
        receipt = coordinator.sweep_receipt(self.reader, original, BEFORE)
        for namespace, event in (("exercise", "workflow_dispatch"), ("production", "push")):
            newer = run(50, source=SOURCE, event=event)
            newer.update(
                display_title=sweep.sweep_title(SOURCE, namespace),
                status="completed",
                conclusion="failure",
            )
            self.reader.origins.append(newer)
        self.reader.verify_origin(receipt["jobs"]["macos"])

    def test_verified_superseded_duplicate_does_not_strand_sweep_or_chain(self):
        original = run(30, source=SOURCE, event="workflow_dispatch")
        original["display_title"] = sweep.sweep_title(SOURCE, "production")
        duplicate = run(40, source=SOURCE, event="workflow_dispatch")
        duplicate["display_title"] = original["display_title"]
        self.reader.origins.extend((original, duplicate))
        self.reader.job_rows[30] = self.reader.job_rows[10]
        self.reader.job_rows[40] = [job(99, "changes")]
        self.reader.selection_record["sweep"] = True
        active = self.reader.selection_record
        superseded = {
            **active,
            "superseded": True,
            "selection": dict.fromkeys(sweep.application_selection(), False),
        }

        def artifact(record, *args):
            return (superseded if record["id"] == 40 else active), self.reader.proof

        with (
            patch.object(self.reader, "artifact", side_effect=artifact),
            patch.object(coordinator, "authorize"),
            patch.object(coordinator, "selected_on_push", return_value={}),
            patch.object(self.reader, "proposal", return_value={"decision": "sweep"}),
        ):
            receipt = coordinator.reconcile(self.reader, SOURCE, BEFORE)
            self.assertEqual(receipt["decision"], "validated")
            self.assertEqual(receipt["jobs"]["macos"]["run"], 30)
            self.reader.verify_origin(receipt["jobs"]["macos"])
            # Invalid, partial or unsuccessful no-ops are never ignored.
            for change in (
                {"superseded": False},
                {"sweep": False},
                {"sweep_namespace": "exercise"},
                {"selection": {**superseded["selection"], "macos": True}},
                {"selection": dict.fromkeys(superseded["selection"], 0)},
            ):
                with self.subTest(change=change), patch.dict(superseded, change):
                    with self.assertRaisesRegex(ValueError, "latest production validation"):
                        self.reader.verify_origin(receipt["jobs"]["macos"])
            duplicate["conclusion"] = "failure"
            with self.assertRaisesRegex(ValueError, "latest production validation"):
                self.reader.verify_origin(receipt["jobs"]["macos"])

    def test_unverifiable_newer_duplicate_never_uncovers_old_green_sweep(self):
        original = run(30, source=SOURCE, event="workflow_dispatch")
        original["display_title"] = sweep.sweep_title(SOURCE, "production")
        self.reader.origins.append(original)
        self.reader.job_rows[30] = self.reader.job_rows[10]
        self.reader.selection_record["sweep"] = True
        receipt = coordinator.sweep_receipt(self.reader, original, BEFORE)
        duplicate = run(40, source=SOURCE, event="workflow_dispatch")
        duplicate["display_title"] = original["display_title"]
        self.reader.origins.append(duplicate)
        with patch.object(self.reader, "artifact", side_effect=ValueError("bad checksum")):
            with self.assertRaisesRegex(ValueError, "latest production validation"):
                self.reader.verify_origin(receipt["jobs"]["macos"])

    def test_issue_tracking_is_current_head_only_and_ignores_pending(self):
        result = {"source": SOURCE, "decision": "failed", "run": 40}
        with (
            patch.object(self.reader, "api", return_value=None) as api,
            patch.object(self.reader, "rows", return_value=[]),
        ):
            coordinator.track(self.reader, result)
            self.assertEqual(api.call_args.args[1], "issues")
            result["decision"] = "waiting"
            api.reset_mock()
            coordinator.track(self.reader, result)
            api.assert_not_called()
            result["decision"] = "validated"
            self.reader.main = BEFORE
            coordinator.track(self.reader, result)
            api.assert_not_called()
        self.reader.main = SOURCE
        with (
            patch.object(self.reader, "api") as api,
            patch.object(self.reader, "rows", return_value=[{"number": 7}]),
        ):
            coordinator.track(self.reader, result)
            self.assertEqual(api.call_args.args[3], {"state": "closed"})
            result["decision"] = "failed"
            coordinator.track(self.reader, result)
            self.assertIn("body", api.call_args.args[3])

    def test_authorization_delegates_exact_capability_to_frozen_rollout_verifier(self):
        calls = []
        module = SimpleNamespace(
            authorize=lambda index, **kwargs: (
                calls.append((index, kwargs)) or {"verified": True}
            )
        )
        with patch.dict("sys.modules", {"tools.ci_rollout": module}):
            self.assertEqual(coordinator.authorize(self.reader, SOURCE, index={"schema": 1}), {"verified": True})
        with patch("tools.ci_qualification_index.capability", return_value={"dynamic": True}) as dynamic:
            self.assertEqual(coordinator.authorize(self.reader, SOURCE), {"dynamic": True})
        self.assertEqual(dynamic.call_args.args, ("main_receipts", SOURCE))
        self.assertEqual(calls[0][1]["capabilities"], ("main_receipts",))
        self.assertEqual(calls[0][1]["source"], SOURCE)

    def test_coordinator_cli_status_and_reconciliation_keep_guarded_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result.json"
            github_output = Path(temporary) / "outputs"
            env = {
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "schedule",
                "GITHUB_OUTPUT": str(github_output),
            }
            args = [
                "coordinator",
                "status",
                "--source",
                SOURCE,
                "--output",
                str(output),
            ]
            with (
                patch.dict(os.environ, env, clear=True),
                patch("sys.argv", args),
                patch.object(coordinator, "Reader", return_value=self.reader),
                patch.object(coordinator, "activation", return_value={"active": False}),
            ):
                coordinator.main()
            self.assertIn("active=false", github_output.read_text())
            args[1] = "reconcile"
            result = {"source": SOURCE, "decision": "waiting"}
            with (
                patch.dict(os.environ, env, clear=True),
                patch("sys.argv", args),
                patch.object(coordinator, "Reader", return_value=self.reader),
                patch.object(coordinator, "reconcile", return_value=result),
                patch.object(coordinator, "track"),
            ):
                coordinator.main()
            self.assertEqual(json.loads(output.read_text()), result)
            self.assertIn("source=" + SOURCE, github_output.read_text())
            with patch.dict(os.environ, {}, clear=True), patch("sys.argv", args):
                with self.assertRaisesRegex(ValueError, "main-only"):
                    coordinator.main()

    def test_no_sweep_dispatches_only_after_authorization_and_queued_is_not_validation(
        self,
    ):
        with (
            patch.object(coordinator, "authorize"),
            patch.object(coordinator, "selected_on_push", return_value={}),
            patch.object(self.reader, "proposal", return_value={"decision": "sweep"}),
            patch.object(
                coordinator,
                "dispatch",
                return_value={"source": SOURCE, "status": "dispatched"},
            ),
        ):
            self.assertEqual(
                coordinator.reconcile(self.reader, SOURCE, BEFORE)["decision"],
                "sweep-requested",
            )

    def test_fully_green_exercise_cannot_supply_a_production_receipt(self):
        exercise = run(40, source=SOURCE, event="workflow_dispatch")
        exercise["display_title"] = sweep.sweep_title(SOURCE, "exercise")
        self.reader.origins.append(exercise)
        self.reader.job_rows[40] = self.reader.job_rows[10]
        self.reader.selection_record.update(sweep=True, sweep_namespace="exercise")
        sweep.qualify(self.reader, exercise, namespace="exercise")
        with self.assertRaisesRegex(ValueError, "application owner closure"):
            coordinator.sweep_receipt(self.reader, exercise, BEFORE)
        with (
            patch.object(coordinator, "authorize"),
            patch.object(coordinator, "selected_on_push", return_value={}),
            patch.object(self.reader, "proposal", return_value={"decision": "sweep"}),
            patch.object(self.reader, "api") as api,
        ):
            result = coordinator.reconcile(self.reader, SOURCE, BEFORE)
            self.assertEqual(result["decision"], "sweep-requested")
            self.assertEqual(
                api.call_args.args[3]["inputs"]["sweep_namespace"], "production"
            )

    def test_namespace_unknown_is_rejected_before_any_dispatch(self):
        with self.assertRaisesRegex(ValueError, "namespace"):
            sweep.sweep_title(SOURCE, "preview")


class SweepRecoveryTests(unittest.TestCase):
    def test_title_collision_from_push_never_blocks_guard_or_dispatch(self):
        reader = FixtureReader()
        current = run(40, source=SOURCE, event="workflow_dispatch")
        spoof = run(30, source=SOURCE, event="push")
        spoof.update(
            display_title=sweep.sweep_title(SOURCE, "exercise"), status="queued"
        )
        reader.origins.extend([spoof, current])
        self.assertEqual(sweep.guard(reader, SOURCE, 40), "")
        with patch.object(reader, "api") as api:
            self.assertEqual(
                sweep.dispatch(reader, source=SOURCE, exercise=True)["status"],
                "exercise-dispatched",
            )
            self.assertEqual(api.call_count, 1)

    def test_cancelled_newest_sweep_cannot_promote_old_success_or_old_active_run(self):
        for old_status in ("completed", "in_progress"):
            with self.subTest(old_status=old_status):
                reader = FixtureReader()
                reader.mode = "production"
                old = run(30, source=SOURCE, event="workflow_dispatch")
                old.update(
                    display_title=sweep.sweep_title(SOURCE, "production"),
                    status=old_status,
                )
                cancelled = run(40, source=SOURCE, event="workflow_dispatch")
                cancelled.update(
                    display_title=sweep.sweep_title(SOURCE, "production"),
                    conclusion="cancelled",
                )
                reader.origins.extend([old, cancelled])
                reader.job_rows[30] = reader.job_rows[10]
                reader.selection_record["sweep"] = True
                with (
                    patch.object(coordinator, "authorize"),
                    patch.object(coordinator, "selected_on_push", return_value={}),
                    patch.object(
                        reader, "proposal", return_value={"decision": "sweep"}
                    ),
                    patch.object(reader, "api") as api,
                ):
                    result = coordinator.reconcile(reader, SOURCE, BEFORE)
                self.assertEqual(result["decision"], "sweep-requested")
                self.assertEqual(
                    api.call_args.args[1], "actions/workflows/macos.yml/dispatches"
                )
                self.assertEqual(
                    api.call_args.args[3]["inputs"]["sweep_namespace"], "production"
                )

    def test_later_cancellation_prevents_an_older_active_run_superseding_fresh_work(
        self,
    ):
        reader = FixtureReader()
        reader.selection_record.update(sweep=True, sweep_namespace="exercise")
        earlier = run(30, source=SOURCE, event="workflow_dispatch")
        earlier.update(
            display_title=sweep.sweep_title(SOURCE, "exercise"), status="in_progress"
        )
        cancelled = run(35, source=SOURCE, event="workflow_dispatch")
        cancelled.update(
            display_title=sweep.sweep_title(SOURCE, "exercise"), conclusion="cancelled"
        )
        current = run(40, source=SOURCE, event="workflow_dispatch")
        reader.origins.extend([earlier, cancelled, current])
        self.assertEqual(sweep.guard(reader, SOURCE, 40), "")


if __name__ == "__main__":
    unittest.main()


def test_partial_acceptance_cannot_authorize_full_main_receipt():
    reader = FixtureReader()
    reader.selection_record["acceptance_phases"] = {"cpu-models": True, "software-gpu": False, "virtual-audio": True}
    proposal = reader.proposal(SOURCE, BEFORE, dict.fromkeys(evidence.APPLICATION, True))
    assert proposal["decision"] == "sweep"
    assert "Partial acceptance" in proposal["reason"]
    assert proposal["jobs"] == {}
