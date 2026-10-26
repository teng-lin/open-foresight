"""Fingerprint selected public diagnostic compiler/OS metadata, not whole SDK bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Never

VERSION = re.compile(r"[0-9]{1,10}(?:\.[0-9]{1,10}){1,3}\Z")
PACKAGE_VERSION = re.compile(r"[A-Za-z0-9.+:~_-]{1,128}\Z")
LINUX_PACKAGES = (
    "libc6",
    "libc6-dev",
    "linux-libc-dev",
    "libc-bin",
    "binutils",
    "binutils-x86-64-linux-gnu",
)


class MetadataError(ValueError):
    pass


def _command(arguments: list[str]) -> str:
    result = subprocess.run(
        arguments, capture_output=True, text=True, timeout=30, check=False
    )
    if result.returncode or len(result.stdout) > 65536:
        raise MetadataError("diagnostic_toolchain_metadata_unavailable")
    return result.stdout.strip()


def _sha(path: Path) -> str:
    if not path.is_file():
        raise MetadataError("diagnostic_toolchain_metadata_unavailable")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def metadata(
    target: str, compiler: Path, family: str, version: str, sdk_root: Path | None = None
) -> dict:
    allowed = {"linux-x86_64": {"clang", "gcc"}, "darwin-arm64": {"apple-clang"}}
    if (
        family not in allowed.get(target, set())
        or not VERSION.fullmatch(version)
        or not compiler.is_absolute()
        or (sdk_root is not None and target != "darwin-arm64")
    ):
        raise MetadataError("diagnostic_toolchain_metadata_unavailable")
    compiler = compiler.resolve(strict=True)
    invocation_sha256 = _sha(compiler)
    if target == "darwin-arm64" and compiler.parent == Path("/usr/bin"):
        # Apple's command-line shims dispatch into the selected Xcode. Record
        # the actual selected compiler bytes as well as the public shim.
        compiler = Path(_command(["/usr/bin/xcrun", "--find", "clang"]))
        if not compiler.is_absolute():
            raise MetadataError("diagnostic_toolchain_metadata_unavailable")
        compiler = compiler.resolve(strict=True)
    text = _command([str(compiler), "--version"])
    marker = (
        "Apple clang version"
        if family == "apple-clang"
        else (
            "clang version"
            if family == "clang"
            else r"(?:gcc|cc|g\+\+)(?:-[0-9]+)?[^\n]*"
        )
    )
    if not re.search(marker + r"[^\n]*\b" + re.escape(version) + r"\b", text):
        if family != "apple-clang":
            raise MetadataError("diagnostic_toolchain_metadata_unavailable")
        # CMake's AppleClang version appends __apple_build_version__, which
        # is not a literal dotted component of clang's public banner.
        macros = _command([str(compiler), "-dM", "-E", "-x", "c", "/dev/null"])
        names = [
            "__clang_major__",
            "__clang_minor__",
            "__clang_patchlevel__",
            "__apple_build_version__",
        ]
        parts = []
        for name in names:
            found = re.search(
                r"^#define " + name + r" ([0-9]{1,10})$", macros, re.MULTILINE
            )
            if found is None:
                raise MetadataError("diagnostic_toolchain_metadata_unavailable")
            parts.append(found[1])
        if ".".join(parts) != version:
            raise MetadataError("diagnostic_toolchain_metadata_unavailable")
    record: dict = {
        "schema": 1,
        "kind": "diagnostic-selected-public-toolchain",
        "assurance": "metadata-fingerprint-not-whole-sdk-byte-attestation",
        "target": target,
        "compiler": {
            "family": family,
            "version": version,
            "sha256": _sha(compiler),
            "invocation_sha256": invocation_sha256,
        },
    }
    if target == "linux-x86_64":
        text = _command(
            [
                "/usr/bin/dpkg-query",
                "-W",
                "-f=${Package}=${Version}\\n",
                *LINUX_PACKAGES,
            ]
        )
        packages = {}
        for line in text.splitlines():
            name, separator, value = line.partition("=")
            if not separator or name not in LINUX_PACKAGES or name in packages:
                raise MetadataError("diagnostic_toolchain_metadata_unavailable")
            if not PACKAGE_VERSION.fullmatch(value):
                raise MetadataError("diagnostic_toolchain_metadata_unavailable")
            packages[name] = value
        if set(packages) != set(LINUX_PACKAGES):
            raise MetadataError("diagnostic_toolchain_metadata_unavailable")
        record["system"] = {
            "kind": "selected-dpkg-system-headers-libc-binutils",
            "packages": packages,
        }
    else:
        sdk = Path(_command(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]))
        if sdk_root is not None and sdk_root.resolve(strict=True) != sdk.resolve(strict=True):
            raise MetadataError("diagnostic_toolchain_metadata_unavailable")
        sdk_version = _command(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]
        )
        sdk_build = _command(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"]
        )
        if (
            not sdk.is_absolute()
            or not VERSION.fullmatch(sdk_version)
            or not re.fullmatch(r"[A-Za-z0-9.]{1,64}", sdk_build)
        ):
            raise MetadataError("diagnostic_toolchain_metadata_unavailable")
        record["system"] = {
            "kind": "selected-apple-os-sdk-metadata",
            "version": sdk_version,
            "build": sdk_build,
            "sdk_settings_sha256": _sha(sdk / "SDKSettings.json"),
        }
    canonical = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
    return {"fingerprint": hashlib.sha256(canonical).hexdigest(), "record": record}


class _ClosedParser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        raise MetadataError("diagnostic_toolchain_metadata_unavailable")


def main() -> int:
    parser = _ClosedParser(description=__doc__)
    parser.add_argument(
        "--target", choices=("linux-x86_64", "darwin-arm64"), required=True
    )
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument(
        "--family", choices=("clang", "gcc", "apple-clang"), required=True
    )
    parser.add_argument("--version", required=True)
    parser.add_argument("--sdk-root", type=Path)
    try:
        args = parser.parse_args()
        result = metadata(
            args.target, args.compiler, args.family, args.version, args.sdk_root
        )
    except (MetadataError, OSError, subprocess.SubprocessError, UnicodeError):
        print('{"error":"diagnostic_toolchain_metadata_unavailable"}', file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
