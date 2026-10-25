#!/usr/bin/env python3
"""Provision the immutable acceptance evidence archive outside the source tree.

The frozen failure baseline already pins the archive name and SHA-256; this
module adds only the commit whose raw GitHub URL serves those exact bytes.
Network access happens solely through the explicit ``--fetch`` mode. Test
consumers call ``verified_bytes``/``resolve``, which never fetch or run Git and
fail with the provisioning command when the asset is absent or tampered.
"""

import argparse
import contextlib
import hashlib
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Any, BinaryIO, Callable
import urllib.request

from tools import ci_acceptance_plan as acceptance

ROOT = Path(__file__).resolve().parents[1]

# Commit that added tests/fixtures/<archive>; commit-addressed raw URLs are
# immutable, and the baseline digest is verified regardless.
SOURCE_COMMIT = "053673dd9cf05d0df174cfbf9a1a01bfdef1eab3"
CACHE_ENV = "FORESIGHT_EVIDENCE_CACHE"
MAX_BYTES = 64 * 1024 * 1024
CHUNK = 1024 * 1024
FETCH_TIMEOUT = 300
COMMAND = "python -m tools.evidence_fixture --fetch"


class EvidenceError(ValueError):
    """The pinned evidence asset is unavailable, unsafe, or does not verify."""


def pin(root: Path = ROOT) -> dict[str, str]:
    """Reuse the checksum-verified baseline as the only digest authority."""
    baseline, _ = acceptance.failure_baseline(root)
    archive = baseline.get("evidence_archive") or {}
    name, digest = archive.get("path"), archive.get("sha256")
    if not (
        isinstance(name, str)
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz", name)
        and isinstance(digest, str)
        and re.fullmatch(r"[a-f0-9]{64}", digest)
    ):
        raise EvidenceError(
            "Frozen acceptance baseline lacks a pinned evidence archive"
        )
    return {
        "name": name,
        "sha256": digest,
        "url": "https://raw.githubusercontent.com/"
        f"{baseline['repository']}/{SOURCE_COMMIT}/tests/fixtures/{name}",
    }


def cache_dir(explicit: Path | None = None) -> Path:
    if explicit is not None:
        return explicit
    if value := os.environ.get(CACHE_ENV):
        return Path(value)
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "open-foresight" / "evidence"


def asset_path(pinned: dict[str, str], directory: Path) -> Path:
    # Content-addressed, so a committed copy under tests/fixtures never matches.
    return directory / f"{pinned['sha256']}-{pinned['name']}"


def _check_directory(directory: Path) -> None:
    info = directory.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise EvidenceError(
            f"Evidence cache {directory} must be a real directory, not a symlink"
        )
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise EvidenceError(
            f"Evidence cache {directory} must not be group- or world-writable"
        )


def _missing(pinned: dict[str, str], directory: Path) -> EvidenceError:
    return EvidenceError(
        f"Acceptance evidence {pinned['name']} is not provisioned in {directory}. "
        f"Run: {COMMAND} (network), or python -m tools.evidence_fixture "
        f"--archive PATH for a local copy of {pinned['url']}; set {CACHE_ENV} "
        "to choose the cache"
    )


def _open_regular(path: Path) -> BinaryIO:
    """Open without following symlinks and reject every non-regular file."""
    if not stat.S_ISREG(path.lstat().st_mode):
        raise EvidenceError(f"{path} must be a regular file, not a symlink")
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise EvidenceError(f"{path} must be a regular file: {error}") from error
    stream = os.fdopen(descriptor, "rb")
    if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
        stream.close()
        raise EvidenceError(f"{path} must be a regular file")
    return stream


def verified_bytes(root: Path = ROOT, cache: Path | None = None) -> bytes:
    """Return the provisioned archive bytes after verifying exactly those bytes."""
    pinned = pin(root)
    directory = cache_dir(cache)
    target = asset_path(pinned, directory)
    try:
        _check_directory(directory)
        stream = _open_regular(target)
    except FileNotFoundError as error:
        raise _missing(pinned, directory) from error
    with stream:
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES or hashlib.sha256(raw).hexdigest() != pinned["sha256"]:
        raise EvidenceError(
            f"Provisioned evidence {target} failed SHA-256 verification against the "
            f"frozen baseline; re-provision with: {COMMAND}"
        )
    return raw


def resolve(root: Path = ROOT, cache: Path | None = None) -> Path:
    verified_bytes(root, cache)
    return asset_path(pin(root), cache_dir(cache))


def _publish(source: BinaryIO, pinned: dict[str, str], directory: Path) -> Path:
    """Stream to a private temporary file and atomically publish only verified bytes."""
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    _check_directory(directory)
    descriptor, temporary = tempfile.mkstemp(prefix=".partial-", dir=directory)
    try:
        digest = hashlib.sha256()
        size = 0
        with os.fdopen(descriptor, "wb") as stream:
            while chunk := source.read(CHUNK):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise EvidenceError(f"Evidence source exceeds {MAX_BYTES} bytes")
                digest.update(chunk)
                stream.write(chunk)
            stream.flush()
            os.fsync(stream.fileno())
        if digest.hexdigest() != pinned["sha256"]:
            raise EvidenceError(
                f"Evidence source digest {digest.hexdigest()} does not match pinned "
                f"{pinned['sha256']}; nothing was published"
            )
        os.chmod(temporary, 0o444)
        os.replace(temporary, asset_path(pinned, directory))
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise
    return _verify_published(pinned, directory)


def _verify_published(pinned: dict[str, str], directory: Path) -> Path:
    target = asset_path(pinned, directory)
    with _open_regular(target) as stream:
        if hashlib.sha256(stream.read()).hexdigest() != pinned["sha256"]:
            raise EvidenceError(
                f"Published evidence {target} changed after verification"
            )
    return target


def provision_archive(
    source: Path, root: Path = ROOT, cache: Path | None = None
) -> Path:
    pinned = pin(root)
    with _open_regular(source) as stream:
        return _publish(stream, pinned, cache_dir(cache))


def _urlopen(url: str, timeout: float) -> Any:
    return urllib.request.urlopen(url, timeout=timeout)  # noqa: S310 - pinned https URL


def provision_fetch(
    root: Path = ROOT,
    cache: Path | None = None,
    opener: Callable[[str, float], Any] = _urlopen,
) -> Path:
    """Opt-in network provisioning from the pinned immutable commit URL."""
    pinned = pin(root)
    with contextlib.suppress(EvidenceError):
        return resolve(root, cache)
    with opener(pinned["url"], FETCH_TIMEOUT) as response:
        status = getattr(response, "status", None)
        if status != 200:
            raise EvidenceError(f"Evidence download returned HTTP {status}")
        return _publish(response, pinned, cache_dir(cache))


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--fetch", action="store_true", help="download the pinned commit URL (network)"
    )
    mode.add_argument("--archive", type=Path, help="verify and publish a local copy")
    mode.add_argument(
        "--check", action="store_true", help="verify an already provisioned asset"
    )
    parser.add_argument("--cache-dir", type=Path, help=f"overrides ${CACHE_ENV}")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        if args.fetch:
            path = provision_fetch(args.root, args.cache_dir)
        elif args.archive is not None:
            path = provision_archive(args.archive, args.root, args.cache_dir)
        else:
            path = resolve(args.root, args.cache_dir)
    except (EvidenceError, OSError) as error:
        raise SystemExit(f"evidence_fixture: {error}") from error
    print(path)


if __name__ == "__main__":
    main()
