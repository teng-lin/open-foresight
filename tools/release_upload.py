#!/usr/bin/env python3
"""Attach missing verified draft assets without replacing successful outputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from tools.ci_artifacts import api
from tools.github_release import release_for_tag
from tools.release_asset_acceptance import source_revision, verify_checksum


def upload(repository, tag, paths):
    release = release_for_tag(repository, tag)
    source = api(repository, f"commits/{tag}")["sha"]
    if not release["draft"] or release.get("target_commitish") != source:
        raise ValueError("Only the source-bound unpublished draft can receive assets")
    existing = {item["name"]: item for item in release["assets"]}
    pending = []
    names = set()
    for path in paths:
        if not path.is_file() or path.name in names:
            raise ValueError("Missing or duplicate package asset")
        names.add(path.name)
        for kind, suffix in {
            "deb": ".deb",
            "rpm": ".rpm",
            "arch": ".pkg.tar.zst",
            "dmg": ".dmg",
            "tar": ".tar.gz",
        }.items():
            if path.name.endswith(suffix):
                digest = verify_checksum(path, Path(str(path) + ".sha256"))
                metadata = json.loads(Path(str(path) + ".build.json").read_text())
                if source_revision(metadata, kind, tag, digest) != source:
                    raise ValueError("Installer differs from immutable release source")
        with path.open("rb") as stream:
            digest = "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
        if path.name in existing:
            asset = existing[path.name]
            remote = asset.get("digest")
            if not remote:
                with tempfile.TemporaryFile() as stream:
                    subprocess.run(
                        [
                            "gh",
                            "api",
                            "-H",
                            "Accept: application/octet-stream",
                            f"repos/{repository}/releases/assets/{asset['id']}",
                        ],
                        stdout=stream,
                        check=True,
                        timeout=300,
                    )
                    stream.seek(0)
                    remote = (
                        "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
                    )
            if remote != digest or asset["size"] != path.stat().st_size:
                raise ValueError(
                    f"Draft already contains different bytes: {path.name}; preserve them and select an explicit new package generation"
                )
            print(f"Retain identical published draft asset {path.name}", flush=True)
        else:
            pending.append(str(path))
    if pending:
        subprocess.run(
            ["gh", "release", "upload", tag, "--repo", repository, *pending],
            check=True,
            timeout=300,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    upload(os.environ["GITHUB_REPOSITORY"], args.tag, args.paths)


if __name__ == "__main__":
    main()
