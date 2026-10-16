import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
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
        (source / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.19)\nproject(gRPC C)\nadd_library(grpc SHARED probe.c)\nadd_library(grpc_unsecure SHARED probe.c)\ninstall(TARGETS grpc EXPORT gRPC LIBRARY DESTINATION lib)\ninstall(TARGETS grpc_unsecure EXPORT gRPC LIBRARY DESTINATION lib)\ninstall(EXPORT gRPC DESTINATION lib/cmake)\n')
        build, prefix = self.root / 'build', self.root / 'prefix'
        for command in (
            ['cmake', '-S', str(source), '-B', str(build),
             '-DCMAKE_PROJECT_gRPC_INCLUDE=' + str(ROOT / 'packaging/minimal-grpc.cmake'),
             '-DCMAKE_INSTALL_PREFIX=' + str(prefix)],
            ['cmake', '--build', str(build)],
            ['cmake', '--install', str(build)],
        ):
            subprocess.run(command, check=True, capture_output=True, text=True)
        self.assertTrue((prefix / 'lib/libgrpc.so').exists())
        self.assertFalse((build / 'libgrpc_unsecure.so').exists())
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


if __name__ == '__main__':
    unittest.main()
