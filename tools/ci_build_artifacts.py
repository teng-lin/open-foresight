#!/usr/bin/env python3
"""Retained compiler/artifact contracts, independent of cached test results."""

import importlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile

ci_git = importlib.import_module("tools.ci_git" if __package__ else "ci_git")
digest = ci_git.digest
source_times = ci_git.source_times
restore_source_times = ci_git.restore_source_times

ROOT = Path(__file__).resolve().parents[1]
NATIVE_PATHS = (
    "build/CMakeCache.txt",
    "build/CMakeFiles",
    "build/_deps",
    "build/Testing",
    "build/build.ninja",
    "build/.ninja_deps",
    "build/.ninja_log",
    "build/Makefile",
    "build/cmake_install.cmake",
    "build/CTestTestfile.cmake",
    "build/native",
    "build/services",
    "build/macos",
    "build/sdk/foresight-sdk.json",
    "build/sdk/share/foresight-sdk/licenses",
)


# Consumers execute these products; they never need CMake objects, third-party
# source/build trees or the compiler SDK. Keep only the SDK notices for packaging.
NATIVE_RUNTIME_PATHS = (
    "build/native/libforesight_native.so",
    "build/native/libforesight_native.dylib",
    "build/native/libforesight_sql_support.so",
    "build/native/libforesight_sql_support.dylib",
    "build/native/libforesight_diagnostic_support.so",
    "build/native/libforesight_diagnostic_support.dylib",
    "build/native/foresight-diagnostic-launcher",
    "build/native/diagnostic-native-inputs.json",
    "build/native/diagnostic-toolchain-metadata.json",
    "build/native/diagnostic-products.json",
    "build/native/foresight-audio",
    "build/services/helper/ForesightHelper",
    "build/services/helper/ForesightHelperTest",
    "build/services/helper/model_worker_fixture",
    "build/services/inference/foresight-model",
    "build/services/inference/foresight-query",
    "build/macos/foresight-notifications",
    "build/macos/foresight-file-parser",
    "build/macos/foresight-model-crypto",
    "build/macos/libforesight_sqlite3.dylib",
    "build/macos/foresight-sqlite3.json",
    "build/sdk/foresight-sdk.json",
    "build/sdk/share/foresight-sdk/licenses",
)


def roots(platform, stage):
    if platform not in ("linux", "macos"):
        raise ValueError("Unknown stage platform")
    if stage == "native":
        return (*NATIVE_PATHS, f"test-results/{platform}/native")
    if stage == "native-runtime":
        return NATIVE_RUNTIME_PATHS
    if stage == "core":
        return (
            "build/application",
            "coverage/core",
            "test-results/build-gates/core.log",
            f"test-results/{platform}/core",
        )
    if stage == "desktop":
        product = (
            "apps/desktop/build/macos/Build/Products/Release"
            if platform == "macos"
            else "apps/desktop/build/linux/x64/release/bundle"
        )
        return (
            product,
            "apps/desktop/coverage",
            "test-results/build-gates/desktop.log",
            f"test-results/{platform}/desktop",
        )
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
        # tarfile stores stat().st_mtime as a float. Its sub-microsecond rounding
        # invalidates Ninja's exact object-mtime dependency records on restore.
        "output_times": {
            name: (root / name).stat().st_mtime_ns
            for name, value in record.items()
            if stage == "native" and value["kind"] == "file"
        },
    }
    (output / "content.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")
    return manifest


def restore_legacy_ninja_times(root, files):
    """Repair only tar rounding in verified legacy objects, using Ninja's log.

    `-t deps` only reads the restored manifest/dependency database; it never runs
    a producer command or builds a target. Accept only listed regular objects
    whose dependency-record timestamp differs by less than one microsecond,
    the range explained by tar's floating-point round-trip.
    """
    if "build/.ninja_deps" not in files or "build/build.ninja" not in files:
        return
    result = subprocess.check_output(
        ["ninja", "-C", str(root / "build"), "-t", "deps"],
        text=True,
        timeout=30,
    )
    for line in result.splitlines():
        match = re.fullmatch(
            r"(.+): #deps [0-9]+, deps mtime ([0-9]+) \((?:VALID|STALE)\)", line
        )
        if not match:
            continue
        candidate = Path(match[1])
        path = candidate if candidate.is_absolute() else root / "build" / candidate
        if not path.resolve().is_relative_to(root.resolve()):
            continue
        name = path.relative_to(root).as_posix()
        if name not in files or files[name]["kind"] != "file" or path.is_symlink():
            continue
        expected = int(match[2])
        if 0 < expected < 2**63 and abs(path.stat().st_mtime_ns - expected) < 1000:
            os.utime(path, ns=(path.stat().st_atime_ns, expected))


def discard_unlisted_event_reports(root, platform, stage, files):
    """Prevent stale local reports from becoming evidence in a saved copy."""
    if stage not in ("core", "desktop"):
        return
    directory = root / f"test-results/{platform}/{stage}"
    for parent in (directory, *directory.parents):
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError("Stage event report directory traverses a symlink")
    stale = [
        path
        for path in directory.glob("*.events.jsonl")
        if path.relative_to(root).as_posix() not in files
    ]
    for path in stale:
        if path.is_dir() and not path.is_symlink():
            raise ValueError("Stage event report collides with a directory")
    for path in stale:
        path.unlink()


def unpack(root, platform, stage, archive, manifest, force_changed=False):
    files = manifest.get("files")
    if (
        not isinstance(files, dict)
        or not files
        or any(not allowed(name, platform, stage) for name in files)
    ):
        raise ValueError("Unexpected stage manifest paths")
    output_times = manifest.get("output_times", {})
    if not isinstance(output_times, dict) or any(
        name not in files
        or files[name].get("kind") != "file"
        or type(value) is not int
        or not 0 <= value < 2**63
        for name, value in output_times.items()
    ):
        raise ValueError("Invalid output timestamp inventory")
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
            if name in output_times:
                path = payload / name
                os.utime(path, ns=(path.stat().st_atime_ns, output_times[name]))
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
        discard_unlisted_event_reports(root, platform, stage, files)
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
    if stage == "native" and "output_times" not in manifest:
        restore_legacy_ninja_times(root, files)
    restore_source_times(root, manifest, force_changed)
