"""Build artifacts restore only their stage's verified outputs."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "stage_artifacts", ROOT / "tools/ci_stage_artifacts.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def repository(path):
    path.mkdir()
    subprocess.run(["git", "init", "-q", str(path)], check=True, timeout=10)
    source = path / "source.cpp"
    source.write_text("source body")
    subprocess.run(
        ["git", "-C", str(path), "add", "source.cpp"], check=True, timeout=10
    )
    return source


def test_native_round_trip_keeps_modes_and_unchanged_source_times(tmp_path):
    root = tmp_path / "original"
    source = repository(root)
    source_time = source.stat().st_mtime_ns
    binary = root / "build/native/libfixture.so"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"native bytes")
    binary.chmod(0o755)
    binary.parent.chmod(0o700)
    link = binary.with_name("libalias.so")
    link.symlink_to(binary.name)
    output = tmp_path / "artifact"
    manifest = module.pack(root, "linux", "native", output)
    target = tmp_path / "target"
    destination_source = repository(target)
    os.utime(destination_source, ns=(source_time + 10000, source_time + 10000))
    module.unpack(target, "linux", "native", output / "payload.tar.gz", manifest)
    restored = target / binary.relative_to(root)
    assert restored.read_bytes() == b"native bytes"
    assert restored.stat().st_mode & 0o777 == 0o755
    assert restored.parent.stat().st_mode & 0o777 == 0o700
    assert (restored.parent / link.name).is_symlink()
    assert destination_source.stat().st_mtime_ns == source_time


def test_changed_source_times_are_never_overwritten(tmp_path):
    root = tmp_path / "original"
    repository(root)
    (root / "build/application").mkdir(parents=True)
    (root / "build/application/service").write_text("binary")
    output = tmp_path / "artifact"
    manifest = module.pack(root, "linux", "core", output)
    target = tmp_path / "target"
    source = repository(target)
    source.write_text("changed source")
    before = source.stat().st_mtime_ns
    manifest["source_times"] = module.source_times(root)
    module.unpack(target, "linux", "core", output / "payload.tar.gz", manifest)
    assert source.stat().st_mtime_ns == before


@pytest.mark.parametrize(
    "bad_path",
    ["../escape", "/absolute", "build/sdk/private", "build/application/service"],
)
def test_native_manifest_rejects_other_stages_and_escaping_paths(tmp_path, bad_path):
    with pytest.raises(ValueError, match="manifest paths"):
        module.unpack(
            tmp_path, "linux", "native", tmp_path / "unused", {"files": {bad_path: {}}}
        )


def test_corrupt_archive_never_installs_a_partial_stage(tmp_path):
    root = tmp_path / "original"
    repository(root)
    binary = root / "build/native/library.so"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"bytes")
    output = tmp_path / "artifact"
    manifest = module.pack(root, "linux", "native", output)
    damaged = copy.deepcopy(manifest)
    damaged["files"]["build/native/library.so"]["sha256"] = "0" * 64
    target = tmp_path / "target"
    with pytest.raises(ValueError, match="content mismatch"):
        module.unpack(target, "linux", "native", output / "payload.tar.gz", damaged)
    assert not (target / "build").exists()


def test_unlisted_archive_member_is_rejected(tmp_path):
    archive = tmp_path / "payload.tar"
    with tarfile.open(archive, "w") as stream:
        stream.addfile(tarfile.TarInfo("payload/../escape"))
    with pytest.raises(ValueError, match="archive members"):
        module.unpack(
            tmp_path / "target",
            "linux",
            "native",
            archive,
            {"files": {"build/native/library.so": {}}},
        )


def test_stage_manifest_is_serializable(tmp_path):
    root = tmp_path / "original"
    repository(root)
    binary = root / "build/native/library.so"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"bytes")
    output = tmp_path / "artifact"
    manifest = module.pack(root, "linux", "native", output)
    assert json.loads((output / "content.json").read_text()) == manifest


def test_restore_refuses_existing_directory_symlink_before_touching_outputs(tmp_path):
    root = tmp_path / "original"
    repository(root)
    binary = root / "build/native/library.so"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"bytes")
    output = tmp_path / "artifact"
    manifest = module.pack(root, "linux", "native", output)
    outside = tmp_path / "outside"
    outside.mkdir(mode=0o700)
    target = tmp_path / "target"
    (target / "build").mkdir(parents=True)
    (target / "build/native").symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        module.unpack(target, "linux", "native", output / "payload.tar.gz", manifest)
    assert not list(outside.iterdir())
    assert outside.stat().st_mode & 0o777 == 0o700


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_desktop_artifact_preserves_flutter_coverage_at_actual_output_path(
    tmp_path, platform
):
    root = tmp_path / "original"
    repository(root)
    coverage = root / "apps/desktop/coverage/lcov.info"
    coverage.parent.mkdir(parents=True)
    coverage.write_text("SF:lib/main.dart\nDA:1,1\nend_of_record\n")
    output = tmp_path / "artifact"
    manifest = module.pack(root, platform, "desktop", output)
    target = tmp_path / "target"
    repository(target)
    module.unpack(target, platform, "desktop", output / "payload.tar.gz", manifest)
    assert (target / coverage.relative_to(root)).read_bytes() == coverage.read_bytes()
