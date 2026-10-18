"""A helper's advertised revision must survive container checkout ownership."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(
    shutil.which("cmake") and shutil.which("git"), "Requires CMake and Git"
)
class HelperBuildIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="helper-identity-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = self.root / "identity.cmake"
        self.script.write_text(
            f'include("{ROOT / "cmake/ForesightBuildIdentity.cmake"}")\n'
            'foresight_build_revision(revision "${SOURCE_ROOT}")\n'
            'file(WRITE "${OUTPUT_FILE}" "${revision}")\n'
        )
        self.output = self.root / "revision.txt"
        # Hosted runners may globally trust every checkout. The fixture must
        # exercise Git ownership checks independently of that machine policy.
        self.environment = {
            **os.environ,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
        }

    def configure(self, source, revision=None, ownership=False):
        args = ["cmake", f"-DSOURCE_ROOT={source}", f"-DOUTPUT_FILE={self.output}"]
        if revision is not None:
            args.append(f"-DFORESIGHT_BUILD_REVISION={revision}")
        env = self.environment.copy()
        if ownership:
            env["GIT_TEST_ASSUME_DIFFERENT_OWNER"] = "true"
        return subprocess.run(
            [*args, "-P", str(self.script)],
            env=env,
            text=True,
            capture_output=True,
            timeout=300,
        )

    def test_container_checkout_ownership_uses_scoped_trust_and_twelve_digits(self):
        source = self.root / "repository"
        subprocess.run(
            ["git", "init", str(source)],
            env=self.environment,
            check=True,
            capture_output=True,
            timeout=300,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(source),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.test",
                "commit",
                "--allow-empty",
                "-m",
                "Identity fixture",
            ],
            env=self.environment,
            check=True,
            capture_output=True,
            timeout=300,
        )
        expected = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            env=self.environment,
            text=True,
            timeout=300,
        ).strip()[:12]
        rejected = subprocess.run(
            ["git", "-c", "safe.directory=", "-C", str(source), "rev-parse", "HEAD"],
            env={**self.environment, "GIT_TEST_ASSUME_DIFFERENT_OWNER": "true"},
            text=True,
            capture_output=True,
            timeout=300,
        )
        self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
        result = self.configure(source, ownership=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), expected)

    def test_exported_source_requires_valid_explicit_revision(self):
        source = self.root / "exported"
        source.mkdir()
        missing = self.configure(source)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("FORESIGHT_BUILD_REVISION", missing.stderr)
        for revision in ("unknown", "abc", "a" * 41):
            invalid = self.configure(source, revision)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("hexadecimal", invalid.stderr)
        valid = self.configure(source, "ABCDEF0123456789" * 2)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(self.output.read_text(), "abcdef012345")


def test_revision_change_recompiles_only_the_identity_unit(tmp_path):
    """Current-revision metadata must survive reuse of expensive native objects."""
    import shutil
    import subprocess

    import pytest

    if not shutil.which("cmake") or not shutil.which("c++"):
        pytest.skip("Native toolchain required for incremental revision test")
    source = tmp_path / "source"
    source.mkdir()
    template = ROOT / "services/helper/build_identity.cpp.in"
    (source / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\n"
        "project(identity_fixture LANGUAGES CXX)\n"
        'set(OPEN_FORESIGHT_VERSION "1.0.0")\n'
        f'configure_file("{template}" "${{CMAKE_BINARY_DIR}}/identity.cpp" @ONLY)\n'
        'add_executable(probe main.cpp "${CMAKE_BINARY_DIR}/identity.cpp")\n'
    )
    (source / "main.cpp").write_text(
        "#include <iostream>\n"
        "const char *foresight_helper_build_id();\n"
        "int main() { std::cout << foresight_helper_build_id(); }\n"
    )
    build = tmp_path / "build"

    def compile_revision(revision):
        subprocess.run(
            ["cmake", "-S", str(source), "-B", str(build), f"-DBUILD_REV={revision}"],
            capture_output=True,
            check=True,
            timeout=60,
        )
        subprocess.run(
            ["cmake", "--build", str(build)],
            capture_output=True,
            check=True,
            timeout=60,
        )
        return subprocess.check_output([str(build / "probe")], text=True, timeout=5)

    assert compile_revision("123456789abc") == "open-foresight-1.0.0-123456789abc"
    objects = list(build.rglob("main.cpp.o"))
    assert len(objects) == 1
    original = objects[0].stat().st_mtime_ns
    assert compile_revision("abcdef123456") == "open-foresight-1.0.0-abcdef123456"
    assert objects[0].stat().st_mtime_ns == original
