#!/usr/bin/env python3
"""Select and checksum-verify the immediately preceding published stable installer."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import api  # noqa: E402
from tools.release_asset_acceptance import select_asset, verify_checksum  # noqa: E402
from tools.release_latest import stable_version  # noqa: E402


def previous(repository, tag, kind):
    target = stable_version(tag)
    if target is None:
        raise ValueError("Upgrade acceptance requires a stable target version")
    eligible = []
    page = 1
    while True:
        batch = api(repository, f"releases?per_page=100&page={page}")
        for release in batch:
            version = stable_version(release.get("tag_name", ""))
            if (
                not release.get("draft")
                and not release.get("prerelease")
                and version is not None
                and version < target
            ):
                eligible.append((version, release))
        if len(batch) < 100:
            break
        page += 1
    if not eligible:
        raise ValueError(
            "No previous published stable release exists for upgrade acceptance"
        )
    version = max(item[0] for item in eligible)
    selected = [item[1] for item in eligible if item[0] == version]
    if len(selected) != 1:
        raise ValueError("Previous stable release is ambiguous")
    # Never silently skip a broken previous release in favor of an older one.
    select_asset(selected[0], kind)
    return selected[0]["tag_name"]


def prepare(repository, tag, kind, directory):
    selected = previous(repository, tag, kind)
    subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("release_asset_acceptance.py")),
            "--tag",
            selected,
            "--repo",
            repository,
            "--format",
            kind,
            "--directory",
            str(directory),
        ],
        check=True,
        timeout=900,
    )
    identity = json.loads((directory / "installer.json").read_text())
    if identity.get("tag") != selected or identity.get("status") != "verified_download":
        raise ValueError("Previous installer identity was not verified")
    return identity


def verified_pair(previous_directory, current_directory):
    """Check both immutable local installer identities before an upgrade executes."""
    identities = []
    for directory in (previous_directory, current_directory):
        identity = json.loads((directory / "installer.json").read_text())
        name = identity.get("asset", "")
        if (
            not name
            or Path(name).name != name
            or identity.get("status") != "verified_download"
            or stable_version(identity.get("tag", "")) is None
        ):
            raise ValueError("Upgrade requires verified stable installer identities")
        installer = directory / name
        if installer.is_symlink() or not installer.is_file():
            raise ValueError("Upgrade installer must be a regular downloaded file")
        checksum = verify_checksum(installer, Path(str(installer) + ".sha256"))
        if identity.get("sha256") != checksum:
            raise ValueError("Upgrade installer identity names different bytes")
        identities.append(identity)
    previous, current = identities
    kinds = (".deb", ".rpm", ".pkg.tar.zst", ".dmg")
    kind = next((suffix for suffix in kinds if current["asset"].endswith(suffix)), None)
    if (
        kind is None
        or not previous["asset"].endswith(kind)
        or stable_version(previous["tag"]) >= stable_version(current["tag"])
    ):
        raise ValueError(
            "Upgrade requires the same format from an earlier stable release"
        )
    return previous, current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--format", choices=("deb", "rpm", "arch", "dmg"), required=True
    )
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    print(
        json.dumps(
            prepare(
                os.environ["GITHUB_REPOSITORY"], args.tag, args.format, args.directory
            )
        )
    )


if __name__ == "__main__":
    main()
