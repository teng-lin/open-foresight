"""Copy an explicitly selected, validated Gemma Python runtime into a bundle."""
import json
from pathlib import Path
import shutil
import subprocess


def bundle_runtime(python, destination, runner, architecture, identify):
    python, destination, runner = Path(python).absolute(), Path(destination).absolute(), Path(runner).absolute()
    subprocess.run([str(python), '-I', str(runner), '--check'], check=True,
                   timeout=30, capture_output=True)
    query = '''import sys, sysconfig, json, importlib.metadata as m
print(json.dumps(dict(executable=sys.executable, version=sys.version,
    stdlib=sysconfig.get_path('stdlib'), packages=sysconfig.get_path('purelib'),
    libdir=sysconfig.get_config_var('LIBDIR'),
    library=sysconfig.get_config_var('LDLIBRARY'),
    distributions=sorted((d.metadata['Name'], d.version) for d in m.distributions()))))'''
    config = json.loads(subprocess.check_output(
        [str(python), '-I', '-c', query], text=True, timeout=30))
    executable = Path(config['executable']).resolve(strict=True)
    library = Path(config['libdir']) / config['library']
    if identify(executable) != architecture or identify(library) != architecture:
        raise ValueError('Gemma Python runtime must match the desktop architecture')
    stdlib = Path(config['stdlib'])
    packages = Path(config['packages'])
    if not stdlib.is_dir() or not packages.is_dir():
        raise ValueError('Selected Python is missing its standard library or packages')
    destination.mkdir()
    (destination / 'bin').mkdir()
    (destination / 'lib').mkdir()
    shutil.copy2(executable, destination / 'bin/python3')
    shutil.copy2(library, destination / 'lib' / library.name)
    target_stdlib = destination / 'lib' / stdlib.name
    shutil.copytree(stdlib, target_stdlib,
                    ignore=shutil.ignore_patterns('site-packages', '__pycache__', '*.pyc'))
    shutil.copytree(packages, target_stdlib / 'site-packages',
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    for file in destination.rglob('*.so*'):
        if not file.is_file():
            continue
        with file.open('rb') as stream:
            is_elf = stream.read(4) == b'\x7fELF'
        if is_elf:
            if identify(file) != architecture:
                raise ValueError(f'Mixed architecture in Python runtime: {file.name}')
    # Both executable and modules resolve relative to the relocated runtime.
    # Do not retain a venv's absolute shebangs, prefix, or user Python paths.
    launcher = destination.parent / 'litert-runner'
    launcher.write_text('''#!/usr/bin/env bash
set -euo pipefail
task_runtime=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export LD_LIBRARY_PATH="$task_runtime/python/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$task_runtime/python/bin/python3" -I -B "$task_runtime/litert_runner.py" "$@"
''')
    launcher.chmod(0o755)
    embedding_python = destination.parent / 'litert-python'
    embedding_python.write_text('''#!/usr/bin/env bash
set -euo pipefail
task_runtime=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export LD_LIBRARY_PATH="$task_runtime/python/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$task_runtime/python/bin/python3" -I -B "$@"
''')
    embedding_python.chmod(0o755)
    subprocess.run([str(launcher), '--check'], check=True, timeout=30,
                   capture_output=True, cwd='/')
    return {'version': config['version'], 'distributions': config['distributions'],
            'runner': 'share/open-foresight/litert-runner',
            'limits': 'Requires compatible Linux system libraries; model assets downloaded separately.'}
