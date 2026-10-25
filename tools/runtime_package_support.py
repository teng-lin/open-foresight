"""Carry verified support products into a package and bind final package bytes.

The source receipt remains build provenance. A separate package receipt records
copied or relocated/signed bytes; neither receipt attests compiler execution.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import stat
from typing import Any

try:
    from diagnostic_product_receipt import verify as verify_products
except ModuleNotFoundError:
    from tools.diagnostic_product_receipt import verify as verify_products

METADATA = (
    "diagnostic-products.json",
    "diagnostic-native-inputs.json",
    "diagnostic-toolchain-metadata.json",
    "diagnostic-sql-inputs.json",
    "runtime-support-build.json",
)
METADATA_DIRECTORY = "share/open-foresight/runtime-support"
PACKAGE_RECEIPT = "runtime-support-package.json"


class PackageSupportError(ValueError):
    """Support products cannot be attributed to the selected source build."""


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")


def _digest(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def _read(path: Path, *, executable: bool = False) -> tuple[bytes, dict[str, Any]]:
    descriptor = os.open(
        path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    )
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or not 0 < before.st_size <= 64 * 1024 * 1024
            or (executable and not before.st_mode & 0o111)
        ):
            raise PackageSupportError("unsafe_package_support_input")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            blob = stream.read(64 * 1024 * 1024 + 1)
        after = os.fstat(descriptor)
        if len(blob) != before.st_size or (
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_mode,
        ) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_mode):
            raise PackageSupportError("package_support_changed_during_read")
        return blob, {
            "sha256": _digest(blob),
            "size": len(blob),
            "mode": stat.S_IMODE(before.st_mode),
        }
    finally:
        os.close(descriptor)


def _layout(target: str) -> dict[str, str]:
    suffix = {"linux-x86_64": "so", "darwin-arm64": "dylib"}.get(target)
    if suffix is None:
        raise PackageSupportError("unsupported_package_support_target")
    return {
        f"libforesight_sql_support.{suffix}": f"lib/libforesight_sql_support.{suffix}",
        f"libforesight_diagnostic_support.{suffix}": f"lib/libforesight_diagnostic_support.{suffix}",
        "foresight-diagnostic-launcher": "bin/foresight-diagnostic-launcher",
    }


def _marker(name: str, receipt: dict[str, Any]) -> bytes:
    if "sql_support" in name:
        prefix, value = "FORESIGHT_SQL_SUPPORT_SOURCE_ID", receipt["sql_source_id"]
    else:
        prefix, value = "FORESIGHT_DIAGNOSTIC_NATIVE_ID", receipt["native_id"]
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(c not in "0123456789abcdef" for c in value)
    ):
        raise PackageSupportError("invalid_package_support_identity")
    return b"\0" + f"{prefix}:v1:{value}:end".encode("ascii") + b"\0"


@dataclass(frozen=True)
class PreparedSupport:
    receipt: dict[str, Any]
    artifacts: dict[str, bytes]
    metadata: dict[str, bytes]


def prepare(root: Path, native_build: Path, target: str) -> PreparedSupport:
    """Validate source, identities and bytes before creating package output."""
    receipt = verify_products(root, native_build)
    if receipt["target"] != target or set(receipt["artifacts"]) != set(_layout(target)):
        raise PackageSupportError("package_support_target_mismatch")
    artifacts = {}
    for name in receipt["artifacts"]:
        blob, metadata = _read(
            native_build / name, executable=name == "foresight-diagnostic-launcher"
        )
        if (
            _canonical(metadata) != _canonical(receipt["artifacts"][name])
            or blob.count(_marker(name, receipt)) != 1
        ):
            raise PackageSupportError("package_support_build_bytes_mismatch")
        artifacts[name] = blob
    copied_metadata = {name: _read(native_build / name)[0] for name in METADATA}
    if _canonical(
        json.loads(copied_metadata["diagnostic-products.json"])
    ) != _canonical(
        {"schema": 1, "available": True, "native_id": receipt["native_id"]}
    ):
        raise PackageSupportError("package_support_build_state_changed")
    for name, field in (
        ("diagnostic-native-inputs.json", "native_inputs_sha256"),
        ("diagnostic-toolchain-metadata.json", "toolchain_metadata_sha256"),
        ("diagnostic-sql-inputs.json", "sql_inputs_sha256"),
    ):
        if _digest(copied_metadata[name]) != receipt[field]:
            raise PackageSupportError("package_support_build_metadata_mismatch")
    if _canonical(
        json.loads(copied_metadata["runtime-support-build.json"])
    ) != _canonical(receipt):
        raise PackageSupportError("package_support_build_receipt_changed")
    if _canonical(verify_products(root, native_build)) != _canonical(receipt):
        raise PackageSupportError("package_support_build_changed")
    return PreparedSupport(receipt, artifacts, copied_metadata)


def _directory(payload: Path, relative: str) -> Path:
    directory = payload
    for component in ("", *Path(relative).parts):
        if component:
            directory = directory / component
        directory.mkdir(exist_ok=True)
        if directory.is_symlink() or not directory.is_dir():
            raise PackageSupportError("unsafe_package_support_directory")
    return directory


def stage(payload: Path, prepared: PreparedSupport) -> None:
    """Copy only the three verified products and their public provenance."""
    for name, relative in _layout(prepared.receipt["target"]).items():
        target = payload / relative
        _directory(payload, str(Path(relative).parent))
        with target.open("xb") as stream:
            stream.write(prepared.artifacts[name])
        target.chmod(prepared.receipt["artifacts"][name]["mode"])
    metadata = (
        _directory(payload, str(Path(METADATA_DIRECTORY).parent)) / "runtime-support"
    )
    metadata.mkdir(exist_ok=False)
    for name, blob in prepared.metadata.items():
        with (metadata / name).open("xb") as stream:
            stream.write(blob)
        (metadata / name).chmod(0o644)


def seal(
    payload: Path, prepared: PreparedSupport, *, transformed: bool
) -> dict[str, Any]:
    """Bind final bytes after optional relocation/signing, before outer sealing."""
    metadata = payload / METADATA_DIRECTORY
    for name, blob in prepared.metadata.items():
        if _read(metadata / name)[0] != blob:
            raise PackageSupportError("package_support_provenance_changed")
    artifacts = {}
    for name, relative in _layout(prepared.receipt["target"]).items():
        blob, final = _read(
            payload / relative, executable=name == "foresight-diagnostic-launcher"
        )
        if blob.count(_marker(name, prepared.receipt)) != 1:
            raise PackageSupportError("package_support_marker_changed")
        if not transformed and _canonical(final) != _canonical(
            prepared.receipt["artifacts"][name]
        ):
            raise PackageSupportError("package_support_copy_changed")
        artifacts[relative] = {
            **final,
            "source_build_sha256": prepared.receipt["artifacts"][name]["sha256"],
        }
    receipt = {
        "schema": 1,
        "kind": "runtime-support-package",
        "target": prepared.receipt["target"],
        "native_id": prepared.receipt["native_id"],
        "sql_source_id": prepared.receipt["sql_source_id"],
        "processing": "relocated-signed" if transformed else "unmodified-copy",
        "source_receipt_sha256": _digest(
            prepared.metadata["runtime-support-build.json"]
        ),
        "artifacts": artifacts,
    }
    with (metadata / PACKAGE_RECEIPT).open("x", encoding="ascii") as stream:
        json.dump(receipt, stream, sort_keys=True, indent=2)
        stream.write("\n")
    (metadata / PACKAGE_RECEIPT).chmod(0o644)
    return receipt
