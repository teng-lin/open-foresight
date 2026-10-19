#!/usr/bin/env python3
"""Resolve immutable product inputs independently of the packaging controller."""

import argparse
from datetime import datetime
import json
import os
import re
import subprocess

from tools.ci_artifacts import api
from tools.github_release import release_for_tag
from tools.prepare_release import release_source
from tools.release_asset_acceptance import select_asset, source_revision


def resolve(repository, tag, control, generation=None, formats="all"):
    source = release_source(repository, tag, control)
    draft = release_for_tag(repository, tag)
    if not draft["draft"] or draft.get("target_commitish") != source:
        raise ValueError("Packaging requires the exact source-bound unpublished draft")
    markers = re.findall(
        r"<!-- foresight-package-release: ([0-9]+) -->", draft.get("body") or ""
    )
    if not markers or (
        generation is not None and generation != str(max(map(int, markers)))
    ):
        raise ValueError("Package generation differs from the current draft")
    commit = api(repository, f"commits/{source}")
    epoch = int(
        datetime.fromisoformat(
            commit["commit"]["committer"]["date"].replace("Z", "+00:00")
        ).timestamp()
    )
    selected = ["deb", "rpm", "arch"] if formats == "all" else [formats]
    missing = []
    suffixes = {"deb": ".deb", "rpm": ".rpm", "arch": ".pkg.tar.zst", "dmg": ".dmg"}
    for kind in selected:
        if kind not in suffixes:
            raise ValueError("Unknown installer format")
        if not any(asset["name"].endswith(suffixes[kind]) for asset in draft["assets"]):
            missing.append(kind)
            continue
        asset = select_asset(draft, kind)
        digest = asset.get("digest", "")
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError(
                "Existing installer has no verified API digest; inspect before repackaging"
            )
        metadata = next(
            item
            for item in draft["assets"]
            if item["name"] == asset["name"] + ".build.json"
        )
        raw = subprocess.check_output(
            [
                "gh",
                "api",
                "-H",
                "Accept: application/octet-stream",
                f"repos/{repository}/releases/assets/{metadata['id']}",
            ],
            timeout=60,
        )
        if (
            source_revision(json.loads(raw), kind, tag, digest.removeprefix("sha256:"))
            != source
        ):
            raise ValueError("Existing installer describes another product source")
    return {
        "source": source,
        "version": tag[1:],
        "release": str(max(map(int, markers))),
        "epoch": str(epoch),
        "formats": json.dumps(missing),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--generation")
    parser.add_argument(
        "--formats", default="all", choices=("all", "deb", "rpm", "arch", "dmg")
    )
    args = parser.parse_args()
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Packaging controller must run from reviewed main")
    control = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, timeout=30
    ).strip()
    values = resolve(
        os.environ["GITHUB_REPOSITORY"],
        args.tag,
        control,
        args.generation,
        args.formats,
    )
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
