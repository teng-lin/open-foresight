"""Alias publication must use qualified current-main images and preserve digests."""

import json
import subprocess
import unittest
from unittest.mock import patch

from tools import publish_linux_package_aliases as aliases

REPOSITORY = "teng-lin/open-foresight"
HEAD = "a" * 40
DIGEST = "sha256:" + "b" * 64


class AliasTests(unittest.TestCase):
    def command_output(self, command, **kwargs):
        if command[:2] == ["git", "rev-parse"]:
            return HEAD
        return json.dumps({"sha": HEAD})

    def image(self, component):
        return f"ghcr.io/{REPOSITORY}/{component}@{DIGEST}"

    def test_publishes_and_verifies_each_qualified_image(self):
        with (
            patch.object(
                aliases.subprocess, "check_output", side_effect=self.command_output
            ),
            patch.object(aliases.artifacts, "pull", return_value=True) as pull,
            patch.object(
                aliases,
                "record",
                side_effect=lambda prefix, component: {"image": self.image(component)},
            ),
            patch.object(aliases.subprocess, "run") as publish,
            patch.object(
                aliases.registry,
                "inspect",
                side_effect=lambda alias: alias.removesuffix(":current") + "@" + DIGEST,
            ),
        ):
            aliases.publish(REPOSITORY)
        self.assertEqual(pull.call_count, 4)
        self.assertTrue(
            all(call.kwargs["own_head"] == HEAD for call in pull.call_args_list)
        )
        self.assertEqual(publish.call_count, 4)
        for component, call in zip(
            aliases.COMPONENTS, publish.call_args_list, strict=True
        ):
            self.assertIn("--prefer-index=false", call.args[0])
            self.assertEqual(
                call.args[0][-2:],
                [f"ghcr.io/{REPOSITORY}/{component}:current", self.image(component)],
            )

    def test_main_advancing_stops_before_publication(self):
        for outputs in (
            (HEAD, json.dumps({"sha": "c" * 40})),
            (HEAD, json.dumps({"sha": HEAD}), json.dumps({"sha": "c" * 40})),
        ):
            with (
                patch.object(aliases.subprocess, "check_output", side_effect=outputs),
                patch.object(aliases.artifacts, "pull", return_value=True),
                patch.object(
                    aliases, "record", return_value={"image": self.image("linux-core")}
                ),
                patch.object(aliases.subprocess, "run") as publish,
            ):
                with self.assertRaisesRegex(RuntimeError, "Main advanced"):
                    aliases.publish(REPOSITORY)
                publish.assert_not_called()

    def test_unqualified_missing_or_foreign_sources_cannot_publish(self):
        for descriptor in (
            None,
            {"transport": "docker-archive"},
            {"image": "ghcr.io/other/project/linux-core@" + DIGEST},
        ):
            with (
                patch.object(
                    aliases.subprocess, "check_output", side_effect=self.command_output
                ),
                patch.object(
                    aliases.artifacts, "pull", return_value=descriptor is not None
                ),
                patch.object(aliases, "record", return_value=descriptor),
                patch.object(aliases.subprocess, "run") as publish,
            ):
                with self.assertRaises((ValueError, RuntimeError)):
                    aliases.publish(REPOSITORY)
                publish.assert_not_called()

    def test_failed_push_or_digest_mismatch_cannot_report_success(self):
        for error in (subprocess.CalledProcessError(1, ["docker"]), None):
            with (
                patch.object(
                    aliases.subprocess, "check_output", side_effect=self.command_output
                ),
                patch.object(aliases.artifacts, "pull", return_value=True),
                patch.object(
                    aliases, "record", return_value={"image": self.image("linux-core")}
                ),
                patch.object(aliases.subprocess, "run", side_effect=error),
                patch.object(
                    aliases.registry,
                    "inspect",
                    return_value=self.image("linux-whisper"),
                ),
            ):
                with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                    aliases.publish(REPOSITORY)
