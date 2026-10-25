#!/usr/bin/env python3
"""Bind finished support artifacts to their closed inputs, without loading code.

Called after the native build's actual product dependencies. This is a byte
receipt, not an attestation that compilation occurred or WorkerID acceptance.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any

if __package__ in {None, ""}:
    # CMake invokes -I: select only this script's checked-in package root,
    # independently of cwd, PYTHONPATH and the ambient executable search path.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.diagnostic_build_identity import Compiler, Contract, IdentityError, _read
from tools.sql_support_identity import (
    INPUTS as SQL_INPUTS,
    verify_record as verify_sql_record,
)

RECEIPT = "runtime-support-build.json"


class ProductError(ValueError):
    """A required runtime product has no matching closed build record."""


def _unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProductError("duplicate_product_metadata")
        result[key] = value
    return result


def _json(root: Path, name: str) -> dict[str, Any]:
    data = _read(root, name)
    if len(data) > 1024 * 1024:
        raise ProductError("oversized_product_metadata")
    parsed = json.loads(data, object_pairs_hook=_unique)
    if not isinstance(parsed, dict):
        raise ProductError("invalid_product_metadata")
    return parsed


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _artifact(build: Path, name: str, marker: bytes | None = None) -> dict[str, Any]:
    directory = os.open(
        build, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    )
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=directory,
        )
    finally:
        os.close(directory)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_mode & 0o022
            or not 0 < before.st_size <= 64 * 1024 * 1024
            or (name == "foresight-diagnostic-launcher" and not before.st_mode & 0o111)
        ):
            raise ProductError("unsafe_product_artifact")
        digest = hashlib.sha256()
        contents = bytearray()
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
                if marker is not None:
                    contents.extend(chunk)
        after = os.fstat(descriptor)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns, before.st_mode) != (
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_mode,
        ):
            raise ProductError("product_changed_during_read")
        if marker is not None:
            prefix = marker.split(b":v1:", 1)[0] + b":v1:"
            if contents.count(marker) != 1 or contents.count(prefix) != 1:
                raise ProductError("product_embedded_identity_mismatch")
        return {
            "sha256": digest.hexdigest(),
            "size": before.st_size,
            "mode": stat.S_IMODE(before.st_mode),
        }
    finally:
        os.close(descriptor)


def collect(
    root: Path, build: Path, *, sql_product: Path | None = None
) -> dict[str, Any]:
    """Require available diagnostics and exact current native and SQL inputs."""
    state = _json(build, "diagnostic-products.json")
    if type(state.get("schema")) is not int or state.get("schema") != 1:
        raise ProductError("invalid_product_state")
    if state.get("available") is not True:
        raise ProductError("diagnostic_products_unavailable")
    if set(state) != {"schema", "available", "native_id"}:
        raise ProductError("invalid_product_state")
    native = _json(build, "diagnostic-native-inputs.json")
    if set(native) != {"schema", "kind", "native_id", "record"} or (
        type(native.get("schema")) is not int
        or native.get("schema") != 1
        or native.get("kind") != "native-components"
    ):
        raise ProductError("invalid_native_product_record")
    record = native["record"]
    if not isinstance(record, dict) or record.get("scope") != "components":
        raise ProductError("nonproduction_native_record")
    compiler = record["compiler"]
    expected = Contract(root).native_identity(
        record["target"],
        Compiler(
            compiler["family"],
            compiler["version"],
            compiler["sha256"],
            compiler["toolchain_sha256"],
        ),
        record["flags"],
    )
    if native != expected or native["native_id"] != state["native_id"]:
        raise ProductError("native_product_inputs_mismatch")
    toolchain = _json(build, "diagnostic-toolchain-metadata.json")
    if set(toolchain) != {"fingerprint", "record"} or not isinstance(
        toolchain["record"], dict
    ):
        raise ProductError("invalid_toolchain_metadata")
    fingerprint = _digest(
        json.dumps(toolchain["record"], sort_keys=True, separators=(",", ":")).encode()
    )
    if (
        toolchain["fingerprint"] != fingerprint
        or compiler["toolchain_sha256"] != fingerprint
    ):
        raise ProductError("toolchain_metadata_mismatch")
    suffix = {"linux-x86_64": "so", "darwin-arm64": "dylib"}[record["target"]]
    if (
        sql_product is not None
        and sql_product.absolute()
        != (build / f"libforesight_sql_support.{suffix}").absolute()
    ):
        raise ProductError("unexpected_sql_product_location")
    sql = _json(build, "diagnostic-sql-inputs.json")
    sql_id = verify_sql_record(root, sql)
    if (
        sql["record"]["target"] != record["target"]
        or sql["record"]["toolchain"] != toolchain
    ):
        raise ProductError("sql_product_toolchain_mismatch")
    artifacts = {
        name: _artifact(
            build,
            name,
            (
                b"\0FORESIGHT_SQL_SUPPORT_SOURCE_ID:v1:"
                + sql_id.encode("ascii")
                + b":end\0"
            )
            if "sql_support" in name
            else (
                b"\0FORESIGHT_DIAGNOSTIC_NATIVE_ID:v1:"
                + native["native_id"].encode("ascii")
                + b":end\0"
            ),
        )
        for name in (
            f"libforesight_sql_support.{suffix}",
            f"libforesight_diagnostic_support.{suffix}",
            "foresight-diagnostic-launcher",
        )
    }
    return {
        "schema": 1,
        "kind": "runtime-support-build",
        "native_id": native["native_id"],
        "target": record["target"],
        "sql_source_id": sql_id,
        "sql_inputs_sha256": _digest(_read(build, "diagnostic-sql-inputs.json")),
        "native_inputs_sha256": _digest(_read(build, "diagnostic-native-inputs.json")),
        "toolchain_metadata_sha256": _digest(
            _read(build, "diagnostic-toolchain-metadata.json")
        ),
        "sql_inputs": {name: _digest(_read(root, name)) for name in SQL_INPUTS},
        "artifacts": artifacts,
    }


def verify(
    root: Path, build: Path, *, sql_product: Path | None = None
) -> dict[str, Any]:
    receipt = _json(build, RECEIPT)
    if receipt != collect(root, build, sql_product=sql_product):
        raise ProductError("runtime_support_receipt_mismatch")
    return receipt


def write(
    root: Path, build: Path, *, sql_product: Path | None = None
) -> dict[str, Any]:
    receipt = collect(root, build, sql_product=sql_product)
    temporary = build / f".{RECEIPT}.{os.getpid()}"
    created = False
    try:
        with temporary.open("x", encoding="ascii") as stream:
            created = True
            json.dump(receipt, stream, sort_keys=True, indent=2)
            stream.write("\n")
        os.replace(temporary, build / RECEIPT)
    finally:
        if created:
            temporary.unlink(missing_ok=True)
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument(
        "--build", type=Path, required=True, help="Native binary directory"
    )
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--sql-product", type=Path)
    args = parser.parse_args()
    try:
        (verify if args.verify else write)(
            args.root, args.build, sql_product=args.sql_product
        )
    except (OSError, ValueError, KeyError, TypeError, IdentityError) as error:
        print(
            f"Runtime support products refused: {type(error).__name__}: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
