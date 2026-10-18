"""Reject mismatched runtimes before loading their code."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

LOADER = LIBRARY = None
if __name__ == "__main__":
    LOADER, LIBRARY = map(Path, sys.argv[1:])
    sys.argv = sys.argv[:1]


@unittest.skipUnless(__name__ == "__main__", "Native loader fixture runs through CTest")
class RuntimeIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "bin").mkdir()
        (self.root / "lib").mkdir()
        self.loader = self.root / "bin/loader"
        self.library = self.root / "lib/liblitert-test.so"
        self.marker = self.root / "loaded"
        shutil.copy2(LOADER, self.loader)
        shutil.copy2(LIBRARY, self.library)
        self.sha = hashlib.sha256(self.library.read_bytes()).hexdigest()

    def run_loader(self):
        return subprocess.run(
            [str(self.loader)],
            env={
                **os.environ,
                "FORESIGHT_LITERT_LIBRARY": str(self.library),
                "FORESIGHT_LITERT_LOADED_MARKER": str(self.marker),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )

    def bundle(self, sha=None, version="0.18.0"):
        (self.root / "manifest.json").write_text(
            json.dumps(
                {"gemma_runtime": {"version": version, "sha256": sha or self.sha}}
            )
        )

    def build_identity(self, version="0.18.0"):
        (self.library.parent / "build-manifest.json").write_text(
            json.dumps(
                {
                    "version": version,
                    "library_sha256": self.sha,
                    "upstream_commit": "b2f686e2ed4718fb84ec398a61dd59ca0f0aff27",
                }
            )
        )

    def test_unpinned_library_is_rejected_before_dlopen(self):
        result = self.run_loader()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_manifest_paths_preserve_linux_and_canonical_mac_bundle_resources(self):
        app = self.root / "Moved path/Example.app/Contents"
        service = app / "Library/Services/Service.app/Contents"
        cases = [
            ("linux", self.loader, self.root / "manifest.json"),
            ("macos", app / "MacOS/ui", app / "Resources/manifest.json"),
            ("macos", app / "MacOS/mcp", app / "Resources/manifest.json"),
            ("macos", app / "Resources/bin/model", app / "Resources/manifest.json"),
            ("macos", app / "Resources/bin/helper", app / "Resources/manifest.json"),
            ("macos", service / "MacOS/service", service / "Resources/manifest.json"),
        ]
        for platform, executable, manifest in cases:
            with self.subTest(platform=platform, executable=executable):
                result = subprocess.run(
                    [str(self.loader), "--manifest-path", platform, str(executable)],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=10,
                )
                self.assertEqual(Path(result.stdout.strip()), manifest)

    def test_matching_bundle_identity_loads_and_resolves_cached_symbols(self):
        self.bundle()
        result = self.run_loader()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())

    def test_bundle_pin_cannot_be_replaced_by_override_metadata(self):
        self.bundle("0" * 64)
        self.build_identity()
        self.assertNotEqual(self.run_loader().returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_version_and_modified_bytes_are_rejected_before_dlopen(self):
        self.bundle(version="0.17.0")
        self.assertNotEqual(self.run_loader().returncode, 0)
        self.assertFalse(self.marker.exists())
        self.bundle()
        with self.library.open("ab") as stream:
            stream.write(b"modified")
        self.assertNotEqual(self.run_loader().returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_source_build_identity_requires_pinned_version(self):
        self.build_identity(version="0.17.0")
        self.assertNotEqual(self.run_loader().returncode, 0)
        self.assertFalse(self.marker.exists())
        self.build_identity()
        result = self.run_loader()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
