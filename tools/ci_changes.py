#!/usr/bin/env python3
"""Select expensive CI only for changes that can affect application outputs."""
import argparse
import json
import os
from pathlib import PurePosixPath
import subprocess


def requires_build(paths):
    return any(not (path.startswith('docs/') or PurePosixPath(path).suffix == '.md' or
                   path.startswith('.github/ISSUE_TEMPLATE/')) for path in paths)


def check_gates(jobs, build, main):
    """A skipped selected job is a failure, including after dependency failures."""
    expected = {'changes': 'success', 'macos': 'success' if build else 'skipped',
                'linux-native': 'success' if build else 'skipped',
                'linux-bundle': 'success' if build and main else 'skipped'}
    for name, result in expected.items():
        if jobs.get(name, {}).get('result') != result:
            raise ValueError(f'{name}: expected {result}, got {jobs.get(name, {}).get("result")}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base')
    parser.add_argument('--check-gates', action='store_true')
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    if args.check_gates:
        check_gates(json.loads(os.environ['NEEDS']), os.environ['BUILD'] == 'true',
                    os.environ['MAIN'] == 'true')
        print('All selected platform gates passed.')
        return
    if not args.base:
        parser.error('--base is required for change classification')
    base = args.base
    if not base.strip('0'):
        base = subprocess.check_output(['git', 'hash-object', '-t', 'tree', '/dev/null'], text=True).strip()
    paths = subprocess.check_output(['git', 'diff', '--name-only', '-z', base, 'HEAD']).decode().split('\0')
    subprocess.run(['git', 'diff', '--check', base, 'HEAD'], check=True)
    build = args.force or requires_build([path for path in paths if path])
    print(f'Application/native checks required: {build}')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'build={str(build).lower()}\n')


if __name__ == '__main__':
    main()
