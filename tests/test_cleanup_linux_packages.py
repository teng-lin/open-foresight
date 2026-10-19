"""Protect live images and descriptors when retiring obsolete GHCR versions."""

import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import cleanup_linux_packages as cleanup


def version(number, *tags):
    return {
        "id": number,
        "name": f"sha256:{number:064x}",
        "metadata": {"container": {"tags": list(tags)}},
    }


class CleanupTests(unittest.TestCase):
    def test_keeps_current_caches_alias_children_and_untagged(self):
        versions = [
            version(1, "new"),
            version(2, "current"),
            version(3, "buildcache"),
            version(4, "app-buildcache-x86-64"),
            version(5),
            version(6, "old"),
            version(7, "child"),
            version(8, "old-alias", "current"),
            version(9, "app-deps-buildcache-v1"),
            version(10, "acceptance-tools-buildcache-v1"),
        ]
        self.assertEqual(
            cleanup.candidates(versions, "new", {versions[6]["name"]}), [versions[5]]
        )

    def test_acceptance_cache_and_child_manifests_are_protected(self):
        versions = [
            version(1, "new"),
            version(2, "acceptance-tools-buildcache-v1"),
            version(3, "old-child"),
            version(4, "retired"),
        ]

        def response(request, **kwargs):
            url = request if isinstance(request, str) else request.full_url
            if "/token?" in url:
                value = {"token": "fixture-token"}
            elif url.endswith(versions[1]["name"]):
                value = {"manifests": [{"digest": versions[2]["name"]}]}
            else:
                value = {}
            return io.BytesIO(json.dumps(value).encode())

        with patch.object(cleanup.urllib.request, "urlopen", side_effect=response):
            protected = cleanup.protected_manifests("linux-sdk", versions, "new")
        self.assertEqual(protected, {item["name"] for item in versions[:3]})
        self.assertEqual(cleanup.candidates(versions, "new", protected), versions[3:])

    def test_missing_current_image_stops_cleanup(self):
        with self.assertRaisesRegex(RuntimeError, "not published"):
            cleanup.candidates([version(1, "old")], "new", set())

    def test_approval_bridge_preserves_original_images_and_descriptors(self):
        current, original, obsolete = "a" * 64, "b" * 64, "c" * 64
        entry = {
            "repository": cleanup.REPO,
            "component": "linux-litert",
            "semantic_identity": current,
            "legacy_identity": original,
        }
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "bridge.json"
            manifest.write_text(json.dumps({"schema": 1, "entries": [entry]}))
            keep = cleanup.retained_identities("linux-litert", current, manifest)
            self.assertEqual(keep, {current, original})
            self.assertEqual(
                cleanup.retained_identities("linux-core", current, manifest), {current}
            )
            self.assertEqual(
                cleanup.retained_identities("linux-litert", obsolete, manifest),
                {obsolete},
            )
        versions = [version(1, current), version(2, original), version(3, obsolete)]
        retired = cleanup.candidates(versions, current, set(), keep)
        self.assertEqual(retired, [versions[2]])
        identities = {"linux-litert": set().union(*(cleanup.tags(v) for v in retired))}
        for prefix in ("ci-", "receipt-ci-"):
            self.assertFalse(
                cleanup.obsolete_artifact(
                    prefix + "linux-litert-" + original, identities
                )
            )
            self.assertTrue(
                cleanup.obsolete_artifact(
                    prefix + "linux-litert-" + obsolete, identities
                )
            )

    def test_invalid_bridge_stops_cleanup_instead_of_retiring_originals(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "bridge.json"
            for record in (
                {"schema": 2, "entries": []},
                {"schema": 1, "entries": [None]},
            ):
                with self.subTest(record=record):
                    manifest.write_text(json.dumps(record))
                    with self.assertRaisesRegex(RuntimeError, "refusing cleanup"):
                        cleanup.retained_identities("linux-core", "a" * 64, manifest)

    def test_matches_only_retired_component_descriptors(self):
        old, new = "a" * 64, "b" * 64
        identities = {"linux-core": {old}}
        for prefix in ("ci-", "receipt-ci-"):
            self.assertTrue(
                cleanup.obsolete_artifact(prefix + "linux-core-" + old, identities)
            )
            self.assertFalse(
                cleanup.obsolete_artifact(prefix + "linux-core-" + new, identities)
            )
            self.assertFalse(
                cleanup.obsolete_artifact(prefix + "linux-litert-" + old, identities)
            )
        self.assertFalse(cleanup.obsolete_artifact("ci-linux-app-" + old, identities))

    def plan(self):
        return {
            "repository": cleanup.REPO,
            "head": "head",
            "packages": {
                "linux-core": {"identity": "new", "versions": [version(1, "old")]}
            },
            "artifacts": [{"id": 9, "name": "old-descriptor"}],
        }

    def test_changed_plan_stops_before_mutations(self):
        plan = self.plan()
        changed = copy.deepcopy(plan)
        changed["packages"]["linux-core"]["versions"][0]["metadata"]["container"][
            "tags"
        ].append("current")
        with (
            patch.object(cleanup, "make_plan", return_value=changed),
            patch.object(cleanup, "api") as api,
        ):
            with self.assertRaisesRegex(RuntimeError, "changed"):
                cleanup.apply(plan)
            api.assert_not_called()

    def test_active_ci_stops_before_deletion(self):
        with (
            patch.object(cleanup, "make_plan", return_value=self.plan()),
            patch.object(cleanup, "api", return_value={"total_count": 1}) as api,
        ):
            with self.assertRaisesRegex(RuntimeError, "CI is active"):
                cleanup.apply(self.plan())
            self.assertFalse(
                any(call.args[-1] == "DELETE" for call in api.call_args_list)
            )

    def test_descriptors_are_deleted_before_images(self):
        calls = []

        def api(path, method="GET"):
            calls.append((path, method))
            if "actions/runs?" in path:
                return {"total_count": 0}
            if method == "GET":
                return version(1, "old")

        with (
            patch.object(cleanup, "make_plan", return_value=self.plan()),
            patch.object(cleanup, "api", side_effect=api),
        ):
            cleanup.apply(self.plan())
        deletes = [path for path, method in calls if method == "DELETE"]
        self.assertIn("actions/artifacts/9", deletes[0])
        self.assertIn("/versions/1", deletes[1])


if __name__ == "__main__":
    unittest.main()
