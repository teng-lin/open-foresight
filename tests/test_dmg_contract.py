"""Exercise the real DMG packager with a tiny signed executable fixture."""

import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "dmg_packager", ROOT / "tools/create_dmg.py"
)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


@unittest.skipUnless(sys.platform == "darwin", "Apple codesign and hdiutil required")
class DmgContractTest(unittest.TestCase):
    def test_verification_waits_for_owned_image_lock_without_changing_bytes(self):
        """Exercise real DiskImages EAGAIN beyond the former retry window."""
        import contextlib
        import fcntl
        import io
        import threading

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "evidence").write_text("same-byte verification fixture\n")
            image = root / "locked.dmg"
            subprocess.run(
                [
                    "hdiutil",
                    "create",
                    "-srcfolder",
                    str(source),
                    "-format",
                    "UDZO",
                    str(image),
                ],
                check=True,
                timeout=60,
            )
            digest = packager.image_digest(image)
            released = threading.Event()
            with image.open("r+b") as stream:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = subprocess.run(
                    ["hdiutil", "verify", str(image)],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                self.assertEqual(locked.returncode, 1, locked.stdout + locked.stderr)
                self.assertIn(
                    "hdiutil: verify failed - Resource temporarily unavailable",
                    locked.stderr.splitlines(),
                )

                def unlock():
                    fcntl.flock(stream, fcntl.LOCK_UN)
                    released.set()

                release = threading.Timer(6, unlock)
                diagnostics = io.StringIO()
                release.start()
                try:
                    with contextlib.redirect_stderr(diagnostics):
                        packager.verify_image(image)
                finally:
                    release.cancel()
                    release.join()
                    fcntl.flock(stream, fcntl.LOCK_UN)
                    print(diagnostics.getvalue(), file=sys.stderr, end="")
            self.assertTrue(released.is_set(), "Verification must wait for the lock")
            self.assertGreaterEqual(
                diagnostics.getvalue().count(
                    "hdiutil: verify failed - Resource temporarily unavailable"
                ),
                3,
            )
            self.assertEqual(packager.image_digest(image), digest)
            self.assertEqual(
                sorted(path.name for path in root.iterdir()), ["locked.dmg", "source"]
            )

    def test_signed_fixture_survives_dmg_creation_and_mount(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Open Foresight.app"
            executable = app / "Contents/MacOS/fixture"
            executable.parent.mkdir(parents=True)
            source = root / "fixture.c"
            source.write_text("int main(void) { return 0; }\n")
            subprocess.run(
                ["cc", str(source), "-o", str(executable)], check=True, timeout=60
            )
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "io.openforesight.PackageFixture",
                        "CFBundleExecutable": "fixture",
                        "CFBundlePackageType": "APPL",
                        "CFBundleVersion": "1",
                    },
                    stream,
                )
            subprocess.run(
                ["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=60
            )
            manifest = root / "fixture.manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "revision": "a" * 40,
                        "architecture": "arm64",
                        "version": "0.1.2",
                        "build_number": 10,
                    }
                )
            )
            image = packager.create(
                app, manifest, "Open-Foresight-fixture-macos-arm64.dmg", root / "dist"
            )
            metadata = json.loads(Path(str(image) + ".build.json").read_text())
            self.assertEqual(
                metadata["sha256"], hashlib.sha256(image.read_bytes()).hexdigest()
            )
            mount = root / "mount"
            mount.mkdir()
            subprocess.run(
                [
                    "hdiutil",
                    "attach",
                    "-nobrowse",
                    "-readonly",
                    "-mountpoint",
                    str(mount),
                    str(image),
                ],
                check=True,
                timeout=60,
            )
            try:
                installed = mount / "Open Foresight.app"
                subprocess.run(
                    ["codesign", "--verify", "--deep", "--strict", str(installed)],
                    check=True,
                    timeout=60,
                )
                subprocess.run(
                    [str(installed / "Contents/MacOS/fixture")], check=True, timeout=30
                )
                self.assertEqual(
                    (mount / "Applications").readlink(), Path("/Applications")
                )
            finally:
                subprocess.run(
                    ["hdiutil", "detach", str(mount)], check=True, timeout=60
                )

    def test_previous_signed_dmg_upgrades_owned_copy_without_losing_database(self):
        """Real DMG/signature/atomic-install boundaries with a tiny SQLite fixture."""
        import sqlite3
        from unittest.mock import patch

        sys.path.insert(0, str(ROOT / "tools"))
        import test_release_dmg as acceptance
        from install_macos import install, metadata, verify_signature

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            images = []

            def assert_fixture_version(bundle, version):
                result = subprocess.run(
                    [str(bundle / "Contents/MacOS/fixture")],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(
                    result.returncode,
                    0,
                    f"fixture exit={result.returncode}: "
                    f"stdout={result.stdout!r}, stderr={result.stderr!r}",
                )
                self.assertEqual(result.stdout, version + "\n")

            for version in ("1.2.2", "1.2.3"):
                build = root / version
                app = build / "Open Foresight.app"
                executable = app / "Contents/MacOS/fixture"
                executable.parent.mkdir(parents=True)
                source = build / "fixture.c"
                source.write_text(
                    "#include <stdio.h>\n"
                    f'int main(void) {{ puts("{version}"); return 0; }}\n'
                )
                subprocess.run(
                    ["cc", str(source), "-o", str(executable)], check=True, timeout=60
                )
                (app / "Contents/Info.plist").write_bytes(
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": "io.openforesight.App",
                            "CFBundleExecutable": "fixture",
                            "CFBundlePackageType": "APPL",
                            "CFBundleVersion": version,
                            "CFBundleShortVersionString": version,
                        }
                    )
                )
                subprocess.run(
                    ["codesign", "--force", "--sign", "-", str(app)],
                    check=True,
                    timeout=60,
                )
                assert_fixture_version(app, version)
                manifest = build / "manifest.json"
                manifest.write_text(
                    json.dumps(
                        {
                            "revision": "a" * 40,
                            "architecture": "arm64",
                            "version": version,
                            "build_number": 1,
                        }
                    )
                )
                image = packager.create(
                    app,
                    manifest,
                    "Open-Foresight-upgrade-fixture-macos-arm64.dmg",
                    build / "dist",
                )
                checksum = hashlib.sha256(image.read_bytes()).hexdigest()
                (image.parent / "installer.json").write_text(
                    json.dumps(
                        {
                            "tag": "v" + version,
                            "asset": image.name,
                            "sha256": checksum,
                            "source_commit": "a" * 40,
                            "status": "verified_download",
                        }
                    )
                )
                images.append(image)
            temporary = root / "real-temp"
            temporary.mkdir()
            alias = root / "temp-alias"
            alias.symlink_to(temporary, target_is_directory=True)
            destination = root / "owned/Open Foresight.app"
            destination.mkdir(parents=True)
            output = root / "reports"
            output.mkdir()

            def persistence(bundle, profile, state, phase):
                self.assertEqual(
                    metadata(bundle)["CFBundleShortVersionString"], "1.2.2"
                )
                assert_fixture_version(bundle, "1.2.2")
                profile.mkdir()
                with sqlite3.connect(profile / "application.db") as connection:
                    connection.execute("CREATE TABLE notes(body TEXT)")
                    connection.execute(
                        "INSERT INTO notes VALUES (?)", ("upgrade data",)
                    )

            with patch.object(acceptance, "persistence_probe", side_effect=persistence):
                acceptance.previous_installation(
                    images[0], destination, alias, output, images[1]
                )
            mount = root / "new-volume"
            mount.mkdir()
            subprocess.run(
                [
                    "hdiutil",
                    "attach",
                    "-readonly",
                    "-nobrowse",
                    "-mountpoint",
                    str(mount),
                    str(images[1]),
                ],
                check=True,
                timeout=60,
            )
            try:
                install(
                    mount / "Open Foresight.app",
                    destination,
                    allow_adhoc=True,
                    active=lambda app: set(),
                )
                self.assertEqual(
                    metadata(destination)["CFBundleShortVersionString"], "1.2.3"
                )
                verify_signature(destination)
                with sqlite3.connect(
                    temporary / "upgrade-profile/application.db"
                ) as connection:
                    self.assertEqual(
                        connection.execute("SELECT body FROM notes").fetchall(),
                        [("upgrade data",)],
                    )
                assert_fixture_version(destination, "1.2.3")
            finally:
                subprocess.run(
                    ["hdiutil", "detach", str(mount)], check=True, timeout=60
                )


if __name__ == "__main__":
    unittest.main()
