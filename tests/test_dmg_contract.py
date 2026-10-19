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


if __name__ == "__main__":
    unittest.main()
