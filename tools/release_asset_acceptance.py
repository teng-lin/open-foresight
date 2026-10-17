#!/usr/bin/env python3
"""Download an exact published installer and verify its SHA-256 sidecar."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

SUFFIXES = {'deb': '.deb', 'rpm': '.rpm', 'arch': '.pkg.tar.zst', 'dmg': '.dmg'}


def select_asset(release, kind):
    matches = [a for a in release['assets'] if a['name'].endswith(SUFFIXES[kind])]
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one published {kind} installer')
    asset = matches[0]
    name = asset['name']
    if Path(name).name != name or not re.fullmatch(r'[A-Za-z0-9._+-]+', name):
        raise ValueError('Unsafe release asset filename')
    if not any(a['name'] == name + '.sha256' for a in release['assets']):
        raise ValueError('Published installer checksum is missing')
    return asset


def verify_checksum(package, sidecar):
    """Require the checksum to bind exactly this filename, then hash its bytes."""
    lines = Path(sidecar).read_text().splitlines()
    if len(lines) != 1:
        raise ValueError('Expected one installer checksum')
    fields = lines[0].split()
    if (len(fields) != 2 or fields[1].lstrip('*') != Path(package).name or
            not re.fullmatch(r'[0-9a-fA-F]{64}', fields[0])):
        raise ValueError('Checksum does not name the requested installer')
    with Path(package).open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual != fields[0].lower():
        raise ValueError('Published installer checksum mismatch')
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repo', default='teng-lin/open-foresight')
    parser.add_argument('--format', choices=SUFFIXES, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag):
        parser.error('Use an explicit stable release tag, for example v0.1.0')
    args.directory.mkdir(parents=True, exist_ok=True)
    (args.directory / 'installer.json').write_text(json.dumps({
        'tag': args.tag, 'format': args.format, 'status': 'failed',
        'stage': 'download_or_verification_not_completed'}, indent=2) + '\n')
    release = json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{args.repo}/releases/tags/{args.tag}']))
    if release['draft'] or release['tag_name'] != args.tag:
        raise ValueError('Acceptance requires the requested published release')
    asset = select_asset(release, args.format)
    args.directory.mkdir(parents=True, exist_ok=True)
    for name in (asset['name'], asset['name'] + '.sha256'):
        subprocess.run(['gh', 'release', 'download', args.tag, '--repo', args.repo,
                        '--pattern', name, '--dir', str(args.directory), '--clobber'], check=True)
    package = args.directory / asset['name']
    digest = verify_checksum(package, args.directory / (asset['name'] + '.sha256'))
    if package.stat().st_size != asset['size']:
        raise ValueError('Downloaded installer size differs from published asset')
    commit = json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{args.repo}/commits/{args.tag}']))['sha']
    report = {'tag': args.tag, 'release_id': release['id'], 'asset_id': asset['id'],
              'asset': asset['name'], 'sha256': digest, 'source_commit': commit,
              'release_url': release['html_url'], 'status': 'verified_download'}
    (args.directory / 'installer.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
