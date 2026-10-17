#!/usr/bin/env python3
"""Prove the CI compiler/runtime rejects real address and UB failures."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

CASES = {
    'address': ('int main() { auto* value = new int(7); delete value; return *value; }', 'AddressSanitizer'),
    'undefined': ('int main() { volatile int value = 2147483647; return value + 1; }', 'runtime error: signed integer overflow'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='g++')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name, (code, diagnostic) in CASES.items():
        with tempfile.TemporaryDirectory() as directory:
            source, executable = Path(directory) / 'fault.cpp', Path(directory) / 'fault'
            source.write_text(code)
            subprocess.run([args.compiler, '-g', '-O0', '-fsanitize=address,undefined',
                            '-fno-omit-frame-pointer', '-fno-sanitize-recover=all',
                            str(source), '-o', str(executable)], check=True)
            environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:halt_on_error=1',
                               UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
            environment.pop('LD_PRELOAD', None)
            result = subprocess.run([str(executable)], capture_output=True, text=True,
                                    env=environment, timeout=20)
            (args.output / (name + '.log')).write_text(result.stdout + result.stderr)
            if result.returncode == 0 or diagnostic not in result.stderr:
                raise RuntimeError(name + ' sanitizer failed its fatal-report probe')
    print('ASan and UBSan both rejected their real invalid-memory/undefined-behavior probes.')


if __name__ == '__main__':
    main()
