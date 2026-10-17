"""A changed patch must not be published as the source used by a build."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "litert_builder", ROOT / "tools/build_litert_extensions.py"
)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


@unittest.skipUnless(shutil.which("git"), "Git required")
class BuildSnapshotTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Snapshot test")
        self.git("config", "user.email", "snapshot@example.invalid")
        self.git("config", "core.abbrev", "8")
        self.file = self.source / "input.txt"
        self.file.write_text("original\n")
        self.abi_file = self.source / "z_abi.txt"
        self.abi_file.write_text("original ABI\n")
        self.git("add", "input.txt", "z_abi.txt")
        self.git("commit", "-qm", "Fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.first = self.make_patch("first patch\n")
        self.second = self.make_patch("second patch\n")
        self.patch_path = self.root / "source.patch"
        self.patch_path.write_bytes(self.first)
        self.macos_abi_patch = self.make_patch("macos vendor ABI\n", "z_abi.txt")
        self.macos_abi_patch_path = self.root / "macos.patch"
        self.macos_abi_patch_path.write_bytes(self.macos_abi_patch)
        self.linux_abi_patch = self.make_patch("linux vendor ABI\n", "z_abi.txt")
        self.linux_abi_patch_path = self.root / "linux.patch"
        self.linux_abi_patch_path.write_bytes(self.linux_abi_patch)

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.source, stderr=subprocess.PIPE, timeout=300
        )

    def diff(self):
        return self.git(
            "-c",
            "core.abbrev=8",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "HEAD",
            "--binary",
        )

    def make_patch(self, value, name="input.txt"):
        (self.source / name).write_text(value)
        result = self.diff()
        self.git("checkout", "--", name)
        return result

    def invoke(self, system="Linux"):
        with (
            patch.object(builder, "COMMIT", self.commit),
            patch.object(builder, "PATCH", self.patch_path),
            patch.object(builder, "MACOS_ABI_PATCH", self.macos_abi_patch_path),
            patch.object(builder, "LINUX_ABI_PATCH", self.linux_abi_patch_path),
            patch.object(builder.platform, "system", return_value=system),
            patch("sys.argv", ["builder", str(self.source), "--apply-only"]),
        ):
            builder.main()

    def test_applied_source_matches_the_captured_patch(self):
        self.invoke(system="FreeBSD")
        self.assertEqual(self.file.read_text(), "first patch\n")
        self.assertEqual(self.diff(), self.first)
        self.assertEqual(self.abi_file.read_text(), "original ABI\n")

    def test_macos_patch_applies_after_common_patch_and_is_idempotent(self):
        for system, expected_patch, expected_text in (
            ("Darwin", self.macos_abi_patch, "macos vendor ABI\n"),
            ("Linux", self.linux_abi_patch, "linux vendor ABI\n"),
        ):
            with self.subTest(system=system):
                self.git("checkout", "--", "input.txt", "z_abi.txt")
                self.invoke(system="FreeBSD")
                self.invoke(system=system)
                self.invoke(system=system)
                self.assertEqual(self.diff(), self.first + expected_patch)
                self.assertEqual(self.abi_file.read_text(), expected_text)

    def test_clean_macos_source_gets_both_pinned_patches(self):
        for system, expected_patch in (
            ("Darwin", self.macos_abi_patch),
            ("Linux", self.linux_abi_patch),
        ):
            with self.subTest(system=system):
                self.git("checkout", "--", "input.txt", "z_abi.txt")
                self.invoke(system=system)
                self.assertEqual(self.diff(), self.first + expected_patch)

    def test_source_attestation_ignores_git_display_defaults(self):
        # A shallow hosted checkout defaults to seven-character IDs; global
        # prefix/color settings also must not alter source verification.
        self.git("config", "core.abbrev", "7")
        self.git("config", "diff.noprefix", "true")
        self.git("config", "color.ui", "always")
        for system, expected_text in (
            ("Darwin", "macos vendor ABI\n"),
            ("Linux", "linux vendor ABI\n"),
        ):
            with self.subTest(system=system):
                self.git("checkout", "--", "input.txt", "z_abi.txt")
                self.invoke(system=system)
                self.invoke(system=system)
                self.assertEqual(self.file.read_text(), "first patch\n")
                self.assertEqual(self.abi_file.read_text(), expected_text)

    def test_patch_changed_between_read_and_apply_is_rejected(self):
        original_run = builder.run

        def mutate(source, *args, **kwargs):
            if args[:3] == ("git", "apply", "--check"):
                self.patch_path.write_bytes(self.second)
            return original_run(source, *args, **kwargs)

        with patch.object(builder, "run", side_effect=mutate):
            with self.assertRaisesRegex(RuntimeError, "changed from the verified"):
                self.invoke()
        self.assertEqual(self.file.read_text(), "second patch\n")

    def test_verify_linux_library_abi_rejects_dynamic_stdlib_and_glibcxx_needs(self):
        valid_exports = (
            "0001 T litert_lm_engine_create\n"
            "0002 T litert_lm_embedding_engine_create\n"
            "0003 T litert_lm_session_config_add_stop_token_sequence\n"
        )
        for dynamic, versions, exports in (
            (
                "0x1 (NEEDED) Shared library: [libstdc++.so.6]\n",
                "Version needs section\n",
                valid_exports,
            ),
            (
                "0x1 (NEEDED) Shared library: [libc++.so.1]\n",
                "Version needs section\n",
                valid_exports,
            ),
            (
                "0x1 (NEEDED) Shared library: [libunwind.so.1]\n",
                "Version needs section\n",
                valid_exports,
            ),
            (
                "0x1 (NEEDED) Shared library: [libc.so.6]\n",
                "Version needs section\n  Name: GLIBCXX_3.4.30\n",
                valid_exports,
            ),
            (
                "0x1 (NEEDED) Shared library: [libc.so.6]\n",
                "Version needs section\n  Name: CXXABI_1.3\n",
                valid_exports,
            ),
            (
                "0x1 (NEEDED) Shared library: [libc.so.6]\n",
                "Version needs section\n",
                "0001 T litert_lm_engine_create\n",
            ),
        ):
            with (
                self.subTest(dynamic=dynamic, versions=versions, exports=exports),
                patch.object(
                    builder.subprocess,
                    "check_output",
                    side_effect=[dynamic, versions, exports],
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "Linux LiteRT library"):
                    builder.verify_linux_library_abi(Path("/tmp/liblitert-lm.so"))
        with patch.object(
            builder.subprocess,
            "check_output",
            side_effect=[
                "0x1 (NEEDED) Shared library: [libc.so.6]\n",
                "Version needs section\n  Name: GLIBC_2.34\n",
                valid_exports,
            ],
        ):
            builder.verify_linux_library_abi(Path("/tmp/liblitert-lm.so"))

    def test_linux_abi_report_contains_all_normalized_exports(self):
        dynamic = "0x1 (NEEDED) Shared library: [libc.so.6]\n"
        versions = "Version needs section\n  Name: GLIBC_2.34\n"
        symbols = {
            "litert_lm_engine_create",
            "litert_lm_embedding_engine_create",
            "litert_lm_session_config_add_stop_token_sequence",
            "litert_lm_session_config_delete",
            "_init",
            "_fini",
            "__bss_start",
            "_edata",
            "_end",
        }
        for suffix in ("", "@LITERT_1.0", "@@LITERT_1.0"):
            exports = "\n".join("0001 T " + name + suffix for name in sorted(symbols))
            # Multiple versions of the same export must be recorded once.
            exports += "\n0002 T litert_lm_engine_create@LITERT_0.9\n\n"
            with (
                self.subTest(suffix=suffix),
                patch.object(
                    builder.subprocess,
                    "check_output",
                    side_effect=[dynamic, versions, exports],
                ),
            ):
                report = builder.verify_linux_library_abi(Path("/tmp/liblitert-lm.so"))
                self.assertEqual(
                    report,
                    dynamic
                    + "\n"
                    + versions
                    + "\nDefined dynamic exports:\n"
                    + "\n".join(sorted(symbols))
                    + "\n",
                )

    def test_linux_abi_rejects_exports_outside_public_api_and_loader_allowlist(self):
        required = (
            "0001 T litert_lm_engine_create\n"
            "0002 T litert_lm_embedding_engine_create\n"
            "0003 T litert_lm_session_config_add_stop_token_sequence\n"
        )
        for symbol in (
            "_ZN6google8protobuf7MessageD1Ev",
            "private_helper",
            "litert_lmPrivate",
            "_init_private",
        ):
            for suffix in ("", "@PRIVATE_1.0", "@@PRIVATE_1.0"):
                with (
                    self.subTest(symbol=symbol, suffix=suffix),
                    patch.object(
                        builder.subprocess,
                        "check_output",
                        side_effect=[
                            "",
                            "",
                            required + "0004 T " + symbol + suffix + "\n",
                        ],
                    ),
                ):
                    with self.assertRaisesRegex(RuntimeError, "public C API"):
                        builder.verify_linux_library_abi(Path("/tmp/liblitert-lm.so"))


@unittest.skipUnless(
    builder.platform.system() == "Linux"
    and all(shutil.which(tool) for tool in ("clang++", "ld.gold", "nm", "readelf")),
    "Linux Clang and GNU gold required",
)
class LinuxExportGateTest(unittest.TestCase):
    def test_localized_tls_is_not_an_export_but_public_tls_is_rejected(self):
        """Gold can retain local TLS entries in .dynsym after export isolation."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "fixture.cc"
            source.write_text(
                "thread_local int private_tls;\n"
                'extern "C" int litert_lm_engine_create() { return ++private_tls; }\n'
                'extern "C" void litert_lm_embedding_engine_create() {}\n'
                'extern "C" void litert_lm_session_config_add_stop_token_sequence() {}\n'
            )
            export_map = root / "exports.map"
            export_map.write_text("{ global: litert_lm_*; local: *; };\n")
            library = root / "fixture.so"
            command = [
                "clang++",
                "-shared",
                "-fPIC",
                "-fuse-ld=gold",
                "-nostdlib++",
                str(source),
                "-o",
                str(library),
            ]
            subprocess.run(
                [*command, "-Wl,--version-script=" + str(export_map)],
                check=True,
                timeout=300,
            )
            raw_symbols = subprocess.check_output(
                ["nm", "-D", "--defined-only", str(library)], text=True, timeout=300
            )
            self.assertIn(" b private_tls", raw_symbols)
            report = builder.verify_linux_library_abi(library)
            self.assertNotIn("private_tls", report)
            self.assertIn("litert_lm_engine_create", report)
            subprocess.run(command, check=True, timeout=300)
            with self.assertRaisesRegex(
                RuntimeError, "unexpected exports: private_tls"
            ):
                builder.verify_linux_library_abi(library)


if __name__ == "__main__":
    unittest.main()
