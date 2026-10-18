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


def test_thread_runtime_selection_uses_tsan_instead_of_asan(tmp_path):
    from tools.sanitizer_runtime import address_runtime
    from unittest.mock import patch

    runtime = tmp_path / "libclang_rt.tsan.so"
    runtime.write_text("fixture")
    with patch(
        "tools.sanitizer_runtime.subprocess.check_output", return_value=str(runtime)
    ) as command:
        assert address_runtime(kind="thread") == runtime
        assert "libclang_rt.tsan.so" in command.call_args.args[0][-1]


def test_thread_and_address_sanitizers_have_separate_jobs_and_cache_prefixes():
    from pathlib import Path
    import yaml

    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load(
        (root / ".github/workflows/native-sanitizers.yml").read_text()
    )
    job = workflow["jobs"]["native-thread-sanitizer"]
    source = str(job)
    assert "-DFORESIGHT_THREAD_SANITIZER=ON" in source
    assert "--sanitizer thread" in source
    assert "build/thread-sdk" in source and "build/sanitizer-sdk" not in source
    assert "tools/verify_thread_sanitizer.py" in source
    assert "tools/run_thread_sanitizers.sh" in source
    assert "thread-policy" in job["needs"]
    assert "probation" in job["continue-on-error"]
    config = (root / "cmake/ForesightSanitizers.cmake").read_text()
    assert "FORESIGHT_SANITIZERS AND FORESIGHT_THREAD_SANITIZER" in config
    assert "-fsanitize=thread" in config
