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
from tools.preview_reuse import retained, recovery_identity, has_applications
from tools.release_asset_acceptance import verify_checksum  # noqa: E402

IDENTITY = ".distribution-build.json"


def preview_version(source, latest):
    current = tuple(map(int, source.split(".")))
    stable = tuple(map(int, latest.removeprefix("v").split("."))) if latest else None
    if stable is not None and current <= stable:
        return f"{stable[0]}.{stable[1]}.{stable[2] + 1}"
    return source


def plan(repository, force, validation, reason="", candidate_run=0):
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
    if candidate_run:
        run = request(repository, f"actions/runs/{candidate_run}")
        source = run["head_sha"]
        if request(repository, f"compare/{source}...{commit}")["status"] not in (
            "ahead",
            "identical",
        ):
            raise ValueError("Preview recovery source is not on reviewed main")
        return {
            **recovery_identity(repository, candidate_run, source),
            "validation": validation,
        }
    runs = request(
        repository,
        "actions/workflows/preview-packages.yml/runs?branch=main&per_page=100",
    )["workflow_runs"]
    matching = [
        run
        for run in runs
        if run["head_sha"] == commit and run["id"] < int(os.environ["GITHUB_RUN_ID"])
    ]
    existing = next(
        (
            run
            for run in matching
            if not force and retained(repository, run, request=request)
        ),
        None,
    )
    if matching and not existing and not force:
        recoverable = next(
            (
                run
                for run in matching
                if has_applications(repository, run, request=request)
            ),
            None,
        )
        if recoverable is not None:
            return {
                **recovery_identity(repository, recoverable["id"], commit),
                "validation": validation,
            }
        if any(run.get("status") != "completed" for run in matching):
            raise ValueError(
                "Preserve the running preview producer; wait for its outputs instead of starting a replacement"
            )
        for run in matching:
            items = request(
                repository, f"actions/runs/{run['id']}/artifacts?per_page=100"
            )["artifacts"]
            if any(not item.get("expired") for item in items):
                raise ValueError(
                    "No complete retained preview application pair is available. "
                    "Preserve partial outputs and inspect compatible artifacts "
                    "before requesting an explicit replacement with a rebuild reason."
                )
        print(
            f"Preview producers {[run['id'] for run in matching]} have no retained outputs. "
            "A replacement preview identity needs application bundles; retain compatible SDKs and compiler work.",
            flush=True,
        )
    if existing and not force:
        url = existing.get(
            "html_url", f"https://github.com/{repository}/actions/runs/{existing['id']}"
        )
        if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(summary, "a") as stream:
                stream.write(
                    f"No changes since a successful preview of `{commit}`. [Open its package downloads]({url}). Retained installers keep their original source, build number and checksums.\n"
                )
        return {
            "build": "false",
            "recovery_run": "0",
            "source": commit,
            "reuse_run": str(existing["id"]) if validation == "full" else "0",
            "validation": validation,
        }
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
        "recovery_run": "0",
        "reuse_run": "0",
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
    receipts = []
    for kind in EXTENSIONS:
        installers = list(directory.rglob("*" + EXTENSIONS[kind]))
        if len(installers) != 1:
            raise ValueError(f"Missing or duplicate preview installer: {kind}")
        item = receipt(installers[0].parent, kind, source)
        expected_version = version if kind == "dmg" else f"{version}~{label}"
        if item["version"] != expected_version:
            raise ValueError("Installer version differs from the preview identity")
        receipts.append(item)
    if any(item["build_number"] != number for item in receipts):
        raise ValueError("Installer build numbers differ across platforms")
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
    planning.add_argument("--candidate-run", type=int, default=0)
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
            args.candidate_run,
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
