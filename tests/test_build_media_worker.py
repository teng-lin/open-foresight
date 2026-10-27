from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

import pytest

from tools import build_media_worker as media


def archive(path: Path, members: list[tuple[str, bytes, bytes]]) -> None:
    with tarfile.open(path, "w:gz") as output:
        for name, data, kind in members:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.size = len(data)
            output.addfile(member, io.BytesIO(data))


@pytest.mark.parametrize(
    "name,kind",
    [
        ("../escape", tarfile.REGTYPE),
        ("/absolute", tarfile.REGTYPE),
        ("link", tarfile.SYMTYPE),
        ("hard", tarfile.LNKTYPE),
        ("fifo", tarfile.FIFOTYPE),
    ],
)
def test_archive_rejects_escape_and_special_members(tmp_path, name, kind):
    source = tmp_path / "archive.tar.gz"
    archive(source, [(name, b"", kind)])
    with pytest.raises(ValueError, match="unsafe source archive member"):
        media.extract(source, tmp_path / "extract")


def test_verified_archive_and_extraction(tmp_path):
    source = tmp_path / "fixture.tar.gz"
    archive(source, [("source/COPYING", b"fixture license", tarfile.REGTYPE)])
    expected = hashlib.sha256(source.read_bytes()).hexdigest()
    assert (
        media.checked_archive(
            tmp_path, "fixture", "https://unused.invalid/", expected, False
        )
        == source
    )
    media.extract(source, tmp_path / "extract")
    assert (tmp_path / "extract/source/COPYING").read_bytes() == b"fixture license"
    source.write_bytes(b"corrupt")
    with pytest.raises(ValueError, match="checksum mismatch"):
        media.checked_archive(
            tmp_path, "fixture", "https://unused.invalid/", expected, False
        )


def test_private_directories_and_archive_links(tmp_path):
    directory = tmp_path / "directory"
    directory.mkdir(mode=0o755)
    with pytest.raises(ValueError, match="private owned"):
        media.private_directory(directory)
    link = tmp_path / "link"
    link.symlink_to(directory, target_is_directory=True)
    with pytest.raises(ValueError, match="private owned"):
        media.private_directory(link)
    source = tmp_path / "linked.tar.gz"
    source.symlink_to(directory)
    with pytest.raises(ValueError, match="unsafe source archive"):
        media.checked_archive(
            tmp_path, "linked", "https://unused.invalid", "0" * 64, False
        )


class Download(io.BytesIO):
    url = "https://fixture.invalid/source"


def test_download_requires_verified_https(tmp_path, monkeypatch):
    data = b"pinned fixture bytes"
    monkeypatch.setattr(media.urllib.request, "urlopen", lambda *a, **k: Download(data))
    value = media.checked_archive(
        tmp_path,
        "fixture",
        "https://fixture.invalid",
        hashlib.sha256(data).hexdigest(),
        True,
    )
    assert value.read_bytes() == data
    assert value.stat().st_mode & 0o077 == 0
    with pytest.raises(ValueError, match="HTTPS"):
        media.checked_archive(
            tmp_path, "http", "http://fixture.invalid", "0" * 64, True
        )
    with pytest.raises(ValueError, match="checksum mismatch"):
        media.checked_archive(
            tmp_path, "bad", "https://fixture.invalid", "0" * 64, True
        )
    assert not (tmp_path / "bad.tar.gz").exists()


def test_build_receipt_materials_and_failure_logs(tmp_path, monkeypatch):
    cache = tmp_path / "cache"
    cache.mkdir(mode=0o700)
    sources = {}
    for name in media.SOURCES:
        source = cache / (name + ".tar.gz")
        archive(
            source, [(name + "/COPYING", (name + " license").encode(), tarfile.REGTYPE)]
        )
        sources[name] = ("https://fixture.invalid/" + name, media.sha(source))
    monkeypatch.setattr(media, "SOURCES", sources)
    calls = []
    fail = False

    def run(args, **kwargs):
        calls.append(args)
        cwd = Path(kwargs["cwd"])
        if args[0] == "make" and args[-1] == "install":
            lib = cwd.parent / "stage/lib"
            lib.mkdir(parents=True, exist_ok=True)
            for name in [
                "libopusenc.a",
                "libopusfile.a",
                "libopus.a",
                "libogg.a",
                "libmp3lame.a",
            ]:
                (lib / name).write_bytes(b"synthetic static archive " + name.encode())
        if "-o" in args:
            Path(args[args.index("-o") + 1]).write_bytes(b"synthetic compiler output")
        stdout = b"test compiler"
        if args[-1] == "--describe":
            build_id = next(
                part.split('="', 1)[1][:-1]
                for call in calls
                for part in call
                if part.startswith("-DFORESIGHT_MEDIA_BUILD_ID=")
            )
            stdout = json.dumps({"protocol": 1, "build_id": build_id}).encode()
        if args[0] in ["otool", "ldd"]:
            stdout = b"system runtime only"
        if fail == "timeout":
            raise subprocess.TimeoutExpired(
                args, 30, output=b"captured timed-out compiler output"
            )
        return subprocess.CompletedProcess(args, 3 if fail else 0, stdout + b"\n", None)

    monkeypatch.setattr(media.subprocess, "run", run)
    output = tmp_path / "product"
    media.build(cache, output, fetch=False, jobs=2)
    receipt = json.loads((output / "media-worker-build.json").read_text())
    assert receipt["binary_sha256"] == media.sha(output / "foresight-media-worker")
    assert len(receipt["build_id"]) == 64
    assert len(list((output / "sources").glob("*.tar.gz"))) == 5
    assert len(list((output / "lib").glob("*.a"))) == 5
    assert {p.name for p in (output / "objects").glob("*.o")} == {
        "diagnostic_sha256.o",
        "media_worker.o",
        "media_process.o",
        "media_supervisor.o",
    }
    assert {
        "native/media_assembly.inc",
        "native/media_pager_protocol.h",
        "native/media_process.cpp",
        "native/media_supervisor.cpp",
        "native/media_supervisor_protocol.h",
        "native/portable_process.h",
    }.issubset(receipt["application_sources"])
    assert "objects/media_supervisor.o" in receipt["relink"]
    assert "-pthread" in receipt["relink"]
    if media.os.uname().sysname == "Darwin":
        assert "Security" in receipt["relink"]
        assert "CoreFoundation" in receipt["relink"]
    assert any("-DFORESIGHT_MEDIA_PROCESS_SUPERVISOR=1" in call for call in calls)
    assert len(list((output / "notices").glob("*-COPYING"))) == 5
    assert all("ffmpeg" not in str(call) for call in calls)
    assert any(
        "--disable-decoder" in call and "--disable-frontend" in call for call in calls
    )
    with pytest.raises(ValueError, match="unused output"):
        media.build(cache, output, fetch=False, jobs=2)
    fail = True
    with pytest.raises(RuntimeError, match="retained output"):
        media.build(cache, tmp_path / "failed", fetch=False, jobs=2)
    fail = "timeout"
    with pytest.raises(RuntimeError, match="timed out; retained output"):
        media.build(cache, tmp_path / "timed-out", fetch=False, jobs=2)
    assert any(
        b"captured timed-out compiler output" in p.read_bytes()
        and b"COMMAND TIMED OUT" in p.read_bytes()
        for p in cache.glob("media-*/build.log")
    )
    assert any(
        b"test compiler" in p.read_bytes() for p in cache.glob("media-*/build.log")
    )


def test_missing_archive_never_fetches_implicitly(tmp_path, monkeypatch):
    monkeypatch.setattr(
        media.urllib.request,
        "urlopen",
        lambda *a, **k: pytest.fail("unexpected network"),
    )
    with pytest.raises(FileNotFoundError):
        media.checked_archive(
            tmp_path, "absent", "https://fixture.invalid", "0" * 64, False
        )
