#!/usr/bin/env python3
"""Create and verify DMGs with identical packaging for previews and releases."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def print_output(stdout, stderr):
    for output, stream in ((stdout, sys.stdout), (stderr, sys.stderr)):
        if output:
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
            print(output, end="", file=stream, flush=True)


def image_digest(destination):
    with destination.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def image_diagnostics(destination):
    # Capture owners while the failed image still exists. Suite-level
    # diagnostics run after TemporaryDirectory has removed fixture images.
    for command in (["/usr/sbin/lsof", str(destination)], ["hdiutil", "info"]):
        print(f"DMG failure diagnostic: {command!r}", file=sys.stderr, flush=True)
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            print(
                f"exit={result.returncode}\n{result.stdout[-20000:]}\n{result.stderr[-20000:]}",
                file=sys.stderr,
                flush=True,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Diagnostic unavailable: {error}", file=sys.stderr, flush=True)


def verify_image(destination):
    # DiskImages takes read/write locks on image files. A lock held after
    # creation can outlast the former four-second retry window. Give that lock
    # a bounded recovery window; verify the same bytes, never recreate them.
    original_digest = image_digest(destination) if destination.exists() else None
    deadline = time.monotonic() + 30
    last_failure = None
    while True:
        if original_digest is not None and image_digest(destination) != original_digest:
            raise ValueError("DMG bytes changed during verification retries")
        timeout: float = 300
        if last_failure is not None:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                last_failure.check_returncode()
        try:
            result = subprocess.run(
                ["hdiutil", "verify", str(destination)],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            print_output(error.stdout, error.stderr)
            raise
        print_output(result.stdout, result.stderr)
        if result.returncode == 0:
            if (
                original_digest is not None
                and image_digest(destination) != original_digest
            ):
                raise ValueError("DMG bytes changed during verification")
            return
        print(
            f"DMG verification failed: exit={result.returncode} sha256={original_digest}",
            file=sys.stderr,
            flush=True,
        )
        if (
            result.returncode != 1
            or "hdiutil: verify failed - Resource temporarily unavailable"
            not in result.stderr.splitlines()
        ):
            result.check_returncode()
        last_failure = result
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            result.check_returncode()
        delay = min(2, remaining)
        print(
            f"Disk image verification temporarily unavailable; retrying in {delay:g}s "
            f"({remaining:.1f}s recovery window remaining)",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(delay)
        if time.monotonic() >= deadline:
            result.check_returncode()


def create(app, manifest, name, output):
    if not re.fullmatch(r"Open-Foresight-[A-Za-z0-9.+_-]+-macos-arm64\.dmg", name):
        raise ValueError("Invalid DMG filename")
    metadata = json.loads(manifest.read_text())
    if (
        not re.fullmatch(r"[0-9a-f]{40}", metadata["revision"])
        or metadata["architecture"] != "arm64"
        or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", metadata["version"])
        or type(metadata["build_number"]) is not int
        or metadata["build_number"] < 1
    ):
        raise ValueError("DMG requires a complete arm64 application build identity")
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
    try:
        verify_image(destination)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        image_diagnostics(destination)
        raise
    with destination.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    Path(str(destination) + ".sha256").write_text(f"{digest}  {name}\n")
    shutil.copy2(manifest, Path(str(destination) + ".manifest.json"))
    Path(str(destination) + ".build.json").write_text(
        json.dumps(
            {
                "sha256": digest,
                "format": "dmg",
                "version": metadata["version"],
                "revision": metadata["revision"],
                "arch": metadata["architecture"],
                "build_number": metadata["build_number"],
            },
            indent=2,
        )
        + "\n"
    )
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
