#!/usr/bin/env python3
"""Opt-in acceptance of the shared native raw-session path with a supplied model.

This tests the public-runtime path, not original Foresight output parity. The
production detector mode has context 512. --context permits a diagnostic model
with a different minimum prefill shape; it does not change production settings.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True)
    parser.add_argument('--native-probe', required=True)
    parser.add_argument('--library', required=True)
    parser.add_argument('--context', type=int, default=512)
    parser.add_argument('--backend', choices=('cpu', 'gpu'), default='cpu')
    parser.add_argument('--prompt', default=' <ctrl1>When is the project review?')
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    if not 1 <= args.context <= 4096:
        parser.error('Context must be between 1 and 4096')
    commands = {'cpp': [args.native_probe, args.model, args.prompt, str(args.context), args.backend]}
    report = {'model': args.model, 'prompt': args.prompt, 'context': args.context, 'backend': args.backend,
              'original_detector_parity_established': False}
    env = dict(os.environ, FORESIGHT_LITERT_LIBRARY=args.library)
    for name, command in commands.items():
        started = time.monotonic()
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=180)
        report[name] = {'exit': result.returncode, 'text': result.stdout,
                        'seconds': round(time.monotonic()-started, 2)}
        Path(args.report + '.' + name + '.stderr').write_text(result.stderr)
        print(name, 'exit', result.returncode, 'characters', len(result.stdout), flush=True)
    Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2))
    if report['cpp']['exit']:
        raise SystemExit('Raw runtime failed; see the retained diagnostic report')
    print('Native raw query execution passed; original detector parity remains unverified.')


if __name__ == '__main__':
    main()
