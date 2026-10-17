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
    parser.add_argument('--embedding', type=Path, default=Path(os.environ.get('FORESIGHT_EMBEDDING', ROOT / 'models/local/embeddinggemma2/e7a8a2204b91/embeddinggemma-2-740m.litertlm')))
    parser.add_argument('--runner', type=Path, default=ROOT / 'build/services/inference/foresight-model')
    parser.add_argument('--bundle', type=Path, help='Test a relocated native library, helper and isolated runner')
    parser.add_argument('--report', type=Path, default=ROOT / 'test-results/gemma4-linux.json')
    args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else ROOT / 'dist/open-foresight'
    native_name = 'libforesight_native.dylib' if sys.platform == 'darwin' else 'libforesight_native.so'
    native = bundle / 'lib' / native_name if args.bundle else ROOT / 'build/native' / native_name
    runner = bundle / 'bin/foresight-model' if args.bundle else args.runner.resolve()
    worker = runner
    helper = bundle / 'bin/ForesightHelper' if args.bundle else ROOT / 'build/services/helper/ForesightHelper'
    library_name = 'liblitert-lm.dylib' if sys.platform == 'darwin' else 'liblitert-lm.so'
    library = bundle / 'lib' / library_name if args.bundle else ROOT / 'build/lib' / library_name
    if sys.platform == 'darwin':
        if args.bundle and bundle.suffix != '.app':
            parser.error('On macOS, --bundle must point to a packaged .app')
        if args.bundle:
            resources = bundle / 'Contents/Resources'
            import json
            config = json.loads((resources / 'runtime.json').read_text())
            required = ('FORESIGHT_NATIVE', 'FORESIGHT_HELPER',
                        'FORESIGHT_LITERT_RUNNER', 'FORESIGHT_MODEL_WORKER', 'FORESIGHT_LITERT_LIBRARY')
            missing = [key for key in required
                       if not isinstance(config.get(key), str) or not config[key]]
            if missing:
                parser.error('Bundle lacks required model runtime entries: ' + ', '.join(missing))
            def resource(key):
                return (resources / config[key]).resolve()
            native = resource('FORESIGHT_NATIVE')
            helper = resource('FORESIGHT_HELPER')
            runner = resource('FORESIGHT_LITERT_RUNNER')
            worker = resource('FORESIGHT_MODEL_WORKER')
            library = resource('FORESIGHT_LITERT_LIBRARY')
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
        'FORESIGHT_MODEL_WORKER': str(worker),
        'FORESIGHT_LITERT_LIBRARY': str(library),
        'FORESIGHT_EMBEDDING': str(args.embedding.resolve()),
        'FORESIGHT_GEMMA_REPORT': str(report),
        'LD_LIBRARY_PATH': str(bundle / 'lib'),
    })
    subprocess.run([args.flutter, 'test', '--no-pub', 'test/gemma_native_test.dart', '--reporter', 'expanded'],
                   cwd=ROOT / 'apps/desktop', env=env, check=True, timeout=510)


if __name__ == '__main__':
    main()
