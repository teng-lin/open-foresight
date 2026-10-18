import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import zipfile

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import litert_extensions as extensions  # noqa: E402 - Imports follow the local tools path setup.


class ExtensionArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def fixture(
        self,
        *,
        platform="darwin",
        extra=None,
        embedded=None,
        native=b"new native",
        version="0.18.0",
        tag=None,
        missing_vendor=None,
    ):
        library = self.root / (
            "liblitert-lm.dylib" if platform == "darwin" else "liblitert-lm.so"
        )
        library.write_bytes(native)
        wheel = self.root / "api.whl"
        metadata = "litert_lm_api-0.18.0.dist-info/"
        tag = tag or (
            "py3-none-macosx_12_0_arm64"
            if platform == "darwin"
            else "py3-none-manylinux_2_27_x86_64"
        )
        vendors = (
            extensions.MACOS_VENDOR_LIBRARIES
            if platform == "darwin"
            else extensions.LINUX_VENDOR_LIBRARIES
        )
        vendor_payloads = {
            "litert_lm/" + name: self.elf(name.encode())
            if platform == "linux"
            else ("vendor-" + name).encode()
            for name in vendors
        }
        additional = []
        for name, payload in (
            extra if isinstance(extra, list) else [extra] if extra else []
        ):
            if name in vendor_payloads:
                vendor_payloads[name] = payload
            else:
                additional.append((name, payload))
        with zipfile.ZipFile(wheel, "w") as archive:
            archive.writestr(
                metadata + "METADATA", f"Name: litert-lm-api\nVersion: {version}\n"
            )
            archive.writestr(
                metadata + "WHEEL", "Wheel-Version: 1.0\nTag: " + tag + "\n"
            )
            archive.writestr(
                "litert_lm/" + library.name, native if embedded is None else embedded
            )
            archive.writestr("litert_lm/engine.py", "source-built API")
            for name, payload in vendor_payloads.items():
                if name != "litert_lm/" + str(missing_vendor):
                    archive.writestr(name, payload)
            for entry in additional:
                archive.writestr(*entry)
        log = self.root / "native-test.log"
        log.write_text(
            "[ RUN      ] "
            + extensions.NATIVE_TEST
            + "\n[       OK ] "
            + extensions.NATIVE_TEST
        )
        abi_report = self.root / "native-status-abi-report.json"
        abi_report.write_text(
            json.dumps(
                {
                    "status": "passed",
                    "exit_code": 0,
                    "stdout": "vendor_register_return_callback_ok\n",
                }
            )
        )
        export_log = self.root / "native-exported-symbols.txt"
        if platform == "darwin":
            export_log.write_text(
                "\n".join("_" + name for name in extensions.REQUIRED_C_EXPORTS) + "\n"
            )
        else:
            export_log.write_text(
                "0x1 (NEEDED) Shared library: [libc.so.6]\n"
                + "\nDefined dynamic exports:\n"
                + "\n".join(extensions.REQUIRED_C_EXPORTS)
                + "\n"
            )
        self.manifest = {
            "upstream_commit": extensions.UPSTREAM_COMMIT,
            "patch_sha256": extensions.file_sha256(extensions.PATCH),
            "distribution": "litert-lm-api",
            "version": "0.18.0",
            "wheel": wheel.name,
            "wheel_sha256": extensions.file_sha256(wheel),
            "library": library.name,
            "library_sha256": extensions.file_sha256(library),
            "native_test_log": log.name,
            "native_test_log_sha256": extensions.file_sha256(log),
            "vendor_libraries": {
                Path(name).name: hashlib.sha256(payload).hexdigest()
                for name, payload in vendor_payloads.items()
            },
            **(
                {
                    "macos_abi_patch_sha256": extensions.file_sha256(
                        extensions.MACOS_ABI_PATCH
                    )
                }
                if platform == "darwin"
                else {
                    "linux_abi_patch_sha256": extensions.file_sha256(
                        extensions.LINUX_ABI_PATCH
                    )
                }
            ),
            "native_status_abi_report": abi_report.name,
            "native_status_abi_report_sha256": extensions.file_sha256(abi_report),
            "native_export_log": export_log.name,
            "native_export_log_sha256": extensions.file_sha256(export_log),
        }
        self.path = self.root / "manifest.json"
        self.save()
        return self.path

    def test_macos_package_extracts_only_authenticated_arm64_native_libraries(self):
        header = b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01'
        extra = [('litert_lm/' + name, header + name.encode())
                 for name in extensions.MACOS_VENDOR_LIBRARIES]
        manifest = self.fixture(native=header + b'native', extra=extra)
        bundle = extensions.verify_extensions_manifest(manifest, platform_name='darwin')
        output = self.root / 'lib'
        output.mkdir()
        copied = extensions.copy_macos_extension_dependencies(bundle, output)
        self.assertEqual({path.name for path in copied}, {'liblitert-lm.dylib', *extensions.MACOS_VENDOR_LIBRARIES})
        self.assertFalse(list(output.rglob('*.py')))
        bundle.wheel.write_bytes(b'changed after verification')
        with self.assertRaisesRegex(ValueError, 'changed after verification'):
            extensions.copy_macos_extension_dependencies(bundle, output)

    def test_macos_package_rejects_non_arm64_vendor_payload(self):
        header = b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01'
        bundle = extensions.verify_extensions_manifest(self.fixture(native=header), platform_name='darwin')
        output = self.root / 'lib'
        output.mkdir()
        with self.assertRaisesRegex(ValueError, 'macOS arm64 Mach-O'):
            extensions.copy_macos_extension_dependencies(bundle, output)

    def save(self):
        self.path.write_text(json.dumps(self.manifest))

    def test_exact_artifacts_are_accepted_for_each_release_platform(self):
        for platform in ("darwin", "linux"):
            with self.subTest(platform=platform):
                bundle = extensions.verify_extensions_manifest(
                    self.fixture(platform=platform), platform_name=platform
                )
                self.assertEqual(bundle.library.parent, self.root)

    def test_source_patch_version_and_distribution_cannot_be_overridden(self):
        for name, value in (
            ("upstream_commit", "different"),
            ("patch_sha256", "different"),
            ("version", "0.19.0"),
            ("distribution", "arbitrary-package"),
        ):
            with self.subTest(name=name):
                self.fixture()
                self.manifest[name] = value
                self.save()
                with self.assertRaisesRegex(ValueError, "not pinned"):
                    extensions.verify_extensions_manifest(
                        self.path, platform_name="darwin"
                    )

    def test_platform_abi_patches_are_required_and_cannot_cross_platforms(self):
        for platform, key in (
            ("darwin", "macos_abi_patch_sha256"),
            ("linux", "linux_abi_patch_sha256"),
        ):
            for value in (None, "incorrect"):
                with self.subTest(platform=platform, value=value):
                    self.fixture(platform=platform)
                    self.manifest[key] = value
                    self.save()
                    with self.assertRaisesRegex(ValueError, "ABI patch is not pinned"):
                        extensions.verify_extensions_manifest(
                            self.path, platform_name=platform
                        )
        self.fixture(platform="linux")
        self.manifest["macos_abi_patch_sha256"] = extensions.file_sha256(
            extensions.MACOS_ABI_PATCH
        )
        self.save()
        with self.assertRaisesRegex(ValueError, "cannot describe a Linux build"):
            extensions.verify_extensions_manifest(self.path, platform_name="linux")
        self.fixture(platform="darwin")
        self.manifest["linux_abi_patch_sha256"] = extensions.file_sha256(
            extensions.LINUX_ABI_PATCH
        )
        self.save()
        with self.assertRaisesRegex(ValueError, "cannot describe a macOS build"):
            extensions.verify_extensions_manifest(self.path, platform_name="darwin")

    def test_status_callback_regression_and_export_reports_are_verified_on_all_platforms(
        self,
    ):
        for platform in ("darwin", "linux"):
            with self.subTest(platform=platform):
                for field in ("native_status_abi_report", "native_export_log"):
                    self.fixture(platform=platform)
                    del self.manifest[field]
                    self.save()
                    with self.assertRaisesRegex(ValueError, "filename"):
                        extensions.verify_extensions_manifest(
                            self.path, platform_name=platform
                        )
                for report in (
                    {"status": "failed", "exit_code": -11},
                    {"status": "passed", "exit_code": 0, "stdout": "wrong fixture"},
                ):
                    self.fixture(platform=platform)
                    path = self.root / self.manifest["native_status_abi_report"]
                    path.write_text(json.dumps(report))
                    self.manifest["native_status_abi_report_sha256"] = (
                        extensions.file_sha256(path)
                    )
                    self.save()
                    with self.assertRaisesRegex(
                        ValueError, "ABI regression did not pass"
                    ):
                        extensions.verify_extensions_manifest(
                            self.path, platform_name=platform
                        )
                self.fixture(platform=platform)
                path = self.root / self.manifest["native_status_abi_report"]
                path.write_text("tampered")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    extensions.verify_extensions_manifest(
                        self.path, platform_name=platform
                    )
                for bad_export in (
                    "missing_symbols\n",
                    "_litert_lm_engine_create\n_extra_private_symbol\n"
                    if platform == "darwin"
                    else "\nDefined dynamic exports:\n"
                    + "\n".join(extensions.REQUIRED_C_EXPORTS)
                    + "\n[libstdc++.so.6]\n",
                ):
                    self.fixture(platform=platform)
                    export_path = self.root / self.manifest["native_export_log"]
                    export_path.write_text(bad_export)
                    self.manifest["native_export_log_sha256"] = extensions.file_sha256(
                        export_path
                    )
                    self.save()
                    with self.assertRaisesRegex(ValueError, "report is invalid"):
                        extensions.verify_extensions_manifest(
                            self.path, platform_name=platform
                        )

    def test_linux_export_report_enforces_complete_public_symbol_set(self):
        """Release verification must reject leaks and substring-only API matches."""
        required = "\n".join(extensions.REQUIRED_C_EXPORTS) + "\n"
        valid = (
            required
            + "litert_lm_engine_delete\n_init\n_fini\n__bss_start\n_edata\n_end\n"
        )
        reports = (
            (valid, True),
            (required + "_ZNSt3__16vector\n", False),
            (required + "private_helper\n", False),
            (required + "_initialize\n", False),
            (
                required.replace(
                    "litert_lm_engine_create\n", "litert_lm_engine_create_private\n"
                ),
                False,
            ),
            (required + "litert_lm_engine_delete private_helper\n", False),
            ("", False),
        )
        for symbols, accepted in reports:
            with self.subTest(symbols=symbols):
                self.fixture(platform="linux")
                export_path = self.root / self.manifest["native_export_log"]
                # Required names in readelf output are not proof of defined exports.
                export_path.write_text(
                    required + "\nDefined dynamic exports:\n" + symbols
                )
                self.manifest["native_export_log_sha256"] = extensions.file_sha256(
                    export_path
                )
                self.save()
                if accepted:
                    extensions.verify_extensions_manifest(
                        self.path, platform_name="linux"
                    )
                else:
                    with self.assertRaisesRegex(ValueError, "report is invalid"):
                        extensions.verify_extensions_manifest(
                            self.path, platform_name="linux"
                        )

    def test_packaged_provenance_retains_vendor_and_platform_abi_hashes(self):
        for platform, patch_key in (
            ("darwin", "macos_abi_patch_sha256"),
            ("linux", "linux_abi_patch_sha256"),
        ):
            with self.subTest(platform=platform):
                bundle = extensions.verify_extensions_manifest(
                    self.fixture(platform=platform), platform_name=platform
                )
                destination = self.root / f"packaged-provenance-{platform}.json"
                extensions.write_extension_provenance(bundle, destination)
                value = json.loads(destination.read_text())
                for key in (
                    "vendor_libraries",
                    patch_key,
                    "native_status_abi_report_sha256",
                    "native_export_log_sha256",
                ):
                    self.assertEqual(value[key], self.manifest[key])

    def test_modified_wheel_library_and_test_log_are_rejected(self):
        for name in ("wheel", "library", "native_test_log"):
            with self.subTest(name=name):
                self.fixture()
                with (self.root / self.manifest[name]).open("ab") as stream:
                    stream.write(b"changed")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    extensions.verify_extensions_manifest(
                        self.path, platform_name="darwin"
                    )

    def test_manifest_paths_cannot_escape_or_follow_external_symlinks(self):
        self.fixture()
        self.manifest["wheel"] = "../outside.whl"
        self.save()
        with self.assertRaisesRegex(ValueError, "filename"):
            extensions.verify_extensions_manifest(self.path, platform_name="darwin")
        self.fixture()
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside) / "wheel.whl"
            shutil.copy2(self.root / self.manifest["wheel"], external)
            alias = self.root / "alias.whl"
            alias.symlink_to(external)
            self.manifest["wheel"] = alias.name
            self.save()
            with self.assertRaisesRegex(ValueError, "escapes"):
                extensions.verify_extensions_manifest(self.path, platform_name="darwin")

    def test_wheel_metadata_platform_and_embedded_native_hash_must_match(self):
        for arguments in (
            {"version": "0.17.0"},
            {"tag": "py3-none-any"},
            {"embedded": b"unrelated native"},
        ):
            with self.subTest(arguments=arguments):
                with self.assertRaises(ValueError):
                    extensions.verify_extensions_manifest(
                        self.fixture(**arguments), platform_name="darwin"
                    )
        with self.assertRaises(ValueError):
            extensions.verify_extensions_manifest(self.fixture(), platform_name="linux")

    def test_wheel_rejects_path_traversal_and_unrelated_packages(self):
        for name in (
            "../escape.py",
            "/escape.py",
            "another_package/code.py",
            "litert_lm/./engine.py",
        ):
            with self.subTest(name=name), self.assertRaises(ValueError):
                extensions.verify_extensions_manifest(
                    self.fixture(extra=(name, "payload")), platform_name="darwin"
                )

    def test_selected_native_regression_must_have_run_and_passed(self):
        self.fixture()
        log = self.root / self.manifest["native_test_log"]
        log.write_text("[  PASSED  ] 0 tests.")
        self.manifest["native_test_log_sha256"] = extensions.file_sha256(log)
        self.save()
        with self.assertRaisesRegex(ValueError, "regression"):
            extensions.verify_extensions_manifest(self.path, platform_name="darwin")

    def copied_prefix(self):
        source = self.root / "original-python"
        source_site = source / "lib/python3.13/site-packages"
        package = source_site / "litert_lm"
        package.mkdir(parents=True)
        (package / "engine.py").write_text("original API")
        (package / "liblitert-lm.dylib").write_bytes(b"original native")
        (package / "libLiteRtMetalAccelerator.dylib").write_bytes(b"preserve backend")
        destination = self.root / "copied-python"
        shutil.copytree(source, destination)
        target = destination / source_site.relative_to(source)
        return source, source_site, destination, target

    def test_overlay_changes_only_copy_and_installs_verified_backend_libraries(self):
        bundle = extensions.verify_extensions_manifest(
            self.fixture(), platform_name="darwin"
        )
        source, source_site, destination, target = self.copied_prefix()
        extensions.install_extension_wheel(
            bundle,
            site_packages=target,
            source_prefix=source,
            destination_prefix=destination,
        )
        self.assertEqual(
            (source_site / "litert_lm/engine.py").read_text(), "original API"
        )
        self.assertEqual(
            (source_site / "litert_lm/liblitert-lm.dylib").read_bytes(),
            b"original native",
        )
        self.assertEqual(
            (target / "litert_lm/engine.py").read_text(), "source-built API"
        )
        self.assertEqual(
            (target / "litert_lm/liblitert-lm.dylib").read_bytes(), b"new native"
        )
        self.assertEqual(
            (source_site / "litert_lm/libLiteRtMetalAccelerator.dylib").read_bytes(),
            b"preserve backend",
        )
        self.assertEqual(
            (target / "litert_lm/libLiteRtMetalAccelerator.dylib").read_bytes(),
            b"vendor-libLiteRtMetalAccelerator.dylib",
        )

    def test_overlay_rejects_source_prefix_and_external_symlink_destinations(self):
        bundle = extensions.verify_extensions_manifest(
            self.fixture(), platform_name="darwin"
        )
        source, source_site, destination, target = self.copied_prefix()
        with self.assertRaisesRegex(ValueError, "isolated"):
            extensions.install_extension_wheel(
                bundle,
                site_packages=source_site,
                source_prefix=source,
                destination_prefix=source,
            )
        engine = target / "litert_lm/engine.py"
        engine.unlink()
        engine.symlink_to(source_site / "litert_lm/engine.py")
        with self.assertRaisesRegex(ValueError, "escapes"):
            extensions.install_extension_wheel(
                bundle,
                site_packages=target,
                source_prefix=source,
                destination_prefix=destination,
            )
        self.assertEqual(
            (source_site / "litert_lm/engine.py").read_text(), "original API"
        )

    def test_wheel_cannot_change_after_verification(self):
        bundle = extensions.verify_extensions_manifest(
            self.fixture(), platform_name="darwin"
        )
        source, _, destination, target = self.copied_prefix()
        with bundle.wheel.open("ab") as stream:
            stream.write(b"modified")
        with self.assertRaisesRegex(ValueError, "changed after verification"):
            extensions.install_extension_wheel(
                bundle,
                site_packages=target,
                source_prefix=source,
                destination_prefix=destination,
            )

    def test_python_probe_requires_positive_native_capability(self):
        run = MagicMock(return_value='{"native_stop_token_sequences":true}')
        extensions.probe_python_extensions(Path("/copy/bin/python3"), run)
        self.assertEqual(
            run.call_args.args[:3], (Path("/copy/bin/python3"), "-I", "-c")
        )
        run.return_value = '{"native_stop_token_sequences":false}'
        with self.assertRaises(ValueError):
            extensions.probe_python_extensions(Path("/copy/bin/python3"), run)

    def test_native_probe_calls_the_actual_c_api_and_releases_config(self):
        library = MagicMock()
        library.litert_lm_session_config_create.return_value = 12
        library.litert_lm_session_config_add_stop_token_sequence.return_value = 0
        with patch.object(extensions.ctypes, "CDLL", return_value=library):
            extensions.probe_native_extensions(
                self.fixture().parent / self.manifest["library"]
            )
        library.litert_lm_session_config_delete.assert_called_once_with(12)

    @staticmethod
    def elf(payload=b""):
        return b"\x7fELF\x02\x01" + bytes(12) + b"\x3e\x00" + payload

    def test_linux_vendor_dependencies_are_copied_from_verified_wheel(self):
        native = self.elf(b"native")
        payloads = [
            ("litert_lm/" + name, self.elf(name.encode()))
            for name in extensions.LINUX_VENDOR_LIBRARIES
        ]
        bundle = extensions.verify_extensions_manifest(
            self.fixture(platform="linux", native=native, extra=payloads),
            platform_name="linux",
        )
        destination = self.root / "bundle-lib"
        destination.mkdir()
        shutil.copy2(bundle.library, destination / bundle.library.name)
        copied = extensions.copy_linux_extension_dependencies(bundle, destination)
        self.assertEqual(
            {path.name for path in copied},
            {"liblitert-lm.so", *extensions.LINUX_VENDOR_LIBRARIES},
        )
        for name, content in payloads:
            self.assertEqual((destination / Path(name).name).read_bytes(), content)

    def test_linux_wheel_requires_x86_64_elf_payloads(self):
        for native, extra in (
            (b"not ELF", None),
            (self.elf(b"valid"), ("litert_lm/libwebgpu_dawn.so", b"not ELF")),
        ):
            with self.subTest(native=native, extra=extra):
                bundle = extensions.verify_extensions_manifest(
                    self.fixture(platform="linux", native=native, extra=extra),
                    platform_name="linux",
                )
                destination = self.root / ("lib-" + str(len(native)))
                destination.mkdir()
                shutil.copy2(bundle.library, destination / bundle.library.name)
                with self.assertRaises(ValueError):
                    extensions.copy_linux_extension_dependencies(bundle, destination)

    def test_required_gpu_closure_is_present_and_materialized_for_each_platform(self):
        for platform, names in (
            ("darwin", extensions.MACOS_VENDOR_LIBRARIES),
            ("linux", extensions.LINUX_VENDOR_LIBRARIES),
        ):
            for name in names:
                with self.subTest(platform=platform, missing=name):
                    with self.assertRaisesRegex(ValueError, "required GPU dependency"):
                        extensions.verify_extensions_manifest(
                            self.fixture(platform=platform, missing_vendor=name),
                            platform_name=platform,
                        )
            name = names[-1]
            for payload in (
                b"",
                b"version https://git-lfs.github.com/spec/v1\noid sha256:fixture\n",
            ):
                with self.subTest(platform=platform, payload=payload):
                    with self.assertRaises(ValueError):
                        extensions.verify_extensions_manifest(
                            self.fixture(
                                platform=platform, extra=("litert_lm/" + name, payload)
                            ),
                            platform_name=platform,
                        )

    def test_vendor_provenance_cannot_omit_or_misidentify_dawn(self):
        for value in (None, {}, {"libwebgpu_dawn.dylib": "wrong"}):
            with self.subTest(value=value):
                self.fixture()
                self.manifest["vendor_libraries"] = value
                self.save()
                with self.assertRaisesRegex(ValueError, "complete GPU runtime closure"):
                    extensions.verify_extensions_manifest(
                        self.path, platform_name="darwin"
                    )
        self.fixture()
        self.manifest["vendor_libraries"]["libwebgpu_dawn.dylib"] = "incorrect hash"
        self.save()
        with self.assertRaisesRegex(ValueError, "GPU dependency checksum mismatch"):
            extensions.verify_extensions_manifest(self.path, platform_name="darwin")

    def test_linux_dependency_validation_rejects_missing_and_external_vendor_libraries(
        self,
    ):
        destination = self.root / "lib"
        destination.mkdir()
        provider = "libGemmaModelConstraintProvider.so"
        for output in (
            provider + " => not found\n",
            provider + " => /outside/" + provider + " (0x0)\n",
            "libarbitrary.so => /outside/libarbitrary.so (0x0)\n",
            "libstdc++.so.6 => /usr/lib/libstdc++.so.6 (0x0)\n",
            "libc++.so.1 => /usr/lib/libc++.so.1 (0x0)\n",
            "libc++abi.so.1 => /usr/lib/libc++abi.so.1 (0x0)\n",
            "libunwind.so.1 => /usr/lib/libunwind.so.1 (0x0)\n",
        ):
            with (
                self.subTest(output=output),
                patch.object(
                    extensions.subprocess, "check_output", return_value=output
                ),
            ):
                with self.assertRaises(ValueError):
                    extensions.validate_linux_extension_dependencies([], destination)
        with patch.object(
            extensions.subprocess,
            "check_output",
            return_value=(
                provider + " => " + str(destination / provider) + " (0x0)\n"
                "libc.so.6 => /usr/lib/libc.so.6 (0x0)\n"
            ),
        ) as check:
            environment = extensions.validate_linux_extension_dependencies(
                [], destination
            )
        self.assertEqual(environment["LD_LIBRARY_PATH"], str(destination))
        self.assertEqual(
            check.call_args.kwargs["env"]["LD_LIBRARY_PATH"], str(destination)
        )


class StatusAbiToolTest(unittest.TestCase):
    def test_find_linux_libcxx_resolves_static_libraries_and_headers(self):
        import test_litert_status_abi as status_abi

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "include/c++/v1").mkdir(parents=True)
            (root / "include/c++/v1/string").write_text("// header\n")
            (root / "lib").mkdir(parents=True)
            (root / "lib/libc++.a").write_bytes(b"!<arch>\n")
            (root / "lib/libc++abi.a").write_bytes(b"!<arch>\n")
            with patch.dict(
                status_abi.os.environ, {"FORESIGHT_LIBCXX_ROOT": str(root)}
            ):
                inc, lib = status_abi.find_linux_libcxx("nonexistent-clang++")
            self.assertEqual(inc, (root / "include/c++/v1").resolve())
            self.assertEqual(lib, (root / "lib").resolve())
            with (
                patch.dict(status_abi.os.environ, {}, clear=True),
                patch.object(status_abi.shutil, "which", return_value=None),
                patch.object(Path, "is_file", return_value=False),
            ):
                with self.assertRaisesRegex(RuntimeError, "libc\\+\\+-dev"):
                    status_abi.find_linux_libcxx("nonexistent-clang++")


if __name__ == "__main__":
    unittest.main()
