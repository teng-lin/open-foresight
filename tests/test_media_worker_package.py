"""Byte-level media package proofs; synthetic headers are not compiler evidence."""

from __future__ import annotations
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import pytest
from tools import media_worker_package as media


def put(path: Path, blob: bytes) -> bytes:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)
    return blob


@pytest.fixture(params=["linux-x86_64", "darwin-arm64"])
def built(tmp_path, monkeypatch, request):
    root, build, payload = (tmp_path / name for name in ("source", "build", "payload"))
    for path in (root, build, payload):
        path.mkdir(mode=0o700)
    sources = {
        name: media._sha(put(root / name, ("synthetic " + name).encode()))
        for name in media.APPLICATION_SOURCES
    }
    put(root / "LICENSE", b"synthetic project license")
    materials = {}
    pins = {}
    for name in media.SOURCES:
        archive = build / "sources" / f"{name}.tar.gz"
        archive.parent.mkdir(exist_ok=True)
        with tarfile.open(archive, "w:gz") as stream:
            blob = (name + " license").encode()
            member = tarfile.TarInfo(name + "/COPYING")
            member.size = len(blob)
            stream.addfile(member, io.BytesIO(blob))
        pins[name] = (
            "https://fixture.invalid/" + name,
            media._sha(archive.read_bytes()),
        )
        put(build / "notices" / f"{name}-COPYING", blob)
    monkeypatch.setattr(media, "SOURCES", pins)
    for name in media.APPLICATION_SOURCES:
        put(build / "sources" / Path(name).name, (root / name).read_bytes())
    put(build / "notices/open-foresight-LICENSE", (root / "LICENSE").read_bytes())
    platform, architecture = request.param.split("-", 1)
    identity = {
        "protocol": 1,
        "sources": {n: list(v) for n, v in pins.items()},
        "application_sources": sources,
        "compiler": "synthetic fixture compiler, not executed",
        "platform": "Darwin" if platform == "darwin" else "Linux",
        "architecture": architecture,
        "deployment_target": "15.0" if platform == "darwin" else None,
        "commands": [
            ["fixture-cc", "--version"],
            ["./configure", "--prefix=<build>/stage"],
        ],
    }
    build_id = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    binary = bytearray(64)
    if platform == "darwin":
        binary[:8] = bytes.fromhex("cffaedfe0c000001")
    else:
        binary[:6] = b"\x7fELF\x02\x01"
        binary[18:20] = b"\x3e\0"
    binary += b"synthetic package fixture" + build_id.encode()
    put(build / "foresight-media-worker", bytes(binary))
    (build / "foresight-media-worker").chmod(0o755)
    for directory, names, field in [
        ("lib", media.LIBRARIES, "static_library_sha256"),
        ("objects", media.OBJECTS, "relink_object_sha256"),
    ]:
        materials[field] = {
            name: media._sha(
                put(build / directory / name, ("synthetic " + name).encode())
            )
            for name in names
        }
    receipt = {
        **identity,
        "build_id": build_id,
        "binary_sha256": media._sha(binary),
        "binary_bytes": len(binary),
        **materials,
        "description": {
            "protocol": 1,
            "bootstrap_protocol": 2,
            "supervisor_fence_protocol": 1,
            "capability_transport": "scm_rights",
            "owner_lock_fd": 7,
            "build_id": build_id,
            "operations": media.OPERATIONS,
            "sample_rate": 48000,
            "channels": 1,
            "max_chunk_frames": 240000,
            "max_range_frames": 4800,
        },
        "dynamic_dependencies": "system runtime only",
        "build_log": "/original/build/build.log",
        "commands": [
            ["fixture-cc", "--version"],
            ["./configure", "--prefix=/original/build/stage"],
            [
                "fixture-cc",
                "-std=c11",
                "-c",
                "/original/source/native/diagnostic_sha256.c",
            ],
            ["fixture-c++", "-c", "/original/source/native/media_worker.cpp"],
        ],
    }
    put(build / media.BUILD_RECEIPT, json.dumps(receipt).encode())
    monkeypatch.setattr(media, "_cdhash", lambda path: "c" * 40)
    return root, build, payload, request.param, receipt


def prepare(built):
    return media.prepare(built[0], built[1], built[3])


def test_verified_stage_and_post_sign_receipt(built):
    root, build, payload, target, source = built
    prepared = prepare(built)
    media.stage(payload, prepared)
    binary = payload / media.BINARY
    if target == "darwin-arm64":
        binary.write_bytes(binary.read_bytes() + b"synthetic signature")
    result = media.seal(payload, prepared)
    assert result["build_id"] == source["build_id"]
    assert result["sha256"] == media._sha(binary.read_bytes())
    assert result["macos_cdhash"] == ("c" * 40 if target == "darwin-arm64" else None)
    assert result["source_receipt_sha256"] == media._sha(
        (build / media.BUILD_RECEIPT).read_bytes()
    )
    assert json.loads((payload / media.receipt_path(target)).read_text()) == result
    with tarfile.open(payload / media.MATERIALS / "relink-materials.tar.gz") as archive:
        for directory, names in (("lib", media.LIBRARIES), ("objects", media.OBJECTS)):
            for name in names:
                stream = archive.extractfile(f"{directory}/{name}")
                assert stream is not None
                assert stream.read() == (build / directory / name).read_bytes()
    assert result["capabilities"] == {
        "operations": media.OPERATIONS,
        "assembly_protocol": 0,
    }
    assert (payload / media.BINARY).stat().st_mode & 0o777 == 0o755
    with pytest.raises(FileExistsError):
        media.stage(payload, prepared)
    with pytest.raises(FileExistsError):
        media.seal(payload, prepared)


@pytest.mark.parametrize(
    "bad",
    [
        "binary",
        "source",
        "copied-source",
        "archive",
        "library",
        "object",
        "license",
        "build-id",
        "target",
        "protocol",
        "protocol_bool",
        "incomplete_assembly",
        "pins",
        "commands",
        "codec-dll",
    ],
)
def test_prepare_refuses_changed_actual_inputs(built, bad):
    root, build, _, _, receipt = built
    if bad in (
        "binary",
        "source",
        "copied-source",
        "archive",
        "library",
        "object",
        "license",
    ):
        path = {
            "binary": build / "foresight-media-worker",
            "source": root / media.APPLICATION_SOURCES[0],
            "copied-source": build / "sources/media_worker.cpp",
            "archive": build / "sources" / f"{next(iter(media.SOURCES))}.tar.gz",
            "library": build / "lib" / media.LIBRARIES[0],
            "object": build / "objects" / media.OBJECTS[0],
            "license": build / "notices/open-foresight-LICENSE",
        }[bad]
        path.write_bytes(path.read_bytes() + b"changed")
    else:
        if bad == "build-id":
            receipt["build_id"] = "0" * 64
        elif bad == "target":
            receipt["architecture"] = "foreign"
        elif bad == "protocol":
            receipt["description"]["bootstrap_protocol"] = 1
        elif bad == "protocol_bool":
            receipt["description"]["channels"] = True
        elif bad == "incomplete_assembly":
            receipt["description"].update(
                assembly_protocol=1,
                operations=media.OPERATIONS + ["assemble-mp3-v1", "assemble-opus-v1"],
                max_range_frames=240000,
            )
        elif bad == "pins":
            receipt["sources"] = {}
        elif bad == "commands":
            receipt["commands"][1][1] = "--prefix=forged"
        else:
            receipt["dynamic_dependencies"] = "libopus.so => /foreign/libopus.so"
        (build / media.BUILD_RECEIPT).write_text(json.dumps(receipt))
    with pytest.raises((ValueError, OSError)):
        prepare(built)


def test_assembly_receipt_preserves_exact_qualified_features(built):
    receipt = built[4]
    operations = media.OPERATIONS + [
        "assemble-mp3-v1",
        "assemble-opus-v1",
        "assemble-pcm-v1",
    ]
    receipt["description"].update(
        assembly_protocol=1, operations=operations, max_range_frames=240000
    )
    (built[1] / media.BUILD_RECEIPT).write_text(json.dumps(receipt))
    prepared = prepare(built)
    media.stage(built[2], prepared)
    result = media.seal(built[2], prepared)
    assert result["capabilities"] == {
        "operations": operations,
        "assembly_protocol": 1,
    }


@pytest.mark.parametrize(
    "entry",
    [
        "foresight-media-worker",
        media.BUILD_RECEIPT,
        "sources",
        "lib",
        "objects",
        "notices",
    ],
)
def test_input_symlink_components_refused(built, entry):
    path = built[1] / entry
    other = path.with_name(path.name + "-original")
    path.rename(other)
    path.symlink_to(other, target_is_directory=other.is_dir())
    with pytest.raises((ValueError, OSError)):
        prepare(built)


def test_unsafe_permissions_and_destination_escape_refused(built):
    worker = built[1] / "foresight-media-worker"
    worker.chmod(0o777)
    with pytest.raises(ValueError, match="unsafe_media_file"):
        prepare(built)
    worker.chmod(0o755)
    prepared = prepare(built)
    outside = built[2].parent / "outside"
    outside.mkdir()
    (built[2] / "bin").symlink_to(outside, target_is_directory=True)
    with pytest.raises(OSError):
        media.stage(built[2], prepared)
    assert list(outside.iterdir()) == []


def test_final_provenance_and_copy_rechecked(built):
    prepared = prepare(built)
    media.stage(built[2], prepared)
    material = built[2] / media.MATERIALS / media.BUILD_RECEIPT
    material.write_bytes(material.read_bytes() + b"changed")
    with pytest.raises(ValueError, match="provenance_changed"):
        media.seal(built[2], prepared)
    material.write_bytes(prepared.materials[media.BUILD_RECEIPT])
    binary = built[2] / media.BINARY
    binary.write_bytes(
        binary.read_bytes().replace(prepared.build_id.encode(), b"0" * 64)
    )
    with pytest.raises(ValueError, match="build_identity_changed"):
        media.seal(built[2], prepared)


def test_copy_transformation_needs_macos_postsign_identity(built, monkeypatch):
    prepared = prepare(built)
    media.stage(built[2], prepared)
    binary = built[2] / media.BINARY
    binary.write_bytes(binary.read_bytes() + b"changed")
    if built[3] == "linux-x86_64":
        with pytest.raises(ValueError, match="copy_changed"):
            media.seal(built[2], prepared)
    else:

        def mutate_during_verification(path):
            path.write_bytes(path.read_bytes() + b"raced")
            return "c" * 40

        monkeypatch.setattr(media, "_cdhash", mutate_during_verification)
        with pytest.raises(ValueError, match="changed_during_signing_check"):
            media.seal(built[2], prepared)


@pytest.mark.parametrize("failure", ["none", "verify", "missing"])
def test_codesign_final_hash_and_failure_evidence(tmp_path, monkeypatch, failure):
    calls = []

    def run(args, **kwargs):
        calls.append(args)
        assert (
            kwargs["timeout"] == 30
            and kwargs["capture_output"]
            and kwargs["check"] is False
        )
        return subprocess.CompletedProcess(
            args,
            1 if failure == "verify" else 0,
            "captured stdout",
            "captured stderr" if failure == "missing" else "CDHash=" + "A" * 40 + "\n",
        )

    monkeypatch.setattr(media.subprocess, "run", run)
    if failure in ("verify", "missing"):
        with pytest.raises(ValueError, match="captured stdout|cdhash_missing"):
            media._cdhash(tmp_path / "worker")
    else:
        assert media._cdhash(tmp_path / "worker") == "a" * 40
        assert calls[0][1:3] == ["--verify", "--strict"] and calls[1][1:3] == [
            "--display",
            "--verbose=4",
        ]
