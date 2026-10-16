"""Controlled process-lifetime fixture, not an inference quality substitute."""
import json
import os
from pathlib import Path
import signal
import sys
import time

if log := os.environ.get('FORESIGHT_FIXTURE_PID_LOG'):
    with open(log, 'a') as stream:
        stream.write(f'{os.getpid()}\n')
stubborn = Path(sys.argv[1]).name == 'stubborn'
if stubborn:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
print(json.dumps({'ready': True, 'dimensions': 4, 'digest': 'fixture',
                  'tokenizer_digest': 'fixture', 'preprocessing': 'fixture'}), flush=True)
for line in sys.stdin:
    try:
        # Reproduce libraries writing progress to inherited helper stderr.
        print('fixture progress', file=sys.stderr, flush=True)
        request = json.loads(line)
        if request['op'] == 'encode':
            result = list(request['text'].encode())
        elif request['op'] == 'decode':
            result = bytes(request['tokens']).decode()
        else:
            result = [1., 0., 0., 0.]
        print(json.dumps({'result': result}), flush=True)
    except Exception as error:
        print(json.dumps({'error': str(error)}), flush=True)
if stubborn:
    while True:
        time.sleep(1)
