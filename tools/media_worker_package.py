"""Verify pinned codec build materials, stage them, and seal installed bytes.

This is an installed executable admission boundary, not CI producer approval.
The explicit source build must independently satisfy existing artifact rules.
New receipt/schema changes require owner review; no compiler work is inferred
from a receipt or from copying a previously qualified product.
"""

from __future__ import annotations

from dataclasses import dataclass
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
from typing import Any, cast

try:
    from build_media_worker import SOURCES
except ModuleNotFoundError:
    from tools.build_media_worker import SOURCES

BINARY = "bin/foresight-media-worker"
MATERIALS = "licenses/media"
BUILD_RECEIPT = "media-worker-build.json"
APPLICATION_SOURCES = (
    "native/media_worker.cpp",
    "native/media_assembly.inc",
    "native/media_pager_protocol.h",
    "native/media_bootstrap.h",
    "native/media_process.cpp",
    "native/media_process.h",
    "native/media_supervisor.cpp",
    "native/media_supervisor.h",
    "native/media_supervisor_protocol.h",
    "native/portable_process.h",
    "native/diagnostic_sha256.c",
    "native/diagnostic_sha256.h",
    "tools/build_media_worker.py",
)
LIBRARIES = ("libopusenc.a", "libopusfile.a", "libopus.a", "libogg.a", "libmp3lame.a")
OBJECTS = (
    "media_worker.o",
    "diagnostic_sha256.o",
    "media_process.o",
    "media_supervisor.o",
)
OPERATIONS = ["encode-opus", "encode-recording-wav-v1", "decode-pcm", "mix-export-mp3"]
_SHA = re.compile(r"^[0-9a-f]{64}$")


class MediaPackageError(ValueError):
    """Selected media worker cannot be attributed to the current pinned build."""


def _require(value: bool, message: str) -> None:
    if not value:
        raise MediaPackageError(message)


def _sha(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def _relative(name: str) -> list[str]:
    path = PurePosixPath(name)
    _require(
        not path.is_absolute()
        and bool(path.parts)
        and str(path) == name
        and all(part not in (".", "..") for part in path.parts),
        "unsafe_media_relative_path",
    )
    return list(path.parts)


def _directory_info(fd: int) -> None:
    value = os.fstat(fd)
    _require(
        stat.S_ISDIR(value.st_mode)
        and value.st_uid in (0, os.getuid())
        and not value.st_mode & 0o022,
        "unsafe_media_directory",
    )


def _read(
    root: Path, name: str, *, executable: bool = False, maximum: int = 64 * 1024 * 1024
) -> bytes:
    parts = _relative(name)
    root = root.absolute()
    _require(not root.is_symlink(), "unsafe_media_directory")
    directory = os.open(
        root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    )
    fd = -1
    try:
        _directory_info(directory)
        for part in parts[:-1]:
            child = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=directory,
            )
            os.close(directory)
            directory = child
            _directory_info(directory)
        fd = os.open(
            parts[-1],
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=directory,
        )
        before = os.fstat(fd)
        _require(
            stat.S_ISREG(before.st_mode)
            and before.st_nlink == 1
            and before.st_uid in (0, os.getuid())
            and not before.st_mode & 0o022
            and 0 < before.st_size <= maximum
            and (not executable or bool(before.st_mode & 0o111)),
            "unsafe_media_file",
        )
        with os.fdopen(fd, "rb", closefd=False) as stream:
            blob = stream.read(maximum + 1)
        after = os.fstat(fd)
        fields = (
            "st_dev",
            "st_ino",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
            "st_uid",
            "st_mode",
            "st_nlink",
        )
        _require(
            len(blob) == before.st_size
            and all(
                getattr(before, field) == getattr(after, field) for field in fields
            ),
            "media_file_changed_during_read",
        )
        return blob
    finally:
        if fd >= 0:
            os.close(fd)
        os.close(directory)


def receipt_path(target: str) -> str:
    _require(target in ("darwin-arm64", "linux-x86_64"), "unsupported_media_target")
    return (
        "media-worker.json"
        if target == "darwin-arm64"
        else "share/open-foresight/media-worker.json"
    )


def _format(blob: bytes, target: str) -> None:
    if target == "linux-x86_64":
        okay = (
            len(blob) >= 64
            and blob[:6] == b"\x7fELF\x02\x01"
            and blob[18:20] == b"\x3e\0"
        )
    else:
        okay = len(blob) >= 32 and blob[:8] == b"\xcf\xfa\xed\xfe\x0c\0\0\x01"
    _require(okay, "media_executable_architecture_mismatch")


def _description(value: Any, build_id: str) -> tuple[tuple[str, ...], int]:
    assembly = value.get("assembly_protocol", 0) if isinstance(value, dict) else None
    operations = OPERATIONS + (
        ["assemble-mp3-v1", "assemble-opus-v1", "assemble-pcm-v1"]
        if assembly == 1
        else []
    )
    _require(
        isinstance(value, dict)
        and type(assembly) is int
        and assembly in (0, 1)
        and all(
            type(value.get(key)) is int and value.get(key) == expected
            for key, expected in {
                "protocol": 1,
                "bootstrap_protocol": 2,
                "supervisor_fence_protocol": 1,
                "owner_lock_fd": 7,
                "sample_rate": 48000,
                "channels": 1,
                "max_chunk_frames": 240000,
                "max_range_frames": 240000 if assembly == 1 else 4800,
            }.items()
        )
        and value.get("capability_transport") == "scm_rights"
        and value.get("build_id") == build_id
        and value.get("operations") == operations,
        "media_worker_protocol_mismatch",
    )
    return tuple(operations), cast(int, assembly)


def _identity(receipt: dict[str, Any]) -> str:
    # Builder freezes the identity before compiling worker objects. Its public
    # commands field later contains the full raw transcript, so reconstruct the
    # exact pre-compilation normalized prefix rather than relabeling all commands.
    commands = receipt["commands"]
    _require(
        isinstance(commands, list)
        and 1 <= len(commands) <= 128
        and all(
            isinstance(command, list)
            and 1 <= len(command) <= 128
            and all(isinstance(part, str) and len(part) <= 8192 for part in command)
            for command in commands
        ),
        "invalid_media_build_commands",
    )
    first_compile = next(
        (
            index
            for index, command in enumerate(commands)
            if "-std=c11" in command
            and any(part.endswith("/native/diagnostic_sha256.c") for part in command)
        ),
        -1,
    )
    source = next(
        (
            part
            for command in commands
            for part in command
            if part.endswith("/native/media_worker.cpp")
        ),
        "",
    )
    _require(
        first_compile > 0
        and source.startswith("/")
        and isinstance(receipt["build_log"], str)
        and receipt["build_log"].startswith("/"),
        "invalid_media_build_identity",
    )
    old_root = str(Path(source).parents[1])
    old_work = str(Path(receipt["build_log"]).parent)
    identity = {
        key: receipt[key]
        for key in (
            "protocol",
            "sources",
            "application_sources",
            "compiler",
            "platform",
            "architecture",
            "deployment_target",
        )
    }
    identity["commands"] = [
        [
            part.replace(old_work, "<build>").replace(old_root, "<source>")
            for part in command
        ]
        for command in commands[:first_compile]
    ]
    return _sha(json.dumps(identity, sort_keys=True).encode())


@dataclass(frozen=True)
class PreparedMediaWorker:
    target: str
    build_id: str
    binary: bytes
    materials: dict[str, bytes]
    source_receipt_sha256: str
    operations: tuple[str, ...] = tuple(OPERATIONS)
    assembly_protocol: int = 0


def prepare(root: Path, build: Path, target: str) -> PreparedMediaWorker:
    """Verify actual selected bytes and complete source/relink materials."""
    receipt_path(target)
    receipt_blob = _read(build, BUILD_RECEIPT, maximum=1024 * 1024)
    receipt = json.loads(receipt_blob)
    _require(isinstance(receipt, dict), "invalid_media_build_receipt")
    platform, architecture = target.split("-", 1)
    _require(
        receipt.get("platform") == {"darwin": "Darwin", "linux": "Linux"}[platform]
        and receipt.get("architecture") == architecture
        and receipt.get("deployment_target")
        == ("15.0" if platform == "darwin" else None),
        "media_build_target_mismatch",
    )
    build_id = receipt.get("build_id")
    _require(
        isinstance(build_id, str) and bool(_SHA.fullmatch(build_id)),
        "invalid_media_build_id",
    )
    _require(
        receipt.get("sources")
        == {name: list(value) for name, value in SOURCES.items()},
        "media_codec_pins_mismatch",
    )
    expected_sources = {name: _sha(_read(root, name)) for name in APPLICATION_SOURCES}
    _require(
        receipt.get("application_sources") == expected_sources,
        "media_application_source_mismatch",
    )
    _require(_identity(receipt) == build_id, "media_build_identity_mismatch")
    operations, assembly_protocol = _description(receipt.get("description"), build_id)
    dependencies = receipt.get("dynamic_dependencies")
    _require(
        isinstance(dependencies, str)
        and not any(
            name in dependencies
            for name in ("libopus", "libogg", "libmp3lame", "libmpg123")
        ),
        "external_media_codec_dependency",
    )
    binary = _read(
        build, "foresight-media-worker", executable=True, maximum=32 * 1024 * 1024
    )
    _format(binary, target)
    _require(
        _sha(binary) == receipt.get("binary_sha256")
        and len(binary) == receipt.get("binary_bytes")
        and binary.count(build_id.encode()) == 1,
        "media_build_binary_mismatch",
    )
    materials = {BUILD_RECEIPT: receipt_blob}
    for relative, digest in expected_sources.items():
        name = "sources/" + Path(relative).name
        blob = _read(build, name)
        _require(_sha(blob) == digest, "media_copied_source_mismatch")
        materials[name] = blob
    for directory, names, field in (
        ("lib", LIBRARIES, "static_library_sha256"),
        ("objects", OBJECTS, "relink_object_sha256"),
    ):
        hashes = receipt.get(field)
        _require(
            isinstance(hashes, dict) and set(hashes) == set(names),
            "media_relink_materials_mismatch",
        )
        for name in names:
            blob = _read(build, f"{directory}/{name}")
            _require(_sha(blob) == hashes[name], "media_relink_materials_mismatch")
            materials[f"{directory}/{name}"] = blob
    for name, (_, digest) in SOURCES.items():
        relative = "sources/" + name + ".tar.gz"
        blob = _read(build, relative)
        _require(_sha(blob) == digest, "media_codec_archive_mismatch")
        materials[relative] = blob
        # Read the pinned archive's COPYING without extracting arbitrary paths.
        with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
            member = archive.getmember(name + "/COPYING")
            _require(
                member.isfile() and 0 < member.size <= 1024 * 1024,
                "unsafe_media_license",
            )
            stream = archive.extractfile(member)
            if stream is None:
                raise MediaPackageError("missing_media_license")
            with stream:
                license_blob = stream.read(1024 * 1024 + 1)
        notice = "notices/" + name + "-COPYING"
        _require(_read(build, notice) == license_blob, "media_license_mismatch")
        materials[notice] = license_blob
    notice = "notices/open-foresight-LICENSE"
    materials[notice] = _read(root, "LICENSE")
    _require(_read(build, notice) == materials[notice], "media_license_mismatch")
    _require(
        sum(map(len, materials.values())) <= 256 * 1024 * 1024,
        "media_materials_exceed_limit",
    )
    return PreparedMediaWorker(
        target,
        build_id,
        binary,
        materials,
        _sha(receipt_blob),
        operations,
        assembly_protocol,
    )


def _put(payload: Path, relative: str, blob: bytes, mode: int) -> None:
    parts = _relative(relative)
    directory = os.open(
        payload, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    )
    fd = -1
    try:
        _directory_info(directory)
        for part in parts[:-1]:
            try:
                os.mkdir(part, mode=0o755, dir_fd=directory)
            except FileExistsError:
                pass
            child = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=directory,
            )
            os.close(directory)
            directory = child
            _directory_info(directory)
        fd = os.open(
            parts[-1],
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            mode,
            dir_fd=directory,
        )
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(blob)
    finally:
        if fd >= 0:
            os.close(fd)
        os.close(directory)


def _staged_materials(prepared: PreparedMediaWorker) -> dict[str, bytes]:
    # Raw Mach-O relink objects must not be treated as executable bundle code by
    # generic relocation/signing. A deterministic archive preserves exact bytes.
    packed = io.BytesIO()
    with gzip.GzipFile(fileobj=packed, mode="wb", filename="", mtime=0) as zipped:
        with tarfile.open(
            fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT
        ) as archive:
            for name, blob in sorted(prepared.materials.items()):
                _relative(name)
                info = tarfile.TarInfo(name)
                info.size = len(blob)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(blob))
    return {
        BUILD_RECEIPT: prepared.materials[BUILD_RECEIPT],
        "relink-materials.tar.gz": packed.getvalue(),
        **{
            name: blob
            for name, blob in prepared.materials.items()
            if name.startswith("notices/")
        },
    }


def stage(payload: Path, prepared: PreparedMediaWorker) -> None:
    _put(payload, BINARY, prepared.binary, 0o755)
    for relative, blob in _staged_materials(prepared).items():
        _put(payload, f"{MATERIALS}/{relative}", blob, 0o644)


def _cdhash(path: Path) -> str:
    for args in (
        ["codesign", "--verify", "--strict", str(path)],
        ["codesign", "--display", "--verbose=4", str(path)],
    ):
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=30, check=False
        )
        _require(
            result.returncode == 0,
            f"media_codesign_failed: {result.stdout}\n{result.stderr}",
        )
    match = re.search(r"^CDHash=([0-9a-fA-F]{40,64})$", result.stderr, re.MULTILINE)
    _require(match is not None, "media_codesign_cdhash_missing")
    return match.group(1).lower() if match else ""


def seal(payload: Path, prepared: PreparedMediaWorker) -> dict[str, Any]:
    """Run after leaf signing/relocation and before any outer signature seal."""
    for relative, blob in _staged_materials(prepared).items():
        _require(
            _read(payload, f"{MATERIALS}/{relative}") == blob,
            "media_package_provenance_changed",
        )
    binary = _read(payload, BINARY, executable=True, maximum=32 * 1024 * 1024)
    _format(binary, prepared.target)
    _require(
        binary.count(prepared.build_id.encode()) == 1,
        "media_package_build_identity_changed",
    )
    mac = prepared.target == "darwin-arm64"
    _require(mac or binary == prepared.binary, "media_package_copy_changed")
    cdhash = _cdhash(payload / BINARY) if mac else None
    # codesign is read-only, but do not publish a receipt if bytes changed while
    # it inspected the executable. Native admission re-verifies again at launch.
    _require(
        _read(payload, BINARY, executable=True, maximum=32 * 1024 * 1024) == binary,
        "media_package_changed_during_signing_check",
    )
    receipt = {
        "schema": 1,
        "kind": "audio-media-worker",
        "target": prepared.target,
        "path": BINARY,
        "protocol": 1,
        "bootstrap_protocol": 2,
        "supervisor_fence_protocol": 1,
        "build_id": prepared.build_id,
        "sha256": _sha(binary),
        "bytes": len(binary),
        "macos_cdhash": cdhash,
        "source_receipt_sha256": prepared.source_receipt_sha256,
        "capabilities": {
            "operations": list(prepared.operations),
            "assembly_protocol": prepared.assembly_protocol,
        },
    }
    _put(
        payload,
        receipt_path(prepared.target),
        (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode(),
        0o644,
    )
    return receipt
