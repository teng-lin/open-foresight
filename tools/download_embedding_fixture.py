#!/usr/bin/env python3
"""Download the pinned MiniLM embedding model and verify file hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'sentence-transformers/all-MiniLM-L6-v2'
REVISION = '1110a243fdf4706b3f48f1d95db1a4f5529b4d41'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    report = json.loads((ROOT / 'models/minilm-manifest.json').read_text())
    args.destination.mkdir(parents=True, exist_ok=True)
    for item in report['assets']:
        name = item['path']
        if name == 'asset-provenance.json':
            continue
        target = args.destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            staging = target.with_suffix(target.suffix + '.part')
            urllib.request.urlretrieve(
                f'https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}', staging)
            if hashlib.sha256(staging.read_bytes()).hexdigest() != item['sha256']:
                staging.unlink()
                raise RuntimeError(f'Asset hash mismatch: {name}')
            staging.replace(target)
        assert hashlib.sha256(target.read_bytes()).hexdigest() == item['sha256'], f'Hash mismatch: {name}'
        print(name)
    (args.destination / 'asset-provenance.json').write_text(json.dumps(
        {'repository': REPOSITORY, 'revision': REVISION,
         'files': [item['path'] for item in report['assets'] if item['path'] != 'asset-provenance.json']}, indent=2))

if __name__ == '__main__':
    main()
