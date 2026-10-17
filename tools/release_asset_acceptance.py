#!/usr/bin/env python3
"""Download an exact published installer and verify its SHA-256 sidecar."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from github_release import release_for_tag

SUFFIXES = {"deb": ".deb", "rpm": ".rpm", "arch": ".pkg.tar.zst", "dmg": ".dmg"}


def provenance_name(asset, kind):
    return asset["name"] + (".manifest.json" if kind == "dmg" else ".build.json")


def named_asset(release, name):
    matches = [asset for asset in release["assets"] if asset["name"] == name]
    if len(matches) != 1:
        raise ValueError("Expected exactly one published asset: " + name)
    return matches[0]


def select_asset(release, kind):
    matches = [a for a in release["assets"] if a["name"].endswith(SUFFIXES[kind])]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one published {kind} installer")
    asset = matches[0]
    name = asset["name"]
    if Path(name).name != name or not re.fullmatch(r"[A-Za-z0-9._+-]+", name):
        raise ValueError("Unsafe release asset filename")
    named_asset(release, name + ".sha256")
    named_asset(release, provenance_name(asset, kind))
    return asset


def verify_checksum(package, sidecar):
    """Require the checksum to bind exactly this filename, then hash its bytes."""
    lines = Path(sidecar).read_text().splitlines()
    if len(lines) != 1:
        raise ValueError("Expected one installer checksum")
    fields = lines[0].split()
    if (
        len(fields) != 2
        or fields[1].lstrip("*") != Path(package).name
        or not re.fullmatch(r"[0-9a-fA-F]{64}", fields[0])
    ):
        raise ValueError("Checksum does not name the requested installer")
    with Path(package).open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != fields[0].lower():
        raise ValueError("Published installer checksum mismatch")
    return actual


def source_revision(metadata, kind, tag, installer_digest):
    """Bind Linux build provenance to these exact installer bytes, not the tag HEAD."""
    if not isinstance(metadata, dict):
        raise ValueError("Installer provenance must be an object")
    revision = metadata.get("revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Installer provenance requires a full source commit")
    if kind == "dmg":
        if metadata.get("architecture") != "arm64":
            raise ValueError(
                "DMG provenance must describe the published arm64 installer"
            )
    elif (
        metadata.get("sha256") != installer_digest
        or metadata.get("format") != kind
        or metadata.get("version") != tag[1:]
    ):
        raise ValueError(
            "Build provenance does not match the installer checksum, format or release version"
        )
    return revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--allow-draft",
        action="store_true",
        help="Validate unpublished release candidates",
    )
    parser.add_argument(
        "--allow-recovery-revision",
        action="store_true",
        help="Explicitly audit a historical installer built from a different commit",
    )
    parser.add_argument("--repo", default="teng-lin/open-foresight")
    parser.add_argument("--format", choices=SUFFIXES, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
        parser.error("Use an explicit stable release tag, for example v0.1.0")
    args.directory.mkdir(parents=True, exist_ok=True)
    (args.directory / "installer.json").write_text(
        json.dumps(
            {
                "tag": args.tag,
                "format": args.format,
                "status": "failed",
                "stage": "download_or_verification_not_completed",
            },
            indent=2,
        )
        + "\n"
    )
    release = release_for_tag(args.repo, args.tag)
    if (release["draft"] and not args.allow_draft) or release["tag_name"] != args.tag:
        raise ValueError("Acceptance requires the requested published release")
    asset = select_asset(release, args.format)
    args.directory.mkdir(parents=True, exist_ok=True)
    metadata_name = provenance_name(asset, args.format)
    metadata_asset = named_asset(release, metadata_name)
    for name in (asset["name"], asset["name"] + ".sha256", metadata_name):
        subprocess.run(
            [
                "gh",
                "release",
                "download",
                args.tag,
                "--repo",
                args.repo,
                "--pattern",
                name,
                "--dir",
                str(args.directory),
                "--clobber",
            ],
            check=True,
            timeout=300,
        )
    package = args.directory / asset["name"]
    digest = verify_checksum(package, args.directory / (asset["name"] + ".sha256"))
    if package.stat().st_size != asset["size"]:
        raise ValueError("Downloaded installer size differs from published asset")
    metadata_path = args.directory / metadata_name
    if metadata_path.stat().st_size != metadata_asset["size"]:
        raise ValueError("Downloaded provenance size differs from published asset")
    commit = source_revision(
        json.loads(metadata_path.read_text()), args.format, args.tag, digest
    )
    tag_commit = json.loads(
        subprocess.check_output(
            ["gh", "api", f"repos/{args.repo}/commits/{args.tag}"], timeout=300
        )
    )["sha"]
    if commit != tag_commit and not args.allow_recovery_revision:
        raise ValueError("Installer source revision differs from release tag commit")
    if commit != tag_commit:
        resolved = json.loads(
            subprocess.check_output(
                ["gh", "api", f"repos/{args.repo}/commits/{commit}"], timeout=300
            )
        )["sha"]
        if resolved != commit:
            raise ValueError(
                "Installer provenance source commit is not valid in this repository"
            )
    report = {
        "tag": args.tag,
        "release_id": release["id"],
        "asset_id": asset["id"],
        "asset": asset["name"],
        "sha256": digest,
        "source_commit": commit,
        "release_tag_commit": tag_commit,
        "recovery_revision": commit != tag_commit,
        "provenance_asset": metadata_name,
        "provenance_asset_id": metadata_asset["id"],
        "provenance_sha256": hashlib.sha256(metadata_path.read_bytes()).hexdigest(),
        "release_url": release["html_url"],
        "status": "verified_download",
    }
    (args.directory / "installer.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
