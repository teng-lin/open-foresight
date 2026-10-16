#!/usr/bin/env python3
"""Run real local Gemma native/helper acceptance without account data."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--model', type=Path, default=ROOT / 'models/local/gemma4/gemma-4-E2B-it-181938105e0e/gemma-4-E2B-it.litertlm')
    parser.add_argument('--embedding-gpu', action='store_true')
    parser.add_argument('--embedding', type=Path, default=Path(os.environ.get('FORESIGHT_EMBEDDING', ROOT / 'models/local/all-MiniLM-L6-v2')))
    parser.add_argument('--python', type=Path, default=Path(os.environ.get('FORESIGHT_MODEL_PYTHON', ROOT / '.venv/bin/python')))
    parser.add_argument('--runner', type=Path, default=ROOT / 'models/local/native/litert-runner')
    parser.add_argument('--bundle', type=Path, help='Test a relocated native library, helper and isolated runner')
    parser.add_argument('--report', type=Path, default=ROOT / 'test-results/gemma4-linux.json')
    args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else ROOT / 'dist/open-foresight'
    native_name = 'libforesight_native.dylib' if sys.platform == 'darwin' else 'libforesight_native.so'
    native = bundle / 'lib' / native_name if args.bundle else ROOT / 'build/native' / native_name
    runner = bundle / 'share/open-foresight/litert-runner' if args.bundle else args.runner.resolve()
    adapter = bundle / 'share/open-foresight/model_adapter.py' if args.bundle else ROOT / 'services/helper/model_adapter.py'
    helper = bundle / 'bin/ForesightHelper' if args.bundle else ROOT / 'build/services/helper/ForesightHelper'
    embedding_adapter = ROOT / 'services/helper/litert_embedding_adapter.py'
    model_python = args.python.expanduser().absolute()
    if args.bundle and bundle.suffix == '.app':
        resources = bundle / 'Contents/Resources'
        import json
        config = json.loads((resources / 'runtime.json').read_text())
        def resource(key):
            return (resources / config[key]).resolve()
        native = resource('FORESIGHT_NATIVE')
        helper = resource('FORESIGHT_HELPER')
        runner = resource('FORESIGHT_LITERT_RUNNER')
        adapter = resource('FORESIGHT_MODEL_ADAPTER')
        embedding_adapter = resource('FORESIGHT_LITERT_EMBEDDING_ADAPTER')
        model_python = resource('FORESIGHT_MODEL_PYTHON')
    report = args.report.resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({
        'FORESIGHT_GEMMA_TEST': '1',
        'FORESIGHT_EMBEDDING_GPU': '1' if args.embedding_gpu else '0',
        'FORESIGHT_NATIVE': str(native),
        'FORESIGHT_GEMMA_MODEL': str(args.model.resolve()),
        'FORESIGHT_LITERT_RUNNER': str(runner),
        'FORESIGHT_HELPER': str(helper),
        'FORESIGHT_MODEL_ADAPTER': str(adapter),
        'FORESIGHT_MODEL_PYTHON': str(model_python),
        'FORESIGHT_LITERT_PYTHON': str(model_python),
        'FORESIGHT_LITERT_EMBEDDING_ADAPTER': str(embedding_adapter),
        'FORESIGHT_EMBEDDING': str(args.embedding.resolve()),
        'FORESIGHT_GEMMA_REPORT': str(report),
        'LD_LIBRARY_PATH': str(bundle / 'lib'),
    })
    subprocess.run([args.flutter, 'test', '--no-pub', 'test/gemma_native_test.dart', '--reporter', 'expanded'],
                   cwd=ROOT / 'apps/desktop', env=env, check=True, timeout=510)


if __name__ == '__main__':
    main()
