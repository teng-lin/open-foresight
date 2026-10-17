#!/usr/bin/env python3
"""Real-model acceptance through a packaged service and MCP in a private profile."""
import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tests/service'))
import test_service_process as protocol


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--embedding', type=Path, required=True)
    p.add_argument('--generation', type=Path, required=True)
    p.add_argument('--backend', choices=['cpu','gpu'], default='gpu')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    bundle = args.bundle.resolve()
    protocol.MCP = bundle/'open-foresight-mcp'
    with tempfile.TemporaryDirectory(prefix='foresight-native-service-') as temporary:
        root = Path(temporary)
        env = dict(os.environ, FORESIGHT_DATA=str(root/'data'), FORESIGHT_RUNTIME=str(root/'run'),
                   FORESIGHT_LITERT_BACKEND=args.backend)
        commands = root/'system-commands'
        commands.mkdir(mode=0o700)
        for name in ('bash', 'dirname', 'chmod', 'stat', 'id'):
            (commands/name).symlink_to(shutil.which(name))
        env['PATH'] = str(commands)
        assert shutil.which('python', path=env['PATH']) is None
        assert shutil.which('python3', path=env['PATH']) is None
        env.pop('FORESIGHT_MODEL_MANIFEST', None)
        env.pop('FORESIGHT_MODEL_WORKER', None)
        log = (root/'service.log').open('w+')
        process = None
        peer = None
        mcp = None
        def start():
            proc = subprocess.Popen([str(bundle/'open-foresight-service')], env=env, stdout=log, stderr=log)
            deadline = time.monotonic()+30
            while True:
                try:
                    connection = protocol.Peer(root/'run/application.sock')
                    connection.socket.settimeout(300)
                    token = root/'data/.desktop-capability'
                    if token.exists():
                        connection.call('security.attach_desktop', {'token': token.read_text()})
                    return proc, connection
                except (FileNotFoundError,ConnectionRefusedError):
                    assert proc.poll() is None, (root/'service.log').read_text()[-3000:]
                    assert time.monotonic()<deadline, 'Service startup timeout'
                    time.sleep(.05)
        try:
            process,peer = start()
            peer.call('models.embedding',{'path':str(args.embedding.resolve()),'gpu':args.backend=='gpu'})
            peer.call('models.generation',{'path':str(args.generation.resolve()),'runtime':'/missing/retired-python-runner','backend':'litert_lm'})
            configured = sqlite3.connect(root/'data/application.db')
            runtime = configured.execute("SELECT runtime FROM models WHERE kind='generation'").fetchone()[0]
            assert runtime == str(bundle/'bin/foresight-model'), runtime
            configured.close()
            source = peer.call('sources.import',{'title':'Native acceptance','text':'Mira sends the draft Tuesday.'})
            mcp = protocol.McpPeer(env)
            mcp.initialize()
            assert mcp.tool('get_status')['structuredContent']['result']['pid'] == process.pid
            answer = mcp.tool('ask',{'question':'Who sends the draft and when?'})
            assert not answer.get('isError'), answer
            serialized = json.dumps(answer)
            assert 'Mira' in serialized and 'Tuesday' in serialized and 'S1' in serialized, answer
            mcp.close();mcp=None
            process.send_signal(signal.SIGTERM);process.wait(timeout=30);peer.close();peer=None
            with sqlite3.connect(root/'data/application.db') as db:
                db.execute("UPDATE models SET runtime='/missing/retired-python-runner' WHERE kind='generation'")
            process,peer = start()
            deadline = time.monotonic()+90
            while True:
                state = peer.call('status')
                if (state.get('generation') or {}).get('state') == 'ready': break
                assert time.monotonic()<deadline, state
                time.sleep(.2)
            restored = peer.call('answer',{'question':'Who sends the draft and when?'})
            assert 'Mira' in restored['text'] and 'Tuesday' in restored['text'], restored
            report = {'python_unavailable_in_application_path':True,'native_service_and_mcp':True,'shared_owner':True,'source_id':source['id'],
                      'generation_registration_uses_bundled_worker':True,'obsolete_python_registration_restores':True,
                      'answer':answer,'restored_answer':restored,'backend':state['generation']['backend']}
            args.output.parent.mkdir(parents=True,exist_ok=True)
            args.output.write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(report,indent=2))
        finally:
            if mcp: mcp.close()
            if peer: peer.close()
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=30)
                except subprocess.TimeoutExpired: process.kill();process.wait()
            log.close()


if __name__ == '__main__':
    main()
