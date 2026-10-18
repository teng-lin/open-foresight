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
    if arguments == ["git", "rev-parse", "HEAD"]:
        return "a" * 40 + "\n"
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
        preflight = patch.object(
            sdk.sdk_build_transport, "prepare", return_value=["docker", "build"]
        )
        self.preflight = preflight.start()
        self.addCleanup(preflight.stop)

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


def test_registry_cache_preflight_precedes_parent_loads(tmp_path):
    from tools.sdk_build_transport import command

    events = []

    def pull(repository, component, identity, prefix, **kwargs):
        if component == "linux-litert":
            return False
        write_archive(prefix, component)
        return True

    def prepare(*args, **kwargs):
        events.append("cache-preflight")
        return [
            "docker",
            "buildx",
            "build",
            "--builder",
            "default",
            "--load",
            "--cache-from",
            "type=registry,ref=ghcr.io/owner/repo/linux-litert:buildcache",
        ]

    def load(*args):
        events.append("parent-load")
        return "foresight-core:pr"

    def run(arguments, **kwargs):
        if arguments[:3] == ["docker", "buildx", "build"]:
            events.append("build-with-readonly-layers")
            assert "--cache-from" in arguments
            assert "--cache-to" not in arguments
            assert "CORE_IMAGE=foresight-core:pr" in arguments
        elif arguments[:3] == ["docker", "image", "save"]:
            Path(arguments[arguments.index("--output") + 1]).write_bytes(b"image")

    with (
        patch.object(artifacts, "pull", side_effect=pull),
        patch.object(sdk.sdk_build_transport, "prepare", side_effect=prepare),
        patch.object(sdk.sdk_build_transport, "command", wraps=command),
        patch.object(sdk, "load", side_effect=load),
        patch.object(sdk, "run", side_effect=run),
        patch.object(sdk, "qualify"),
        patch.object(sdk, "inspect", return_value=IMAGE_ID),
    ):
        sdk.produce("linux-litert", tmp_path / "output", REPOSITORY)
    assert events == ["cache-preflight", "parent-load", "build-with-readonly-layers"]


class RegistryDescriptorProvenanceTests(unittest.TestCase):
    def test_promoted_descriptor_preserves_original_receipts_and_nested_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = {
                "component": "linux-sdk",
                "source_commit": "1" * 40,
                "source_run_attempt": 2,
                "sha256": "2" * 64,
            }
            history = {
                "producer_run": 123,
                "artifact_id": 456,
                "artifact_digest": "sha256:" + "3" * 64,
                "source_receipt": original,
            }
            for metadata in ("approved-source.json", "source-qualification.json"):
                with self.subTest(metadata=metadata):
                    source = root / metadata.removesuffix(".json")
                    source.mkdir()
                    # Include existing qualification history exactly as received;
                    # descriptor publication must not relabel it as a new build.
                    qualification = {**history, "prior": {"reused_from": history}}
                    encoded = json.dumps(qualification).encode()
                    (source / metadata).write_bytes(encoded)
                    (source / "image.json").write_text(
                        '{"transport":"verified-original"}'
                    )
                    destination = root / (metadata + "-descriptor")
                    sdk.describe(destination, "linux-sdk", REGISTRY_IMAGE, source)
                    self.assertEqual(
                        json.loads(
                            (destination / "source-qualification.json").read_text()
                        ),
                        qualification,
                    )
                    self.assertFalse((destination / "approved-source.json").exists())
                    self.assertEqual((source / metadata).read_bytes(), encoded)
                    published = root / (metadata + "-published")
                    artifacts.pack("linux-sdk", "f" * 64, destination, published)
                    receipt = json.loads((published / "identity.json").read_text())
                    self.assertEqual(receipt["reused_from"], qualification)
                    self.assertNotEqual(
                        receipt["source_commit"], original["source_commit"]
                    )
                    unpacked = root / (metadata + "-unpacked")
                    artifacts.unpack("linux-sdk", "f" * 64, published, unpacked)
                    self.assertEqual(
                        json.loads(
                            (unpacked / "source-qualification.json").read_text()
                        )["source_receipt"],
                        original,
                    )
                    self.assertFalse((unpacked / "approved-source.json").exists())

    def test_fresh_registry_descriptor_has_no_fabricated_compile_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk.describe(
                root / "descriptor",
                "linux-core",
                REGISTRY_IMAGE,
                root / "absent-shared-prefix",
            )
            self.assertEqual(
                json.loads((root / "descriptor/image.json").read_text()),
                {"image": REGISTRY_IMAGE},
            )
            self.assertFalse((root / "descriptor/source-qualification.json").exists())

    def test_present_shared_prefix_requires_regular_qualification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "shared"
            source.mkdir()
            destination = root / "descriptor"
            with self.assertRaisesRegex(
                ValueError, "missing its original qualification"
            ):
                sdk.describe(destination, "linux-sdk", REGISTRY_IMAGE, source)
            self.assertFalse(destination.exists())
            external = root / "original.json"
            external.write_text('{"source_receipt":{}}')
            (source / "approved-source.json").symlink_to(external)
            with self.assertRaisesRegex(ValueError, "must be regular"):
                sdk.describe(destination, "linux-sdk", REGISTRY_IMAGE, source)
            self.assertFalse(destination.exists())

    def test_all_main_linux_publishers_preserve_shared_source_qualification(self):
        import yaml

        workflow = yaml.safe_load(
            (artifacts.ROOT / ".github/workflows/ci-dependencies.yml").read_text()
        )
        publishers = [
            step
            for job in workflow["jobs"].values()
            for step in job.get("steps", [])
            if step.get("name") == "Publish qualified SDK descriptor"
        ]
        self.assertEqual(len(publishers), 4)
        for step in publishers:
            self.assertIn("linux_sdk_artifacts.py describe", step["run"])
            self.assertIn("--source-prefix build/shared-descriptor", step["run"])
            self.assertIn('--tag "$SDK_IMAGE"', step["run"])
            self.assertLess(
                step["run"].index("linux_sdk_artifacts.py describe"),
                step["run"].index("ci_artifacts.py pack"),
            )


def oci_archive(prefix, *, nested=False, wrong_config=False, missing_layer=False):
    """A Docker-save compatible OCI layout, including its legacy manifest.json."""
    import hashlib
    import io
    import tarfile

    files = {"oci-layout": b'{"imageLayoutVersion":"1.0.0"}'}

    def blob(value, media):
        data = json.dumps(value, separators=(",", ":")).encode()
        digest = hashlib.sha256(data).hexdigest()
        files["blobs/sha256/" + digest] = data
        return {"mediaType": media, "digest": "sha256:" + digest, "size": len(data)}

    layer_bytes = b"\0" * 1024  # A valid empty tar layer; no producer code executes.
    layer_digest = "sha256:" + hashlib.sha256(layer_bytes).hexdigest()
    if not missing_layer:
        files["blobs/sha256/" + layer_digest[7:]] = layer_bytes
    config = blob(
        {
            "os": "linux",
            "architecture": "amd64",
            "rootfs": {"type": "layers", "diff_ids": [layer_digest]},
        },
        "application/vnd.oci.image.config.v1+json",
    )
    manifest = blob(
        {
            "schemaVersion": 2,
            "config": config,
            "layers": [
                {
                    "mediaType": "application/vnd.oci.image.layer.v1.tar",
                    "digest": layer_digest,
                    "size": len(layer_bytes),
                }
            ],
        },
        "application/vnd.oci.image.manifest.v1+json",
    )
    target = manifest
    if nested:
        target = blob(
            {"schemaVersion": 2, "manifests": [manifest]},
            "application/vnd.oci.image.index.v1+json",
        )
    files["index.json"] = json.dumps(
        {"schemaVersion": 2, "manifests": [target]}
    ).encode()
    files["manifest.json"] = json.dumps(
        [
            {
                "Config": "blobs/sha256/" + config["digest"][7:],
                "RepoTags": ["foresight-sdk:pr"],
                "Layers": ["blobs/sha256/" + layer_digest[7:]],
            }
        ]
    ).encode()
    descriptor = write_archive(
        prefix, image_id=(IMAGE_ID if wrong_config else config["digest"])
    )
    with tarfile.open(prefix / "image.tar", "w") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    descriptor["archive_sha256"] = artifacts.digest(prefix / "image.tar")
    (prefix / "image.json").write_text(json.dumps(descriptor))
    return descriptor["image_id"], manifest["digest"], target["digest"]


def missing_docker_image(image):
    import subprocess

    return subprocess.CalledProcessError(
        1,
        ["docker", "image", "inspect", image],
        output=f"Error response from daemon: No such image: {image}\n",
    )


class ContainerdArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.prefix = Path(self.temporary.name) / "payload"

    def test_receipt_config_id_resolves_verified_manifest_and_nested_index(self):
        for nested in (False, True):
            with self.subTest(nested=nested):
                original, manifest, target = oci_archive(self.prefix, nested=nested)

                def inspect(image, target=target):
                    # Real Docker29's diagnostic: a legacy config ID is not an
                    # image address; a loaded OCI index may be the only address.
                    if image != target:
                        raise missing_docker_image(image)
                    return target

                with (
                    patch.object(sdk, "inspect", side_effect=inspect),
                    patch.object(sdk, "run") as run,
                ):
                    self.assertEqual(
                        sdk.load(self.prefix, "linux-sdk", "verified:pr"), "verified:pr"
                    )
                self.assertNotEqual(original, manifest)
                self.assertEqual(
                    run.call_args.args[0],
                    ["docker", "image", "tag", target, "verified:pr"],
                )

    def test_archive_manifest_cannot_substitute_different_receipt_config(self):
        original, _, _ = oci_archive(self.prefix, wrong_config=True)
        with (
            patch.object(sdk, "inspect", side_effect=missing_docker_image(original)),
            patch.object(sdk, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "unique manifest"):
                sdk.load(self.prefix, "linux-sdk", "verified:pr")
        self.assertEqual(run.call_count, 1)

    def test_daemon_failure_does_not_enable_archive_fallback(self):
        import subprocess

        oci_archive(self.prefix)
        failure = subprocess.CalledProcessError(
            1, ["docker"], output="Cannot connect to Docker daemon"
        )
        with (
            patch.object(sdk, "inspect", side_effect=failure),
            patch.object(sdk, "archive_manifests") as read,
            patch.object(sdk, "run"),
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                sdk.load(self.prefix, "linux-sdk", "verified:pr")
        read.assert_not_called()

    def test_content_addressed_metadata_is_verified_even_in_receipted_archive(self):
        import tarfile
        import io

        original, _, _ = oci_archive(self.prefix)
        archive = self.prefix / "image.tar"
        with tarfile.open(archive) as source:
            files = [(member, source.extractfile(member).read()) for member in source]
        with tarfile.open(archive, "w") as target:
            for member, data in files:
                if member.name == "blobs/sha256/" + original[7:]:
                    data = data.replace(b"amd64", b"arm64")
                target.addfile(member, io.BytesIO(data))
        descriptor = json.loads((self.prefix / "image.json").read_text())
        descriptor["archive_sha256"] = artifacts.digest(archive)
        (self.prefix / "image.json").write_text(json.dumps(descriptor))
        with (
            patch.object(sdk, "inspect", side_effect=missing_docker_image(original)),
            patch.object(sdk, "run"),
        ):
            with self.assertRaisesRegex(ValueError, "checksum"):
                sdk.load(self.prefix, "linux-sdk", "verified:pr")

    def test_missing_referenced_layer_is_not_a_qualified_loaded_image(self):
        original, _, _ = oci_archive(self.prefix, missing_layer=True)
        with (
            patch.object(sdk, "inspect", side_effect=missing_docker_image(original)),
            patch.object(sdk, "run") as run,
        ):
            with self.assertRaisesRegex(ValueError, "layer blob"):
                sdk.load(self.prefix, "linux-sdk", "verified:pr")
        self.assertEqual(run.call_count, 1)
