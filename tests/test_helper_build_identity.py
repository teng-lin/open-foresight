"""A helper's advertised revision must survive container checkout ownership."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('cmake') and shutil.which('git'), 'Requires CMake and Git')
class HelperBuildIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='helper-identity-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = self.root / 'identity.cmake'
        self.script.write_text(
            f'include("{ROOT / "cmake/ForesightBuildIdentity.cmake"}")\n'
            'foresight_build_revision(revision "${SOURCE_ROOT}")\n'
            'file(WRITE "${OUTPUT_FILE}" "${revision}")\n')
        self.output = self.root / 'revision.txt'
        # Hosted runners may globally trust every checkout. The fixture must
        # exercise Git ownership checks independently of that machine policy.
        self.environment = {**os.environ, 'GIT_CONFIG_NOSYSTEM': '1',
                            'GIT_CONFIG_GLOBAL': os.devnull}

    def configure(self, source, revision=None, ownership=False):
        args = ['cmake', f'-DSOURCE_ROOT={source}', f'-DOUTPUT_FILE={self.output}']
        if revision is not None:
            args.append(f'-DFORESIGHT_BUILD_REVISION={revision}')
        env = self.environment.copy()
        if ownership:
            env['GIT_TEST_ASSUME_DIFFERENT_OWNER'] = 'true'
        return subprocess.run([*args, '-P', str(self.script)], env=env,
                              text=True, capture_output=True)

    def test_container_checkout_ownership_uses_scoped_trust_and_twelve_digits(self):
        source = self.root / 'repository'
        subprocess.run(['git', 'init', str(source)], env=self.environment, check=True, capture_output=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.test', 'commit', '--allow-empty',
                        '-m', 'Identity fixture'], env=self.environment, check=True, capture_output=True)
        expected = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], env=self.environment, text=True).strip()[:12]
        rejected = subprocess.run(['git', '-c', 'safe.directory=', '-C', str(source), 'rev-parse', 'HEAD'],
                                 env={**self.environment, 'GIT_TEST_ASSUME_DIFFERENT_OWNER': 'true'},
                                 text=True, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
        result = self.configure(source, ownership=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), expected)

    def test_exported_source_requires_valid_explicit_revision(self):
        source = self.root / 'exported'
        source.mkdir()
        missing = self.configure(source)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('FORESIGHT_BUILD_REVISION', missing.stderr)
        for revision in ('unknown', 'abc', 'a' * 41):
            invalid = self.configure(source, revision)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn('hexadecimal', invalid.stderr)
        valid = self.configure(source, 'ABCDEF0123456789' * 2)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(self.output.read_text(), 'abcdef012345')
