"""A control-workflow repair cannot move the immutable product source."""

import base64
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from tools import prepare_release as release


class ReleaseSourceTest(unittest.TestCase):
    product = "a" * 40
    control = "b" * 40
    tag = "v0.1.1"

    def responses(self, *, status="ahead", version="0.1.1", commit=None):
        return [
            [{"ref": "refs/tags/" + self.tag}],
            {"sha": self.product if commit is None else commit},
            {"status": status},
            {
                "encoding": "base64",
                "content": base64.b64encode(
                    f"name: desktop\nversion: {version}+2\n".encode()
                ).decode()
                + "\n",
            },
        ]

    def test_missing_admin_tag_is_rejected_without_matching_a_longer_prefix(self):
        with patch.object(
            release, "api", return_value=[{"ref": "refs/tags/v0.1.10"}]
        ) as api:
            with self.assertRaisesRegex(ValueError, "administrator must create"):
                release.release_source("owner/repo", self.tag, self.control)
            self.assertEqual(api.call_count, 1)

    def test_retry_uses_reviewed_tag_even_when_control_workflow_has_changed(self):
        with patch.object(release, "api", side_effect=self.responses()) as api:
            self.assertEqual(
                release.release_source("owner/repo", self.tag, self.control),
                self.product,
            )
            self.assertEqual(
                api.call_args_list[2].args[1],
                f"compare/{self.product}...{self.control}",
            )
            self.assertEqual(
                api.call_args.args[1],
                f"contents/apps/desktop/pubspec.yaml?ref={self.product}",
            )

    def test_unreviewed_or_version_mismatched_tags_are_refused(self):
        for status in ("behind", "diverged"):
            with (
                self.subTest(status=status),
                patch.object(release, "api", side_effect=self.responses(status=status)),
            ):
                with self.assertRaisesRegex(ValueError, "reviewed main"):
                    release.release_source("owner/repo", self.tag, self.control)
        with patch.object(release, "api", side_effect=self.responses(version="0.1.0")):
            with self.assertRaisesRegex(ValueError, "immutable application version"):
                release.release_source("owner/repo", self.tag, self.control)
        with patch.object(release, "api", side_effect=self.responses(commit="a" * 12)):
            with self.assertRaisesRegex(ValueError, "full source commit"):
                release.release_source("owner/repo", self.tag, self.control)

    def test_expired_tag_candidates_never_dispatch_or_substitute_newer_main(self):
        with (
            patch.object(release, "candidate_runs", return_value={}),
            patch.object(release, "api", return_value={"workflow_runs": []}),
            patch.object(release.subprocess, "run") as command,
        ):
            with self.assertRaisesRegex(
                ValueError, "Fully tested release candidates are unavailable"
            ):
                release.verified_candidates("owner/repo", self.product, 42)
            command.assert_not_called()

    def test_retry_gates_and_draft_use_product_commit_and_record_control_separately(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            with (
                patch.object(
                    sys, "argv", ["prepare", "--tag", self.tag, "--candidate-run", "42"]
                ),
                patch.dict(
                    os.environ,
                    {
                        "GITHUB_REF": "refs/heads/main",
                        "GITHUB_OUTPUT": str(output),
                        "GITHUB_STEP_SUMMARY": str(summary),
                    },
                ),
                patch.object(release, "stale", return_value=[]),
                patch.object(release, "read_version", return_value=("0.2.0", 3)),
                patch.object(
                    release.subprocess, "check_output", return_value=self.control
                ),
                patch.object(release, "release_source", return_value=self.product),
                patch.object(
                    release,
                    "verified_candidates",
                    return_value={"linux-app": 42, "macos-app": 42},
                ) as candidates,
                patch.object(release, "create_draft", return_value="2") as draft,
            ):
                release.main()
            candidates.assert_called_once_with(
                "teng-lin/open-foresight",
                self.product,
                42,
            )
            draft.assert_called_once_with(
                "teng-lin/open-foresight", self.tag, self.product
            )
            self.assertIn(
                f"commit={self.product}\ncontrol_commit={self.control}",
                output.read_text(),
            )
            self.assertIn(f"Product commit: `{self.product}`", summary.read_text())
            self.assertIn(f"Control commit: `{self.control}`", summary.read_text())

    def test_resume_cli_preserves_product_and_candidate_id(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "prepare",
                        "--tag",
                        self.tag,
                        "--repo",
                        "owner/repo",
                        "--candidate-run",
                        "42",
                    ],
                ),
                patch.dict(
                    os.environ,
                    {
                        "GITHUB_REF": "refs/heads/main",
                        "GITHUB_OUTPUT": str(output),
                        "GITHUB_STEP_SUMMARY": "",
                    },
                ),
                patch.object(release, "stale", return_value=[]),
                patch.object(
                    release.subprocess, "check_output", return_value=self.control
                ),
                patch.object(release, "release_source", return_value=self.product),
                patch.object(
                    release,
                    "verified_candidates",
                    return_value={"linux-app": 42, "macos-app": 42},
                ) as candidates,
                patch.object(release, "create_draft", return_value="2") as draft,
            ):
                release.main()
            candidates.assert_called_once_with("owner/repo", self.product, 42)
            draft.assert_called_once_with("owner/repo", self.tag, self.product)
            self.assertIn("candidate_run=42\n", output.read_text())
            self.assertIn(
                "linux_candidate_run=42\nmacos_candidate_run=42\n", output.read_text()
            )
            self.assertIn(f"commit={self.product}\n", output.read_text())

    def test_new_tag_cannot_use_a_different_current_application_version(self):
        with (
            patch.object(
                sys, "argv", ["prepare", "--tag", self.tag, "--candidate-run", "42"]
            ),
            patch.dict(os.environ, {"GITHUB_REF": "refs/heads/main"}),
            patch.object(release, "stale", return_value=[]),
            patch.object(release, "read_version", return_value=("0.2.0", 3)),
            patch.object(release.subprocess, "check_output", return_value=self.control),
            patch.object(release, "release_source", return_value=self.control),
            patch.object(release, "verified_candidates") as candidates,
            patch.object(release, "create_draft") as draft,
        ):
            with self.assertRaisesRegex(ValueError, "new release tag"):
                release.main()
            candidates.assert_not_called()
            draft.assert_not_called()
