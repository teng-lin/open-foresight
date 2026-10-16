#!/usr/bin/env python3
"""Run real local Gemma native/helper acceptance without account data."""
import argparse
import os
from pathlib import Path
import subprocess

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
    native = bundle / 'lib/libforesight_native.so' if args.bundle else ROOT / 'build/native/libforesight_native.so'
    runner = bundle / 'bin/foresight-model' if args.bundle else args.runner.resolve()
    worker = bundle / 'bin/foresight-model' if args.bundle else args.runner.resolve()
    report = args.report.resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({
        'FORESIGHT_GEMMA_TEST': '1',
        'FORESIGHT_EMBEDDING_GPU': '1' if args.embedding_gpu else '0',
        'FORESIGHT_NATIVE': str(native),
        'FORESIGHT_GEMMA_MODEL': str(args.model.resolve()),
        'FORESIGHT_LITERT_RUNNER': str(runner),
        'FORESIGHT_HELPER': str(bundle / 'bin/ForesightHelper'),
        'FORESIGHT_MODEL_WORKER': str(worker),
        'FORESIGHT_LITERT_LIBRARY': str(bundle / 'lib/liblitert-lm.so' if args.bundle else ROOT / 'build/lib/liblitert-lm.so'),
        'FORESIGHT_EMBEDDING': str(args.embedding.resolve()),
        'FORESIGHT_GEMMA_REPORT': str(report),
        'LD_LIBRARY_PATH': str(bundle / 'lib'),
    })
    subprocess.run([args.flutter, 'test', '--no-pub', 'test/gemma_native_test.dart', '--reporter', 'expanded'],
                   cwd=ROOT / 'apps/desktop', env=env, check=True, timeout=510)


if __name__ == '__main__':
    main()
