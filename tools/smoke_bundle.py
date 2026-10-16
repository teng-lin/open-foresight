#!/usr/bin/env python3
"""Relocate and launch the desktop bundle, then verify its private helper RPC."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import grpc
from evaluate_models import PACKAGE, messages, control_snapshot

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='foresight-relocation-') as temp:
        root = Path(temp)
        relocated = root / 'relocated bundle'
        shutil.copytree(args.bundle, relocated)
        env = os.environ.copy()
        env['FORESIGHT_DATA'] = str(root / 'data')
        env['FORESIGHT_RUNTIME'] = str(root / 'run')
        # Deliberately drop the build-time library path: test bundled resolution.
        env['LD_LIBRARY_PATH'] = str(relocated / 'lib') + ':' + str(relocated / 'app/lib')
        linkage = {}
        for relative in ['bin/ForesightHelper', 'lib/libforesight_native.so', 'app/foresight']:
            value = subprocess.check_output(['ldd', str(relocated / relative)], env=env, text=True)
            assert 'not found' not in value, value
            linkage[relative] = value.splitlines()
        log = root / 'desktop.log'
        socket = str(root / 'run/helper.sock')
        with log.open('w') as output:
            process = subprocess.Popen([str(relocated / 'foresight')],
                env=env, cwd='/', stdout=output, stderr=output, start_new_session=True)
            channel = grpc.insecure_channel('unix:' + socket)
            try:
                grpc.channel_ready_future(channel).result(timeout=30)
                classes = messages()
                rpc = channel.unary_unary('/' + PACKAGE + '.RagService/Ping',
                    request_serializer=lambda value: value.SerializeToString(),
                    response_deserializer=classes['PingResponse'].FromString)
                ping = rpc(classes['PingRequest'](), timeout=5)
                assert ping.success and ping.version == '1.0.3'
                state = control_snapshot(channel)
                assert state['pipeline'] == 'unconfigured', state
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    assert process.poll() is None, f'App exit code: {process.poll()}\n{log.read_text()}'
                    time.sleep(0.25)
                assert (root / 'data/application.db').is_file(), 'Application DB was not created'
                assert (root / 'run').stat().st_mode & 0o077 == 0
                assert (root / 'data').stat().st_mode & 0o077 == 0
                google_configuration = relocated / 'share/foresight/google-client.json'
                if google_configuration.exists():
                    config = json.loads(google_configuration.read_text())
                    assert set(config) == {'installed'}
                    assert set(config['installed']) <= {'client_id', 'client_secret'}
                    assert google_configuration.stat().st_mode & 0o077 == 0
                report = {'relocation': 'passed with spaces in bundle path and cwd=/',
                          'desktop_process_alive': True, 'startup_observation_seconds': 10, 'application_database_created': True,
                          'ping': {'success': ping.success, 'version': ping.version},
                          'state_without_models': state, 'private_paths': True,
                          'google_application_configuration_packaged': google_configuration.exists(),
                          'google_account_tokens_packaged': False,
                          'linkage': linkage,
                          'limitations': ['Same Linux host; independent clean machine not tested'],
                          'log': log.read_text()}
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(report, indent=2) + '\n')
                print(json.dumps({'relocation': 'passed', 'ping': True, 'desktop': True}))
            finally:
                channel.close()
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()

if __name__ == '__main__':
    main()
