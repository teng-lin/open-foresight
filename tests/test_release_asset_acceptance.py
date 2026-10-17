"""Published-byte identity and clean installed-runtime boundaries."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from release_asset_acceptance import select_asset, verify_checksum, main as download_main
from installed_runtime import clean_environment, layout, service_command
from test_release_dmg import run as run_dmg
from argparse import Namespace


class ReleaseAssetAcceptanceTest(unittest.TestCase):
    def test_all_package_formats_require_a_unique_asset_and_its_checksum(self):
        """An incomplete or ambiguous release must never choose arbitrary bytes."""
        for kind, suffix in [('deb', '.deb'), ('rpm', '.rpm'), ('arch', '.pkg.tar.zst'), ('dmg', '.dmg')]:
            name = 'Open-Foresight-0.1.0' + suffix
            release = {'assets': [{'name': name, 'id': 1}, {'name': name + '.sha256'}]}
            self.assertEqual(select_asset(release, kind)['id'], 1)
            with self.assertRaises(ValueError):
                select_asset({'assets': release['assets'][:1]}, kind)
            with self.assertRaises(ValueError):
                select_asset({'assets': release['assets'] + [{'name': 'duplicate' + suffix}]}, kind)
        with self.assertRaises(ValueError):
            select_asset({'assets': [{'name': '../escape.deb'}, {'name': '../escape.deb.sha256'}]}, 'deb')

    def test_failed_download_cannot_leave_a_previous_success_report(self):
        """A reused download directory must not retain misleading passed evidence."""
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'installer.json'
            report.write_text('{"status":"verified_download"}')
            with patch.object(sys, 'argv', ['download', '--tag', 'v0.1.0', '--format', 'deb', '--directory', directory]), \
                    patch('release_asset_acceptance.subprocess.check_output', side_effect=RuntimeError('Fixture network failure')):
                with self.assertRaises(RuntimeError):
                    download_main()
            self.assertEqual(json.loads(report.read_text())['status'], 'failed')

    def test_checksum_binds_filename_and_detects_tampered_download(self):
        """A matching checksum for another filename must not authorize this one."""
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / 'package.rpm'
            sidecar = Path(directory) / 'package.rpm.sha256'
            package.write_bytes(b'published bytes')
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            sidecar.write_text(f'{digest}  {package.name}\n')
            self.assertEqual(verify_checksum(package, sidecar), digest)
            package.write_bytes(b'tampered bytes')
            with self.assertRaises(ValueError):
                verify_checksum(package, sidecar)
            sidecar.write_text(f'{digest}  different.rpm\n')
            with self.assertRaises(ValueError):
                verify_checksum(package, sidecar)

    def test_clean_gui_environment_drops_all_runtime_and_credential_overrides(self):
        """Only display plumbing and explicit synthetic profile paths survive."""
        with patch.dict(os.environ, {'LD_LIBRARY_PATH': '/developer/lib',
                'DYLD_LIBRARY_PATH': '/developer/mac', 'PYTHONPATH': '/checkout',
                'FORESIGHT_SEARCH_API_KEY': 'private-fixture',
                'FORESIGHT_MODEL_WORKER': '/developer/worker', 'DISPLAY': ':99'}):
            env = clean_environment('/tmp/home', '/tmp/data', '/tmp/run')
        self.assertEqual(env['DISPLAY'], ':99')
        self.assertEqual(env['FORESIGHT_DATA'], '/tmp/data')
        self.assertFalse(set(env) & {'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH', 'PYTHONPATH',
                                    'FORESIGHT_SEARCH_API_KEY', 'FORESIGHT_MODEL_WORKER'})

    def test_linux_service_control_uses_the_installed_launcher(self):
        """Do not compensate for a broken wrapper with developer paths."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            (root / 'bin/foresight-service').touch()
            (root / 'open-foresight-service').touch()
            with patch('installed_runtime.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '{"pid":123}', '')) as run:
                self.assertEqual(service_command(root / 'bin/foresight-service', {}, '--status'), {'pid': 123})
                self.assertEqual(run.call_args.args[0], [str(root / 'open-foresight-service'), '--status'])

    def test_dmg_failure_detaches_its_mount_and_removes_only_its_created_copy(self):
        """An application-test failure must not leave a mounted image or installed copy."""
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / 'fixture.dmg'
            dmg.write_bytes(b'fixture')
            Path(str(dmg) + '.sha256').write_text(hashlib.sha256(b'fixture').hexdigest() + '  fixture.dmg\n')
            destination = root / 'Applications/Open Foresight.app'
            commands = []
            def command(arguments, **kwargs):
                commands.append(arguments)
                if arguments[:2] == ['hdiutil', 'attach']:
                    mount = Path(arguments[arguments.index('-mountpoint') + 1])
                    source = mount / 'Open Foresight.app/Contents'
                    source.mkdir(parents=True)
                    (source / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.openforesight.App'}))
                if 'test_installed_release.py' in ' '.join(map(str, arguments)):
                    raise subprocess.CalledProcessError(1, arguments)
                return subprocess.CompletedProcess(arguments, 0, '', '')
            with patch('test_release_dmg.platform.system', return_value='Darwin'), \
                    patch('test_release_dmg.subprocess.run', side_effect=command), \
                    patch('test_release_dmg.verify_signature', return_value={'adhoc': True}):
                with self.assertRaises(subprocess.CalledProcessError):
                    run_dmg(Namespace(dmg=dmg, destination=destination, output=root / 'reports', models=root / 'models'))
            self.assertFalse(destination.exists())
            self.assertTrue(any(command[:2] == ['hdiutil', 'detach'] for command in commands))
            report = json.loads((root / 'reports/installation.json').read_text())
            self.assertEqual(report['status'], 'failed')
            self.assertTrue(report['uninstall_owned_copy'])

    def test_dmg_acceptance_refuses_existing_installation_before_any_system_mutation(self):
        """An acceptance invocation cannot replace the user's app."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / 'fixture.dmg'
            dmg.write_bytes(b'fixture')
            Path(str(dmg) + '.sha256').write_text(hashlib.sha256(b'fixture').hexdigest() + '  fixture.dmg\n')
            existing = root / 'Open Foresight.app'
            existing.mkdir()
            sentinel = existing / 'keep'
            sentinel.write_text('user installation')
            with patch('test_release_dmg.platform.system', return_value='Darwin'), patch('test_release_dmg.subprocess.run') as process:
                with self.assertRaisesRegex(ValueError, 'Refusing to replace'):
                    run_dmg(Namespace(dmg=dmg, destination=existing, output=root / 'reports', models=root / 'models'))
                process.assert_not_called()
            self.assertEqual(sentinel.read_text(), 'user installation')
