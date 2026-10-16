#!/usr/bin/env python3
"""Check ordinary bundle launch on an owned desktop without a model override."""
import argparse
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import grpc
from evaluate_models import control_snapshot

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    desk = ['uv', 'run', '--directory', str(ROOT.parent / 'agent-desktop'),
            '--no-sync', 'agent-desktop']

    def desktop(*arguments):
        return json.loads(subprocess.check_output(desk + list(arguments), text=True))

    session = None
    with tempfile.TemporaryDirectory(prefix='fdm-', dir='/tmp') as temporary:
        root = Path(temporary)
        try:
            session = desktop('create', '--mode', 'headless', '--guard-host')['session']
            launch = desktop('launch', session, '--', 'env', '-u', 'FORESIGHT_MODEL_MANIFEST',
                             'FORESIGHT_DATA=' + str(root / 'data'),
                             'FORESIGHT_RUNTIME=' + str(root / 'run'),
                             str(bundle / 'foresight'))
            print(json.dumps({'session': session, 'pid': launch['pid'], 'logs': launch['logs']}), flush=True)
            deadline = time.monotonic() + 90
            state = None
            models = []
            while time.monotonic() < deadline:
                jobs = desktop('status', session)['applications']
                job = next(item for item in jobs if item['pid'] == launch['pid'])
                assert job['exit_code'] is None, 'Bundle exited before model readiness'
                database = root / 'data/application.db'
                if database.exists():
                    with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as connection:
                        models = connection.execute('SELECT kind,digest,backend FROM models ORDER BY kind').fetchall()
                if len(models) == 3 and (root / 'run/helper.sock').exists():
                    try:
                        with grpc.insecure_channel('unix:' + str(root / 'run/helper.sock')) as channel:
                            state = control_snapshot(channel)
                        if state.get('pipeline') == 'ready':
                            break
                    except grpc.RpcError:
                        pass
                time.sleep(.5)
            assert state and state.get('pipeline') == 'ready', 'Embedding startup timed out'
            expected = json.loads((ROOT / 'models/local/native/installed-gemma-macos-gpu.json').read_text())
            by_kind = {kind: (digest, backend) for kind, digest, backend in models}
            assert by_kind['embedding'] == (expected['embedding']['sha256'], 'litert_lm_embedding_gpu')
            assert by_kind['generation'] == (expected['generation']['sha256'], 'litert_lm')
            assert by_kind['speech'][0] == expected['speech']['sha256']
            assert state['model']['backend'] == 'litert-lm-embedding-gpu'
            report = {'ordinary_launcher_without_model_override': True,
                      'fresh_profile_registered_models': [kind for kind, _, _ in models],
                      'embedding_backend': state['model']['backend'],
                      'embedding_digest': by_kind['embedding'][0],
                      'generation_digest': by_kind['generation'][0],
                      'generation_registration': 'Gemma 4 E2B; execution has separate native meeting acceptance',
                      'bundle_revision': json.loads((bundle / 'manifest.json').read_text())['revision'],
                      'recording_started': False, 'user_profile_used': False,
                      'acceptance_passed': True}
        finally:
            if session is not None:
                assert desktop('destroy', session)['status'] == 'stopped'
        report['private_session_stopped'] = True
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))


if __name__ == '__main__':
    main()
