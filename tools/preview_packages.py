#!/usr/bin/env python3
"""Plan changes-only previews and stamp their immutable build identity."""

import argparse
import hashlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from tools.app_version import read_version, set_version, stale  # noqa: E402
from tools.build_sequence import allocate, request  # noqa: E402
from tools.ci_nightly import previous_nightly
from tools import ci_artifacts  # noqa: E402
from tools.release_asset_acceptance import verify_checksum  # noqa: E402

IDENTITY = ".distribution-build.json"


def preview_version(source, latest):
    current = tuple(map(int, source.split(".")))
    stable = tuple(map(int, latest.removeprefix("v").split("."))) if latest else None
    if stable is not None and current <= stable:
        return f"{stable[0]}.{stable[1]}.{stable[2] + 1}"
    return source


def plan(repository, force, validation, reason=""):
    if force and not reason.strip():
        raise ValueError(
            "A forced new preview identity requires an exact output-affecting rebuild reason"
        )
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Preview coordination requires reviewed main")
    commit = request(repository, "commits/main")["sha"]
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, timeout=30
    ).strip()
    if head != commit:
        raise ValueError("Main advanced before planning; retry the workflow")
    previous = previous_nightly(repository, commit, force, request=request)
    if previous:
        if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(summary, "a") as stream:
                stream.write(previous["summary"] + "\n")
        return {"build": "false", "source": commit, "validation": validation}
    if stale():
        raise ValueError("Source version copies are inconsistent")
    version, minimum = read_version()
    release = request(repository, "releases/latest", optional=True)
    version = preview_version(version, release["tag_name"] if release else None)
    if force:
        print("Explicit preview replacement reason: " + reason, flush=True)
    else:
        print(
            "No retained preview exists for this source. A new preview label/version changes embedded application metadata; reuse verified SDKs and native compiler outputs while building only this new distribution identity.",
            flush=True,
        )
    number = allocate(repository, minimum)
    date = datetime.now(timezone.utc).strftime("%Y%m%d")
    label = f"nightly.{date}.{number}"
    return {
        "build": "true",
        "source": commit,
        "version": version,
        "build_number": str(number),
        "label": label,
        "package_version": f"{version}~{label}",
        "validation": validation,
    }


def stamp(version, number, label="", source="", root=Path(".")):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or (
        label and not re.fullmatch(r"nightly\.\d{8}\.\d+", label)
    ):
        raise ValueError("Invalid distribution version or label")
    if label and int(label.rsplit(".", 1)[1]) != number:
        raise ValueError("Preview label must contain the allocated build number")
    if number <= read_version(root)[1] or (
        source and not re.fullmatch(r"[a-f0-9]{40}", source)
    ):
        raise ValueError(
            "Distribution build must increase and source must be an immutable SHA"
        )
    identity = {
        "version": version,
        "build_number": number,
        "label": label,
        "source_commit": source,
    }
    (root / IDENTITY).write_text(json.dumps(identity, indent=2) + "\n")
    set_version(version, number, root=root)
    return identity


EXTENSIONS = {
    "deb": ".deb",
    "rpm": ".rpm",
    "arch": ".pkg.tar.zst",
    "dmg": ".dmg",
    "tar": ".tar.gz",
}


def receipt(directory, kind, source):
    files = list(directory.glob("*" + EXTENSIONS[kind]))
    if len(files) != 1 or not re.fullmatch(r"[a-f0-9]{40}", source):
        raise ValueError("Expected one installer and an immutable source SHA")
    installer = files[0]
    digest = verify_checksum(installer, Path(str(installer) + ".sha256"))
    metadata = json.loads(Path(str(installer) + ".build.json").read_text())
    if metadata["revision"] != source:
        raise ValueError("Installer provenance does not match the pinned source")
    if metadata.get("sha256") != digest or metadata.get("format") != kind:
        raise ValueError("Installer provenance does not match its checksum or format")
    if kind == "dmg" and metadata.get("arch") != "arm64":
        raise ValueError("DMG provenance must describe an arm64 installer")
    result = {
        "asset": installer.name,
        "sha256": digest,
        "source_commit": source,
        "format": kind,
        "version": metadata["version"],
        "build_number": metadata["build_number"],
    }
    (directory / "installer.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def manifest(directory, version, number, label, source, validation):
    by_format = {
        kind: list(directory.rglob("*" + extension))
        for kind, extension in EXTENSIONS.items()
    }
    if len(by_format["arch"]) == 1:
        # make_arch retains this exact rebuild input beside its installer. It
        # remains in the file/checksum manifest, but is not a second installer.
        retained = by_format["arch"][0].parent / "arch-recipe/payload.tar.gz"
        by_format["tar"] = [path for path in by_format["tar"] if path != retained]
    receipts = []
    for kind, installers in by_format.items():
        if len(installers) != 1:
            raise ValueError(f"Missing or duplicate preview installer: {kind}")
        item = receipt(installers[0].parent, kind, source)
        expected_version = version if kind in ("dmg", "tar") else f"{version}~{label}"
        if item["version"] != expected_version:
            raise ValueError("Installer version differs from the preview identity")
        if item["build_number"] != number:
            raise ValueError("Installer build numbers differ across platforms")
        if kind == "tar":
            # Keep the exact numeric-version tar accepted by linux-test and
            # acceptance. Its verified preview receipt and stamp carry the label.
            parent = installers[0].parent
            stamp = parent / "distribution-stamp.json"
            qualification = parent / "source-qualification.json"
            distribution = {"version": version, "build_number": number}
            if any(
                path.is_symlink() or not path.is_file()
                for path in (stamp, qualification)
            ):
                raise ValueError(
                    "Portable preview requires its verified stamp and receipt"
                )
            original = json.loads(qualification.read_text()).get("source_receipt")
            if (
                json.loads(stamp.read_text())
                != {**distribution, "label": label, "source_commit": source}
                or not ci_artifacts.valid_receipt(original, "linux-app", source)
                or original.get("source_commit") != source
                or original.get("tier") != "preview"
                or original.get("label") != label
                or original.get("distribution") != distribution
            ):
                raise ValueError(
                    "Portable preview stamp or receipt differs from its identity"
                )
        receipts.append(item)
    result = {
        "source_commit": source,
        "version": version,
        "build_number": number,
        "label": label,
        "validation": validation,
        "full_model_cloud_acceptance": "passed" if validation == "full" else "not_run",
        "run_url": f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}",
        "installers": receipts,
        "files": [],
    }
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            result["files"].append(
                {"path": path.relative_to(directory).as_posix(), "sha256": digest}
            )
    (directory / "preview.json").write_text(json.dumps(result, indent=2) + "\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write(
                f"Preview `{version}-{label}` · build `{number}`\n\nSource: `{source}`\n\nValidation: **{validation}**. Full model/cloud acceptance: **{result['full_model_cloud_acceptance']}**.\n\n"
            )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan")
    planning.add_argument("--repository", required=True)
    planning.add_argument("--force", action="store_true")
    planning.add_argument("--rebuild-reason", default="")
    planning.add_argument(
        "--validation", choices=("standard", "full"), default="standard"
    )
    stamping = commands.add_parser("stamp")
    stamping.add_argument("--version", required=True)
    stamping.add_argument("--build-number", type=int, required=True)
    stamping.add_argument("--label", default="")
    stamping.add_argument("--source", default="")
    receiving = commands.add_parser("receipt")
    receiving.add_argument("--directory", type=Path, required=True)
    receiving.add_argument("--format", choices=tuple(EXTENSIONS), required=True)
    receiving.add_argument("--source", required=True)
    final = commands.add_parser("manifest")
    final.add_argument("--directory", type=Path, required=True)
    final.add_argument("--version", required=True)
    final.add_argument("--build-number", type=int, required=True)
    final.add_argument("--label", required=True)
    final.add_argument("--source", required=True)
    final.add_argument("--validation", choices=("standard", "full"), required=True)
    args = parser.parse_args()
    if args.command == "plan":
        result = plan(
            args.repository,
            args.force,
            args.validation,
            args.rebuild_reason,
        )
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")
        print(json.dumps(result, indent=2))
    elif args.command == "receipt":
        print(json.dumps(receipt(args.directory, args.format, args.source)))
    elif args.command == "manifest":
        print(
            json.dumps(
                manifest(
                    args.directory,
                    args.version,
                    args.build_number,
                    args.label,
                    args.source,
                    args.validation,
                )
            )
        )
    else:
        print(
            json.dumps(stamp(args.version, args.build_number, args.label, args.source))
        )


if __name__ == "__main__":
    main()
