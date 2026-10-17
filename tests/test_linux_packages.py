import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_packages', ROOT / 'packaging/package_linux.py')
packages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packages)
spec = importlib.util.spec_from_file_location('abi', ROOT / 'packaging/check_abi.py')
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)


class LinuxPackagesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'bundle'
        # Header-only fixtures test staging contracts; real ELF linkage and GUI
        # startup are tested against the compiled artifacts in CI.
        header = bytearray(20)
        header[:4] = b'\x7fELF'
        header[18:20] = (62).to_bytes(2, 'little')
        for name in ('app/open-foresight', 'bin/ForesightHelper', 'lib/libforesight_native.so'):
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(header)
            path.chmod(0o755)
        (self.bundle / 'open-foresight').write_text('#!/bin/sh\nexit 0\n')
        (self.bundle / 'open-foresight').chmod(0o755)
        icon = self.bundle / 'app/data/flutter_assets/assets/images/foresight-logo.png'
        icon.parent.mkdir(parents=True)
        icon.write_bytes(b'fixture icon')
        config = self.bundle / 'share/open-foresight/google-client.json'
        config.parent.mkdir(parents=True)
        config.write_text('{"installed":{"client_id":"fixture"}}')
        config.chmod(0o600)
        (self.bundle / 'lib/libsqlite3.so').symlink_to('libforesight_native.so')
        self.manifest()

    def manifest(self):
        (self.bundle / 'manifest.json').write_text(json.dumps({
            'revision': 'a' * 40,
            'files': [{'path': str(p.relative_to(self.bundle)), 'sha256': packages.digest(p)}
                      for p in sorted(self.bundle.rglob('*')) if p.is_file() and p.name != 'manifest.json']}))

    def test_system_layout_permissions_and_symlinks(self):
        packages.validate(self.bundle)
        stage = self.root / 'stage'
        packages.stage(self.bundle, stage)
        self.assertEqual((stage / 'opt/open-foresight/share/open-foresight/google-client.json').stat().st_mode & 0o777, 0o644)
        self.assertEqual((stage / 'usr/bin/open-foresight').stat().st_mode & 0o777, 0o755)
        self.assertTrue((stage / 'opt/open-foresight/lib/libsqlite3.so').is_symlink())
        self.assertEqual((stage / 'usr/bin/open-foresight').read_text(), '#!/bin/sh\nexec /opt/open-foresight/open-foresight "$@"\n')
        self.assertTrue((stage / 'usr/share/applications/io.openforesight.App.desktop').exists())
        self.assertFalse((stage / 'home').exists())

    def test_corrupt_extra_account_and_escaping_files_are_rejected(self):
        target = self.bundle / 'app/open-foresight'
        target.write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            packages.validate(self.bundle)
        self.setUpFixtureHeader(target)
        extra = self.bundle / 'extra'
        extra.write_text('unexpected')
        with self.assertRaisesRegex(ValueError, 'absent from its manifest'):
            packages.validate(self.bundle)
        extra.unlink()
        token = self.bundle / 'tokens.json'
        token.write_text('fixture')
        self.manifest()
        with self.assertRaisesRegex(ValueError, 'Account/profile'):
            packages.validate(self.bundle)
        token.unlink()
        (self.bundle / 'escape').symlink_to('/etc/passwd')
        self.manifest()
        with self.assertRaisesRegex(ValueError, 'escapes its root'):
            packages.validate(self.bundle)

    @staticmethod
    def setUpFixtureHeader(target):
        header = bytearray(20)
        header[:4] = b'\x7fELF'
        header[18:20] = (62).to_bytes(2, 'little')
        target.write_bytes(header)

    def test_archive_is_reproducible_and_preserves_executable_mode(self):
        first, second = self.root / 'first.tar.gz', self.root / 'second.tar.gz'
        packages.archive(self.bundle, first, 'open-foresight', 1234)
        os.utime(self.bundle / 'open-foresight', (9999, 9999))
        packages.archive(self.bundle, second, 'open-foresight', 1234)
        self.assertEqual(packages.digest(first), packages.digest(second))
        with tarfile.open(first) as tar:
            entry = tar.getmember('open-foresight/open-foresight')
            self.assertEqual((entry.mode, entry.uid, entry.mtime), (0o755, 0, 1234))

    @unittest.skipUnless(shutil.which('cmake') and shutil.which('cc'), 'CMake and C compiler required')
    def test_minimal_sdk_installs_consumable_export_without_duplicate_library(self):
        source = self.root / 'sdk'
        source.mkdir()
        (source / 'probe.c').write_text('int probe(void) { return 1; }\n')
        (source / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.19)\nproject(grpc C)\nadd_library(grpc SHARED probe.c)\nadd_library(grpc_unsecure SHARED probe.c)\ninstall(TARGETS grpc EXPORT gRPC LIBRARY DESTINATION lib)\ninstall(TARGETS grpc_unsecure EXPORT gRPC LIBRARY DESTINATION lib)\ninstall(EXPORT gRPC DESTINATION lib/cmake)\n')
        build, prefix = self.root / 'build', self.root / 'prefix'
        for command in (
            ['cmake', '-S', str(source), '-B', str(build),
             '-DCMAKE_PROJECT_grpc_INCLUDE=' + str(ROOT / 'packaging/minimal-grpc.cmake'),
             '-DCMAKE_INSTALL_PREFIX=' + str(prefix)],
            ['cmake', '--build', str(build)],
            ['cmake', '--install', str(build)],
        ):
            subprocess.run(command, check=True, capture_output=True, text=True)
        suffix = '.dylib' if sys.platform == 'darwin' else '.so'
        self.assertTrue((prefix / f'lib/libgrpc{suffix}').exists())
        self.assertFalse((build / f'libgrpc_unsecure{suffix}').exists())
        self.assertNotIn('grpc_unsecure', (prefix / 'lib/cmake/gRPC.cmake').read_text())
        consumer = self.root / 'consumer'
        consumer.mkdir()
        (consumer / 'main.c').write_text('int probe(void); int main(void) { return probe() != 1; }\n')
        (consumer / 'CMakeLists.txt').write_text(
            'cmake_minimum_required(VERSION 3.19)\nproject(consumer C)\n'
            f'include("{prefix}/lib/cmake/gRPC.cmake")\n'
            'add_executable(consumer main.c)\ntarget_link_libraries(consumer PRIVATE grpc)\n')
        subprocess.run(['cmake', '-S', str(consumer), '-B', str(consumer / 'build')], check=True, capture_output=True)
        subprocess.run(['cmake', '--build', str(consumer / 'build')], check=True, capture_output=True)
        subprocess.run([str(consumer / 'build/consumer')], check=True,
                       env={**os.environ, 'LD_LIBRARY_PATH': str(prefix / 'lib')})

    @unittest.skipUnless(shutil.which('cc') and shutil.which('readelf'), 'C compiler and readelf required')
    def test_abi_gate_rejects_newer_system_binaries(self):
        source = self.root / 'probe.c'
        source.write_text('#include <stdio.h>\nint main(void) { puts("probe"); return 0; }\n')
        binary = self.root / 'elf'
        binary.mkdir()
        subprocess.run(['cc', str(source), '-o', str(binary / 'probe')], check=True)
        self.assertTrue(abi.inspect(binary, '99.0', '99.0')['passed'])
        self.assertFalse(abi.inspect(binary, '2.0', '3.0')['passed'])


@unittest.skipUnless(sys.platform == 'linux' and shutil.which('cc') and shutil.which('ldd'),
                     'Linux ELF loader and C compiler required')
class LinuxDependencyCollectionTest(unittest.TestCase):
    def test_extension_validation_preserves_sdk_lookup_and_bundle_relocates(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        sys.path.insert(0, str(ROOT / 'tools'))
        import package
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build, sdk, flutter = root / 'build', root / 'sdk', root / 'flutter'
            sdk.mkdir()
            flutter.mkdir()
            (flutter / 'open-foresight').write_text('fixture desktop')

            def compile(source, destination, *arguments):
                destination.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(['cc', '-x', 'c', '-', '-o', str(destination), *map(str, arguments)],
                               input=source, text=True, check=True, capture_output=True)

            # RUNPATH finds a direct dependency but does not apply to its child.
            # The SDK LD_LIBRARY_PATH is required to discover that transitive lib.
            compile('int upb(void) { return 42; }', sdk / 'libupb_fixture.so',
                    '-shared', '-fPIC', '-Wl,-soname,libupb_fixture.so')
            compile('int upb(void); int grpc(void) { return upb(); }', sdk / 'libgrpc_fixture.so',
                    '-shared', '-fPIC', '-Wl,-soname,libgrpc_fixture.so', '-L' + str(sdk), '-lupb_fixture')
            helper = build / 'services/helper/ForesightHelper'
            compile('int grpc(void); int main(void) { return grpc() != 42; }', helper,
                    '-L' + str(sdk), '-lgrpc_fixture', '-Wl,--enable-new-dtags,-rpath,' + str(sdk),
                    '-Wl,-rpath-link,' + str(sdk))
            worker = build / 'services/inference/foresight-model'
            compile('int main(void) { return 0; }', worker)
            for name in ('application/foresight-service', 'application/foresight-mcp'):
                target = build / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(worker, target)
            library = build / 'lib/liblitert-lm.so'
            compile('#include <stdio.h>\nvoid fixture(void) { puts("fixture"); }', library,
                    '-shared', '-fPIC')
            for name in ('native/libforesight_native.so', 'lib/libonnxruntime.so'):
                target = build / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(library, target)
            for name in ('sentencepiece', 'flatbuffers'):
                target = build / f'_deps/{name}-src/LICENSE'
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('fixture license')
            for name in ('protobuf-lite', 'esaxx', 'darts_clone', 'absl'):
                target = build / f'_deps/sentencepiece-src/third_party/{name}/LICENSE'
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('fixture license')
            digest = hashlib.sha256(library.read_bytes()).hexdigest()
            extensions = SimpleNamespace(manifest={'library_sha256': digest})
            output = root / 'bundle'
            arguments = ['package.py', '--build', str(build), '--flutter-bundle', str(flutter),
                         '--output', str(output), '--litert-library', str(library),
                         '--onnx-library', str(build / 'lib/libonnxruntime.so'),
                         '--litert-extensions-manifest', str(root / 'fixture-manifest.json'),
                         '--revision', 'a' * 40]
            # Only artifact authentication/C-API probing is stubbed. Library
            # resolution, dependency copying and relocated execution are real.
            with patch.object(sys, 'argv', arguments), \
                    patch.dict(os.environ, {'LD_LIBRARY_PATH': str(sdk)}), \
                    patch.object(package, 'verify_extensions_manifest', return_value=extensions), \
                    patch.object(package, 'copy_linux_extension_dependencies',
                                 return_value=[output / 'lib/liblitert-lm.so']), \
                    patch.object(package, 'probe_native_extensions'), \
                    patch.object(package, 'ONNX_LIBRARY_SHA256', digest):
                package.main()
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertTrue({'libgrpc_fixture.so', 'libupb_fixture.so'} <= set(manifest['bundled_libraries']))
            shutil.rmtree(sdk)
            subprocess.run([str(output / 'bin/ForesightHelper')], check=True,
                           env={**os.environ, 'LD_LIBRARY_PATH': str(output / 'lib')})


class NativePythonPayloadTest(unittest.TestCase):
    def test_declared_worker_sources_are_allowed_but_runtime_and_extra_code_are_rejected(self):
        spec = importlib.util.spec_from_file_location('smoke_installed', ROOT / 'packaging/smoke_installed.py')
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sys.path.insert(0, str(ROOT / 'tools'))
            from query_worker_packaging import copy_worker
            copy_worker(root / 'share/open-foresight/adapters')
            smoke.validate_native_python_payload(root)
            for name in ('share/open-foresight/adapters/unexpected.py',
                         'elsewhere/legacy_query_worker.py', 'bin/python3',
                         'lib/libpython3.13.so', 'share/worker.pyc', 'share/worker.pyo'):
                with self.subTest(name=name):
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'unexpected payload')
                    with self.assertRaisesRegex(ValueError, name):
                        smoke.validate_native_python_payload(root)
                    path.unlink()


if __name__ == '__main__':
    unittest.main()
