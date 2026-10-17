#!/usr/bin/env python3
"""Relocate the native dedicated detector and test its installed protocol.

--model accepts an explicitly supplied, authenticated decrypted fixture. Without
it, verify native math self-checks and rejection of an unavailable model.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from macos_bundle import relocate_dependencies, audit_dependencies, binaries


def verify(worker, model=None):
    with tempfile.TemporaryDirectory(prefix='foresight-query-package-') as directory:
        root = Path(directory)
        app = root / 'before relocation.app'
        target = app / 'Contents/Resources/bin/foresight-query'
        target.parent.mkdir(parents=True)
        shutil.copy2(worker, target)
        relocate_dependencies(app)
        for file in binaries(app):
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(file)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        moved = root / 'moved directory with spaces/Relocated.app'
        moved.parent.mkdir()
        app.rename(moved)
        worker = moved / 'Contents/Resources/bin/foresight-query'
        environment = {'PATH': '/nonexistent', 'HOME': str(root)}
        subprocess.run([str(worker), '--check'], env=environment, cwd='/', check=True)
        requests = [{'id': 'positive', 'prompt': ' <ctrl1>We need to ship the launch soon. What risks could delay the launch?', 'max_output_tokens': 512},
                    {'id': 'negative', 'prompt': ' <ctrl1>The meeting starts at three.', 'max_output_tokens': 512}]
        result = subprocess.run([str(worker), '--model', str(model or root / 'missing-model')],
            input=''.join(json.dumps(request) + '\n' for request in requests), env=environment,
            cwd='/', stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
        frames = [json.loads(line) for line in result.stdout.splitlines()]
        if model:
            if (result.returncode or frames[0]['type'] != 'ready'
                    or frames[1]['id'] != 'positive'
                    or frames[1]['text'].strip() != 'What risks could delay the launch?'
                    or frames[2]['id'] != 'negative' or frames[2]['text'] != ''):
                raise AssertionError((result.returncode, frames, result.stderr))
        elif result.returncode != 1 or frames[0]['type'] != 'fatal':
            raise AssertionError(frames)
        if list(moved.rglob('*.py')) or list(moved.rglob('*.tflite')):
            raise AssertionError('Unexpected Python or model payload')
        linkage = audit_dependencies(moved)
        return {'relocated': True, 'python_bundled': False, 'model_bundled': False,
                'original_oracle_bundled': False, 'worker_exit': result.returncode,
                'frames': frames, 'mach_o_binaries_audited': len(linkage)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', required=True, type=Path)
    parser.add_argument('--model', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Real Mach-O relocation check requires macOS')
    report = verify(args.worker, args.model.resolve() if args.model else None)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
