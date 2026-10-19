"""Restore corruption and timestamp drift must not destroy warm native outputs."""

import json
import os
import sys
from unittest.mock import Mock

import pytest
from tools import ci_stage_artifacts as stages


def native_payload(tmp_path, monkeypatch):
    source = tmp_path / "producer"
    binary = source / "build/native/fixture.o"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"verified object")
    monkeypatch.setattr(stages, "source_times", lambda root: {})
    packed = tmp_path / "packed"
    manifest = stages.pack(source, "linux", "native", packed)
    target = tmp_path / "target"
    current = target / "build/native/fixture.o"
    current.parent.mkdir(parents=True)
    current.write_bytes(b"existing object")
    return packed / "payload.tar.gz", manifest, target, current


@pytest.mark.parametrize("platform,stage", [("other", "native"), ("linux", "other")])
def test_unknown_stage_cannot_collect_outputs(platform, stage, tmp_path):
    with pytest.raises(ValueError):
        stages.content(tmp_path, platform, stage)


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_service_inventory_contains_only_integration_results(tmp_path, platform):
    report = tmp_path / "test-results/service/result.json"
    report.parent.mkdir(parents=True)
    report.write_text("verified")
    (tmp_path / "test-results/desktop-service-integration.json").write_text(
        "integration"
    )
    record = stages.content(tmp_path, platform, "service")
    assert set(record) == {
        "test-results/service",
        "test-results/service/result.json",
        "test-results/desktop-service-integration.json",
    }
    with pytest.raises(ValueError, match="no files"):
        stages.content(tmp_path / "absent", platform, "service")


def test_stage_inventory_rejects_fifo_and_escaping_link(tmp_path):
    fifo = tmp_path / "pipe"
    os.mkfifo(fifo)
    with pytest.raises(ValueError, match="Unsupported stage file"):
        stages.entry(fifo, tmp_path)
    link = tmp_path / "link"
    link.symlink_to("../outside")
    with pytest.raises(ValueError, match="symlink escapes"):
        stages.entry(link, tmp_path)


@pytest.mark.parametrize(
    "failure",
    [
        "mode-negative",
        "mode-bool",
        "mode-large",
        "hash",
        "symlink-directory",
        "collision",
        "inventory-type",
    ],
)
def test_invalid_restore_preserves_existing_object(tmp_path, monkeypatch, failure):
    archive, manifest, target, current = native_payload(tmp_path, monkeypatch)
    before = current.read_bytes()
    if failure.startswith("mode-"):
        manifest["files"]["build/native/fixture.o"]["mode"] = {
            "mode-negative": -1,
            "mode-bool": True,
            "mode-large": 0o1777,
        }[failure]
    elif failure == "hash":
        manifest["files"]["build/native/fixture.o"]["sha256"] = "0" * 64
    elif failure == "inventory-type":
        manifest["output_times"] = []
    elif failure == "symlink-directory":
        current.unlink()
        current.parent.rmdir()
        outside = tmp_path / "outside"
        outside.mkdir(mode=0o700)
        (target / "build/native").symlink_to(outside)
    else:
        current.unlink()
        current.mkdir()
        (current / "precious").write_bytes(before)
    with pytest.raises(ValueError):
        stages.unpack(target, "linux", "native", archive, manifest)
    if failure == "symlink-directory":
        assert not list(outside.iterdir())
        assert outside.stat().st_mode & 0o777 == 0o700
    elif failure == "collision":
        assert (current / "precious").read_bytes() == before
    else:
        assert current.read_bytes() == before


@pytest.mark.parametrize(
    "previous",
    [
        [],
        {"../escape": {}},
        {"file": {"sha256": "invalid", "mtime_ns": 1}},
        {"file": {"sha256": "a" * 64, "mtime_ns": True}},
    ],
)
def test_invalid_source_timestamps_never_touch_sources(tmp_path, previous):
    path = tmp_path / "file"
    path.write_text("unchanged")
    before = path.stat().st_mtime_ns
    with pytest.raises(ValueError, match="timestamp"):
        stages.restore_source_times(tmp_path, {"source_times": previous})
    assert path.stat().st_mtime_ns == before


def test_force_changed_sources_advance_beyond_cached_objects(tmp_path, monkeypatch):
    source = tmp_path / "source.cpp"
    source.write_bytes(b"new source")
    binary = tmp_path / "object.o"
    binary.write_bytes(b"existing object")
    os.utime(binary, ns=(1_000_000_000, 1_000_000_000))
    monkeypatch.setattr(
        stages,
        "source_times",
        lambda root: {"source.cpp": {"sha256": stages.digest(source)}},
    )
    manifest = {"files": {"object.o": {"kind": "file"}}, "source_times": {}}
    stages.restore_source_times(tmp_path, manifest, force_changed=True)
    assert source.stat().st_mtime_ns > binary.stat().st_mtime_ns
    assert binary.read_bytes() == b"existing object"
    monkeypatch.setattr(stages, "source_times", lambda root: {})
    stages.restore_source_times(tmp_path, manifest, force_changed=True)


@pytest.mark.parametrize("failure", ["future", "clock-resolution", "escape", "wait"])
def test_changed_source_clock_and_path_guards(tmp_path, monkeypatch, failure):
    source = tmp_path / "source.cpp"
    source.write_bytes(b"changed")
    binary = tmp_path / "object.o"
    binary.write_bytes(b"retained")
    os.utime(binary, ns=(10_000_000_000, 10_000_000_000))
    names = {"source.cpp": {"sha256": stages.digest(source)}}
    if failure == "escape":
        outside = tmp_path.parent / (tmp_path.name + "-outside")
        outside.write_text("outside")
        source.unlink()
        source.symlink_to(outside)
    monkeypatch.setattr(stages, "source_times", lambda root: names)
    monkeypatch.setattr(
        stages.time,
        "time_ns",
        lambda: (
            0
            if failure == "future"
            else 10_500_000_000
            if failure == "wait"
            else 11_000_000_000
        ),
    )
    sleep = Mock()
    monkeypatch.setattr(stages.time, "sleep", sleep)
    if failure == "clock-resolution":
        os.utime(source, ns=(1_000_000_000, 1_000_000_000))
        monkeypatch.setattr(stages.os, "utime", Mock())
    manifest = {"files": {"object.o": {"kind": "file"}}}
    if failure == "wait":
        stages.restore_source_times(tmp_path, manifest, force_changed=True)
        sleep.assert_called_once_with(0.5)
    else:
        with pytest.raises(
            ValueError,
            match={
                "future": "future",
                "clock-resolution": "newer",
                "escape": "escapes",
            }[failure],
        ):
            stages.restore_source_times(tmp_path, manifest, force_changed=True)
    assert binary.read_bytes() == b"retained"


def test_legacy_ninja_repair_is_read_only_and_only_repairs_tar_rounding(
    tmp_path, monkeypatch
):
    build = tmp_path / "build"
    build.mkdir()
    good = build / "valid.o"
    stale = build / "stale.o"
    for path in (good, stale):
        path.write_bytes(b"object bytes")
        os.utime(path, ns=(10_000, 10_000))
    (build / "linked.o").symlink_to(good.name)
    files = {
        "build/.ninja_deps": {},
        "build/build.ninja": {},
        "build/valid.o": {"kind": "file"},
        "build/stale.o": {"kind": "file"},
        "build/linked.o": {"kind": "file"},
    }
    output = "\n".join(
        [
            "noise",
            "../outside.o: #deps 1, deps mtime 10001 (VALID)",
            "missing.o: #deps 1, deps mtime 10001 (VALID)",
            "linked.o: #deps 1, deps mtime 10001 (VALID)",
            "valid.o: #deps 1, deps mtime 10001 (STALE)",
            "stale.o: #deps 1, deps mtime 99999 (STALE)",
        ]
    )
    command = Mock(return_value=output)
    monkeypatch.setattr(stages.subprocess, "check_output", command)
    stages.restore_legacy_ninja_times(tmp_path, files)
    command.assert_called_once_with(
        ["ninja", "-C", str(build), "-t", "deps"], text=True, timeout=30
    )
    assert good.stat().st_mtime_ns == 10001
    assert stale.stat().st_mtime_ns == 10000
    assert good.read_bytes() == stale.read_bytes() == b"object bytes"


@pytest.mark.parametrize(
    "arguments",
    [
        ["pack"],
        ["unpack"],
        ["pack", "--output", "OUTPUT"],
        ["unpack", "--archive", "ARCHIVE", "--manifest", "MANIFEST"],
    ],
)
def test_stage_cli_requires_complete_inputs(tmp_path, monkeypatch, arguments):
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"files": {"fixture": {}}}))
    replacements = {
        "OUTPUT": str(tmp_path / "output"),
        "ARCHIVE": str(tmp_path / "archive"),
        "MANIFEST": str(manifest),
    }
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "stages",
            *[replacements.get(a, a) for a in arguments],
            "--platform",
            "linux",
            "--stage",
            "native",
        ],
    )
    pack, unpack = Mock(), Mock()
    monkeypatch.setattr(stages, "pack", pack)
    monkeypatch.setattr(stages, "unpack", unpack)
    if len(arguments) == 1:
        with pytest.raises(SystemExit):
            stages.main()
        pack.assert_not_called()
        unpack.assert_not_called()
    else:
        stages.main()
        assert pack.called == (arguments[0] == "pack")
        assert unpack.called == (arguments[0] == "unpack")
