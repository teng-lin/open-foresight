#!/usr/bin/env python3
"""Choose Latest only for the highest published stable semantic version."""

import argparse
import json
from pathlib import Path
import re


def stable_version(tag):
    match = re.fullmatch(
        r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+[0-9A-Za-z.-]+)?", tag
    )
    return tuple(map(int, match.groups())) if match else None


def is_latest(tag, releases):
    version = stable_version(tag)
    if version is None:
        return False
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        published = stable_version(release["tag_name"])
        if published is not None and published > version:
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--releases", type=Path, required=True)
    args = parser.parse_args()
    pages = json.loads(args.releases.read_text())
    releases = [entry for page in pages for entry in page]
    print(str(is_latest(args.tag, releases)).lower())


if __name__ == "__main__":
    main()
