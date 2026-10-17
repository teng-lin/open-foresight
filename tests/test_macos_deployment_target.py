"""Fresh CMake configurations must honor the supported OS and caller overrides."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('cmake'), 'macOS CMake required')
class MacOSDeploymentTargetTest(unittest.TestCase):
    def configure(self, expected, arguments=(), environment=None, toolchain=None):
        with tempfile.TemporaryDirectory(prefix='of-deployment-') as temporary:
            build = Path(temporary) / 'build'
            env = dict(os.environ)
            env.pop('MACOSX_DEPLOYMENT_TARGET', None)
            env.update(environment or {})
            arguments = list(arguments)
            if toolchain:
                path = Path(temporary) / 'toolchain.cmake'
                path.write_text(toolchain)
                arguments.append('-DCMAKE_TOOLCHAIN_FILE=' + str(path))
            subprocess.run(['cmake', '-S', str(ROOT / 'native'), '-B', str(build),
                            '-DBUILD_TESTING=OFF', *arguments], env=env,
                           capture_output=True, text=True, check=True, timeout=60)
            cache = (build / 'CMakeCache.txt').read_text()
            target = next(line.split('=', 1)[1] for line in cache.splitlines()
                          if line.startswith('CMAKE_OSX_DEPLOYMENT_TARGET:'))
            self.assertEqual(target, expected)

    def test_newer_host_sdk_does_not_raise_default_minimum(self):
        self.configure('15.0')

    def test_explicit_cache_target_is_preserved(self):
        self.configure('16.0', ['-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0'])

    def test_explicit_environment_target_is_preserved(self):
        self.configure('16.0', environment={'MACOSX_DEPLOYMENT_TARGET': '16.0'})

    def test_explicit_toolchain_target_is_preserved(self):
        self.configure('16.0', toolchain='set(CMAKE_OSX_DEPLOYMENT_TARGET 16.0 CACHE STRING "Toolchain target")\n')

    def test_toolchain_without_deployment_target_keeps_supported_default(self):
        self.configure('15.0', toolchain='set(CMAKE_POSITION_INDEPENDENT_CODE ON)\n')

    def test_empty_environment_keeps_supported_default(self):
        self.configure('15.0', environment={'MACOSX_DEPLOYMENT_TARGET': ''})


if __name__ == '__main__':
    unittest.main()
