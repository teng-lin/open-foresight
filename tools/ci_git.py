#!/usr/bin/env python3
"""Retained Git/archive primitives; never reuse a prior validation result.

Legacy stage callers import these same functions while their rollout gates remain
active. Sanitizer and application artifact consumers do not depend on stage-result
cache machinery. Full archive membership, checksum and timestamp checks survive
that machinery's eventual retirement.
"""

import hashlib
import importlib
import json
import os
from pathlib import PurePosixPath
import re
import shutil
import stat
import subprocess
import time
import zipfile

timing = importlib.import_module("tools.ci_timing" if __package__ else "ci_timing")
COMMIT = r"[a-f0-9]{40}"
MAX_STAGE_RECEIPT_BYTES = 16 * 1024 * 1024


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, timeout=120)


def ensure_commit(root, commit):
    if not re.fullmatch(COMMIT, commit):
        raise ValueError("Invalid producer source commit")
    try:
        git(root, "cat-file", "-e", commit + "^{commit}")
    except subprocess.CalledProcessError:
        subprocess.run(
            ["git", "fetch", "--no-tags", "origin", commit],
            cwd=root,
            check=True,
            timeout=300,
        )
        git(root, "cat-file", "-e", commit + "^{commit}")


@timing.phase("stage archive verification and extraction")
def read_zip(path, destination=None):
    """Read exactly the expected two flat regular files, with bounded receipt."""
    with zipfile.ZipFile(path) as stream:
        if sorted(stream.namelist()) != ["identity.json", "payload.tar.gz"]:
            raise ValueError("Unexpected stage artifact members")
        receipt_info = stream.getinfo("identity.json")
        if receipt_info.file_size > MAX_STAGE_RECEIPT_BYTES:
            raise ValueError("Stage receipt too large")
        for entry in stream.infolist():
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG) or entry.is_dir():
                raise ValueError("Stage artifact members must be regular files")
        try:
            receipt = json.loads(stream.read(receipt_info))
        except json.JSONDecodeError as error:
            raise ValueError("Invalid cached stage receipt JSON") from error
        # Do not trust a receipt's checksum without reading the actual payload.
        with (
            timing.phase("stage payload checksum verification"),
            stream.open("payload.tar.gz") as payload,
        ):
            digest = hashlib.sha256()
            while block := payload.read(1024 * 1024):
                digest.update(block)
            checksum = digest.hexdigest()
            if not isinstance(receipt, dict) or receipt.get("sha256") != checksum:
                raise ValueError("Stage payload checksum mismatch")
        if destination:
            with timing.phase("stage ZIP payload extraction"):
                destination.mkdir(parents=True, exist_ok=False)
                for member in ("identity.json", "payload.tar.gz"):
                    with (
                        stream.open(member) as source,
                        (destination / member).open("wb") as target,
                    ):
                        shutil.copyfileobj(source, target)
        return receipt


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_times(root):
    """Restore unchanged source mtimes so Ninja can reuse checked object files."""
    names = (
        subprocess.check_output(["git", "ls-files", "-z"], cwd=root, timeout=30)
        .decode()
        .split("\0")
    )
    return {
        name: {
            "sha256": digest(root / name),
            "mtime_ns": (root / name).stat().st_mtime_ns,
        }
        for name in names
        if name and (root / name).is_file() and not (root / name).is_symlink()
    }


def restore_source_times(root, manifest, force_changed=False):
    """Keep unchanged objects warm without hiding changed old-mtime sources."""
    previous = manifest.get("source_times", {})
    if not isinstance(previous, dict):
        raise ValueError("Invalid source timestamp inventory")
    for name, value in previous.items():
        if (
            not isinstance(name, str)
            or PurePosixPath(name).is_absolute()
            or ".." in PurePosixPath(name).parts
            or not isinstance(value, dict)
            or not isinstance(value.get("sha256"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", value["sha256"])
            or type(value.get("mtime_ns")) is not int
            or not 0 <= value["mtime_ns"] < 2**63
        ):
            raise ValueError("Unsafe source timestamp entry")
        path = root / name
        if (
            path.resolve().is_relative_to(root.resolve())
            and path.is_file()
            and not path.is_symlink()
            and digest(path) == value["sha256"]
        ):
            os.utime(path, ns=(path.stat().st_atime_ns, value["mtime_ns"]))
    if not force_changed:
        return
    current = source_times(root)
    changed = [
        name
        for name, value in current.items()
        if previous.get(name, {}).get("sha256") != value["sha256"]
    ]
    if not changed:
        return
    # A checkout can deliberately preserve an old mtime for different bytes.
    # Touch every changed/new source after all restored outputs, including on
    # filesystems/tools that compare whole seconds. Avoid future CMake inputs:
    # they can otherwise cause an endless build.ninja regeneration loop.
    latest = max(
        (
            (root / name).stat().st_mtime_ns
            for name, value in manifest["files"].items()
            if value["kind"] == "file"
        ),
        default=0,
    )
    minimum = (latest // 1_000_000_000 + 1) * 1_000_000_000
    delay = (minimum - time.time_ns()) / 1_000_000_000
    if delay > 2:
        raise ValueError("Native cache has output timestamps in the future")
    if delay > 0:
        time.sleep(delay)
    stamp = time.time_ns()
    for name in changed:
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("Changed source escapes workspace")
        os.utime(path, ns=(path.stat().st_atime_ns, stamp))
        if path.stat().st_mtime_ns <= latest:
            raise ValueError("Cannot make changed source newer than cached outputs")

