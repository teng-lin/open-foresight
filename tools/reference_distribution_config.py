#!/usr/bin/env python3
"""Import two app-bundled distribution settings from the verified reference build.

Only immutable executable bytes are read; profiles, accounts and Keychain are
never inspected. Values are written privately or piped to GitHub secrets, never
printed. The exact-build gate intentionally rejects other app versions.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

REFERENCE_SHA256 = 'fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326'
# Typed Dart pool reads, bound to IDA call sites in this exact executable.
SETTINGS = {
    'FORESIGHT_WEB_CONTENT_API_KEY': (9019, 0x5EF98B0),
    'FORESIGHT_SEARCH_API_KEY': (27425, 0x5BBCB80),
}


def read_configuration(app):
    binary = app / 'Contents/MacOS/Foresight' if app.suffix == '.app' else app
    data = binary.read_bytes()
    if hashlib.sha256(data).hexdigest() != REFERENCE_SHA256:
        raise ValueError('Reference build differs; retrace its configuration with IDA before importing')
    values = {}
    for name, (_, offset) in SETTINGS.items():
        raw = data[offset:offset + 39]
        if re.fullmatch(rb'AIza[0-9A-Za-z_-]{35}', raw) is None:
            raise ValueError('Verified reference setting has an unexpected representation')
        values[name] = raw.decode('ascii')
    return values


def write_private(path, values):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(values, stream)
        stream.write('\n')


def store_github(values, repository, gh):
    environment = dict(os.environ)
    environment.pop('GH_DEBUG', None)
    for name, value in values.items():
        result = subprocess.run([gh, 'secret', 'set', name, '--repo', repository],
                                input=value, text=True, capture_output=True, env=environment)
        if result.returncode:
            raise RuntimeError('GitHub secret update failed: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/Foresight.app'))
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument('--output', type=Path, help='New private runtime.json outside source control')
    destination.add_argument('--github-repository', help='Explicit owner/repo whose release secrets to update')
    parser.add_argument('--gh', default='gh')
    args = parser.parse_args()
    values = read_configuration(args.app)
    if args.output:
        write_private(args.output, values)
    else:
        store_github(values, args.github_repository, args.gh)
    print(json.dumps({'status': 'imported', 'settings': sorted(values),
                      'reference_sha256': REFERENCE_SHA256, 'values': 'suppressed'}))


if __name__ == '__main__':
    main()
