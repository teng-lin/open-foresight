#!/usr/bin/env python3
"""Check persistent worker health/ownership through the actual helper RPCs."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import grpc
from evaluate_models import PACKAGE, ROOT, messages, control_snapshot, process_memory


def main():
    classes = messages()
    env = os.environ.copy()
    env.update(FORESIGHT_MODEL_WORKER=str(ROOT / 'build/services/helper/model_worker_fixture'))
    with tempfile.TemporaryDirectory(prefix='foresight-worker-health-') as temporary:
        root = Path(temporary)
        model = root / 'model'
        model.mkdir()
        helper = subprocess.Popen([str(ROOT / 'build/services/helper/ForesightHelper'),
                                   str(root / 'run/helper.sock'), str(root / 'data')],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        channel = grpc.insecure_channel('unix:' + str(root / 'run/helper.sock'))
        try:
            grpc.channel_ready_future(channel).result(timeout=15)
            configure = channel.unary_unary('/' + PACKAGE + '.RagService/UpdateModelPaths',
                request_serializer=lambda m: m.SerializeToString(),
                response_deserializer=classes['UpdateModelPathsResponse'].FromString)
            helper.stderr.close()  # The old frontend has gone away.
            result = configure(classes['UpdateModelPathsRequest'](embedding_model_path=str(model)), timeout=10)
            assert result.success, result.error_message
            assert control_snapshot(channel)['pipeline'] == 'ready'
            samples = process_memory(helper.pid)
            assert len(samples) >= 2, 'Memory sampling omitted thread-owned adapter'
            children = set()
            for file in Path(f'/proc/{helper.pid}/task').glob('*/children'):
                children.update(int(pid) for pid in file.read_text().split())
            assert len(children) == 1
            os.kill(children.pop(), signal.SIGKILL)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                state = control_snapshot(channel)
                if state['pipeline'] == 'failed':
                    break
                time.sleep(.05)
            assert state['pipeline'] == 'failed', state
            assert not state.get('tokenizer_ready', False)
            assert 'reload' in state['last_error'].lower()
            result = configure(classes['UpdateModelPathsRequest'](embedding_model_path=str(model)), timeout=10)
            assert result.success, result.error_message
            assert control_snapshot(channel)['pipeline'] == 'ready'
            report = {'before_fix': 'Creator thread retirement reproduced Adapter input failure',
                      'cpp_lifetime_regression': 'passed',
                      'closed_frontend_stderr': 'passed',
                      'dead_worker_marks_pipeline_failed': 'passed',
                      'reload_after_worker_death': 'passed',
                      'thread_owned_worker_memory_sampled': 'passed',
                      'inference_quality': 'Not tested by this controlled process fixture'}
            (ROOT / 'test-results').mkdir(parents=True, exist_ok=True)
            (ROOT / 'test-results/helper-worker-lifetime.json').write_text(json.dumps(report, indent=2)+'\n')
            print(json.dumps(report))
        finally:
            channel.close()
            helper.terminate()
            helper.wait(timeout=5)


if __name__ == '__main__':
    main()
