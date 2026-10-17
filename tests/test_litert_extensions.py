import importlib.util
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import zipfile

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import litert_extensions as extensions


class ExtensionArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def fixture(self, *, platform='darwin', extra=None, embedded=None, native=b'new native',
                version='0.18.0', tag=None, missing_vendor=None):
        library = self.root / ('liblitert-lm.dylib' if platform == 'darwin' else 'liblitert-lm.so')
        library.write_bytes(native)
        wheel = self.root / 'api.whl'
        metadata = 'litert_lm_api-0.18.0.dist-info/'
        tag = tag or ('py3-none-macosx_12_0_arm64' if platform == 'darwin' else
                      'py3-none-manylinux_2_27_x86_64')
        vendors = (extensions.MACOS_VENDOR_LIBRARIES if platform == 'darwin'
                   else extensions.LINUX_VENDOR_LIBRARIES)
        vendor_payloads = {'litert_lm/' + name: self.elf(name.encode())
                           if platform == 'linux' else ('vendor-' + name).encode()
                           for name in vendors}
        additional = []
        for name, payload in (extra if isinstance(extra, list) else [extra] if extra else []):
            if name in vendor_payloads:
                vendor_payloads[name] = payload
            else:
                additional.append((name, payload))
        with zipfile.ZipFile(wheel, 'w') as archive:
            archive.writestr(metadata + 'METADATA', f'Name: litert-lm-api\nVersion: {version}\n')
            archive.writestr(metadata + 'WHEEL', 'Wheel-Version: 1.0\nTag: ' + tag + '\n')
            archive.writestr('litert_lm/' + library.name, native if embedded is None else embedded)
            archive.writestr('litert_lm/engine.py', 'source-built API')
            for name, payload in vendor_payloads.items():
                if name != 'litert_lm/' + str(missing_vendor):
                    archive.writestr(name, payload)
            for entry in additional:
                archive.writestr(*entry)
        log = self.root / 'native-test.log'
        log.write_text('[ RUN      ] ' + extensions.NATIVE_TEST + '\n[       OK ] ' + extensions.NATIVE_TEST)
        abi_report = self.root / 'native-status-abi-report.json'
        abi_report.write_text(json.dumps({'status': 'passed', 'exit_code': 0,
                                         'stdout': 'vendor_register_return_callback_ok\n'}))
        self.manifest = {
            'upstream_commit': extensions.UPSTREAM_COMMIT,
            'patch_sha256': extensions.file_sha256(extensions.PATCH),
            'distribution': 'litert-lm-api', 'version': '0.18.0',
            'wheel': wheel.name, 'wheel_sha256': extensions.file_sha256(wheel),
            'library': library.name, 'library_sha256': extensions.file_sha256(library),
            'native_test_log': log.name, 'native_test_log_sha256': extensions.file_sha256(log),
            'vendor_libraries': {Path(name).name: hashlib.sha256(payload).hexdigest()
                                 for name, payload in vendor_payloads.items()},
            **({'macos_abi_patch_sha256': extensions.file_sha256(extensions.MACOS_ABI_PATCH)}
               if platform == 'darwin' else {}),
            **({'native_status_abi_report': abi_report.name,
                'native_status_abi_report_sha256': extensions.file_sha256(abi_report)}
               if platform == 'darwin' else {}),
        }
        self.path = self.root / 'manifest.json'
        self.save()
        return self.path

    def save(self):
        self.path.write_text(json.dumps(self.manifest))

    def test_exact_artifacts_are_accepted_for_each_release_platform(self):
        for platform in ('darwin', 'linux'):
            with self.subTest(platform=platform):
                bundle = extensions.verify_extensions_manifest(self.fixture(platform=platform),
                                                                platform_name=platform)
                self.assertEqual(bundle.library.parent, self.root)

    def test_source_patch_version_and_distribution_cannot_be_overridden(self):
        for name, value in (('upstream_commit', 'different'), ('patch_sha256', 'different'),
                            ('version', '0.19.0'), ('distribution', 'arbitrary-package')):
            with self.subTest(name=name):
                self.fixture()
                self.manifest[name] = value
                self.save()
                with self.assertRaisesRegex(ValueError, 'not pinned'):
                    extensions.verify_extensions_manifest(self.path, platform_name='darwin')

    def test_macos_abi_patch_is_required_only_on_macos(self):
        for value in (None, 'incorrect'):
            with self.subTest(value=value):
                self.fixture()
                self.manifest['macos_abi_patch_sha256'] = value
                self.save()
                with self.assertRaisesRegex(ValueError, 'ABI patch is not pinned'):
                    extensions.verify_extensions_manifest(self.path, platform_name='darwin')
        self.fixture(platform='linux')
        self.manifest['macos_abi_patch_sha256'] = extensions.file_sha256(extensions.MACOS_ABI_PATCH)
        self.save()
        with self.assertRaisesRegex(ValueError, 'cannot describe a Linux build'):
            extensions.verify_extensions_manifest(self.path, platform_name='linux')

    def test_macos_status_callback_regression_report_is_verified(self):
        self.fixture()
        del self.manifest['native_status_abi_report']
        self.save()
        with self.assertRaisesRegex(ValueError, 'filename'):
            extensions.verify_extensions_manifest(self.path, platform_name='darwin')
        for report in ({'status': 'failed', 'exit_code': -10},
                       {'status': 'passed', 'exit_code': 0, 'stdout': 'wrong fixture'}):
            with self.subTest(report=report):
                self.fixture()
                path = self.root / self.manifest['native_status_abi_report']
                path.write_text(json.dumps(report))
                self.manifest['native_status_abi_report_sha256'] = extensions.file_sha256(path)
                self.save()
                with self.assertRaisesRegex(ValueError, 'ABI regression did not pass'):
                    extensions.verify_extensions_manifest(self.path, platform_name='darwin')
        self.fixture()
        path = self.root / self.manifest['native_status_abi_report']
        path.write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            extensions.verify_extensions_manifest(self.path, platform_name='darwin')

    def test_packaged_provenance_retains_vendor_and_platform_abi_hashes(self):
        bundle = extensions.verify_extensions_manifest(self.fixture(), platform_name='darwin')
        destination = self.root / 'packaged-provenance.json'
        extensions.write_extension_provenance(bundle, destination)
        value = json.loads(destination.read_text())
        for key in ('vendor_libraries', 'macos_abi_patch_sha256', 'native_status_abi_report_sha256'):
            self.assertEqual(value[key], self.manifest[key])

    def test_modified_wheel_library_and_test_log_are_rejected(self):
        for name in ('wheel', 'library', 'native_test_log'):
            with self.subTest(name=name):
                self.fixture()
                with (self.root / self.manifest[name]).open('ab') as stream:
                    stream.write(b'changed')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    extensions.verify_extensions_manifest(self.path, platform_name='darwin')

    def test_manifest_paths_cannot_escape_or_follow_external_symlinks(self):
        self.fixture()
        self.manifest['wheel'] = '../outside.whl'
        self.save()
        with self.assertRaisesRegex(ValueError, 'filename'):
            extensions.verify_extensions_manifest(self.path, platform_name='darwin')
        self.fixture()
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside) / 'wheel.whl'
            shutil.copy2(self.root / self.manifest['wheel'], external)
            alias = self.root / 'alias.whl'
            alias.symlink_to(external)
            self.manifest['wheel'] = alias.name
            self.save()
            with self.assertRaisesRegex(ValueError, 'escapes'):
                extensions.verify_extensions_manifest(self.path, platform_name='darwin')

    def test_wheel_metadata_platform_and_embedded_native_hash_must_match(self):
        for arguments in ({'version': '0.17.0'}, {'tag': 'py3-none-any'},
                          {'embedded': b'unrelated native'}):
            with self.subTest(arguments=arguments):
                with self.assertRaises(ValueError):
                    extensions.verify_extensions_manifest(self.fixture(**arguments), platform_name='darwin')
        with self.assertRaises(ValueError):
            extensions.verify_extensions_manifest(self.fixture(), platform_name='linux')

    def test_wheel_rejects_path_traversal_and_unrelated_packages(self):
        for name in ('../escape.py', '/escape.py', 'another_package/code.py', 'litert_lm/./engine.py'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                extensions.verify_extensions_manifest(self.fixture(extra=(name, 'payload')),
                                                       platform_name='darwin')

    def test_selected_native_regression_must_have_run_and_passed(self):
        self.fixture()
        log = self.root / self.manifest['native_test_log']
        log.write_text('[  PASSED  ] 0 tests.')
        self.manifest['native_test_log_sha256'] = extensions.file_sha256(log)
        self.save()
        with self.assertRaisesRegex(ValueError, 'regression'):
            extensions.verify_extensions_manifest(self.path, platform_name='darwin')

    def copied_prefix(self):
        source = self.root / 'original-python'
        source_site = source / 'lib/python3.13/site-packages'
        package = source_site / 'litert_lm'
        package.mkdir(parents=True)
        (package / 'engine.py').write_text('original API')
        (package / 'liblitert-lm.dylib').write_bytes(b'original native')
        (package / 'libLiteRtMetalAccelerator.dylib').write_bytes(b'preserve backend')
        destination = self.root / 'copied-python'
        shutil.copytree(source, destination)
        target = destination / source_site.relative_to(source)
        return source, source_site, destination, target

    def test_overlay_changes_only_copy_and_installs_verified_backend_libraries(self):
        bundle = extensions.verify_extensions_manifest(self.fixture(), platform_name='darwin')
        source, source_site, destination, target = self.copied_prefix()
        extensions.install_extension_wheel(bundle, site_packages=target,
                                           source_prefix=source, destination_prefix=destination)
        self.assertEqual((source_site / 'litert_lm/engine.py').read_text(), 'original API')
        self.assertEqual((source_site / 'litert_lm/liblitert-lm.dylib').read_bytes(), b'original native')
        self.assertEqual((target / 'litert_lm/engine.py').read_text(), 'source-built API')
        self.assertEqual((target / 'litert_lm/liblitert-lm.dylib').read_bytes(), b'new native')
        self.assertEqual((source_site / 'litert_lm/libLiteRtMetalAccelerator.dylib').read_bytes(), b'preserve backend')
        self.assertEqual((target / 'litert_lm/libLiteRtMetalAccelerator.dylib').read_bytes(),
                         b'vendor-libLiteRtMetalAccelerator.dylib')

    def test_overlay_rejects_source_prefix_and_external_symlink_destinations(self):
        bundle = extensions.verify_extensions_manifest(self.fixture(), platform_name='darwin')
        source, source_site, destination, target = self.copied_prefix()
        with self.assertRaisesRegex(ValueError, 'isolated'):
            extensions.install_extension_wheel(bundle, site_packages=source_site,
                                               source_prefix=source, destination_prefix=source)
        engine = target / 'litert_lm/engine.py'
        engine.unlink()
        engine.symlink_to(source_site / 'litert_lm/engine.py')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            extensions.install_extension_wheel(bundle, site_packages=target,
                                               source_prefix=source, destination_prefix=destination)
        self.assertEqual((source_site / 'litert_lm/engine.py').read_text(), 'original API')

    def test_wheel_cannot_change_after_verification(self):
        bundle = extensions.verify_extensions_manifest(self.fixture(), platform_name='darwin')
        source, _, destination, target = self.copied_prefix()
        with bundle.wheel.open('ab') as stream:
            stream.write(b'modified')
        with self.assertRaisesRegex(ValueError, 'changed after verification'):
            extensions.install_extension_wheel(bundle, site_packages=target,
                                               source_prefix=source, destination_prefix=destination)

    def test_python_probe_requires_positive_native_capability(self):
        run = MagicMock(return_value='{"native_stop_token_sequences":true}')
        extensions.probe_python_extensions(Path('/copy/bin/python3'), run)
        self.assertEqual(run.call_args.args[:3], (Path('/copy/bin/python3'), '-I', '-c'))
        run.return_value = '{"native_stop_token_sequences":false}'
        with self.assertRaises(ValueError):
            extensions.probe_python_extensions(Path('/copy/bin/python3'), run)

    def test_native_probe_calls_the_actual_c_api_and_releases_config(self):
        library = MagicMock()
        library.litert_lm_session_config_create.return_value = 12
        library.litert_lm_session_config_add_stop_token_sequence.return_value = 0
        with patch.object(extensions.ctypes, 'CDLL', return_value=library):
            extensions.probe_native_extensions(self.fixture().parent / self.manifest['library'])
        library.litert_lm_session_config_delete.assert_called_once_with(12)

    @staticmethod
    def elf(payload=b''):
        return b'\x7fELF\x02\x01' + bytes(12) + b'\x3e\x00' + payload

    def test_linux_vendor_dependencies_are_copied_from_verified_wheel(self):
        native = self.elf(b'native')
        payloads = [('litert_lm/' + name, self.elf(name.encode()))
                    for name in extensions.LINUX_VENDOR_LIBRARIES]
        bundle = extensions.verify_extensions_manifest(
            self.fixture(platform='linux', native=native, extra=payloads), platform_name='linux')
        destination = self.root / 'bundle-lib'
        destination.mkdir()
        shutil.copy2(bundle.library, destination / bundle.library.name)
        copied = extensions.copy_linux_extension_dependencies(bundle, destination)
        self.assertEqual({path.name for path in copied},
                         {'liblitert-lm.so', *extensions.LINUX_VENDOR_LIBRARIES})
        for name, content in payloads:
            self.assertEqual((destination / Path(name).name).read_bytes(), content)

    def test_linux_wheel_requires_x86_64_elf_payloads(self):
        for native, extra in ((b'not ELF', None), (self.elf(b'valid'),
                ('litert_lm/libwebgpu_dawn.so', b'not ELF'))):
            with self.subTest(native=native, extra=extra):
                bundle = extensions.verify_extensions_manifest(
                    self.fixture(platform='linux', native=native, extra=extra), platform_name='linux')
                destination = self.root / ('lib-' + str(len(native)))
                destination.mkdir()
                shutil.copy2(bundle.library, destination / bundle.library.name)
                with self.assertRaises(ValueError):
                    extensions.copy_linux_extension_dependencies(bundle, destination)

    def test_required_gpu_closure_is_present_and_materialized_for_each_platform(self):
        for platform, names in (('darwin', extensions.MACOS_VENDOR_LIBRARIES),
                                ('linux', extensions.LINUX_VENDOR_LIBRARIES)):
            for name in names:
                with self.subTest(platform=platform, missing=name):
                    with self.assertRaisesRegex(ValueError, 'required GPU dependency'):
                        extensions.verify_extensions_manifest(
                            self.fixture(platform=platform, missing_vendor=name), platform_name=platform)
            name = names[-1]
            for payload in (b'', b'version https://git-lfs.github.com/spec/v1\noid sha256:fixture\n'):
                with self.subTest(platform=platform, payload=payload):
                    with self.assertRaises(ValueError):
                        extensions.verify_extensions_manifest(self.fixture(platform=platform,
                            extra=('litert_lm/' + name, payload)), platform_name=platform)

    def test_vendor_provenance_cannot_omit_or_misidentify_dawn(self):
        for value in (None, {}, {'libwebgpu_dawn.dylib': 'wrong'}):
            with self.subTest(value=value):
                self.fixture()
                self.manifest['vendor_libraries'] = value
                self.save()
                with self.assertRaisesRegex(ValueError, 'complete GPU runtime closure'):
                    extensions.verify_extensions_manifest(self.path, platform_name='darwin')
        self.fixture()
        self.manifest['vendor_libraries']['libwebgpu_dawn.dylib'] = 'incorrect hash'
        self.save()
        with self.assertRaisesRegex(ValueError, 'GPU dependency checksum mismatch'):
            extensions.verify_extensions_manifest(self.path, platform_name='darwin')

    def test_linux_dependency_validation_rejects_missing_and_external_vendor_libraries(self):
        destination = self.root / 'lib'
        destination.mkdir()
        provider = 'libGemmaModelConstraintProvider.so'
        for output in (provider + ' => not found\n',
                       provider + ' => /outside/' + provider + ' (0x0)\n',
                       'libarbitrary.so => /outside/libarbitrary.so (0x0)\n'):
            with self.subTest(output=output), patch.object(
                    extensions.subprocess, 'check_output', return_value=output):
                with self.assertRaises(ValueError):
                    extensions.validate_linux_extension_dependencies([], destination)
        with patch.object(extensions.subprocess, 'check_output', return_value=(
                provider + ' => ' + str(destination / provider) + ' (0x0)\n'
                'libc.so.6 => /usr/lib/libc.so.6 (0x0)\n')) as check:
            environment = extensions.validate_linux_extension_dependencies([], destination)
        self.assertEqual(environment['LD_LIBRARY_PATH'], str(destination))
        self.assertEqual(check.call_args.kwargs['env']['LD_LIBRARY_PATH'], str(destination))


if __name__ == '__main__':
    unittest.main()
