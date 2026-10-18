#!/usr/bin/env python3
"""Create and verify DMGs with identical packaging for previews and releases."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def create(app, manifest, name, output):
    if not re.fullmatch(r"Open-Foresight-[A-Za-z0-9.+_-]+-macos-arm64\.dmg", name):
        raise ValueError("Invalid DMG filename")
    output.mkdir(parents=True, exist_ok=True)
    destination = (output / name).resolve()
    if destination.exists():
        raise FileExistsError(destination)
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)],
        check=True,
        timeout=300,
    )
    with tempfile.TemporaryDirectory(prefix="foresight-dmg-") as directory:
        staging = Path(directory)
        subprocess.run(
            ["ditto", str(app), str(staging / "Open Foresight.app")],
            check=True,
            timeout=300,
        )
        (staging / "Applications").symlink_to("/Applications")
        subprocess.run(
            [
                "hdiutil",
                "create",
                "-volname",
                "Open Foresight",
                "-srcfolder",
                str(staging),
                "-format",
                "UDZO",
                str(destination),
            ],
            check=True,
            timeout=300,
        )
    subprocess.run(["hdiutil", "verify", str(destination)], check=True, timeout=300)
    with destination.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    Path(str(destination) + ".sha256").write_text(f"{digest}  {name}\n")
    shutil.copy2(manifest, Path(str(destination) + ".manifest.json"))
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--output", type=Path, default=Path("dist"))
    args = parser.parse_args()
    print(create(args.app, args.manifest, args.name, args.output))


if __name__ == "__main__":
    main()
