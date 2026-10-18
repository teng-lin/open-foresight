"""Seal runtime identity after Mach-O signing for every native Mac host."""

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import macos_bundle  # noqa: E402 - Local tools are imported after path setup.
from package_macos import write_litert_manifests  # noqa: E402 - Local tools path.


class MacRuntimeIdentityTests(unittest.TestCase):
    def test_signed_library_identity_precedes_every_bundle_seal(self):
        for identity in ("-", "Test Developer ID"):
            with self.subTest(identity=identity):
                self._check_identity(identity)

    def _check_identity(self, identity):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Moved path with spaces/Example.app"
            library = app / "Contents/Resources/lib/liblitert-lm.dylib"
            service = app / (
                "Contents/Library/Services/Open Foresight Service.app/"
                "Contents/MacOS/foresight-service"
            )
            hosts = [
                app / "Contents/MacOS/open-foresight",
                app / "Contents/MacOS/foresight-mcp",
                app / "Contents/Resources/bin/foresight-model",
                app / "Contents/Resources/bin/ForesightHelper",
                service,
            ]
            for path in [library, *hosts]:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"unsigned code")
            expected = hashlib.sha256(b"signed relocated library").hexdigest()
            events = []

            def codesign(*args):
                if "--sign" not in args:
                    return ""
                target = Path(args[-1])
                if target == library:
                    library.write_bytes(b"signed relocated library")
                    events.append("library signed")
                elif target.is_dir():
                    for host in hosts:
                        manifest = (host.parent / "../manifest.json").resolve()
                        self.assertEqual(
                            json.loads(manifest.read_text())["gemma_runtime"],
                            {"version": "0.18.0", "sha256": expected},
                        )
                    events.append("bundle sealed")
                return ""

            def receipt():
                self.assertEqual(events, ["library signed"])
                write_litert_manifests(app, library, service)
                events.append("identity written")

            with (
                patch.object(macos_bundle, "binaries", return_value=[library]),
                patch.object(macos_bundle, "run", side_effect=codesign),
            ):
                macos_bundle.sign_application(
                    app,
                    identity,
                    ROOT / "packaging/macos/Release.entitlements",
                    before_seal=receipt,
                )
            self.assertEqual(events[:2], ["library signed", "identity written"])
            self.assertIn("bundle sealed", events[2:])


if __name__ == "__main__":
    unittest.main()
