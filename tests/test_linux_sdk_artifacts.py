"""Retained Linux SDK images are verified before Docker consumes or publishes them."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import ci_artifacts as artifacts
from tools import linux_sdk_artifacts as sdk


IMAGE_ID = "sha256:" + "a" * 64
REGISTRY_IMAGE = "ghcr.io/example/foresight-sdk@sha256:" + "b" * 64
REPOSITORY = "example/foresight"


def write_archive(prefix, component="linux-sdk", **changes):
    prefix.mkdir(parents=True, exist_ok=True)
    archive = prefix / "image.tar"
    archive.write_bytes(b"saved Docker image fixture")
    descriptor = {
        "schema": 1,
        "transport": "docker-archive",
        "component": component,
        "identity": artifacts.fingerprint(component),
        "image_id": IMAGE_ID,
        "platform": "linux/amd64",
        "archive_sha256": artifacts.digest(archive),
        **changes,
    }
    (prefix / "image.json").write_text(json.dumps(descriptor))
    return descriptor


def docker_output(arguments, **kwargs):
    if arguments[:3] == ["docker", "image", "inspect"]:
        return json.dumps({"Id": IMAGE_ID, "Os": "linux", "Architecture": "amd64"})
    if arguments[-2:] == ["/opt/toolchain/bin/protoc", "--version"]:
        return "libprotoc 35.1\n"
    raise AssertionError(f"Unexpected Docker output request: {arguments}")


class RetainedImageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.prefix = Path(self.temporary.name) / "payload"

    def registry(self, image=REGISTRY_IMAGE):
        self.prefix.mkdir()
        (self.prefix / "image.json").write_text(json.dumps({"image": image}))

    def test_registry_resolution_preserves_digest_without_touching_docker(self):
        self.registry()
        with patch.object(sdk, "run") as run, patch.object(sdk, "inspect") as inspect:
            self.assertEqual(sdk.resolve(self.prefix), REGISTRY_IMAGE)
        run.assert_not_called()
        inspect.assert_not_called()

    def test_unpinned_registry_reference_is_rejected_without_docker(self):
        for image in (
            "ghcr.io/example/foresight-sdk:latest",
            "ghcr.io/example/foresight-sdk@sha256:abc",
            "other.example/image@sha256:" + "b" * 64,
        ):
            with self.subTest(image=image):
                self.prefix.mkdir(exist_ok=True)
                (self.prefix / "image.json").write_text(json.dumps({"image": image}))
                with patch.object(sdk, "run") as run:
                    with self.assertRaisesRegex(ValueError, "Unpinned"):
                        sdk.resolve(self.prefix)
                run.assert_not_called()

    def test_archive_resolution_loads_verified_id_then_uses_local_tag(self):
        write_archive(self.prefix)
        with (
            patch.object(sdk, "run") as run,
            patch.object(sdk.subprocess, "check_output", side_effect=docker_output),
        ):
            self.assertEqual(sdk.resolve(self.prefix), "foresight-sdk:pr")
        self.assertEqual(
            [call.args[0] for call in run.call_args_list],
            [
                ["docker", "image", "load", "--input", str(self.prefix / "image.tar")],
                ["docker", "image", "tag", IMAGE_ID, "foresight-sdk:pr"],
            ],
        )

    def test_descriptor_rejections_happen_before_docker_load(self):
        for change in (
            {"schema": 2},
            {"transport": "unknown"},
            {"component": "linux-core"},
            {"identity": "0" * 64},
            {"platform": "linux/arm64"},
            {"image_id": "sha256:abc"},
            {"image_id": "foresight-sdk:pr"},
            {"archive_sha256": "0" * 64},
        ):
            with self.subTest(change=change):
                write_archive(self.prefix, **change)
                with (
                    patch.object(sdk, "run") as run,
                    patch.object(sdk, "inspect") as inspect,
                ):
                    with self.assertRaises(ValueError):
                        sdk.load(self.prefix, "linux-sdk", "target:tag")
                run.assert_not_called()
                inspect.assert_not_called()

    def test_archive_tampering_is_rejected_before_docker_load(self):
        write_archive(self.prefix)
        (self.prefix / "image.tar").write_bytes(b"replaced after descriptor creation")
        with patch.object(sdk, "run") as run:
            with self.assertRaisesRegex(ValueError, "checksum"):
                sdk.resolve(self.prefix)
        run.assert_not_called()

    def test_missing_and_symlink_archives_are_rejected_before_load(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                write_archive(self.prefix)
                archive = self.prefix / "image.tar"
                archive.unlink()
                if symlink:
                    target = self.prefix.parent / "outside.tar"
                    target.write_bytes(b"saved Docker image fixture")
                    archive.symlink_to(target)
                with patch.object(sdk, "run") as run:
                    with self.assertRaisesRegex(ValueError, "regular file"):
                        sdk.resolve(self.prefix)
                run.assert_not_called()

    def test_loaded_configuration_must_match_descriptor_before_tagging(self):
        write_archive(self.prefix)
        with (
            patch.object(sdk, "run") as run,
            patch.object(sdk, "inspect", return_value="sha256:" + "c" * 64),
        ):
            with self.assertRaisesRegex(ValueError, "configuration ID mismatch"):
                sdk.load(self.prefix, "linux-sdk", "target:tag")
        self.assertEqual(len(run.call_args_list), 1)
        self.assertEqual(run.call_args.args[0][:3], ["docker", "image", "load"])

    def test_loaded_wrong_platform_is_rejected_before_tagging(self):
        write_archive(self.prefix)
        metadata = {"Id": IMAGE_ID, "Os": "linux", "Architecture": "arm64"}
        with (
            patch.object(sdk, "run") as run,
            patch.object(
                sdk.subprocess, "check_output", return_value=json.dumps(metadata)
            ),
        ):
            with self.assertRaisesRegex(ValueError, "linux/amd64"):
                sdk.load(self.prefix, "linux-sdk", "target:tag")
        self.assertEqual(len(run.call_args_list), 1)

    def test_inspect_rejects_malformed_id_and_wrong_operating_system(self):
        for metadata in (
            {"Id": "image:tag", "Os": "linux", "Architecture": "amd64"},
            {"Id": IMAGE_ID, "Os": "windows", "Architecture": "amd64"},
            {"Id": IMAGE_ID, "Os": "linux", "Architecture": "arm64"},
        ):
            with self.subTest(metadata=metadata):
                with patch.object(
                    sdk.subprocess, "check_output", return_value=json.dumps(metadata)
                ):
                    with self.assertRaises(ValueError):
                        sdk.inspect("candidate")

    def test_registry_load_pulls_immutable_reference_and_verifies_platform(self):
        self.registry()
        with (
            patch.object(sdk, "run") as run,
            patch.object(sdk.subprocess, "check_output", side_effect=docker_output),
        ):
            self.assertEqual(sdk.load(self.prefix, "linux-sdk", "local:pr"), "local:pr")
        self.assertEqual(
            [call.args[0] for call in run.call_args_list],
            [
                ["docker", "pull", REGISTRY_IMAGE],
                ["docker", "image", "tag", REGISTRY_IMAGE, "local:pr"],
            ],
        )

    def test_promotion_loads_verified_archive_and_pushes_requested_tag(self):
        write_archive(self.prefix)
        tag = "ghcr.io/example/foresight-sdk:approved"
        with (
            patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push"}),
            patch.object(sdk, "run") as run,
            patch.object(sdk.subprocess, "check_output", side_effect=docker_output),
        ):
            self.assertEqual(sdk.promote(self.prefix, "linux-sdk", tag), tag)
        self.assertEqual(
            [call.args[0] for call in run.call_args_list],
            [
                ["docker", "image", "load", "--input", str(self.prefix / "image.tar")],
                ["docker", "image", "tag", IMAGE_ID, tag],
                ["docker", "push", tag],
            ],
        )

    def test_registry_promotion_keeps_original_uri_without_pull_or_push(self):
        self.registry()
        with (
            patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push"}),
            patch.object(sdk, "run") as run,
        ):
            self.assertEqual(
                sdk.promote(self.prefix, "linux-sdk", "new:tag"), REGISTRY_IMAGE
            )
        run.assert_not_called()

    def test_pull_request_cannot_promote_any_transport(self):
        for registry in (False, True):
            with self.subTest(registry=registry):
                if registry:
                    (self.prefix / "image.json").write_text(
                        json.dumps({"image": REGISTRY_IMAGE})
                    )
                else:
                    write_archive(self.prefix)
                with (
                    patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request"}),
                    patch.object(sdk, "run") as run,
                ):
                    with self.assertRaisesRegex(RuntimeError, "cannot publish"):
                        sdk.promote(self.prefix, "linux-sdk", "new:tag")
                run.assert_not_called()

    def test_tampered_archive_cannot_be_promoted(self):
        write_archive(self.prefix)
        (self.prefix / "image.tar").write_bytes(b"tampered")
        with (
            patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push"}),
            patch.object(sdk, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "checksum"):
                sdk.promote(self.prefix, "linux-sdk", "new:tag")
        run.assert_not_called()


class ImageProductionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_valid_cache_hit_is_verified_and_repacked_without_docker(self):
        for component in sdk.COMPONENTS:
            with self.subTest(component=component):
                output = self.root / component

                def pull(
                    repository, selected, identity, prefix, expected=component, **kwargs
                ):
                    self.assertEqual(selected, expected)
                    self.assertEqual(identity, artifacts.fingerprint(expected))
                    write_archive(prefix, selected)
                    return True

                with (
                    patch.object(artifacts, "pull", side_effect=pull) as pull_mock,
                    patch.object(sdk, "run") as run,
                    patch.object(
                        sdk.subprocess, "check_output", side_effect=docker_output
                    ),
                ):
                    sdk.produce(
                        component, output, REPOSITORY, own_head="d" * 40, own_pr=23
                    )
                self.assertEqual(pull_mock.call_count, 1)
                self.assertEqual(
                    pull_mock.call_args.kwargs, {"own_head": "d" * 40, "own_pr": 23}
                )
                commands = [call.args[0] for call in run.call_args_list]
                self.assertFalse(
                    any(command[:2] == ["docker", "build"] for command in commands)
                )
                self.assertFalse(
                    any(
                        command[:3] == ["docker", "image", "save"]
                        for command in commands
                    )
                )
                self.assertEqual(commands, [])
                restored = self.root / f"restored-{component}"
                artifacts.unpack(
                    component, artifacts.fingerprint(component), output, restored
                )
                self.assertEqual(sdk.record(restored, component)["image_id"], IMAGE_ID)

    def test_invalid_cache_hit_fails_closed_instead_of_building(self):
        def pull(repository, component, identity, prefix, **kwargs):
            write_archive(prefix, component, identity="0" * 64)
            return True

        with (
            patch.object(artifacts, "pull", side_effect=pull),
            patch.object(sdk, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "identity"):
                sdk.produce("linux-sdk", self.root / "upload", REPOSITORY)
        run.assert_not_called()
        self.assertFalse((self.root / "upload").exists())

    def test_registry_cache_hit_preserves_descriptor_without_rebuilding(self):
        def pull(repository, component, identity, prefix, **kwargs):
            prefix.mkdir()
            (prefix / "image.json").write_text(json.dumps({"image": REGISTRY_IMAGE}))
            return True

        output = self.root / "upload"
        with (
            patch.object(artifacts, "pull", side_effect=pull),
            patch.object(sdk, "run") as run,
            patch.object(sdk.subprocess, "check_output", side_effect=docker_output),
        ):
            sdk.produce("linux-sdk", output, REPOSITORY)
        run.assert_not_called()
        restored = self.root / "restored"
        artifacts.unpack(
            "linux-sdk", artifacts.fingerprint("linux-sdk"), output, restored
        )
        self.assertEqual(sdk.resolve(restored), REGISTRY_IMAGE)
        self.assertFalse((restored / "image.tar").exists())

    def test_cache_miss_builds_one_component_from_verified_parents_and_exports(self):
        requested = []

        def pull(repository, component, identity, prefix, **kwargs):
            requested.append((component, kwargs))
            if component == "linux-sdk":
                return False
            write_archive(prefix, component)
            return True

        def run(arguments, **kwargs):
            if arguments[:3] == ["docker", "image", "save"]:
                Path(arguments[arguments.index("--output") + 1]).write_bytes(
                    b"new saved image"
                )

        output = self.root / "upload"
        with (
            patch.object(artifacts, "pull", side_effect=pull),
            patch.object(sdk, "run", side_effect=run) as run_mock,
            patch.object(sdk.subprocess, "check_output", side_effect=docker_output),
        ):
            sdk.produce("linux-sdk", output, REPOSITORY, own_head="e" * 40, own_pr=31)
        self.assertEqual(
            [component for component, _ in requested],
            ["linux-sdk", "linux-core", "linux-litert", "linux-whisper"],
        )
        for _, options in requested[1:]:
            self.assertEqual(options, {"wait": 300, "own_head": "e" * 40, "own_pr": 31})
        builds = [
            call
            for call in run_mock.call_args_list
            if call.args[0][:2] == ["docker", "build"]
        ]
        self.assertEqual(len(builds), 1)
        self.assertEqual(
            builds[0].args[0],
            [
                "docker",
                "build",
                "-f",
                str(artifacts.ROOT / "packaging/sdk.Dockerfile"),
                "-t",
                "foresight-sdk:pr",
                "--build-arg",
                "CORE_IMAGE=foresight-core:pr",
                "--build-arg",
                "LITERT_IMAGE=foresight-litert:pr",
                "--build-arg",
                "WHISPER_IMAGE=foresight-whisper:pr",
                str(artifacts.ROOT),
            ],
        )
        self.assertEqual(builds[0].kwargs["timeout"], 10800)
        saves = [
            call.args[0]
            for call in run_mock.call_args_list
            if call.args[0][:3] == ["docker", "image", "save"]
        ]
        self.assertEqual(len(saves), 1)
        self.assertEqual(saves[0][-1], IMAGE_ID)
        artifacts.unpack(
            "linux-sdk",
            artifacts.fingerprint("linux-sdk"),
            output,
            self.root / "restored",
        )
        descriptor = sdk.record(self.root / "restored", "linux-sdk")
        self.assertEqual(descriptor["image_id"], IMAGE_ID)
        self.assertEqual(
            (self.root / "restored/image.tar").read_bytes(), b"new saved image"
        )

    def test_missing_parent_prevents_build_and_output(self):
        with (
            patch.object(artifacts, "pull", return_value=False),
            patch.object(sdk, "run") as run,
        ):
            with self.assertRaisesRegex(RuntimeError, "linux-core.*unavailable"):
                sdk.produce("linux-litert", self.root / "upload", REPOSITORY)
        run.assert_not_called()
        self.assertFalse((self.root / "upload").exists())

    def test_wrong_parent_identity_prevents_build(self):
        def pull(repository, component, identity, prefix, **kwargs):
            if component == "linux-litert":
                return False
            write_archive(prefix, component, identity="0" * 64)
            return True

        with (
            patch.object(artifacts, "pull", side_effect=pull),
            patch.object(sdk, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "identity"):
                sdk.produce("linux-litert", self.root / "upload", REPOSITORY)
        run.assert_not_called()

    def test_failed_qualification_does_not_export_or_pack(self):
        with (
            patch.object(artifacts, "pull", return_value=False),
            patch.object(sdk, "run") as run,
            patch.object(sdk, "inspect", return_value=IMAGE_ID),
            patch.object(
                sdk.subprocess, "check_output", return_value="libprotoc 30.0\n"
            ),
        ):
            with self.assertRaisesRegex(ValueError, "protobuf version"):
                sdk.produce("linux-core", self.root / "upload", REPOSITORY)
        self.assertEqual(len(run.call_args_list), 1)
        self.assertEqual(run.call_args.args[0][:2], ["docker", "build"])
        self.assertFalse((self.root / "upload").exists())
