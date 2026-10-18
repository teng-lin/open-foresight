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

    def test_new_tag_uses_current_main_without_matching_a_longer_tag_prefix(self):
        with patch.object(
            release, "api", return_value=[{"ref": "refs/tags/v0.1.10"}]
        ) as api:
            self.assertEqual(
                release.release_source("owner/repo", self.tag, self.control),
                self.control,
            )
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
            patch.object(release, "candidates_ready", return_value=False),
            patch.object(release, "api", return_value={"sha": self.control}),
            patch.object(release.subprocess, "run") as command,
        ):
            with self.assertRaisesRegex(ValueError, "refusing to substitute"):
                release.require_candidates("owner/repo", self.product, 0)
            command.assert_not_called()

    def test_retry_gates_and_draft_use_product_commit_and_record_control_separately(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            with (
                patch.object(sys, "argv", ["prepare", "--tag", self.tag]),
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
                patch.object(release, "require_candidates") as candidates,
                patch.object(release, "create_draft", return_value="2") as draft,
            ):
                release.main()
            candidates.assert_called_once_with(
                "teng-lin/open-foresight", self.product, 10800, fresh=True
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

    def test_new_tag_cannot_use_a_different_current_application_version(self):
        with (
            patch.object(sys, "argv", ["prepare", "--tag", self.tag]),
            patch.dict(os.environ, {"GITHUB_REF": "refs/heads/main"}),
            patch.object(release, "stale", return_value=[]),
            patch.object(release, "read_version", return_value=("0.2.0", 3)),
            patch.object(release.subprocess, "check_output", return_value=self.control),
            patch.object(release, "release_source", return_value=self.control),
            patch.object(release, "require_candidates") as candidates,
            patch.object(release, "create_draft") as draft,
        ):
            with self.assertRaisesRegex(ValueError, "new release tag"):
                release.main()
            candidates.assert_not_called()
            draft.assert_not_called()
