"""Exercise actual RPM expansion and shell execution without application builds."""

import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "rpm_package", ROOT / "packaging/package_linux.py"
)
packages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packages)


@unittest.skipUnless(
    sys.platform == "linux" and shutil.which("rpmspec"), "Linux rpmspec required"
)
class RpmScriptletsTest(unittest.TestCase):
    def test_expanded_install_and_remove_guards(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.exercise(Path(temporary))

    def exercise(self, root_path):
        import fcntl

        spec = root_path / "fixture.spec"
        spec.write_text(packages.rpm_spec("0.1.2", "1", packages.METADATA))
        expanded = subprocess.run(
            ["rpmspec", "--parse", str(spec)],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        ).stdout
        root = root_path / "install"
        root.mkdir()
        identity = hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:24]
        directory = root_path / f"of-install-{os.getuid()}-{identity}"
        directory.mkdir(mode=0o700)
        for section, following in (("pre", "preun"), ("preun", "prep")):
            script = expanded.split(f"%{section}\n", 1)[1].split(f"%{following}\n", 1)[
                0
            ]
            assert packages.upgrade_helper() in script
            script = script.replace("/opt/open-foresight", str(root)).replace(
                "/tmp/of-install-*", str(root_path / "of-install-*")
            )
            with (directory / "lock").open("w+") as lock:
                for held in (False, True, False):
                    fcntl.lockf(lock, fcntl.LOCK_SH if held else fcntl.LOCK_UN)
                    result = subprocess.run(
                        ["sh", "-c", script, "rpm-fixture", "0"],
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    assert result.returncode == (1 if held else 0), result.stderr
                    assert "bad substitution" not in result.stderr
                    assert ("holds the install lock" in result.stderr) == held


if __name__ == "__main__":
    unittest.main()
