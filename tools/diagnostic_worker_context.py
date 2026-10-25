#!/usr/bin/env python3
"""Build a closed standalone worker context from actual source, package and SDK bytes.

This source-context generator never traverses the application/service graph or runs a
compiler. Actual worker compilation and package provenance remain separate gates.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import stat
import sys
from typing import Any
from urllib.parse import unquote, urlparse

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools import diagnostic_build_identity as identity
from tools import diagnostic_product_receipt as products

PACKAGES = frozenset({"ffi", "meta", "path", "crypto", "typed_data", "collection"})
EXTERNAL = frozenset(
    {
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
)
CORE = "packages/foresight_core"
ENTRY = f"{CORE}/bin/diagnostic_storage_worker.dart"
DIAGNOSTICS = f"{CORE}/lib/src/diagnostics"
EXACT = frozenset(
    {
        ENTRY,
        f"{CORE}/lib/src/persistence/backup_files.dart",
        f"{CORE}/pubspec.yaml",
        f"{CORE}/pubspec.lock",
        "native/diagnostic_support.c",
        "native/diagnostic_support.h",
    }
)


def owned_path(name: object) -> str:
    value = identity._worker_path(name)
    if value not in EXACT and not (
        value.startswith(DIAGNOSTICS + "/")
        and PurePosixPath(value).parent.as_posix() == DIAGNOSTICS
        and value.endswith(".dart")
    ):
        raise identity.IdentityError("unowned_worker_input")
    return value


def external_path(name: object, *, sdk: bool = False) -> str:
    value = identity._worker_path(name)
    if sdk:
        if value not in {"version", "revision"} and not value.startswith(
            ("bin/", "lib/")
        ):
            raise identity.IdentityError("unowned_sdk_input")
    elif value != "pubspec.yaml" and not (
        value.startswith("lib/") and value.endswith(".dart")
    ):
        raise identity.IdentityError("unowned_package_input")
    return value


def _anchor(root: Path) -> int:
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in root.absolute().parts[1:]:
            child = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def digest_file(root: Path, name: str) -> str:
    """Descriptor-anchored bounded hash; no symlink, device or mid-read change."""
    name = identity._worker_path(name)
    descriptor = _anchor(root)
    try:
        parts = name.split("/")
        for part in parts[:-1]:
            child = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
        file = os.open(
            parts[-1],
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=descriptor,
        )
        try:
            before = os.fstat(file)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_nlink != 1
                or before.st_mode & 0o022
                or before.st_size > 256 * 1024 * 1024
            ):
                raise identity.IdentityError("unsafe_worker_runtime_input")
            digest = hashlib.sha256()
            size = 0
            while block := os.read(file, 1024 * 1024):
                size += len(block)
                if size > 256 * 1024 * 1024:
                    raise identity.IdentityError("oversized_worker_runtime_input")
                digest.update(block)
            after = os.fstat(file)
            fields = (
                "st_dev",
                "st_ino",
                "st_size",
                "st_mtime_ns",
                "st_ctime_ns",
                "st_mode",
            )
            if size != before.st_size or any(
                getattr(before, f) != getattr(after, f) for f in fields
            ):
                raise identity.IdentityError("worker_runtime_input_changed")
            return digest.hexdigest()
        finally:
            os.close(file)
    finally:
        os.close(descriptor)


def tree_names(root: Path, branch: str, *, sdk: bool = False) -> list[str]:
    directory = root / branch
    descriptor = _anchor(directory)
    os.close(descriptor)
    if directory.is_symlink() or not directory.is_dir():
        raise identity.IdentityError("unsafe_worker_runtime_root")
    names = []
    for base, directories, files in os.walk(
        directory, followlinks=False, onerror=identity._walk_error
    ):
        for child in directories:
            if (Path(base) / child).is_symlink():
                raise identity.IdentityError("unsafe_worker_runtime_root")
        for child in files:
            name = (Path(base) / child).relative_to(root).as_posix()
            if sdk or name.endswith(".dart"):
                names.append(external_path(name, sdk=sdk))
    return sorted(names)


def package_roots(config: Path, root: Path) -> tuple[dict[str, Path], dict[str, str]]:
    data = json.loads(
        identity._read(root, f"{CORE}/.dart_tool/package_config.json"),
        object_pairs_hook=identity._unique_object,
    )
    if (
        not isinstance(data, dict)
        or data.get("configVersion") != 2
        or not isinstance(data.get("packages"), list)
    ):
        raise identity.IdentityError("invalid_worker_package_config")
    roots: dict[str, Path] = {}
    languages: dict[str, str] = {}
    core_found = False
    seen = set()
    for entry in data["packages"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            raise identity.IdentityError("invalid_worker_package_config")
        name = entry["name"]
        if name in seen:
            raise identity.IdentityError("duplicate_worker_package")
        seen.add(name)
        if name not in PACKAGES and name != "foresight_core":
            continue
        if entry.get("packageUri") != "lib/" or not isinstance(
            entry.get("languageVersion"), str
        ):
            raise identity.IdentityError("invalid_worker_package_config")
        uri = urlparse(entry["rootUri"])
        if uri.scheme not in {"", "file"} or uri.netloc or uri.query or uri.fragment:
            raise identity.IdentityError("invalid_worker_package_root")
        selected = Path(unquote(uri.path))
        if not selected.is_absolute():
            selected = config.parent / selected
        selected = selected.absolute()
        if any(
            part in str(selected).lower()
            for part in (
                "reference_distribution",
                "credential",
                "search_service",
                "search-service",
            )
        ):
            raise identity.IdentityError("excluded_worker_package_root")
        if name == "foresight_core":
            if (
                selected.resolve() != (root / CORE).resolve()
                or entry["languageVersion"] != "3.8"
            ):
                raise identity.IdentityError("invalid_worker_core_mapping")
            core_found = True
        else:
            # A package URI can never turn this tool into a repository/private
            # path reader, even before its file-content hash is attempted.
            if (
                selected.parent.name != "pub.dev"
                or selected.parent.parent.name != "hosted"
                or not selected.name.startswith(name + "-")
                or selected.is_symlink()
            ):
                raise identity.IdentityError("invalid_worker_package_root")
            roots[name] = selected
            languages[name] = entry["languageVersion"]
    if not core_found or set(roots) != PACKAGES:
        raise identity.IdentityError("missing_worker_package")
    return roots, languages


def package_imports(
    name: str, data: bytes, package: str, inventories: dict[str, list[str]]
) -> None:
    # The selected collection release annotates deprecated public libraries.
    # Accept only that fixed single-string metadata spelling in directive headers.
    data = re.sub(rb"(?m)^@Deprecated\('[A-Za-z0-9 ._-]+'\)\s*$", b"", data)
    for uri in identity._dart_uris(data, declaration_metadata=True):
        if any(
            word in uri.lower()
            for word in (
                "reference_distribution",
                "credential",
                "search_service",
                "search-service",
            )
        ):
            raise identity.IdentityError("excluded_worker_package_import")
        if uri.startswith("dart:"):
            if uri not in EXTERNAL and uri != "dart:core":
                raise identity.IdentityError("unclassified_package_sdk_import")
            continue
        target_package = package
        if uri.startswith("package:"):
            path = uri.removeprefix("package:")
            if "/" not in path:
                raise identity.IdentityError("unclassified_worker_package_import")
            target_package, relative = path.split("/", 1)
            target = external_path("lib/" + relative)
        elif ":" in uri:
            raise identity.IdentityError("unclassified_worker_package_import")
        else:
            target = external_path(identity._relative_import(name, uri))
        if target_package not in PACKAGES or target not in inventories[target_package]:
            raise identity.IdentityError("unclassified_worker_package_import")


def collect(
    root: Path, build: Path, sdk: Path, config: Path, mode: str
) -> dict[str, Any]:
    if mode not in {"jit", "kernel", "aot"}:
        raise identity.IdentityError("invalid_worker_mode")
    root, build, sdk, config = (p.absolute() for p in (root, build, sdk, config))
    if config != root / CORE / ".dart_tool/package_config.json":
        raise identity.IdentityError("unowned_worker_package_config")
    contract = identity.Contract(root)
    # Validate the complete declared source inventory and all package roots
    # before opening any declared runtime source/dependency content.
    names = {owned_path(n) for n in identity._strings(contract.worker["inputs"])}
    required = {owned_path(n) for n in identity._strings(contract.worker["required"])}
    roots = [
        owned_path(n) if n != DIAGNOSTICS else n
        for n in identity._strings(contract.worker["roots"])
    ]
    if (
        set(roots) != {DIAGNOSTICS, *EXACT}
        or not required <= names
        or ENTRY not in names
        or contract.worker["exceptions"] != {}
    ):
        raise identity.IdentityError("incomplete_worker_source_contract")
    observed = set(EXACT)
    descriptor = _anchor(root / DIAGNOSTICS)
    os.close(descriptor)
    for child in (root / DIAGNOSTICS).iterdir():
        if child.is_symlink() or child.is_dir():
            raise identity.IdentityError("unclassified_worker_source")
        if child.suffix == ".dart":
            observed.add(owned_path(child.relative_to(root).as_posix()))
    if observed != names:
        raise identity.IdentityError("unclassified_worker_source")
    if tuple(sdk.parts[-3:]) != ("bin", "cache", "dart-sdk") or any(
        part in str(sdk).lower()
        for part in (
            "reference_distribution",
            "credential",
            "search_service",
            "search-service",
        )
    ):
        raise identity.IdentityError("unowned_worker_sdk_root")
    packages, languages = package_roots(config, root)
    sdk_names = [
        "version",
        "revision",
        *tree_names(sdk, "bin", sdk=True),
        *tree_names(sdk, "lib", sdk=True),
    ]
    package_names = {
        name: ["pubspec.yaml", *tree_names(path, "lib")]
        for name, path in packages.items()
    }
    # Product verification performs only its own predeclared native/SQL reads.
    native = products.verify(root, build)["native_id"]
    source = {}
    for name in sorted(names):
        data = identity._read(root, name)
        if name.endswith(".dart"):
            identity._check_dart_imports(name, data, names, set(EXTERNAL))
        source[name] = hashlib.sha256(data).hexdigest()
    if (
        identity._read(sdk, "version").strip() != b"3.9.2"
        or identity._read(sdk, "revision").strip()
        != b"a29e08c72e2ce21813c1edf50cbcdfcac7a7acdd"
    ):
        raise identity.IdentityError("unqualified_worker_sdk")
    sdk_inputs = {name: digest_file(sdk, name) for name in sorted(sdk_names)}
    runtime_names = {
        "version",
        "revision",
        "bin/dart",
        "bin/snapshots/kernel-service.dart.snapshot",
    }
    runtime_names.update(name for name in sdk_inputs if name.startswith("lib/"))
    if not runtime_names <= sdk_inputs.keys():
        raise identity.IdentityError("incomplete_worker_runtime_sdk")
    dependencies = {}
    for name, path in sorted(packages.items()):
        inputs = {}
        for relative in package_names[name]:
            digest = digest_file(path, relative)
            if relative.endswith(".dart"):
                data = identity._read(path, relative)
                if hashlib.sha256(data).hexdigest() != digest:
                    raise identity.IdentityError("worker_runtime_input_changed")
                package_imports(relative, data, name, package_names)
            inputs[relative] = digest
        dependencies[name] = {"language": languages[name], "inputs": inputs}
    catalog = [owned_path(n) for n in identity._strings(contract.worker["catalog"])]
    if not catalog or not set(catalog) <= names:
        raise identity.IdentityError("invalid_worker_catalog")
    catalog_id = identity._digest({n: source[n] for n in catalog})
    record = {
        "algorithm": "foresight-standalone-worker-v1",
        "scope": "components",
        "native_id": native,
        "mode": mode,
        "catalog_id": catalog_id,
        "inputs": source,
        "sdk": {
            "version": "3.9.2",
            "revision": "a29e08c72e2ce21813c1edf50cbcdfcac7a7acdd",
            "inputs": sdk_inputs,
            "runtime_inputs": {
                name: sdk_inputs[name] for name in sorted(runtime_names)
            },
        },
        "packages": dependencies,
        "options": {"record_schema": 2, "assertions": False},
        "external_imports": sorted(EXTERNAL),
    }
    return {
        "schema": 1,
        "kind": "standalone-worker" if mode == "jit" else "standalone-worker-candidate",
        "worker_id": identity._digest(record),
        "catalog_id": catalog_id,
        "record": record,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "build", "sdk", "package-config", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--mode", choices=("jit", "kernel", "aot"), required=True)
    args = parser.parse_args()
    try:
        result = collect(
            args.root, args.build, args.sdk, args.package_config, args.mode
        )
        args.output.write_bytes(identity._canonical(result) + b"\n")
    except (OSError, ValueError, KeyError, TypeError):
        print("Worker context unavailable: closed inputs refused", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
