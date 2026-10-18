#!/usr/bin/env python3
"""Package independent CI stages, preserving modes and validating restored trees."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE_PATHS = (
    "build/CMakeCache.txt",
    "build/CMakeFiles",
    "build/build.ninja",
    "build/.ninja_deps",
    "build/.ninja_log",
    "build/Makefile",
    "build/cmake_install.cmake",
    "build/CTestTestfile.cmake",
    "build/native",
    "build/services",
    "build/macos",
)


def roots(platform, stage):
    if platform not in ("linux", "macos"):
        raise ValueError("Unknown stage platform")
    if stage == "native":
        return NATIVE_PATHS
    if stage == "core":
        return (
            "build/application",
            "coverage/core",
            "test-results/build-gates/core.log",
        )
    if stage == "desktop":
        product = (
            "apps/desktop/build/macos/Build/Products/Release"
            if platform == "macos"
            else "apps/desktop/build/linux/x64/release/bundle"
        )
        return (product, "coverage/desktop", "test-results/build-gates/desktop.log")
    if stage == "service":
        return ("test-results/service", "test-results/desktop-service-integration.json")
    raise ValueError("Unknown build stage")


def allowed(name, platform, stage):
    path = PurePosixPath(name)
    return (
        not path.is_absolute()
        and ".." not in path.parts
        and any(
            name == base or name.startswith(base + "/")
            for base in roots(platform, stage)
        )
    )


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def entry(path, root):
    name = path.relative_to(root).as_posix()
    mode = path.lstat().st_mode & 0o777
    if path.is_symlink():
        target = os.readlink(path)
        resolved = (path.parent / target).resolve()
        if Path(target).is_absolute() or not resolved.is_relative_to(root.resolve()):
            raise ValueError(f"Stage symlink escapes workspace: {name}")
        return {"kind": "symlink", "mode": mode, "target": target}
    if path.is_file():
        return {"kind": "file", "mode": mode, "sha256": digest(path)}
    if path.is_dir():
        return {"kind": "directory", "mode": mode}
    raise ValueError(f"Unsupported stage file: {name}")


def content(root, platform, stage):
    record = {}
    for relative in roots(platform, stage):
        base = root / relative
        if not base.exists() and not base.is_symlink():
            continue
        paths = [base]
        if base.is_dir() and not base.is_symlink():
            paths.extend(base.rglob("*"))
        for path in paths:
            record[path.relative_to(root).as_posix()] = entry(path, root)
    if not record:
        raise ValueError("Stage produced no files")
    return dict(sorted(record.items()))


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


def pack(root, platform, stage, output):
    record = content(root, platform, stage)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "payload.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1, dereference=False) as stream:
        for name in record:
            stream.add(root / name, arcname="payload/" + name, recursive=False)
    manifest = {
        "files": record,
        "source_times": source_times(root) if stage == "native" else {},
    }
    (output / "content.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")
    return manifest


def unpack(root, platform, stage, archive, manifest):
    files = manifest.get("files")
    if (
        not isinstance(files, dict)
        or not files
        or any(not allowed(name, platform, stage) for name in files)
    ):
        raise ValueError("Unexpected stage manifest paths")
    root.mkdir(parents=True, exist_ok=True)
    # Validate all members before changing any build outputs.
    with tempfile.TemporaryDirectory(dir=root) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive) as stream:
            members = stream.getmembers()
            names = [m.name.removeprefix("payload/") for m in members]
            if (
                len(names) != len(set(names))
                or set(names) != set(files)
                or any(
                    not m.name.startswith("payload/")
                    or not allowed(name, platform, stage)
                    for m, name in zip(members, names, strict=True)
                )
            ):
                raise ValueError("Unexpected stage archive members")
            stream.extractall(staging, filter="data")
        payload = staging / "payload"
        for name, expected in files.items():
            mode = expected.get("mode")
            if type(mode) is not int or mode < 0 or mode > 0o777:
                raise ValueError(f"Unsafe stage file mode: {name}")
            if expected.get("kind") != "symlink":
                (payload / name).chmod(mode)
            if entry(payload / name, payload) != expected:
                raise ValueError(f"Stage content mismatch: {name}")
        # Validate existing destination links before changing any output. Never
        # chmod through a pre-existing directory symlink outside the stage.
        for name, expected in files.items():
            destination = root / name
            for parent in destination.parents:
                if parent == root:
                    break
                if parent.is_symlink():
                    raise ValueError(f"Stage destination traverses a symlink: {name}")
            if expected["kind"] == "directory" and destination.is_symlink():
                raise ValueError(f"Stage destination is a symlink: {name}")
        # Do not replace an unrelated directory (for example build/sdk).
        for name, expected in files.items():
            destination = root / name
            if expected["kind"] == "directory":
                destination.mkdir(parents=True, exist_ok=True)
                destination.chmod(expected["mode"])
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists() or destination.is_symlink():
                if destination.is_dir() and not destination.is_symlink():
                    raise ValueError(f"Stage file collides with directory: {name}")
                destination.unlink()
            (payload / name).rename(destination)
    for name, value in manifest.get("source_times", {}).items():
        path = root / name
        if (
            not isinstance(name, str)
            or PurePosixPath(name).is_absolute()
            or ".." in PurePosixPath(name).parts
        ):
            raise ValueError("Unsafe source timestamp path")
        if (
            path.resolve().is_relative_to(root.resolve())
            and path.is_file()
            and not path.is_symlink()
            and digest(path) == value["sha256"]
        ):
            os.utime(path, ns=(path.stat().st_atime_ns, value["mtime_ns"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("pack", "unpack"))
    parser.add_argument("--platform", choices=("linux", "macos"), required=True)
    parser.add_argument(
        "--stage", choices=("native", "core", "desktop", "service"), required=True
    )
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    if args.command == "pack":
        if not args.output:
            parser.error("pack requires --output")
        pack(args.root, args.platform, args.stage, args.output)
    else:
        if not args.archive or not args.manifest:
            parser.error("unpack requires --archive and --manifest")
        unpack(
            args.root,
            args.platform,
            args.stage,
            args.archive,
            json.loads(args.manifest.read_text()),
        )


if __name__ == "__main__":
    main()
