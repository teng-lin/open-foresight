"""Compute closed diagnostic component identities without Git or ambient defines.

This build-time tool never runs in the live application. Compiler fingerprints
are explicit public build metadata; the eventual build integration must bind
those values to its actual pinned compiler. Product/cache provenance is separate.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
import posixpath
from pathlib import Path, PurePosixPath
import re
import stat
import sys
from typing import Never, Sequence

DEFAULT_CONTRACT = "tools/diagnostic_build_inputs.json"
NATIVE_ALGORITHM = "foresight-diagnostic-native-v1"
WORKER_ALGORITHM = "foresight-diagnostic-worker-v1"
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
VERSION = re.compile(r"[0-9]{1,6}(?:\.[0-9]{1,6}){1,3}\Z")
RUNTIME_EXTENSIONS = frozenset(
    {
        ".dart",
        ".c",
        ".h",
        ".cpp",
        ".cc",
        ".cxx",
        ".hpp",
        ".mm",
        ".m",
        ".swift",
        ".proto",
        ".pb",
        ".json",
        ".yaml",
        ".lock",
        ".py",
        ".in",
        ".plist",
    }
)
NATIVE_FLAGS = frozenset(
    {
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-O0",
        "-O2",
        "-O3",
        "-g",
        "-DNDEBUG",
        "-fPIC",
        "-fvisibility=hidden",
        "-pthread",
        "-shared",
        "-mmacosx-version-min=15.0",
    }
)
TARGETS = {
    "linux-x86_64": {"compiler": "clang", "floor": "glibc-2.39-linux-x86_64"},
    "darwin-arm64": {"compiler": "apple-clang", "floor": "macos-15.0-arm64"},
}
C_EXTENSIONS = frozenset({".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".mm", ".m"})
NATIVE_DIRECTIVES = frozenset(
    {
        "include",
        "define",
        "undef",
        "if",
        "ifdef",
        "ifndef",
        "elif",
        "else",
        "endif",
        "error",
        "warning",
        "pragma",
        "line",
    }
)
# Exact current diagnostic SDK includes. Build integration must bind their
# resolution and include search order to the verified toolchain fingerprint.
SYSTEM_HEADERS = frozenset(
    {
        "atomic",
        "errno.h",
        "fcntl.h",
        "libproc.h",
        "limits.h",
        "poll.h",
        "signal.h",
        "spawn.h",
        "stdatomic.h",
        "stddef.h",
        "stdint.h",
        "stdio.h",
        "string.h",
        "sys/attr.h",
        "sys/event.h",
        "sys/file.h",
        "sys/mman.h",
        "sys/mount.h",
        "sys/pidfd.h",
        "sys/proc_info.h",
        "sys/random.h",
        "sys/stat.h",
        "sys/syscall.h",
        "sys/sysmacros.h",
        "sys/types.h",
        "sys/vfs.h",
        "sys/wait.h",
        "time.h",
        "unistd.h",
    }
)
# Defense in depth: a fixture/custom contract cannot opt these excluded paths in.
FORBIDDEN = frozenset(
    {
        "tools/reference_distribution_config.py",
        "tests/test_reference_distribution_config.py",
        "tools/web_search_release.py",
        "tests/test_web_search_release.py",
    }
)


class IdentityError(ValueError):
    """Closed failure category; never includes input/configuration values."""


def _object(value: object, keys: set[str]) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != keys:
        raise IdentityError("invalid_contract")
    return value


def _strings(value: object) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(x, str) for x in value):
        raise IdentityError("invalid_contract")
    if len(value) != len(set(value)):
        raise IdentityError("duplicate_input")
    return value


def _path(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value
        or "\\" in value
        or ":" in value
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
    ):
        raise IdentityError("unsafe_source_path")
    p = PurePosixPath(value)
    if p.is_absolute() or any(x in {"", ".", ".."} for x in value.split("/")):
        raise IdentityError("unsafe_source_path")
    if value in FORBIDDEN or p.name == ".env":
        raise IdentityError("excluded_input")
    return value


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def _digest(value: object) -> str:
    return hashlib.sha256(_canonical(value)).hexdigest()


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise IdentityError("invalid_contract")
        result[key] = value
    return result


def _read(root: Path, name: str, *, seen: set[tuple[int, int]] | None = None) -> bytes:
    """Anchor each component and reject links before a source-content read."""
    name = _path(name)
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        components = name.split("/")
        for component in components[:-1]:
            child = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
        source = os.open(
            components[-1],
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=descriptor,
        )
        try:
            before = os.fstat(source)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_nlink != 1
                or before.st_size > 16 * 1024 * 1024
            ):
                raise IdentityError("unsafe_source_path")
            key = (before.st_dev, before.st_ino)
            if seen is not None:
                if key in seen:
                    raise IdentityError("duplicate_input")
                seen.add(key)
            data = bytearray()
            while block := os.read(source, 65536):
                data.extend(block)
                if len(data) > 16 * 1024 * 1024:
                    raise IdentityError("unsafe_source_path")
            after = os.fstat(source)
            if (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            ) != (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            ):
                raise IdentityError("input_changed")
            return bytes(data)
        finally:
            os.close(source)
    except OSError as error:
        raise IdentityError("unsafe_source_path") from error
    finally:
        os.close(descriptor)


def _exists(root: Path, name: str) -> bool:
    name = _path(name)
    p = root
    for part in name.split("/"):
        p /= part
        if p.is_symlink():
            raise IdentityError("unsafe_source_path")
        if not p.exists():
            return False
    return p.is_file()


def _walk_error(error: OSError) -> Never:
    raise IdentityError("unsafe_source_path") from error


def _worker_path(value: object) -> str:
    name = _path(value)
    if any(
        part in name.lower()
        for part in (
            "reference_distribution",
            "credential",
            "search_service",
            "search-service",
        )
    ):
        raise IdentityError("excluded_worker_input")
    return name


def _relative_import(source: str, uri: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_./-]+", uri) or uri.startswith("/"):
        raise IdentityError("unsupported_worker_import")
    return _worker_path(
        posixpath.normpath(posixpath.join(posixpath.dirname(source), uri))
    )


def _skip_space(text: str, offset: int) -> int:
    while offset < len(text):
        if text[offset].isspace():
            offset += 1
        elif text.startswith("//", offset):
            end = text.find("\n", offset)
            offset = len(text) if end < 0 else end + 1
        elif text.startswith("/*", offset):
            offset += 2
            depth = 1
            while offset < len(text) and depth:
                if text.startswith("/*", offset):
                    depth += 1
                    offset += 2
                elif text.startswith("*/", offset):
                    depth -= 1
                    offset += 2
                else:
                    offset += 1
            if depth:
                raise IdentityError("unsupported_worker_header")
        else:
            break
    return offset


def _dart_uris(data: bytes) -> list[str]:
    # Dart3.9 directives precede declarations. Parse only that header, never
    # application strings, and reject escaped/interpolated URI spellings.
    try:
        text = data.decode("utf-8")
    except UnicodeError as error:
        raise IdentityError("unsupported_worker_header") from error
    text = text.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    offset = text.find("\n") + 1 if text.startswith("#!") else 0
    result: list[str] = []
    while True:
        offset = _skip_space(text, offset)
        if text.startswith("@", offset):
            raise IdentityError("unsupported_worker_header")
        directive = re.match(r"(?:import|export|part|library)\b", text[offset:])
        if directive is None:
            return result
        offset += directive.end()
        while True:
            offset = _skip_space(text, offset)
            if offset >= len(text):
                raise IdentityError("unsupported_worker_header")
            c = text[offset]
            if c == ";":
                offset += 1
                break
            if c in {"'", '"'}:
                if text.startswith(c * 3, offset):
                    raise IdentityError("unsupported_worker_header")
                end = text.find(c, offset + 1)
                if end < 0:
                    raise IdentityError("unsupported_worker_header")
                uri = text[offset + 1 : end]
                if any(ch in uri for ch in ("\\", "$", "\n", "\r")):
                    raise IdentityError("unsupported_worker_import")
                result.append(uri)
                offset = end + 1
            else:
                offset += 1


def _check_dart_imports(
    name: str, data: bytes, names: set[str], external: set[str]
) -> None:
    for uri in _dart_uris(data):
        if any(
            word in uri.lower()
            for word in (
                "reference_distribution",
                "credential",
                "search_service",
                "search-service",
            )
        ):
            raise IdentityError("excluded_worker_input")
        if uri in external:
            continue
        if uri.startswith("package:foresight_core/"):
            target = _worker_path(
                "packages/foresight_core/lib/"
                + uri.removeprefix("package:foresight_core/")
            )
        elif ":" in uri:
            raise IdentityError("unsupported_worker_import")
        else:
            target = _relative_import(name, uri)
        if target not in names:
            raise IdentityError("out_of_root_worker_import")


def _native_lines(data: bytes) -> list[str]:
    try:
        text = data.decode("utf-8").removeprefix("\ufeff")
    except UnicodeError as error:
        raise IdentityError("unsupported_native_include") from error
    if re.search(r"\?\?[=/\\'()!<>-]", text):
        raise IdentityError("unsupported_native_include")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Clang accepts whitespace before a splice newline with a warning. Refuse
    # that extension rather than scanning different directives from the build.
    if re.search(r"\\[ \t\v\f]+\n", text):
        raise IdentityError("unsupported_native_include")
    text = text.replace("\\\n", "").replace("%:", "#")
    text = text.replace("\v", " ").replace("\f", " ")
    result = list(text)
    offset = 0
    while offset < len(text):
        if text[offset] in {"'", '"'}:
            quote = text[offset]
            offset += 1
            while offset < len(text):
                if text[offset] == "\n":
                    raise IdentityError("unsupported_native_include")
                if text[offset] == "\\":
                    offset += 2
                elif text[offset] == quote:
                    offset += 1
                    break
                else:
                    offset += 1
            else:
                raise IdentityError("unsupported_native_include")
        elif text.startswith("//", offset) or text.startswith("/*", offset):
            start = offset
            line = text.startswith("//", offset)
            end = text.find("\n" if line else "*/", offset + 2)
            if end < 0 and not line:
                raise IdentityError("unsupported_native_include")
            offset = len(text) if end < 0 else end if line else end + 2
            for index in range(start, offset):
                if result[index] != "\n":
                    result[index] = " "
        else:
            offset += 1
    return "".join(result).splitlines()


def _check_native_includes(name: str, data: bytes, names: set[str]) -> None:
    for line in _native_lines(data):
        if not re.match(r"[ \t]*#", line):
            continue
        directive = re.match(r"[ \t]*#[ \t]*([A-Za-z_][A-Za-z0-9_]*)", line)
        if directive is None or directive[1] not in NATIVE_DIRECTIVES:
            raise IdentityError("unsupported_native_include")
        if directive[1] != "include":
            continue
        include = re.fullmatch(
            r'[ \t]*#[ \t]*include[ \t]*([<"])([^>"]+)[>"][ \t]*', line
        )
        if include is None:
            raise IdentityError("unsupported_native_include")
        if include[1] == '"':
            target = _relative_import(name, include[2])
            if target not in names:
                raise IdentityError("unclassified_native_include")
        elif include[2] not in SYSTEM_HEADERS:
            raise IdentityError("unclassified_native_include")


@dataclass(frozen=True)
class Compiler:
    family: str
    version: str
    sha256: str
    toolchain_sha256: str

    def record(self, family: str) -> dict[str, str]:
        if (
            self.family != family
            or not VERSION.fullmatch(self.version)
            or not HEX64.fullmatch(self.sha256)
            or not HEX64.fullmatch(self.toolchain_sha256)
        ):
            raise IdentityError("invalid_toolchain")
        return {
            "family": self.family,
            "version": self.version,
            "sha256": self.sha256,
            "toolchain_sha256": self.toolchain_sha256,
        }


class Contract:
    def __init__(self, root: Path, contract: str = DEFAULT_CONTRACT):
        self.root = root.absolute()
        if self.root.is_symlink() or not self.root.is_dir():
            raise IdentityError("unsafe_source_path")
        self.path = _path(contract)
        if PurePosixPath(self.path).name != "diagnostic_build_inputs.json":
            raise IdentityError("invalid_contract_path")
        raw = _read(self.root, self.path)
        try:
            parsed = json.loads(raw, object_pairs_hook=_unique_object)
        except (ValueError, UnicodeError) as error:
            raise IdentityError("invalid_contract") from error
        data = _object(parsed, {"schema", "scope", "native", "worker"})
        if (
            type(data["schema"]) is not int
            or data["schema"] != 1
            or not isinstance(data["scope"], str)
            or data["scope"] not in {"components", "fixture"}
        ):
            raise IdentityError("invalid_contract")
        self.scope = str(data["scope"])
        self.native = _object(
            data["native"], {"root", "prefix", "inputs", "targets", "flags"}
        )
        self.worker = _object(
            data["worker"],
            {
                "status",
                "required",
                "roots",
                "inputs",
                "exceptions",
                "catalog",
                "sdk",
                "options",
                "external_imports",
            },
        )
        _object(self.worker["options"], {"record_schema"})

    def native_identity(
        self, target: str, compiler: Compiler, flags: Sequence[str]
    ) -> dict[str, object]:
        root = _path(self.native["root"])
        if root != "native":
            raise IdentityError("invalid_native_inventory")
        prefix = self.native["prefix"]
        if not isinstance(prefix, str) or prefix != "diagnostic_":
            raise IdentityError("invalid_contract")
        targets = self.native["targets"]
        if targets != TARGETS or target not in TARGETS:
            raise IdentityError("invalid_target")
        profile = _object(targets[target], {"compiler", "floor"})
        compiler_record = compiler.record(str(profile["compiler"]))
        allowed = _strings(self.native["flags"])
        if not set(allowed) <= NATIVE_FLAGS:
            raise IdentityError("invalid_flags")
        if (
            not flags
            or len(flags) != len(set(flags))
            or any(f not in allowed for f in flags)
        ):
            raise IdentityError("invalid_flags")
        if (target == "linux-x86_64" and "-mmacosx-version-min=15.0" in flags) or (
            target == "darwin-arm64" and "-mmacosx-version-min=15.0" not in flags
        ):
            raise IdentityError("invalid_flags")
        rows = self.native["inputs"]
        if not isinstance(rows, list):
            raise IdentityError("invalid_contract")
        inventory: dict[str, list[str]] = {}
        for row in rows:
            item = _object(row, {"path", "targets"})
            name = _path(item["path"])
            platforms = _strings(item["targets"])
            if (
                name in inventory
                or not name.startswith(root + "/")
                or not PurePosixPath(name).name.startswith(prefix)
                or PurePosixPath(name).suffix not in {".c", ".h"}
            ):
                raise IdentityError("invalid_native_inventory")
            if not platforms or any(p not in targets for p in platforms):
                raise IdentityError("invalid_native_inventory")
            if not _exists(self.root, name):
                raise IdentityError("missing_native_input")
            inventory[name] = platforms
        discovered: set[str] = set()
        directory = self.root / root
        if directory.is_symlink() or not directory.is_dir():
            raise IdentityError("unsafe_source_path")
        for base, directories, files in os.walk(
            directory, followlinks=False, onerror=_walk_error
        ):
            for child in directories:
                if (Path(base) / child).is_symlink():
                    raise IdentityError("unsafe_source_path")
            for filename in files:
                p = Path(base) / filename
                if filename.startswith(prefix) and p.suffix in C_EXTENSIONS:
                    discovered.add(p.relative_to(self.root).as_posix())
        if discovered != set(inventory):
            raise IdentityError("unclassified_native_input")
        selected = {name for name in inventory if target in inventory[name]}
        inputs = {}
        seen: set[tuple[int, int]] = set()
        for name in sorted(selected):
            data = _read(self.root, name, seen=seen)
            _check_native_includes(name, data, selected)
            inputs[name] = hashlib.sha256(data).hexdigest()
        record = {
            "algorithm": NATIVE_ALGORITHM,
            "scope": self.scope,
            "target": target,
            "compiler": compiler_record,
            "floor": profile["floor"],
            "flags": list(flags),
            "inputs": inputs,
        }
        return {
            "schema": 1,
            "kind": "native-components",
            "native_id": _digest(record),
            "record": record,
        }

    def worker_identity(self, native_id: str, mode: str) -> dict[str, object]:
        if not HEX64.fullmatch(native_id) or mode not in {
            "jit",
            "kernel",
            "aot",
        }:
            raise IdentityError("invalid_worker_options")
        required = [_worker_path(n) for n in _strings(self.worker["required"])]
        # Check roots before any closure content read, including excluded paths.
        if not required or any(not _exists(self.root, n) for n in required):
            raise IdentityError("missing_worker_closure")
        if self.scope != "fixture" or self.worker["status"] != "fixture":
            raise IdentityError("worker_closure_not_reviewed")
        roots = [_worker_path(n) for n in _strings(self.worker["roots"])]
        if any(
            a == b or a.startswith(b + "/") or b.startswith(a + "/")
            for i, a in enumerate(roots)
            for b in roots[i + 1 :]
        ):
            raise IdentityError("duplicate_input")
        names = {_worker_path(n) for n in _strings(self.worker["inputs"])}
        exceptions = self.worker["exceptions"]
        if not isinstance(exceptions, dict) or any(
            not isinstance(v, str) or not v for v in exceptions.values()
        ):
            raise IdentityError("invalid_contract")
        excluded = {_worker_path(n) for n in exceptions}
        if any(
            not any(n == r or n.startswith(r + "/") for r in roots) for n in excluded
        ):
            raise IdentityError("invalid_worker_inventory")
        if names & excluded or any(
            not any(n == r or n.startswith(r + "/") for r in roots) for n in names
        ):
            raise IdentityError("invalid_worker_inventory")
        observed: set[str] = set()
        for root in roots:
            directory = self.root / root
            if directory.is_symlink() or not directory.exists():
                raise IdentityError("unsafe_source_path")
            if directory.is_file():
                if root not in excluded:
                    observed.add(_worker_path(root))
                continue
            for base, directories, files in os.walk(
                directory, followlinks=False, onerror=_walk_error
            ):
                for child in directories:
                    if (Path(base) / child).is_symlink():
                        raise IdentityError("unsafe_source_path")
                for filename in files:
                    name = (Path(base) / filename).relative_to(self.root).as_posix()
                    if name in excluded:
                        continue
                    if PurePosixPath(name).suffix in RUNTIME_EXTENSIONS:
                        observed.add(_worker_path(name))
        if observed != names or not set(required) <= names:
            raise IdentityError("unclassified_worker_input")
        catalog = [_worker_path(n) for n in _strings(self.worker["catalog"])]
        if not catalog or not set(catalog) <= names:
            raise IdentityError("invalid_catalog")
        sdk = _object(
            self.worker["sdk"],
            {
                "dart",
                "flutter",
                "flutter_commit",
                "revision",
                "compiler_sha256",
                "toolchain_sha256",
            },
        )
        if (
            {
                k: v
                for k, v in sdk.items()
                if k not in {"compiler_sha256", "toolchain_sha256"}
            }
            != {
                "dart": "3.9.2",
                "flutter": "3.35.7",
                "flutter_commit": "adc901062556672b4138e18a4dc62a4be8f4b3c2",
                "revision": "a29e08c72e2ce21813c1edf50cbcdfcac7a7acdd",
            }
            or not isinstance(sdk["compiler_sha256"], str)
            or not HEX64.fullmatch(sdk["compiler_sha256"])
            or not isinstance(sdk["toolchain_sha256"], str)
            or not HEX64.fullmatch(sdk["toolchain_sha256"])
        ):
            raise IdentityError("invalid_sdk")
        options = _object(self.worker["options"], {"record_schema"})
        if type(options["record_schema"]) is not int or options[
            "record_schema"
        ] not in {1, 2}:
            raise IdentityError("invalid_worker_options")
        external = set(_strings(self.worker["external_imports"]))
        allowed_external = {
            "dart:async",
            "dart:collection",
            "dart:convert",
            "dart:ffi",
            "dart:io",
            "dart:isolate",
            "dart:math",
            "dart:typed_data",
            "package:crypto/crypto.dart",
            "package:ffi/ffi.dart",
            "package:meta/meta.dart",
            "package:path/path.dart",
        }
        if not external <= allowed_external:
            raise IdentityError("unsupported_worker_import")
        inputs = {}
        seen: set[tuple[int, int]] = set()
        for name in sorted(names):
            data = _read(self.root, name, seen=seen)
            if name.endswith(".dart"):
                _check_dart_imports(name, data, names, external)
            inputs[name] = hashlib.sha256(data).hexdigest()
        catalog_id = _digest({n: inputs[n] for n in catalog})
        record = {
            "algorithm": WORKER_ALGORITHM,
            "scope": "fixture",
            "native_id": native_id,
            "mode": mode,
            "sdk": sdk,
            "options": options,
            "catalog_id": catalog_id,
            "external_imports": sorted(external),
            "inputs": inputs,
        }
        return {
            "schema": 1,
            "kind": "fixture-worker",
            "worker_id": _digest(record),
            "catalog_id": catalog_id,
            "external_imports": sorted(external),
            "record": record,
        }


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> Never:
        # argparse's default echoes arbitrary rejected -D values.
        raise IdentityError("invalid_arguments")


def main(argv: Sequence[str] | None = None) -> int:
    parser = _Parser(description=__doc__)
    commands = parser.add_subparsers(dest="kind", required=True, parser_class=_Parser)
    native_parser = commands.add_parser("native")
    worker_parser = commands.add_parser("worker")
    for command in (native_parser, worker_parser):
        command.add_argument(
            "--root", type=Path, default=Path(__file__).resolve().parents[1]
        )
        command.add_argument("--contract", default=DEFAULT_CONTRACT)
        command.add_argument("--expected-id")
    native_parser.add_argument(
        "--target", choices=("linux-x86_64", "darwin-arm64"), required=True
    )
    native_parser.add_argument(
        "--compiler-family", choices=("clang", "apple-clang"), required=True
    )
    native_parser.add_argument("--compiler-version", required=True)
    native_parser.add_argument("--compiler-sha256", required=True)
    native_parser.add_argument("--toolchain-sha256", required=True)
    native_parser.add_argument("--flag", action="append", default=[])
    native_parser.add_argument("--format", choices=("json", "header"), default="json")
    worker_parser.add_argument("--native-id", required=True)
    worker_parser.add_argument(
        "--mode", choices=("jit", "kernel", "aot"), default="aot"
    )
    try:
        args = parser.parse_args(argv)
        contract = Contract(args.root, args.contract)
        if args.kind == "native":
            result = contract.native_identity(
                args.target,
                Compiler(
                    args.compiler_family,
                    args.compiler_version,
                    args.compiler_sha256,
                    args.toolchain_sha256,
                ),
                args.flag,
            )
            computed = result["native_id"]
        else:
            result = contract.worker_identity(args.native_id, args.mode)
            computed = result["worker_id"]
        if args.expected_id is not None and (
            not HEX64.fullmatch(args.expected_id) or args.expected_id != computed
        ):
            raise IdentityError("identity_mismatch")
        if args.kind == "native" and args.format == "header":
            print(
                f'/* Generated outside the source inventory; component identity only. */\n#define FORESIGHT_DIAGNOSTIC_NATIVE_ID "{computed}"'
            )
        else:
            print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except (IdentityError, OSError) as error:
        code = str(error) if isinstance(error, IdentityError) else "unsafe_source_path"
        print(json.dumps({"error": code}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
