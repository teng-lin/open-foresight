#!/usr/bin/env python3
"""Download and verify the pinned EmbeddingGemma 2 CPU/GPU fixture (~485 MB)."""
import argparse
from pathlib import Path

from build_macos_runtimes import download
from test_macos_release_models import MODELS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='Model cache directory')
    args = parser.parse_args()
    repository, revision, filename, checksum = MODELS['embedding']
    target = args.destination / filename
    download(f'https://huggingface.co/{repository}/resolve/{revision}/{filename}',
             target, checksum)
    print(target)


if __name__ == '__main__':
    main()
