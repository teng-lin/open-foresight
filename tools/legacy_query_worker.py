#!/usr/bin/env python3
"""Owned-process adapter for the reconstructed dedicated detector.

The caller cancels by terminating this process, never another model worker.
One model is loaded per process; each JSON-line request starts a fresh cache.
This CPU adapter does not establish original int8 GPU/KV-cache parity.
"""

import argparse
import json
from pathlib import Path
import sys


PREFIX = ' <ctrl1>'
MAX_FRAME = 1024 * 1024
BACKEND = 'numpy_float32_cpu_diagnostic'


def emit(output, value):
    output.write(json.dumps(value, ensure_ascii=True) + '\n')
    output.flush()


def serve(executor, source, output):
    emit(output, {'type': 'ready', 'backend': BACKEND,
                  'original_gpu_parity_verified': False})
    while True:
        line = source.readline(MAX_FRAME + 1)
        if not line:
            return
        if len(line) > MAX_FRAME:
            raise ValueError('Detector request frame exceeds 1 MiB')
        request_id = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError('Detector request must be an object')
            request_id = request.get('id')
            if not isinstance(request_id, str) or not 1 <= len(request_id) <= 256:
                request_id = None
                raise ValueError('Detector request requires an owned request id')
            prompt = request.get('prompt')
            if not isinstance(prompt, str) or not prompt.startswith(PREFIX):
                raise ValueError('Detector requires the original raw control prefix')
            limit = request.get('max_output_tokens', 512)
            if type(limit) is not int or not 1 <= limit <= 512:
                raise ValueError('Detector output limit must be between 1 and 512')
            # The service supplies the recovered raw prompt. generate() owns
            # prefix/BOS tokenization; remove exactly one prefix, without trim.
            result = executor.generate(prompt[len(PREFIX):], limit)
            emit(output, {'type': 'result', 'id': request_id,
                          'text': result['text'], 'finish_reason': result['finish_reason'],
                          'backend': BACKEND, 'original_gpu_parity_verified': False})
        except (ValueError, TypeError, KeyError, RuntimeError) as error:
            emit(output, {'type': 'error', 'id': request_id, 'message': str(error)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True)
    args = parser.parse_args()
    try:
        # Kept lazy so protocol tests need no model/runtime dependencies.
        # -I excludes the script directory; use only our own installed siblings.
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from legacy_query_executor import LegacyQueryExecutor
        executor = LegacyQueryExecutor(args.model)  # Authenticated SHA guard.
        serve(executor, sys.stdin.buffer, sys.stdout)
    except Exception as error:
        emit(sys.stdout, {'type': 'fatal', 'message': str(error)})
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
