#!/usr/bin/env python3
"""Exercise real native/Dart capture failure handling with a failing CLI fixture."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--library', type=Path,
                        default=ROOT / 'build/native/libforesight_native.so')
    parser.add_argument('--log', type=Path, required=True)
    args = parser.parse_args()
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='foresight-capture-failure-') as directory:
        runner = Path(directory) / 'pw-record'
        runner.write_text('#!/bin/sh\nexit 1\n')
        runner.chmod(0o755)
        environment = dict(os.environ,
                           FORESIGHT_CAPTURE_STATE_TEST='1',
                           FORESIGHT_NATIVE=str(args.library.resolve()),
                           PATH=directory + ':' + os.environ['PATH'])
        with args.log.open('w') as log:
            result = subprocess.run([
                args.flutter, 'test', '--no-pub', '--reporter', 'expanded',
                'test/capture_failure_test.dart'],
                cwd=ROOT / 'apps/desktop', env=environment,
                stdout=log, stderr=subprocess.STDOUT)
    print(json.dumps({'exit_code': result.returncode, 'log': str(args.log),
                      'method': 'Real native/Dart retry and terminal event path; deterministic failing pw-record CLI; no physical capture or real ASR'}))
    if result.returncode:
        print(args.log.read_text()[-5000:])
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
