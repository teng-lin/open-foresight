"""Independent SQL source/public-recipe identity; never a NativeID or WorkerID."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

INPUTS = (
    "native/sql_support.c",
    "native/sql_support.h",
    "cmake/ForesightSqlSupport.cmake",
    "cmake/ForesightSqlIdentity.cmake",
    "cmake/VerifyDiagnosticToolchain.cmake",
    "tools/sql_support_identity.py",
    "tools/diagnostic_toolchain_metadata.py",
)
FLAGS = frozenset(
    (
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-fvisibility=hidden",
        "-pthread",
        "-DNDEBUG",
        "-g",
        "-g0",
        "-O0",
        "-O1",
        "-O2",
        "-O3",
        "-Os",
        "-mmacosx-version-min=15.0",
    )
)


class SqlIdentityError(ValueError):
    """SQL effective recipe or public inputs are outside the closed contract."""


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")


def identity(root: Path, metadata: dict[str, Any], flags: list[str]) -> dict[str, Any]:
    if set(metadata) != {"fingerprint", "record"} or not isinstance(
        metadata["record"], dict
    ):
        raise SqlIdentityError("invalid_sql_toolchain_metadata")
    fingerprint = hashlib.sha256(canonical(metadata["record"])).hexdigest()
    if metadata["fingerprint"] != fingerprint:
        raise SqlIdentityError("sql_toolchain_metadata_mismatch")
    target = metadata["record"].get("target")
    if target not in ("linux-x86_64", "darwin-arm64"):
        raise SqlIdentityError("unsupported_sql_target")
    if not flags or any(flag not in FLAGS for flag in flags):
        raise SqlIdentityError("unclosed_sql_compile_flags")
    if target == "darwin-arm64" and "-mmacosx-version-min=15.0" not in flags:
        raise SqlIdentityError("unclosed_sql_deployment_target")
    inputs = {}
    for name in INPUTS:
        path = root / name
        # Inputs are an explicit source closure, never a recursive/environment read.
        if path.is_symlink() or not path.is_file():
            raise SqlIdentityError("unsafe_sql_source_input")
        inputs[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    record = {
        "schema": 1,
        "kind": "sql-support-source-and-public-recipe",
        "target": target,
        "inputs": inputs,
        "toolchain": metadata,
        "recipe": {
            "flags": flags,
            "c_standard": 11,
            "extensions": False,
            "visibility": "hidden",
            "pic": True,
            "ipo": False,
            "unity": False,
            "link": ["Threads::Threads", *([] if target == "darwin-arm64" else ["dl"])],
            "build_rpath": "",
            "install_rpath": "",
        },
    }
    return {
        "schema": 1,
        "kind": "sql-support-inputs",
        "sql_source_id": hashlib.sha256(canonical(record)).hexdigest(),
        "record": record,
    }


def verify_record(root: Path, envelope: dict[str, Any]) -> str:
    """Recompute the independent source/public recipe closure without loading code."""
    record = envelope["record"]
    expected = identity(root, record["toolchain"], record["recipe"]["flags"])
    if envelope != expected:
        raise SqlIdentityError("sql_source_record_mismatch")
    return str(expected["sql_source_id"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--flag", action="append", default=[])
    args = parser.parse_args()
    try:
        result = identity(args.root, json.loads(args.metadata.read_text()), args.flag)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(
            f"SQL source identity refused: {type(error).__name__}: {error}",
            file=sys.stderr,
        )
        return 1
    print(canonical(result).decode("ascii"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
