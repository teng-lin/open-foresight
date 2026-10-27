#!/usr/bin/env python3
"""Relocate the verified SDK's public Flutter-tool packages for a non-root gate."""

import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
from urllib.parse import unquote, urlparse


def physical(path):
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise ValueError("Flutter consumer paths must be physical and absolute")


def copy_package(source, destination):
    for parent, directories, files in os.walk(source, followlinks=False):
        for name in (*directories, *files):
            info = (Path(parent) / name).lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError("SDK tool package contains a link or special file")
    shutil.copytree(source, destination)


def prepare(workspace, flutter, *, source_cache=Path("/root/.pub-cache")):
    physical(workspace)
    physical(flutter)
    physical(source_cache)
    config = flutter / "packages/flutter_tools/.dart_tool/package_config.json"
    physical(config)
    before = config.read_bytes()
    record = json.loads(before)
    if record.get("configVersion") != 2 or not isinstance(record.get("packages"), list):
        raise ValueError("Invalid SDK tool package metadata")
    build = workspace / "build"
    physical(build)
    target = build / ".flutter-tool-pub"
    if target.exists() or target.is_symlink():
        raise ValueError("SDK tool consumer cache already exists")
    updated = copy.deepcopy(record)
    selected = []
    source_hosted = source_cache / "hosted/pub.dev"
    physical(source_hosted)
    for package in updated["packages"]:
        parsed = urlparse(package["rootUri"])
        if parsed.scheme not in ("", "file") or parsed.netloc:
            raise ValueError("SDK tool package must use a local root")
        path = Path(unquote(parsed.path))
        path = path if path.is_absolute() else config.parent / path
        resolved = path.resolve(strict=True)
        if resolved.is_relative_to(flutter):
            continue
        if (
            resolved.parent != source_hosted
            or path != resolved
            or not resolved.is_dir()
        ):
            raise ValueError("SDK tool package is outside the verified public cache")
        selected.append(resolved)
        package["rootUri"] = (target / "hosted/pub.dev" / resolved.name).as_uri()
    if not selected or len(set(selected)) != len(selected):
        raise ValueError("SDK tool cache must have unique public packages")
    target.mkdir(mode=0o700)
    hosted = target / "hosted/pub.dev"
    hosted.mkdir(parents=True)
    for source in selected:
        copy_package(source, hosted / source.name)
    # Only rootUri fields differ. Keep versions, language versions, generator,
    # lockfiles and original app cache untouched; no pub solver or network runs.
    if config.read_bytes() != before:
        raise ValueError("SDK tool metadata changed during cache preparation")
    descriptor, temporary = tempfile.mkstemp(prefix=".consumer-", dir=config.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            os.fchmod(stream.fileno(), stat.S_IMODE(config.stat().st_mode))
            json.dump(updated, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, config)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return len(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--flutter-root", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a non-root runtime wrapper command is required")
    count = prepare(args.workspace, args.flutter_root)
    print(json.dumps({"sdk_tool_packages_relocated": count}), flush=True)
    os.execvpe(command[0], command, os.environ)  # noqa: S606 - Fixed CI caller chains the identity-dropping wrapper.


if __name__ == "__main__":
    main()
