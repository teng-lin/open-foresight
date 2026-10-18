#!/usr/bin/env python3
"""Record the actual toolchain and runtime used to validate a CI stage."""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import json
import locale
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def validation_context(environment=None, now=None):
    """Bind process-sensitive validation inputs without publishing credentials."""
    environment = os.environ if environment is None else environment
    original = locale.setlocale(locale.LC_ALL)
    try:
        try:
            locale.setlocale(locale.LC_ALL, "")
            supported = True
        except locale.Error:
            supported = False
        effective_locale = locale.setlocale(locale.LC_ALL)
    finally:
        locale.setlocale(locale.LC_ALL, original)
    moment = now or datetime.now(timezone.utc)
    offset = moment.astimezone().utcoffset()
    return {
        "utc_validation_date": moment.astimezone(timezone.utc).date().isoformat(),
        "locale": {
            "effective": effective_locale,
            "requested_supported": supported,
            "environment": {
                key: value
                for key, value in environment.items()
                if key in ("LANG", "TZ") or key.startswith("LC_")
            },
        },
        "timezone": {
            "names": list(time.tzname),
            "standard_offset_seconds": time.timezone,
            "daylight_saving": time.daylight,
            "current_offset_seconds": None
            if offset is None
            else offset.total_seconds(),
        },
        "validation_environment_sha256": {
            key: hashlib.sha256(value.encode()).hexdigest()
            for key, value in environment.items()
            if key.startswith("FORESIGHT_")
            or key == "CI"
            or key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy")
        },
    }


def sdk_content_digest(prefix):
    """Hash actual compiler inputs, including modes and internal link targets.

    An immutable artifact receipt cannot detect a changed extracted SDK. Bind
    every file's bytes after extraction, and reject special files, dangling
    links, absolute links, or links resolving outside this SDK. Internal directory
    links are bound by their target plus the complete tree's regular-file hashes.
    """
    prefix = prefix.resolve(strict=True)
    if not prefix.is_dir():
        raise ValueError("SDK prefix must be a directory")
    entries = {}
    for path in [prefix, *sorted(prefix.rglob("*"))]:
        name = path.relative_to(prefix).as_posix()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if path.is_symlink():
            target = os.readlink(path)
            resolved = path.resolve(strict=True)
            if Path(target).is_absolute() or not resolved.is_relative_to(prefix):
                raise ValueError(f"SDK symlink escapes prefix: {name}")
            if not resolved.is_file() and not resolved.is_dir():
                raise ValueError(f"SDK symlink targets a special file: {name}")
            entries[name] = {
                "kind": "symlink",
                "mode": mode,
                "target": target,
                "resolved": resolved.relative_to(prefix).as_posix(),
            }
        elif stat.S_ISDIR(metadata.st_mode):
            entries[name] = {"kind": "directory", "mode": mode}
        elif stat.S_ISREG(metadata.st_mode):
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            entries[name] = {"kind": "file", "mode": mode, "sha256": digest}
        else:
            raise ValueError(f"SDK contains a special file: {name}")
    return hashlib.sha256(
        json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def version(command, required=False):
    if not shutil.which(command[0]):
        if required:
            raise RuntimeError(f"Missing stage tool: {command[0]}")
        return None
    return subprocess.check_output(
        command, text=True, stderr=subprocess.STDOUT, timeout=30
    ).strip()


def collect(platform_name, root=ROOT, sdk_prefix=None):
    if platform_name not in ("linux", "macos"):
        raise ValueError("Unknown stage platform")
    record = {
        "schema": 1,
        "platform": platform_name,
        "system": platform.platform(),
        "machine": platform.machine(),
        "workspace": str(root.resolve()),
        "python": sys.version,
        "compiler": version(["c++", "--version"], required=True),
        "cmake": version(["cmake", "--version"], required=True),
        "ninja": version(["ninja", "--version"], required=True),
        "dart": version(["dart", "--version"]),
        "flutter": version(["flutter", "--version", "--machine"]),
        "pins": json.loads((root / "tools/pins.json").read_text()),
        "base_image": os.environ.get("FORESIGHT_STAGE_BASE_IMAGE"),
        "packages": version(["pacman", "-Q"], required=True)
        if platform_name == "linux"
        else version(["brew", "list", "--versions"], required=True),
    }
    record.update(validation_context())
    if platform_name == "macos":
        record["apple_sdk"] = version(["xcrun", "--show-sdk-version"], required=True)
        record["xcode"] = version(["xcodebuild", "-version"], required=True)
    if sdk_prefix:
        artifacts = importlib.import_module(
            "tools.ci_artifacts" if __package__ else "ci_artifacts"
        )
        record["sdk"] = {
            "identity": artifacts.fingerprint("macos-sdk", root),
            "prefix": str(sdk_prefix.resolve()),
            "content_sha256": sdk_content_digest(sdk_prefix),
        }
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("linux", "macos"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk-prefix", type=Path)
    args = parser.parse_args()
    record = collect(args.platform, sdk_prefix=args.sdk_prefix)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
