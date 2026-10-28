#!/usr/bin/env python3
"""Create and verify DMGs with identical packaging for previews and releases."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
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


def _detach_created_image_once(destination, *, deadline):
    """Recover only the unique attachment of this invocation's new output."""
    timeout = 10 if deadline is None else min(10, deadline - time.monotonic())
    if timeout <= 0:
        return False
    try:
        result = subprocess.run(
            ["hdiutil", "info", "-plist"], capture_output=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as error:
        print_output(error.stdout, error.stderr)
        raise
    print_output(None, result.stderr)
    if result.returncode:
        print_output(result.stdout, None)
    result.check_returncode()
    info = plistlib.loads(result.stdout)
    if not isinstance(info, dict) or not isinstance(info.get("images"), list):
        raise ValueError("Invalid disk image attachment inventory")
    matches = [
        image
        for image in info["images"]
        if Path(image["image-path"]).resolve() == destination
    ]
    if not matches:
        return False
    devices = [
        entity["dev-entry"]
        for entity in matches[0]["system-entities"]
        if entity.get("content-hint") == "GUID_partition_scheme"
        and re.fullmatch(r"/dev/disk[0-9]+", entity.get("dev-entry", ""))
    ]
    # APFS also lists a synthesized whole disk. Select only its outer GUID
    # partition scheme, never a partition, APFS container, or guessed disk.
    if (
        len(matches) != 1
        or len(devices) != 1
        or matches[0].get("owner-uid") != os.getuid()
    ):
        raise ValueError("Ambiguous attachment for newly created DMG")
    timeout = 10 if deadline is None else min(10, deadline - time.monotonic())
    if timeout <= 0:
        return False
    print(
        f"Detaching newly created DMG {destination}: {devices[0]}",
        file=sys.stderr,
        flush=True,
    )
    try:
        detached = subprocess.run(
            ["hdiutil", "detach", devices[0]],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        print_output(error.stdout, error.stderr)
        raise
    print_output(detached.stdout, detached.stderr)
    detached.check_returncode()
    return True


def detach_created_image(destination, *, deadline=None):
    """Retry an owned device's busy refusal within the existing cleanup budget."""
    # The previous default allowed ten seconds each for inventory and detach.
    # Retries share that total; verification supplies its own existing deadline.
    if deadline is None:
        deadline = time.monotonic() + 20
    original_digest = image_digest(destination)
    while True:
        if image_digest(destination) != original_digest:
            raise ValueError("DMG bytes changed during attachment cleanup")
        try:
            detached = _detach_created_image_once(destination, deadline=deadline)
            if image_digest(destination) != original_digest:
                raise ValueError("DMG bytes changed during attachment cleanup")
            return detached
        except subprocess.CalledProcessError as error:
            command = error.cmd
            if (
                error.returncode <= 0
                or not isinstance(command, list)
                or len(command) != 3
                or command[:2] != ["hdiutil", "detach"]
                or not re.fullmatch(r"/dev/disk[0-9]+", command[2])
                or not isinstance(error.stderr, str)
                or error.stderr.strip()
                != f'hdiutil: couldn\'t eject "{Path(command[2]).name}" - Resource busy'
            ):
                raise
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise
            delay = min(2, remaining)
            print(
                f"Owned disk image is busy; rechecking attachment after {delay:g}s",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(delay)
            if time.monotonic() >= deadline:
                raise


def verify_image(destination, *, created_image=False):
    # DiskImages takes read/write locks on image files. A lock held after
    # creation can outlast the former four-second retry window. Give that lock
    # a bounded recovery window; verify the same bytes, never recreate them.
    destination = destination.resolve()
    original_digest = image_digest(destination) if destination.exists() else None
    deadline = time.monotonic() + 30
    last_failure = None
    detached = False
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
        if (
            created_image
            and not detached
            and detach_created_image(destination, deadline=deadline)
        ):
            detached = True
            continue
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


def signing_command(arguments, *, timeout=300, check=True):
    """Retain signing diagnostics, including partial output on timeout."""
    try:
        result = subprocess.run(
            [str(argument) for argument in arguments],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        print_output(error.stdout, error.stderr)
        raise
    print_output(result.stdout, result.stderr)
    if check:
        result.check_returncode()
    return result


def developer_id_team(path):
    """Read the team only from a Developer ID Application signature."""
    result = signing_command(["codesign", "-dv", "--verbose=4", path])
    details = result.stdout + result.stderr
    team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", details, re.M)
    if not team or not re.search(
        r"^Authority=Developer ID Application: .+$", details, re.M
    ):
        raise ValueError(f"Developer ID Application signature required: {path}")
    return team.group(1)


def notary_response(result, report):
    """Save raw diagnostics before validating JSON or propagating tool failures."""
    report.write_text(result.stdout)
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        result.check_returncode()
        raise
    if not isinstance(response, dict):
        result.check_returncode()
        raise ValueError("Notarization response must be a JSON object")
    return response


def sign_disk_image(destination, identity, notary_profile, app_team):
    """Sign and assess the image, retaining its submission before bounded polling."""
    signing_command(
        ["codesign", "--force", "--sign", identity, "--timestamp", destination]
    )
    signing_command(["codesign", "--verify", "--strict", destination])
    if developer_id_team(destination) != app_team:
        raise ValueError("DMG and application signing teams differ")
    deadline = time.monotonic() + 3600
    uploaded = signing_command(
        [
            "xcrun",
            "notarytool",
            "submit",
            destination,
            "--keychain-profile",
            notary_profile,
            "--no-wait",
            "--output-format",
            "json",
        ],
        timeout=3600,
        check=False,
    )
    receipt = Path(str(destination) + ".notary.submit.json")
    submission = notary_response(uploaded, receipt)
    uploaded.check_returncode()
    submission_id = submission.get("id")
    if not isinstance(submission_id, str) or not submission_id:
        raise ValueError("Notarization upload did not return a submission ID")
    remaining = deadline - time.monotonic()
    # Reserve time for notarytool to serialize its final response and exit.
    polling = min(3300, int(remaining) - 5)
    if polling <= 0:
        raise TimeoutError(
            f"Upload exhausted notarization budget; submission saved in {receipt}"
        )
    result = signing_command(
        [
            "xcrun",
            "notarytool",
            "wait",
            submission_id,
            "--keychain-profile",
            notary_profile,
            "--timeout",
            f"{polling}s",
            "--output-format",
            "json",
        ],
        timeout=remaining,
        check=False,
    )
    submission = notary_response(result, Path(str(destination) + ".notary.json"))
    if result.returncode or submission.get("status") != "Accepted":
        try:
            signing_command(
                [
                    "xcrun",
                    "notarytool",
                    "log",
                    submission_id,
                    "--keychain-profile",
                    notary_profile,
                    Path(str(destination) + ".notary.log.json"),
                ]
            )
        except (
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            OSError,
        ) as error:
            print(
                f"Notarization log unavailable: {error}",
                file=sys.stderr,
                flush=True,
            )
        result.check_returncode()
        raise ValueError(f"DMG notarization failed: {submission}")
    signing_command(["xcrun", "stapler", "staple", destination])
    signing_command(["xcrun", "stapler", "validate", destination])
    signing_command(
        [
            "spctl",
            "--assess",
            "--type",
            "open",
            "--context",
            "context:primary-signature",
            "--verbose=2",
            destination,
        ]
    )


def create(app, manifest, name, output, *, identity=None, notary_profile=None):
    if (identity is not None or notary_profile is not None) and (
        not identity or not notary_profile or identity == "-"
    ):
        raise ValueError(
            "Signed DMGs require both a Developer ID --identity and --notary-profile"
        )
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
    app_team = None
    if identity:
        if (
            metadata.get("signing") != "developer-id"
            or metadata.get("notarized") is not True
        ):
            raise ValueError(
                "Signed DMGs require a Developer ID signed and notarized application"
            )
        app_team = developer_id_team(app)
        signing_command(["xcrun", "stapler", "validate", app])
        signing_command(["spctl", "--assess", "--type", "execute", "--verbose=2", app])
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
        verify_image(destination, created_image=True)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
        image_diagnostics(destination)
        raise
    if identity:
        sign_disk_image(destination, identity, notary_profile, app_team)
        verify_image(destination)
    else:
        # Sign the container too; an ad-hoc signed app alone leaves its DMG
        # unsigned. This establishes no Developer ID identity or notarization.
        signing_command(
            [
                "codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                "io.openforesight.App.diskimage",
                destination,
            ]
        )
        signing_command(["codesign", "--verify", "--strict", destination])
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
    parser.add_argument(
        "--identity", help="Developer ID Application identity for the DMG"
    )
    parser.add_argument(
        "--notary-profile",
        help="Existing notarytool Keychain profile; requires --identity",
    )
    args = parser.parse_args()
    print(
        create(
            args.app,
            args.manifest,
            args.name,
            args.output,
            identity=args.identity,
            notary_profile=args.notary_profile,
        )
    )


if __name__ == "__main__":
    main()
