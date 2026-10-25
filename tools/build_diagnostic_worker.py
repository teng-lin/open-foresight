#!/usr/bin/env python3
"""Compile the closed standalone worker; emit exact bytes and public Dart defines."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from typing import Any

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import diagnostic_build_identity as identity
from tools import diagnostic_worker_context as context


def definitions(
    root: Path, build: Path, sdk: Path, config: Path, manifest: dict[str, Any]
) -> dict[str, str]:
    mode = manifest["record"]["mode"]
    return {
        "FORESIGHT_DIAGNOSTIC_NATIVE_ID": manifest["record"]["native_id"],
        "FORESIGHT_DIAGNOSTIC_BUILD_ID": manifest["worker_id"],
        "FORESIGHT_DIAGNOSTIC_CATALOG_ID": manifest["catalog_id"],
        "FORESIGHT_DIAGNOSTIC_WORKER_MODE": mode,
        "FORESIGHT_DIAGNOSTIC_TEST_CONTEXT": "true",
        "FORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR": str(root),
        "FORESIGHT_DIAGNOSTIC_BUILD_ROOT": str(build),
        "FORESIGHT_DIAGNOSTIC_DART_EXECUTABLE": str(sdk / "bin/dart"),
        "FORESIGHT_DIAGNOSTIC_DART_SDK_ROOT": str(sdk),
        "FORESIGHT_DIAGNOSTIC_DART_SDK_ID": identity._digest(manifest["record"]["sdk"]),
        "FORESIGHT_DIAGNOSTIC_PACKAGE_CONFIG": str(config),
        "FORESIGHT_DIAGNOSTIC_SOURCE_WORKER": str(root / context.ENTRY),
        "FORESIGHT_DIAGNOSTIC_KERNEL_WORKER": str(
            build / "application/diagnostic-worker.dill"
        ),
    }


def _copy(root: Path, name: str, destination: Path, expected: str) -> None:
    name = identity._worker_path(name)
    directory = context._anchor(root)
    descriptor = -1
    try:
        parts = name.split("/")
        for part in parts[:-1]:
            child = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=directory,
            )
            os.close(directory)
            directory = child
        descriptor = os.open(
            parts[-1],
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=directory,
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or before.st_size > 16 * 1024 * 1024
        ):
            raise identity.IdentityError("unsafe_worker_snapshot_input")
        destination.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        size = 0
        with destination.open("xb") as output:
            while chunk := os.read(descriptor, 65536):
                size += len(chunk)
                if size > 16 * 1024 * 1024:
                    raise identity.IdentityError("oversized_worker_snapshot_input")
                digest.update(chunk)
                output.write(chunk)
        after = os.fstat(descriptor)
        fields = (
            "st_dev",
            "st_ino",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
            "st_mode",
            "st_uid",
            "st_nlink",
        )
        if (
            size != before.st_size
            or any(getattr(before, f) != getattr(after, f) for f in fields)
            or digest.hexdigest() != expected
        ):
            raise identity.IdentityError("worker_snapshot_changed")
        destination.chmod(0o644)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(directory)


def build_worker(
    root: Path, build: Path, sdk: Path, config: Path, mode: str
) -> dict[str, Any]:
    root, build, sdk, config = (p.absolute() for p in (root, build, sdk, config))
    anchor = context._anchor(build / "native")
    os.close(anchor)
    output = build / "application"
    if output.is_symlink():
        raise identity.IdentityError("unsafe_worker_output")
    output.mkdir(parents=True, mode=0o700, exist_ok=True)
    mode_bits = output.stat().st_mode
    if mode_bits & 0o022 or output.stat().st_uid != os.geteuid():
        raise identity.IdentityError("unsafe_worker_output")
    metadata = output / "diagnostic-worker-build.json"
    metadata.unlink(missing_ok=True)
    worker_inputs = build / "native/diagnostic-worker-inputs.json"
    worker_inputs.unlink(missing_ok=True)
    worker_inputs.write_bytes(b'{"schema":1,"available":false}\n')
    manifest = context.collect(root, build / "native", sdk, config, mode)
    defines = definitions(root, build, sdk, config, manifest)
    if mode == "jit":
        artifact = None
    else:
        filename = (
            "foresight-diagnostic-worker" if mode == "aot" else "diagnostic-worker.dill"
        )
        target = output / filename
        if target.is_symlink():
            raise identity.IdentityError("unsafe_worker_output")
        packages, languages = context.package_roots(config, root)
        # The compiler sees only this private snapshot of the classified owned
        # graph and its six public packages, never the application's resolver.
        with tempfile.TemporaryDirectory(prefix="worker-", dir=output) as temporary:
            snapshot = Path(temporary)
            for name, expected in manifest["record"]["inputs"].items():
                _copy(root, name, snapshot / "source" / name, expected)
            entries = [
                {
                    "name": "foresight_core",
                    "rootUri": (snapshot / "source" / context.CORE).as_uri(),
                    "packageUri": "lib/",
                    "languageVersion": "3.8",
                }
            ]
            for package, selected in packages.items():
                destination = snapshot / "pub-cache/hosted/pub.dev" / selected.name
                for name, expected in manifest["record"]["packages"][package][
                    "inputs"
                ].items():
                    _copy(selected, name, destination / name, expected)
                entries.append(
                    {
                        "name": package,
                        "rootUri": destination.as_uri(),
                        "packageUri": "lib/",
                        "languageVersion": languages[package],
                    }
                )
            resolver = snapshot / "package_config.json"
            resolver.write_bytes(
                identity._canonical({"configVersion": 2, "packages": entries}) + b"\n"
            )
            staged = snapshot / filename
            command = [
                str(sdk / "bin/dart"),
                "compile",
                "exe" if mode == "aot" else "kernel",
                f"--packages={resolver}",
                *[f"-D{name}={value}" for name, value in sorted(defines.items())],
                "-o",
                str(staged),
                str(snapshot / "source" / context.ENTRY),
            ]
            log = output / f"diagnostic-worker-{mode}.log"
            env = {
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
                "TMPDIR": temporary,
            }
            with log.open("wb") as captured:
                completed = subprocess.run(
                    command,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=captured,
                    stderr=subprocess.STDOUT,
                    timeout=300,
                    check=False,
                )
            if completed.returncode:
                raise identity.IdentityError("worker_compilation_failed")
            # Reject source/package/SDK movement during compilation. The owned
            # code and packages actually compiled were independently snapshotted.
            if context.collect(root, build / "native", sdk, config, mode) != manifest:
                raise identity.IdentityError("worker_inputs_changed_during_compile")
            info = staged.lstat()
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_size <= 0
                or info.st_size > 64 * 1024 * 1024
            ):
                raise identity.IdentityError("invalid_worker_artifact")
            staged.chmod(0o755 if mode == "aot" else 0o644)
            staged.replace(target)
        artifact = {
            "path": f"application/{filename}",
            "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            "size": target.stat().st_size,
            "mode": stat.S_IMODE(target.stat().st_mode),
        }
    manifest["kind"] = "standalone-worker"
    (build / "native/diagnostic-worker-inputs.json").write_bytes(
        identity._canonical(manifest) + b"\n"
    )
    receipt = {
        "schema": 1,
        "kind": "standalone-worker-build",
        "mode": mode,
        "worker_id": manifest["worker_id"],
        "native_id": manifest["record"]["native_id"],
        "catalog_id": manifest["catalog_id"],
        "artifact": artifact,
        "defines": defines,
    }
    metadata.write_bytes(identity._canonical(receipt) + b"\n")
    return receipt


def verify_worker_build(
    root: Path, build: Path, sdk: Path, config: Path, mode: str
) -> dict[str, Any]:
    root, build, sdk, config = (p.absolute() for p in (root, build, sdk, config))
    receipt_bytes = identity._read(build, "application/diagnostic-worker-build.json")
    receipt = json.loads(receipt_bytes, object_pairs_hook=identity._unique_object)
    manifest = context.collect(root, build / "native", sdk, config, mode)
    manifest["kind"] = "standalone-worker"
    actual_manifest = identity._read(build, "native/diagnostic-worker-inputs.json")
    if actual_manifest != identity._canonical(manifest) + b"\n":
        raise identity.IdentityError("worker_context_mismatch")
    artifact = None
    if mode != "jit":
        filename = (
            "foresight-diagnostic-worker" if mode == "aot" else "diagnostic-worker.dill"
        )
        relative = f"application/{filename}"
        path = build / relative
        before = path.lstat()
        digest = context.digest_file(build, relative)
        after = path.lstat()
        fields = (
            "st_dev",
            "st_ino",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
            "st_mode",
            "st_uid",
            "st_nlink",
        )
        if (
            any(getattr(before, f) != getattr(after, f) for f in fields)
            or before.st_size <= 0
            or before.st_size > 64 * 1024 * 1024
            or stat.S_IMODE(before.st_mode) != (0o755 if mode == "aot" else 0o644)
        ):
            raise identity.IdentityError("unsafe_worker_artifact")
        artifact = {
            "path": relative,
            "sha256": digest,
            "size": before.st_size,
            "mode": stat.S_IMODE(before.st_mode),
        }
    expected = {
        "schema": 1,
        "kind": "standalone-worker-build",
        "mode": mode,
        "worker_id": manifest["worker_id"],
        "native_id": manifest["record"]["native_id"],
        "catalog_id": manifest["catalog_id"],
        "artifact": artifact,
        "defines": definitions(root, build, sdk, config, manifest),
    }
    if receipt_bytes != identity._canonical(expected) + b"\n" or identity._canonical(
        receipt
    ) != identity._canonical(expected):
        raise identity.IdentityError("worker_build_receipt_mismatch")
    return expected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "build", "sdk", "package-config"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--mode", choices=("jit", "kernel", "aot"), required=True)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--defines-output", type=Path)
    args = parser.parse_args()
    try:
        operation = verify_worker_build if args.verify else build_worker
        receipt = operation(
            args.root, args.build, args.sdk, args.package_config, args.mode
        )
        if args.defines_output is not None:
            destination = args.defines_output.absolute()
            anchor = context._anchor(destination.parent)
            os.close(anchor)
            if destination.is_symlink() or destination.parent.stat().st_mode & 0o022:
                raise identity.IdentityError("unsafe_worker_defines_output")
            data = b"".join(
                f"-D{name}={value}".encode() + b"\0"
                for name, value in sorted(receipt["defines"].items())
            )
            with tempfile.NamedTemporaryFile(
                dir=destination.parent, prefix="defines-", delete=False
            ) as staging:
                temporary = Path(staging.name)
                staging.write(data)
            temporary.replace(destination)
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        print(
            "Standalone worker build unavailable; captured compiler output retained",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
