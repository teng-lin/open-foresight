"""Published-byte identity and clean installed-runtime boundaries."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from release_asset_acceptance import (
    select_asset,
    verify_checksum,
    source_revision,
    provenance_name,
    main as download_main,
)
from installed_runtime import clean_environment, service_command
from test_release_dmg import run as run_dmg
from argparse import Namespace


class ReleaseAssetAcceptanceTest(unittest.TestCase):
    def test_draft_download_uses_list_lookup_and_requires_explicit_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "open-foresight_0.1.1-1_amd64.deb"
            digest = hashlib.sha256(b"installer").hexdigest()
            metadata = json.dumps(
                {
                    "revision": "a" * 40,
                    "sha256": digest,
                    "version": "0.1.1",
                    "format": "deb",
                }
            ).encode()
            payloads = {
                name: b"installer",
                name + ".sha256": f"{digest}  {name}\n".encode(),
                name + ".build.json": metadata,
            }
            draft = {
                "draft": True,
                "tag_name": "v0.1.1",
                "id": 42,
                "html_url": "https://example/release",
                "assets": [
                    {"name": key, "size": len(value), "id": index + 1}
                    for index, (key, value) in enumerate(payloads.items())
                ],
            }

            def response(command, **kwargs):
                if command == [
                    "gh",
                    "api",
                    "repos/owner/repo/releases?per_page=100&page=1",
                ]:
                    return json.dumps([draft])
                if command == ["gh", "api", "repos/owner/repo/commits/v0.1.1"]:
                    return json.dumps({"sha": "a" * 40})
                raise subprocess.CalledProcessError(1, command, stderr="HTTP 404")

            def download(arguments, **kwargs):
                selected = arguments[arguments.index("--pattern") + 1]
                (root / selected).write_bytes(payloads[selected])

            arguments = [
                "download",
                "--tag",
                "v0.1.1",
                "--repo",
                "owner/repo",
                "--format",
                "deb",
                "--directory",
                directory,
            ]
            with (
                patch.object(sys, "argv", arguments),
                patch("release_asset_acceptance.subprocess.run") as command,
                patch(
                    "release_asset_acceptance.subprocess.check_output",
                    side_effect=response,
                ),
            ):
                with self.assertRaisesRegex(ValueError, "requested published release"):
                    download_main()
                command.assert_not_called()
            with (
                patch.object(sys, "argv", arguments + ["--allow-draft"]),
                patch("release_asset_acceptance.subprocess.run", side_effect=download),
                patch(
                    "release_asset_acceptance.subprocess.check_output",
                    side_effect=response,
                ),
            ):
                download_main()
            report = json.loads((root / "installer.json").read_text())
            self.assertEqual(report["release_id"], 42)
            self.assertEqual(report["source_commit"], "a" * 40)
            self.assertEqual(report["status"], "verified_download")

    def test_all_package_formats_require_a_unique_asset_and_its_checksum(self):
        """An incomplete or ambiguous release must never choose arbitrary bytes."""
        for kind, suffix in [
            ("deb", ".deb"),
            ("rpm", ".rpm"),
            ("arch", ".pkg.tar.zst"),
            ("dmg", ".dmg"),
        ]:
            name = "Open-Foresight-0.1.0" + suffix
            metadata_name = provenance_name({"name": name}, kind)
            release = {
                "assets": [
                    {"name": name, "id": 1},
                    {"name": name + ".sha256"},
                    {"name": metadata_name},
                ]
            }
            self.assertEqual(select_asset(release, kind)["id"], 1)
            with self.assertRaises(ValueError):
                select_asset({"assets": release["assets"][:-1]}, kind)
            with self.assertRaises(ValueError):
                select_asset(
                    {"assets": release["assets"] + [{"name": metadata_name}]}, kind
                )
            with self.assertRaises(ValueError):
                select_asset({"assets": release["assets"][:1]}, kind)
            with self.assertRaises(ValueError):
                select_asset(
                    {"assets": release["assets"] + [{"name": "duplicate" + suffix}]},
                    kind,
                )
        with self.assertRaises(ValueError):
            select_asset(
                {
                    "assets": [
                        {"name": "../escape.deb"},
                        {"name": "../escape.deb.sha256"},
                    ]
                },
                "deb",
            )

    def test_linux_provenance_binds_revision_to_installer_version_format_and_bytes(
        self,
    ):
        metadata = {
            "revision": "b" * 40,
            "sha256": "c" * 64,
            "format": "deb",
            "version": "0.1.0",
        }
        self.assertEqual(source_revision(metadata, "deb", "v0.1.0", "c" * 64), "b" * 40)
        for change in (
            {"revision": "main"},
            {"revision": "b" * 39},
            {"revision": None},
            {"sha256": "d" * 64},
            {"format": "rpm"},
            {"version": "0.2.0"},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                source_revision({**metadata, **change}, "deb", "v0.1.0", "c" * 64)
        with self.assertRaises(ValueError):
            source_revision([], "deb", "v0.1.0", "c" * 64)
        self.assertEqual(
            source_revision(
                {
                    "revision": "a" * 40,
                    "arch": "arm64",
                    "sha256": "c" * 64,
                    "format": "dmg",
                    "version": "0.1.0",
                },
                "dmg",
                "v0.1.0",
                "c" * 64,
            ),
            "a" * 40,
        )
        with self.assertRaises(ValueError):
            source_revision(
                {"revision": "a" * 40, "architecture": "x86_64"},
                "dmg",
                "v0.1.0",
                "c" * 64,
            )

    def test_recovered_installer_download_uses_its_build_commit_and_preserves_tag_identity(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "open-foresight_0.1.0-1_amd64.deb"
            digest = hashlib.sha256(b"installer bytes").hexdigest()
            metadata = json.dumps(
                {
                    "revision": "b" * 40,
                    "sha256": digest,
                    "version": "0.1.0",
                    "format": "deb",
                }
            ).encode()
            payloads = {
                name: b"installer bytes",
                name + ".sha256": f"{digest}  {name}\n".encode(),
                name + ".build.json": metadata,
            }
            release = {
                "draft": False,
                "tag_name": "v0.1.0",
                "id": 1,
                "html_url": "https://example/release",
                "assets": [
                    {"name": key, "size": len(value), "id": index + 1}
                    for index, (key, value) in enumerate(payloads.items())
                ],
            }

            def download(arguments, **kwargs):
                selected = arguments[arguments.index("--pattern") + 1]
                (root / selected).write_bytes(payloads[selected])

            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "download",
                        "--tag",
                        "v0.1.0",
                        "--format",
                        "deb",
                        "--directory",
                        directory,
                        "--allow-recovery-revision",
                    ],
                ),
                patch("release_asset_acceptance.subprocess.run", side_effect=download),
                patch(
                    "release_asset_acceptance.subprocess.check_output",
                    side_effect=[
                        json.dumps([release]),
                        json.dumps({"sha": "a" * 40}),
                        json.dumps({"sha": "b" * 40}),
                    ],
                ),
            ):
                download_main()
            report = json.loads((root / "installer.json").read_text())
            self.assertEqual(report["source_commit"], "b" * 40)
            self.assertEqual(report["release_tag_commit"], "a" * 40)
            self.assertEqual(report["status"], "verified_download")
            self.assertEqual(report["provenance_asset"], name + ".build.json")
            self.assertEqual(
                report["provenance_sha256"], hashlib.sha256(metadata).hexdigest()
            )

    def test_mismatched_installer_revision_is_rejected_without_explicit_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "open-foresight_0.1.0-1_amd64.deb"
            digest = hashlib.sha256(b"installer bytes").hexdigest()
            metadata = json.dumps(
                {
                    "revision": "b" * 40,
                    "sha256": digest,
                    "version": "0.1.0",
                    "format": "deb",
                }
            ).encode()
            payloads = {
                name: b"installer bytes",
                name + ".sha256": f"{digest}  {name}\n".encode(),
                name + ".build.json": metadata,
            }
            release = {
                "draft": False,
                "tag_name": "v0.1.0",
                "id": 1,
                "html_url": "https://example/release",
                "assets": [
                    {"name": key, "size": len(value), "id": index + 1}
                    for index, (key, value) in enumerate(payloads.items())
                ],
            }

            def download(arguments, **kwargs):
                selected = arguments[arguments.index("--pattern") + 1]
                (root / selected).write_bytes(payloads[selected])

            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "download",
                        "--tag",
                        "v0.1.0",
                        "--format",
                        "deb",
                        "--directory",
                        directory,
                    ],
                ),
                patch("release_asset_acceptance.subprocess.run", side_effect=download),
                patch(
                    "release_asset_acceptance.subprocess.check_output",
                    side_effect=[
                        json.dumps([release]),
                        json.dumps({"sha": "a" * 40}),
                        json.dumps({"sha": "b" * 40}),
                    ],
                ),
            ):
                with self.assertRaisesRegex(ValueError, "differs from release tag"):
                    download_main()
            self.assertEqual(
                json.loads((root / "installer.json").read_text())["status"], "failed"
            )

    def test_failed_download_cannot_leave_a_previous_success_report(self):
        """A reused download directory must not retain misleading passed evidence."""
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "installer.json"
            report.write_text('{"status":"verified_download"}')
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "download",
                        "--tag",
                        "v0.1.0",
                        "--format",
                        "deb",
                        "--directory",
                        directory,
                    ],
                ),
                patch(
                    "release_asset_acceptance.subprocess.check_output",
                    side_effect=RuntimeError("Fixture network failure"),
                ),
            ):
                with self.assertRaises(RuntimeError):
                    download_main()
            self.assertEqual(json.loads(report.read_text())["status"], "failed")

    def test_checksum_binds_filename_and_detects_tampered_download(self):
        """A matching checksum for another filename must not authorize this one."""
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.rpm"
            sidecar = Path(directory) / "package.rpm.sha256"
            package.write_bytes(b"published bytes")
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            sidecar.write_text(f"{digest}  {package.name}\n")
            self.assertEqual(verify_checksum(package, sidecar), digest)
            package.write_bytes(b"tampered bytes")
            with self.assertRaises(ValueError):
                verify_checksum(package, sidecar)
            sidecar.write_text(f"{digest}  different.rpm\n")
            with self.assertRaises(ValueError):
                verify_checksum(package, sidecar)

    def test_clean_gui_environment_drops_all_runtime_and_credential_overrides(self):
        """Only display plumbing and explicit synthetic profile paths survive."""
        with patch.dict(
            os.environ,
            {
                "LD_LIBRARY_PATH": "/developer/lib",
                "DYLD_LIBRARY_PATH": "/developer/mac",
                "PYTHONPATH": "/checkout",
                "FORESIGHT_SEARCH_API_KEY": "private-fixture",
                "FORESIGHT_MODEL_WORKER": "/developer/worker",
                "DISPLAY": ":99",
            },
        ):
            env = clean_environment("/tmp/home", "/tmp/data", "/tmp/run")
        self.assertEqual(env["DISPLAY"], ":99")
        self.assertEqual(env["FORESIGHT_DATA"], "/tmp/data")
        self.assertFalse(
            set(env)
            & {
                "LD_LIBRARY_PATH",
                "DYLD_LIBRARY_PATH",
                "PYTHONPATH",
                "FORESIGHT_SEARCH_API_KEY",
                "FORESIGHT_MODEL_WORKER",
            }
        )

    def test_linux_service_control_uses_the_installed_launcher(self):
        """Do not compensate for a broken wrapper with developer paths."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            (root / "bin/foresight-service").touch()
            (root / "open-foresight-service").touch()
            with patch(
                "installed_runtime.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, '{"pid":123}', ""),
            ) as run:
                self.assertEqual(
                    service_command(root / "bin/foresight-service", {}, "--status"),
                    {"pid": 123},
                )
                self.assertEqual(
                    run.call_args.args[0],
                    [str(root / "open-foresight-service"), "--status"],
                )

    def test_dmg_failure_detaches_its_mount_and_removes_only_its_created_copy(self):
        """An application-test failure must not leave a mounted image or installed copy."""
        import plistlib

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "fixture.dmg"
            dmg.write_bytes(b"fixture")
            digest = hashlib.sha256(b"fixture").hexdigest()
            Path(str(dmg) + ".sha256").write_text(digest + "  fixture.dmg\n")
            revision = "a" * 40
            (root / "installer.json").write_text(
                json.dumps(
                    {
                        "asset": "fixture.dmg",
                        "sha256": digest,
                        "source_commit": revision,
                    }
                )
            )
            destination = root / "Applications/Open Foresight.app"
            commands = []

            def command(arguments, **kwargs):
                commands.append(arguments)
                if arguments[:2] == ["hdiutil", "attach"]:
                    mount = Path(arguments[arguments.index("-mountpoint") + 1])
                    source = mount / "Open Foresight.app/Contents"
                    source.mkdir(parents=True)
                    (source / "Info.plist").write_bytes(
                        plistlib.dumps({"CFBundleIdentifier": "io.openforesight.App"})
                    )
                if "test_installed_release.py" in " ".join(map(str, arguments)):
                    self.assertIn(revision, arguments)
                    raise subprocess.CalledProcessError(1, arguments)
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with (
                patch("test_release_dmg.platform.system", return_value="Darwin"),
                patch("test_release_dmg.subprocess.run", side_effect=command),
                patch(
                    "test_release_dmg.verify_signature", return_value={"adhoc": True}
                ),
            ):
                with self.assertRaises(subprocess.CalledProcessError):
                    run_dmg(
                        Namespace(
                            dmg=dmg,
                            destination=destination,
                            output=root / "reports",
                            models=root / "models",
                        )
                    )
            self.assertFalse(destination.exists())
            self.assertTrue(
                any(command[:2] == ["hdiutil", "detach"] for command in commands)
            )
            report = json.loads((root / "reports/installation.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertTrue(report["uninstall_owned_copy"])

    def test_standard_dmg_smoke_receives_verified_installer_revision(self):
        import plistlib

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "fixture.dmg"
            dmg.write_bytes(b"fixture")
            digest = hashlib.sha256(b"fixture").hexdigest()
            Path(str(dmg) + ".sha256").write_text(digest + "  fixture.dmg\n")
            revision = "c" * 40
            (root / "installer.json").write_text(
                json.dumps(
                    {
                        "asset": dmg.name,
                        "sha256": digest,
                        "source_commit": revision,
                    }
                )
            )
            commands = []

            def command(arguments, **kwargs):
                commands.append(arguments)
                if arguments[:2] == ["hdiutil", "attach"]:
                    mount = Path(arguments[arguments.index("-mountpoint") + 1])
                    contents = mount / "Open Foresight.app/Contents"
                    contents.mkdir(parents=True)
                    (contents / "Info.plist").write_bytes(
                        plistlib.dumps(
                            {
                                "CFBundleIdentifier": "io.openforesight.App",
                            }
                        )
                    )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with (
                patch("test_release_dmg.platform.system", return_value="Darwin"),
                patch("test_release_dmg.subprocess.run", side_effect=command),
                patch(
                    "test_release_dmg.verify_signature", return_value={"adhoc": True}
                ),
                patch("test_release_dmg.probe_installed_documents", return_value={}),
                patch("test_release_dmg.persistence_probe"),
                patch("test_release_dmg.install"),
            ):
                run_dmg(
                    Namespace(
                        dmg=dmg,
                        destination=root / "Installed.app",
                        models=None,
                        validation="standard",
                        output=root / "reports",
                    )
                )
            smoke = next(
                args
                for args in commands
                if any(str(arg).endswith("/smoke_macos_bundle.py") for arg in args)
            )
            self.assertEqual(smoke[smoke.index("--expected-revision") + 1], revision)
            self.assertFalse(
                any("test_installed_release.py" in str(args) for args in commands)
            )

    def test_dmg_requires_installer_identity_report_and_handles_detach_failures(self):
        """DMG acceptance must require installer.json and preserve primary errors on detach failure."""
        import plistlib

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "fixture.dmg"
            dmg.write_bytes(b"fixture")
            digest = hashlib.sha256(b"fixture").hexdigest()
            Path(str(dmg) + ".sha256").write_text(digest + "  fixture.dmg\n")
            destination = root / "Applications/Open Foresight.app"
            detach_codes = [1, 2]

            def command(arguments, **kwargs):
                if arguments[:2] == ["hdiutil", "attach"]:
                    mount = Path(arguments[arguments.index("-mountpoint") + 1])
                    source = mount / "Open Foresight.app/Contents"
                    source.mkdir(parents=True)
                    (source / "Info.plist").write_bytes(
                        plistlib.dumps({"CFBundleIdentifier": "io.openforesight.App"})
                    )
                if arguments[:2] == ["hdiutil", "detach"]:
                    return subprocess.CompletedProcess(
                        arguments, detach_codes.pop(0), "", ""
                    )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with (
                patch("test_release_dmg.platform.system", return_value="Darwin"),
                patch("test_release_dmg.subprocess.run", side_effect=command),
                patch(
                    "test_release_dmg.verify_signature", return_value={"adhoc": True}
                ),
            ):
                with self.assertRaises(FileNotFoundError):
                    run_dmg(
                        Namespace(
                            dmg=dmg,
                            destination=destination,
                            output=root / "reports",
                            models=root / "models",
                        )
                    )
            report = json.loads((root / "reports/installation.json").read_text())
            self.assertEqual(report["error_type"], "FileNotFoundError")
            self.assertEqual(report["detach_error"], 2)
            # If all checks pass, a persistent detach failure must still fail acceptance.
            (root / "installer.json").write_text(
                json.dumps(
                    {
                        "asset": "fixture.dmg",
                        "sha256": digest,
                        "source_commit": "b" * 40,
                    }
                )
            )
            detach_codes = [1, 3]
            with (
                patch("test_release_dmg.platform.system", return_value="Darwin"),
                patch("test_release_dmg.subprocess.run", side_effect=command),
                patch(
                    "test_release_dmg.verify_signature", return_value={"adhoc": True}
                ),
                patch("test_release_dmg.persistence_probe"),
                patch("test_release_dmg.install"),
            ):
                with self.assertRaisesRegex(RuntimeError, "Failed to detach"):
                    run_dmg(
                        Namespace(
                            dmg=dmg,
                            destination=destination,
                            output=root / "reports",
                            models=root / "models",
                        )
                    )
            report = json.loads((root / "reports/installation.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["detach_error"], 3)

    def test_dmg_acceptance_refuses_existing_installation_before_any_system_mutation(
        self,
    ):
        """An acceptance invocation cannot replace the user's app."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / "fixture.dmg"
            dmg.write_bytes(b"fixture")
            Path(str(dmg) + ".sha256").write_text(
                hashlib.sha256(b"fixture").hexdigest() + "  fixture.dmg\n"
            )
            existing = root / "Open Foresight.app"
            existing.mkdir()
            sentinel = existing / "keep"
            sentinel.write_text("user installation")
            with (
                patch("test_release_dmg.platform.system", return_value="Darwin"),
                patch("test_release_dmg.subprocess.run") as process,
            ):
                with self.assertRaisesRegex(ValueError, "Refusing to replace"):
                    run_dmg(
                        Namespace(
                            dmg=dmg,
                            destination=existing,
                            output=root / "reports",
                            models=root / "models",
                        )
                    )
                process.assert_not_called()
            self.assertEqual(sentinel.read_text(), "user installation")

    def test_linux_package_launcher_exports_runtime_revision_and_uninstall_checks_desktop_entry(
        self,
    ):
        """Linux package launcher must export FORESIGHT_RUNTIME_REVISION for exact revision acceptance."""
        import package

        revision = "c" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build"
            flutter = root / "flutter"
            flutter.mkdir()
            (flutter / "open-foresight").write_text("app")
            for rel in (
                "services/helper/ForesightHelper",
                "native/libforesight_native.so",
                "application/foresight-service",
                "application/foresight-mcp",
                "services/inference/foresight-model",
                "lib/liblitert-lm.so",
                "_deps/sentencepiece-src/LICENSE",
                "_deps/flatbuffers-src/LICENSE",
                "_deps/sentencepiece-src/third_party/protobuf-lite/LICENSE",
                "_deps/sentencepiece-src/third_party/esaxx/LICENSE",
                "_deps/sentencepiece-src/third_party/darts_clone/LICENSE",
                "_deps/sentencepiece-src/third_party/absl/LICENSE",
            ):
                target = build / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"fixture")
            output = root / "dist"
            litert_digest = hashlib.sha256(b"fixture").hexdigest()
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "package.py",
                        "--build",
                        str(build),
                        "--flutter-bundle",
                        str(flutter),
                        "--output",
                        str(output),
                        "--litert-library",
                        str(build / "lib/liblitert-lm.so"),
                        "--revision",
                        revision,
                    ],
                ),
                patch.object(package, "LIBRARY_SHA256", litert_digest),
                patch("package.subprocess.run"),
                patch("package.subprocess.check_output", return_value=""),
            ):
                package.main()
            launcher = (output / "open-foresight").read_text()
            self.assertIn(f'export FORESIGHT_RUNTIME_REVISION="{revision}"', launcher)
        script = (
            Path(__file__).resolve().parents[1] / "packaging/ci/test-release-package.sh"
        ).read_text()
        self.assertIn(
            "test ! -e /usr/share/applications/io.openforesight.App.desktop", script
        )


def test_dmg_provenance_requires_bytes_format_and_version():
    import pytest

    metadata = {
        "revision": "a" * 40,
        "arch": "arm64",
        "format": "dmg",
        "version": "0.1.1",
        "sha256": "b" * 64,
    }
    assert source_revision(metadata, "dmg", "v0.1.1", "b" * 64) == "a" * 40
    for changed in (
        {"sha256": "c" * 64},
        {"format": "deb"},
        {"version": "0.1.0"},
        {"arch": "x86_64"},
    ):
        with pytest.raises(ValueError):
            source_revision({**metadata, **changed}, "dmg", "v0.1.1", "b" * 64)
