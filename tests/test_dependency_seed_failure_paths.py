"""Seed extraction rejects incompatible bytes without touching retained outputs."""

import hashlib
import io
import json
import tarfile

import pytest
from test_ci_app_dependency_seed import seed, archive, file, PREFIX


def tar_bytes(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as stream:
        for name, content, kind in entries:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.size = len(content)
            stream.addfile(member, io.BytesIO(content))
    return output.getvalue()


@pytest.mark.parametrize(
    "reader,name,constant,record",
    [
        (
            "toolchain_proof",
            "ubuntu_app_dependency_seed.json",
            "TOOLCHAIN_PROOF",
            {"schema": 2},
        ),
        (
            "tool_runtime_compatibility",
            "ubuntu_app_dependency_runtime_compatibility.json",
            "TOOL_RUNTIME_COMPATIBILITY",
            {"schema": 2},
        ),
    ],
)
def test_proof_requires_both_checksum_and_supported_schema(
    tmp_path, monkeypatch, reader, name, constant, record
):
    path = tmp_path / "tools" / name
    path.parent.mkdir()
    path.write_text(json.dumps(record))
    with pytest.raises(ValueError, match="changed"):
        getattr(seed, reader)(tmp_path)
    monkeypatch.setattr(seed, constant, seed.digest(path))
    with pytest.raises(ValueError, match="Invalid"):
        getattr(seed, reader)(tmp_path)


def test_copied_hashes_ignores_directories_and_only_reads_requested_headers():
    data = tar_bytes(
        [
            (".", b"", tarfile.DIRTYPE),
            ("include", b"", tarfile.DIRTYPE),
            ("include/needed.h", b"verified header", tarfile.REGTYPE),
            ("include/other.h", b"unconsumed", tarfile.REGTYPE),
        ]
    )
    assert seed.copied_hashes(data, "/usr/include", {"/usr/include/needed.h"}) == {
        "/usr/include/needed.h": hashlib.sha256(b"verified header").hexdigest()
    }


def test_single_file_sdk_copy_cannot_substitute_multiple_members():
    data = tar_bytes(
        [
            ("parent/first", b"a", tarfile.REGTYPE),
            ("parent/second", b"b", tarfile.REGTYPE),
        ]
    )
    with pytest.raises(ValueError, match="single-file SDK inspection"):
        seed.verify_toolchain_files(
            "unstarted", {"files": {"/usr/bin/gcc": "a" * 64}}, lambda *a, **kw: data
        )


@pytest.mark.parametrize("failure", ["image", "container"])
def test_sdk_profile_validates_identifiers_before_copy_or_execution(failure):
    calls = []

    def request(command, **kwargs):
        calls.append(command)
        if command[:3] == ["docker", "image", "inspect"]:
            return json.dumps(
                {"Id": "invalid" if failure == "image" else "sha256:" + "a" * 64}
            )
        assert command[:2] == ["docker", "create"]
        return "invalid-container"

    with pytest.raises(ValueError, match="Invalid"):
        seed.sdk_profile("verified-sdk", request)
    assert len(calls) == (1 if failure == "image" else 2)
    assert not any("start" in command or "run" in command for command in calls)


def test_registry_token_is_read_only_and_bounded(monkeypatch):
    calls = []

    def opening(url, **kw):
        calls.append((url, kw))
        return io.BytesIO(b'{"token":"fixture-token"}')

    monkeypatch.setattr(seed.urllib.request, "urlopen", opening)
    assert seed.registry_token() == "fixture-token"
    assert calls == [
        (
            "https://ghcr.io/token?scope=repository:"
            + seed.REPOSITORY
            + "/linux-sdk:pull",
            {"timeout": 60},
        )
    ]


@pytest.mark.parametrize(
    "response,expected_size", [(b"too long", 1), (b"short", 8), (b"bad checksum", 12)]
)
def test_failed_blob_download_retains_other_verified_blobs(
    tmp_path, monkeypatch, response, expected_size
):
    keep = tmp_path / "verified-blob"
    keep.write_bytes(b"keep successful download")
    monkeypatch.setattr(
        seed.urllib.request, "urlopen", lambda *a, **kw: io.BytesIO(response)
    )
    with pytest.raises(ValueError):
        seed.fetch(
            tmp_path,
            "a" * 64,
            expected_size,
            "blobs/sha256:" + "a" * 64,
            "fixture-token",
        )
    assert sorted(p.name for p in tmp_path.iterdir()) == ["verified-blob"]
    assert keep.read_bytes() == b"keep successful download"


@pytest.mark.parametrize(
    "failure", ["mode", "budget", "member-parent", "whiteout-parent"]
)
def test_invalid_layer_does_not_escape_staging(tmp_path, monkeypatch, failure):
    output = tmp_path / "staging"
    output.mkdir()
    outside = tmp_path / "successful"
    outside.mkdir()
    keep = outside / "keep.o"
    keep.write_bytes(b"verified object")
    if failure in ("member-parent", "whiteout-parent"):
        (output / "src/build").mkdir(parents=True)
        (output / "src/build/_deps").symlink_to(outside)
    name = PREFIX + ("/.wh.keep.o" if failure == "whiteout-parent" else "/new.o")
    layer = archive(tmp_path / "layer.gz", [file(name)])
    if failure == "mode":
        with tarfile.open(layer, "w:gz") as stream:
            member = tarfile.TarInfo(name)
            member.mode = 0o4755
            stream.addfile(member)
    elif failure == "budget":
        monkeypatch.setattr(seed, "MAX_SELECTED_BYTES", 1)
    with pytest.raises(ValueError):
        seed.apply_layers([layer], output)
    assert keep.read_bytes() == b"verified object"


def test_overlay_replaces_file_directory_symlink_and_hardlink_without_losing_unrelated_outputs(
    tmp_path,
):
    first = archive(
        tmp_path / "first.gz",
        [
            file(PREFIX + "/directory"),
            file(PREFIX + "/original.o"),
            file(PREFIX + "/link"),
            file(PREFIX + "/hard"),
        ],
    )
    second = archive(
        tmp_path / "second.gz",
        [
            (PREFIX + "/directory", b"", tarfile.DIRTYPE, ""),
            file(PREFIX + "/directory/old.o"),
            (PREFIX + "/link", b"", tarfile.SYMTYPE, "original.o"),
            (PREFIX + "/hard", b"", tarfile.LNKTYPE, PREFIX + "/original.o"),
        ],
    )
    third = archive(
        tmp_path / "third.gz",
        [
            file(PREFIX + "/directory/.wh..wh..opq", b""),
            file(PREFIX + "/directory/new.o", b"new"),
        ],
    )
    output = tmp_path / "seed"
    output.mkdir()
    seed.apply_layers([first, second, third], output)
    assert not (output / PREFIX / "directory/old.o").exists()
    assert (output / PREFIX / "directory/new.o").read_bytes() == b"new"
    assert (output / PREFIX / "link").is_symlink()
    assert (output / PREFIX / "hard").stat().st_ino == (
        output / PREFIX / "original.o"
    ).stat().st_ino
    assert (output / PREFIX / "original.o").read_bytes() == b"object"
