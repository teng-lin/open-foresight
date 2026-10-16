"""Explicit packaging of the reconstructed CPU query worker and its runtime."""
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MODULES = ('legacy_query_worker.py', 'legacy_query_executor.py', 'legacy_query_weights.py')
DEPENDENCIES = {'numpy': '2.5.1', 'sentencepiece': '0.2.1'}


def copy_worker(adapters):
    adapters.mkdir(parents=True, exist_ok=True)
    for name in MODULES:
        shutil.copy2(ROOT / 'tools' / name, adapters / name)
    return adapters / MODULES[0]


def inspect_runtime(python):
    source = ('import sys,sysconfig,json,importlib.metadata as m; '
              'import numpy as np,sentencepiece; '
              'assert (np.array([[2.]],dtype=np.float32)@np.array([[3.]],dtype=np.float32)).item()==6.; '
              'print(json.dumps({"version":list(sys.version_info[:2]),"base":sys.base_prefix,'
              '"stdlib":sysconfig.get_path("stdlib"),"dependencies":'
              '{name:m.version(name) for name in sys.argv[1:]},"licenses":'
              '{name:[str(m.distribution(name).locate_file(p)) for p in m.distribution(name).files '
              'if ".dist-info/licenses/" in str(p)] for name in sys.argv[1:]}}))')
    value = json.loads(subprocess.check_output([str(python), '-I', '-B', '-c', source, *DEPENDENCIES], text=True))
    if value['version'] < [3, 12] or value['dependencies'] != DEPENDENCIES:
        raise ValueError('Dedicated query worker requires Python >=3.12, NumPy2.5.1 and SentencePiece0.2.1')
    return value


def copy_licenses(python, notices):
    value = inspect_runtime(python)
    for name, files in value['licenses'].items():
        if not files:
            if name == 'sentencepiece':
                destination = notices / 'sentencepiece-licenses/LICENSE'
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / 'third_party/sentencepiece/LICENSE', destination)
                continue
            raise ValueError('Missing distribution licenses for ' + name)
        for file in files:
            source = Path(file)
            # Retain the complete NumPy vendor license hierarchy, not only its
            # top-level BSD notice. The source metadata comes from pinned wheels.
            parts = source.parts
            index = next(i for i, part in enumerate(parts) if part.endswith('.dist-info'))
            relative = Path(*parts[index + 2:])
            destination = notices / (name + '-licenses') / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    return value


def copy_runtime(source, target, notices):
    source = source.resolve(strict=True)
    python = source / 'bin/python3'
    value = inspect_runtime(python)
    if any(not Path(value[key]).resolve().is_relative_to(source) for key in ('base', 'stdlib')):
        raise ValueError('Use a standalone Python prefix, not a venv/system interpreter')
    shutil.copytree(source, target, symlinks=True,
        ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.a', 'test', 'tests'))
    for file in target.rglob('*'):
        if file.is_symlink() and not file.resolve().is_relative_to(target.resolve()):
            raise ValueError('Query Python symlink escapes package: ' + str(file))
    copy_licenses(target / 'bin/python3', notices)
    return value
