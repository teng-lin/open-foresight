"""Guard both installed Clang runtime layouts used by native CI."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools.sanitizer_runtime import address_runtime


class SanitizerRuntimeTests(unittest.TestCase):
    def test_legacy_qualified_library(self):
        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / "libclang_rt.asan-x86_64.so"
            library.touch()
            with patch(
                "tools.sanitizer_runtime.subprocess.check_output",
                side_effect=["libclang_rt.asan.so\n", str(library) + "\n"],
            ):
                self.assertEqual(address_runtime(), library.resolve())

    def test_new_unqualified_runtime_resolves_target_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "x86_64-unknown-linux-gnu" / "libclang_rt.asan.so"
            target.parent.mkdir()
            target.touch()
            alias = root / "libclang_rt.asan.so"
            alias.symlink_to(target)
            with patch(
                "tools.sanitizer_runtime.subprocess.check_output",
                return_value=str(alias) + "\n",
            ):
                self.assertEqual(address_runtime(), target.resolve())
                self.assertEqual(address_runtime().parent, target.parent.resolve())

    def test_compatibility_alias_also_resolves_to_unqualified_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target" / "libclang_rt.asan.so"
            target.parent.mkdir()
            target.touch()
            alias = root / "libclang_rt.asan-x86_64.so"
            alias.symlink_to(target)
            with patch(
                "tools.sanitizer_runtime.subprocess.check_output",
                side_effect=["libclang_rt.asan.so\n", str(alias) + "\n"],
            ):
                self.assertEqual(address_runtime(), target.resolve())

    def test_runtime_in_a_symlinked_parent_directory_is_canonical(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "physical" / "libclang_rt.asan.so"
            target.parent.mkdir()
            target.touch()
            alias = root / "logical"
            alias.symlink_to(target.parent, target_is_directory=True)
            with patch(
                "tools.sanitizer_runtime.subprocess.check_output",
                return_value=str(alias / target.name) + "\n",
            ):
                self.assertEqual(address_runtime(), target.resolve())
                self.assertEqual(address_runtime().parent, target.parent.resolve())

    def test_missing_runtime_fails_closed(self):
        with patch(
            "tools.sanitizer_runtime.subprocess.check_output",
            side_effect=["libclang_rt.asan.so\n", "libclang_rt.asan-x86_64.so\n"],
        ):
            with self.assertRaisesRegex(FileNotFoundError, "shared ASan runtime"):
                address_runtime()
