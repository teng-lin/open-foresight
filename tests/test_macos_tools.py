"""Installer transaction and MCP transport tests; no release/signing claims."""
import json
import os
import shutil
import subprocess
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import install_macos as installer
from smoke_macos_bundle import McpPeer, stop_desktop

SIGNATURE = {'team': 'test-team', 'adhoc': False}


def bundle(path, version, identifier=installer.IDENTIFIER):
    (path/'Contents').mkdir(parents=True)
    with (path/'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier':identifier},stream)
    (path/'version').write_text(version)
    return path


def portable_swap(first, second):
    # Test transaction logic on Linux too; production uses one Darwin RENAME_SWAP.
    temporary = first.parent/'swap-backup'
    os.replace(first,temporary)
    os.replace(second,first)
    os.replace(temporary,second)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = bundle(self.root/'Source.app','new')
        self.destination = bundle(self.root/'Installed.app','old')
        self.options = {'verify':lambda _:SIGNATURE, 'active':lambda _:{}, 'swap':portable_swap}

    def tearDown(self):
        self.temporary.cleanup()
        shutil.rmtree(installer.installation_lock_path(self.destination).parent,ignore_errors=True)

    def test_foreign_application_is_never_replaced(self):
        with (self.destination/'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier':'com.google.foresight'},stream)
        with self.assertRaisesRegex(ValueError,'different application'):
            installer.install(self.source,self.destination,**self.options)
        self.assertEqual((self.destination/'version').read_text(),'old')

    def test_live_process_defers_without_modifying_bundle(self):
        self.options['active'] = lambda _:{42:'/installed/service'}
        with self.assertRaises(installer.Deferred):
            installer.install(self.source,self.destination,**self.options)
        self.assertEqual((self.destination/'version').read_text(),'old')
        self.assertEqual(list(self.root.glob('.open-foresight-install-*')),[])

    def test_upgrade_stages_swaps_and_preserves_source(self):
        result = installer.install(self.source,self.destination,**self.options)
        self.assertTrue(result['upgraded'])
        self.assertEqual((self.destination/'version').read_text(),'new')
        self.assertEqual((self.source/'version').read_text(),'new')
        self.assertEqual(list(self.root.glob('.open-foresight-install-*')),[])

    def test_staged_signature_failure_preserves_old_app(self):
        def verify(path):
            if path.parent.name.startswith('.open-foresight-install-'):
                raise ValueError('corrupted staging signature')
            return SIGNATURE
        self.options['verify'] = verify
        with self.assertRaisesRegex(ValueError,'corrupted staging'):
            installer.install(self.source,self.destination,**self.options)
        self.assertEqual((self.destination/'version').read_text(),'old')

    def test_post_swap_signature_failure_rolls_back(self):
        def verify(path):
            if path == self.destination and (path/'version').read_text() == 'new':
                raise ValueError('post-swap failure')
            return SIGNATURE
        self.options['verify'] = verify
        with self.assertRaisesRegex(ValueError,'post-swap'):
            installer.install(self.source,self.destination,**self.options)
        self.assertEqual((self.destination/'version').read_text(),'old')

    def test_failed_rollback_retains_old_bundle_for_recovery(self):
        def verify(path):
            if path == self.destination and (path/'version').read_text() == 'new':
                raise ValueError('post-swap failure')
            return SIGNATURE
        swaps = []
        def swap(first,second):
            swaps.append((first,second))
            if len(swaps)>1:
                raise OSError('rollback disk failure')
            portable_swap(first,second)
        self.options.update(verify=verify,swap=swap)
        with self.assertRaisesRegex(RuntimeError,'preserved recovery bundle'):
            installer.install(self.source,self.destination,**self.options)
        recovery = list(self.root.glob('.open-foresight-install-*/Installed.app'))
        self.assertEqual(len(recovery),1)
        self.assertEqual((recovery[0]/'version').read_text(),'old')

    def test_running_app_during_staging_defers(self):
        self.options['active'] = Mock(side_effect=[{}, {}, {43:'newly launched service'}])
        with self.assertRaisesRegex(installer.Deferred,'while staging'):
            installer.install(self.source,self.destination,**self.options)
        self.assertEqual((self.destination/'version').read_text(),'old')

    def test_explicit_stop_requires_no_remaining_processes(self):
        stopper = Mock()
        self.options.update(active=Mock(side_effect=[{42:'service'}, {}, {}, {}]),stopper=stopper)
        installer.install(self.source,self.destination,stop_services=True,profiles=['profile'],**self.options)
        stopper.assert_called_once_with(self.destination,{42:'service'},['profile'])

    def lock_attempt(self, exclusive):
        code = """import sys
from install_macos import installation_lock,Deferred
try:
 with installation_lock(sys.argv[1],exclusive=sys.argv[2]=='true'):
  print('acquired')
except Deferred:
 print('deferred')
 sys.exit(3)
"""
        return subprocess.run([sys.executable,'-c',code,str(self.destination),'true' if exclusive else 'false'],
            env={**os.environ,'PYTHONPATH':str(Path(installer.__file__).parent)},capture_output=True,text=True)

    def test_live_service_shared_lock_defers_concurrent_installer_subprocess(self):
        with installer.installation_lock(self.destination,exclusive=False):
            outcome=self.lock_attempt(True)
            self.assertEqual(outcome.returncode,3,outcome.stderr)
            self.assertEqual(outcome.stdout.strip(),'deferred')
            # Independent profiles can concurrently hold shared service locks.
            self.assertEqual(self.lock_attempt(False).returncode,0)
        self.assertEqual(self.lock_attempt(True).returncode,0)

    def test_installer_exclusive_lock_blocks_new_service_subprocess(self):
        with installer.installation_lock(self.destination):
            self.assertEqual(self.lock_attempt(False).returncode,3)
            self.assertEqual(self.lock_attempt(True).returncode,3)
        self.assertEqual(self.lock_attempt(False).returncode,0)

    def test_lock_rejects_symlink_and_public_mode(self):
        path=installer.installation_lock_path(self.destination)
        path.parent.mkdir(mode=0o700)
        other=self.root/'unrelated'
        other.write_text('preserve')
        path.symlink_to(other)
        with self.assertRaises(OSError):
            with installer.installation_lock(self.destination): pass
        self.assertEqual(other.read_text(),'preserve')
        path.unlink()
        path.parent.chmod(0o755)
        with self.assertRaisesRegex(ValueError,'private'):
            with installer.installation_lock(self.destination): pass
        path.parent.chmod(0o700)

    def test_signature_team_cannot_change_during_upgrade(self):
        self.options['verify'] = lambda path:dict(SIGNATURE,team='foreign' if path==self.destination else 'test-team')
        with self.assertRaisesRegex(ValueError,'signing team'):
            installer.install(self.source,self.destination,**self.options)
        self.assertEqual((self.destination/'version').read_text(),'old')

    def test_profile_reporting_arbitrary_pid_is_never_stopped(self):
        executable=(self.destination/installer.SERVICE).resolve()
        response=SimpleNamespace(returncode=0,stdout=json.dumps({'pid':999}),stderr='')
        with patch.object(installer.subprocess,'run',return_value=response) as run:
            with self.assertRaisesRegex(installer.Deferred,'not owned'):
                installer.stop_owned_services(self.destination,{42:str(executable)},['profile'])
        self.assertEqual([call.args[0][-1] for call in run.call_args_list],['--status'])

    def test_recording_upgrade_defers_before_stopping_any_profile(self):
        executable=(self.destination/installer.SERVICE).resolve()
        responses=[SimpleNamespace(returncode=0,stdout=json.dumps({'pid':42,'capture':{'active':False}}),stderr=''),
                   SimpleNamespace(returncode=0,stdout=json.dumps({'pid':43,'capture':{'active':True}}),stderr='')]
        with patch.object(installer.subprocess,'run',side_effect=responses) as run, \
             patch.object(installer,'process_path',return_value=executable):
            with self.assertRaisesRegex(installer.Deferred,'final transcript'):
                installer.stop_owned_services(self.destination,{42:str(executable),43:str(executable)},['first','recording'])
        self.assertEqual([call.args[0][-1] for call in run.call_args_list],['--status','--status'])
        self.assertEqual((self.destination/'version').read_text(),'old')

    def test_failed_service_shutdown_never_reaches_staging_or_swap(self):
        self.options.update(active=lambda _:{42:'service'},
            stopper=Mock(side_effect=subprocess.TimeoutExpired('service --stop',1800)))
        with self.assertRaises(subprocess.TimeoutExpired):
            installer.install(self.source,self.destination,stop_services=True,profiles=['profile'],**self.options)
        self.assertEqual((self.destination/'version').read_text(),'old')
        self.assertEqual(list(self.root.glob('.open-foresight-install-*')),[])

    def test_unowned_worker_is_never_treated_as_service_descendant(self):
        executable=(self.destination/installer.SERVICE).resolve()
        response=SimpleNamespace(returncode=0,stdout=json.dumps({'pid':42}),stderr='')
        with patch.object(installer.subprocess,'run',return_value=response) as run, \
             patch.object(installer.subprocess,'check_output',return_value='42 1\n43 1\n'), \
             patch.object(installer,'process_path',return_value=executable):
            with self.assertRaisesRegex(installer.Deferred,'unrelated worker'):
                installer.stop_owned_services(self.destination,{42:str(executable),43:str(self.destination/'worker')},['profile'])
        self.assertEqual([call.args[0][-1] for call in run.call_args_list],['--status'])

    @unittest.skipUnless(sys.platform=='darwin','Darwin metadata copy')
    def test_app_copy_preserves_extended_attributes_and_quarantine(self):
        subprocess.run(['/usr/bin/xattr','-w','com.openforesight.test','retained',str(self.source)],check=True)
        subprocess.run(['/usr/bin/xattr','-w','com.apple.quarantine','0081;12345678;OpenForesightTest;',str(self.source)],check=True)
        copied=self.root/'Copied.app'
        installer.copy_application(self.source,copied)
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr','-p','com.openforesight.test',str(copied)],text=True).strip(),'retained')
        quarantine=subprocess.check_output(['/usr/bin/xattr','-p','com.apple.quarantine',str(copied)],text=True).strip()
        # macOS may normalize provenance/time fields when propagating quarantine.
        self.assertTrue(int(quarantine.split(';')[0],16) & 1,quarantine)

    @unittest.skipUnless(sys.platform=='darwin','Darwin atomic exchange')
    def test_real_darwin_atomic_exchange_of_nonempty_apps(self):
        installer.atomic_swap(self.source,self.destination)
        self.assertEqual((self.destination/'version').read_text(),'new')
        self.assertEqual((self.source/'version').read_text(),'old')


class McpTransportTests(unittest.TestCase):
    def runner(self, root, trailing_noise=False):
        path = root/'mcp fixture'
        code = '''import sys,json
for line in sys.stdin:
 request=json.loads(line)
 if 'id' in request:
  result={'protocolVersion':'2025-11-25','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}} if request['method']=='initialize' else {'structuredContent':{'result':request['params']['arguments']}}
  print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
'''
        if trailing_noise:
            code += 'print("accidental diagnostic on MCP stdout",flush=True)\n'
        path.write_text('#!'+sys.executable+'\n'+code)
        path.chmod(0o755)
        return path

    def test_real_subprocess_transport_closes_cleanly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            peer=McpPeer(self.runner(root),installer.minimal_environment(root))
            self.assertEqual(peer.tool('echo',{'key':'value'}),{'key':'value'})
            peer.close()
            self.assertEqual(peer.process.returncode,0)

    def test_trailing_stdout_pollution_fails_even_after_successful_reply(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            peer=McpPeer(self.runner(root,True),installer.minimal_environment(root))
            self.assertEqual(peer.tool('echo'),{})
            with self.assertRaisesRegex(RuntimeError,'Non-protocol'):
                peer.close()

    def test_owned_desktop_cleanup_reaps_process_ignoring_sigterm(self):
        process=subprocess.Popen([sys.executable,'-c',"import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"],stdout=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(),b'ready\n')
            self.assertEqual(stop_desktop(process,timeout=.1),-9)
            self.assertIsNotNone(process.poll())
        finally:
            if process.poll() is None:
                process.kill();process.wait()
            process.stdout.close()

    def test_optimized_python_cannot_skip_smoke_assertions(self):
        result=subprocess.run([sys.executable,'-O','-c',"from smoke_macos_bundle import smoke; smoke(None,None)"],
            env={**os.environ,'PYTHONPATH':str(Path(installer.__file__).parent)},capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('run Python without -O',result.stderr)

    def test_minimal_environment_has_no_developer_runtime_leaks(self):
        env=installer.minimal_environment('/tmp/home','/tmp/profile')
        self.assertEqual(set(env),{'HOME','PATH','FORESIGHT_DATA'})
        self.assertEqual(env['PATH'],'/usr/bin:/bin:/usr/sbin:/sbin')


if __name__=='__main__':
    unittest.main()
