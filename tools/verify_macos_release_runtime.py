#!/usr/bin/env python3
"""Reject incomplete Mac releases and exercise their own isolated runtimes."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from litert_extensions import PYTHON_CAPABILITY_PROBE


def runtime_paths(app):
    app = app.resolve(strict=True)
    resources = app / 'Contents/Resources'
    config = json.loads((resources / 'runtime.json').read_text())
    paths = {}
    for key in ('FORESIGHT_MODEL_PYTHON', 'FORESIGHT_LITERT_PYTHON',
                'FORESIGHT_LITERT_RUNNER', 'FORESIGHT_LITERT_EMBEDDING_ADAPTER',
                'FORESIGHT_WHISPER_RUNTIME', 'FORESIGHT_QUERY_WORKER'):
        relative = config.get(key)
        if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
            raise ValueError('Release lacks bundled ' + key)
        path = (resources / relative).resolve(strict=True)
        if not path.is_file() or not path.is_relative_to(app):
            raise ValueError('Release runtime escapes bundle: ' + key)
        paths[key] = path
    for notice in ('requirements-litert-macos.lock', 'LiteRT-LM-extension.json', 'whisper-LICENSE'):
        if not (resources / 'licenses' / notice).is_file():
            raise ValueError('Release lacks runtime provenance/license: ' + notice)
    return paths


def verify(app, output):
    paths = runtime_paths(app)
    report = {'status': 'failed', 'checks': {}}
    with tempfile.TemporaryDirectory(prefix='foresight-release-runtime-') as home:
        env = {'PATH': '/usr/bin:/bin', 'HOME': home, 'TMPDIR': home,
               'PYTHONDONTWRITEBYTECODE': '1'}
        commands = {
            'native_first': [paths['FORESIGHT_MODEL_PYTHON'], '-I', '-B', '-c', PYTHON_CAPABILITY_PROBE, '--native-first'],
            'sentencepiece_first': [paths['FORESIGHT_MODEL_PYTHON'], '-I', '-B', '-c', PYTHON_CAPABILITY_PROBE],
            'generation': [paths['FORESIGHT_LITERT_RUNNER'], '--check'],
            'embedding': [paths['FORESIGHT_LITERT_PYTHON'], paths['FORESIGHT_LITERT_EMBEDDING_ADAPTER'], '--check'],
            'whisper': [paths['FORESIGHT_WHISPER_RUNTIME'], '--help'],
        }
        try:
            for name, command in commands.items():
                result = subprocess.run([str(arg) for arg in command], env=env, cwd='/',
                                        capture_output=True, text=True, timeout=60)
                report['checks'][name] = {'exit_code': result.returncode,
                                          'stdout': result.stdout, 'stderr': result.stderr}
                if result.returncode:
                    raise RuntimeError('Packaged runtime failed: ' + name)
            report['status'] = 'passed'
        finally:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(report, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    verify(args.app, args.output)


if __name__ == '__main__':
    main()
