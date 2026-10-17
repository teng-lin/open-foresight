#!/usr/bin/env python3
"""Distinguish a missing dependency image from registry/authentication failures."""
import argparse
import json
import os
import re
import subprocess


def inspect(image):
    result = subprocess.run(['docker', 'buildx', 'imagetools', 'inspect', image,
                             '--format', '{{json .Manifest}}'], capture_output=True, text=True)
    if result.returncode:
        error = result.stderr.lower()
        if any(x in error for x in ('unauthorized', 'denied', 'forbidden', '401', '403')):
            raise RuntimeError('Registry authentication/authorization failed; refusing a cold build')
        if any(x in error for x in ('manifest unknown', 'name unknown',
                                     image.lower() + ': not found')):
            if '@' in image:
                raise RuntimeError('Qualified dependency digest is unavailable; restore it with the producer')
            return None
        raise RuntimeError('Registry lookup failed; refusing to treat a transport error as a cache miss')
    digest = json.loads(result.stdout)['digest']
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', digest):
        raise ValueError('Registry returned an invalid immutable digest')
    return image.split('@')[0].split(':')[0] + '@' + digest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--require', action='store_true')
    args = parser.parse_args()
    image = inspect(args.image)
    if args.require and image is None:
        raise SystemExit('Producer did not publish its promised dependency image')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write('build=' + str(image is None).lower() + '\n')
        if image:
            stream.write('image=' + image + '\n')
    print('Verified immutable dependency image available.' if image else 'Dependency image absent: one producer build is required.')
