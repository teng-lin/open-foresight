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
    os.utime(binary, ns=(1_792_349_811_324_446_623, 1_792_349_811_324_446_623))
    exact_output_time = binary.stat().st_mtime_ns
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
    assert restored.stat().st_mtime_ns == exact_output_time


@pytest.mark.parametrize("platform", ["linux", "macos"])
@pytest.mark.parametrize("stage", ["core", "desktop"])
@pytest.mark.parametrize("legacy", [False, True])
def test_restore_discards_only_unlisted_stage_event_reports(
    tmp_path, platform, stage, legacy
):
    root = tmp_path / "original"
    repository(root)
    product = root / module.roots(platform, stage)[0] / "fixture-product"
    product.parent.mkdir(parents=True)
    product.write_bytes(b"compiled product")
    relative = f"test-results/{platform}/{stage}"
    if not legacy:
        report = root / relative / "current.events.jsonl"
        report.parent.mkdir(parents=True)
        report.write_bytes(b"verified events")
    output = tmp_path / "artifact"
    manifest = module.pack(root, platform, stage, output)
    target = tmp_path / "target"
    reports = target / relative
    reports.mkdir(parents=True)
    (reports / "old.events.jsonl").write_bytes(b"stale events")
    (reports / "diagnostic.log").write_bytes(b"keep diagnostics")
    outside = tmp_path / "outside.events.jsonl"
    outside.write_bytes(b"outside evidence")
    linked = reports / "linked.events.jsonl"
    linked.symlink_to(outside)
    other_stage = "desktop" if stage == "core" else "core"
    sibling = target / f"test-results/{platform}/{other_stage}/old.events.jsonl"
    sibling.parent.mkdir(parents=True)
    sibling.write_bytes(b"other stage")

    module.unpack(target, platform, stage, output / "payload.tar.gz", manifest)

    assert not (reports / "old.events.jsonl").exists()
    assert not linked.is_symlink()
    assert outside.read_bytes() == b"outside evidence"
    assert (reports / "diagnostic.log").read_bytes() == b"keep diagnostics"
    assert sibling.read_bytes() == b"other stage"
    copied = module.pack(target, platform, stage, tmp_path / "copied")
    original_events = {
        name: item
        for name, item in manifest["files"].items()
        if name.endswith(".events.jsonl")
    }
    copied_events = {
        name: item
        for name, item in copied["files"].items()
        if name.endswith(".events.jsonl")
    }
    assert copied_events == original_events


@pytest.mark.parametrize("platform", ["linux", "macos"])
@pytest.mark.parametrize("stage", ["core", "desktop"])
def test_corrupt_restore_keeps_existing_event_evidence(tmp_path, platform, stage):
    root = tmp_path / "original"
    repository(root)
    product = root / module.roots(platform, stage)[0] / "fixture-product"
    product.parent.mkdir(parents=True)
    product.write_bytes(b"compiled product")
    output = tmp_path / "artifact"
    manifest = module.pack(root, platform, stage, output)
    manifest["files"][product.relative_to(root).as_posix()]["sha256"] = "0" * 64
    target = tmp_path / "target"
    old = target / f"test-results/{platform}/{stage}/old.events.jsonl"
    old.parent.mkdir(parents=True)
    old.write_bytes(b"previous evidence")
    with pytest.raises(ValueError, match="content mismatch"):
        module.unpack(target, platform, stage, output / "payload.tar.gz", manifest)
    assert old.read_bytes() == b"previous evidence"


@pytest.mark.parametrize("stage", ["core", "desktop"])
@pytest.mark.parametrize("link_path", ["test-results", "test-results/linux"])
def test_legacy_restore_refuses_report_directory_symlinks(tmp_path, stage, link_path):
    root = tmp_path / "original"
    repository(root)
    product = root / module.roots("linux", stage)[0] / "fixture-product"
    product.parent.mkdir(parents=True)
    product.write_bytes(b"compiled product")
    output = tmp_path / "artifact"
    manifest = module.pack(root, "linux", stage, output)
    target = tmp_path / "target"
    outside = tmp_path / "outside"
    sentinel = outside / "linux" / stage / "old.events.jsonl"
    sentinel.parent.mkdir(parents=True)
    sentinel.write_bytes(b"outside evidence")
    link = target / link_path
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="report directory traverses a symlink"):
        module.unpack(target, "linux", stage, output / "payload.tar.gz", manifest)
    assert sentinel.read_bytes() == b"outside evidence"
    assert not (target / product.relative_to(root)).exists()


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


@pytest.mark.parametrize("platform", ["linux", "macos"])
@pytest.mark.parametrize("stage", ["core", "desktop"])
def test_event_streams_survive_original_and_saved_copy_round_trips(
    tmp_path, platform, stage
):
    root = tmp_path / "original"
    repository(root)
    product = root / module.roots(platform, stage)[0] / "fixture-product"
    product.parent.mkdir(parents=True)
    product.write_bytes(b"compiled product")
    names = (
        ["core.events.jsonl", "plain.events.jsonl", "coverage.events.jsonl"]
        if stage == "core"
        else ["desktop.events.jsonl"]
    )
    reports = {}
    for name in names:
        relative = f"test-results/{platform}/{stage}/{name}"
        report = root / relative
        report.parent.mkdir(parents=True, exist_ok=True)
        reports[relative] = b'{"success":true,"type":"done","time":1234}\n'
        report.write_bytes(reports[relative])
    original_output = tmp_path / "original-payload"
    original_manifest = module.pack(root, platform, stage, original_output)
    restored = tmp_path / "restored"
    module.unpack(
        restored, platform, stage, original_output / "payload.tar.gz", original_manifest
    )
    assert (restored / product.relative_to(root)).read_bytes() == b"compiled product"
    copied_output = tmp_path / "copied-payload"
    copied_manifest = module.pack(restored, platform, stage, copied_output)
    assert copied_manifest == original_manifest
    copied_target = tmp_path / "copied-target"
    module.unpack(
        copied_target,
        platform,
        stage,
        copied_output / "payload.tar.gz",
        copied_manifest,
    )
    for relative, original in reports.items():
        assert (restored / relative).read_bytes() == original
        assert (copied_target / relative).read_bytes() == original


@pytest.mark.parametrize("platform", ["linux", "macos"])
@pytest.mark.parametrize("stage", ["core", "desktop"])
def test_new_report_paths_cannot_restore_another_platform_or_stage(
    tmp_path, platform, stage
):
    other_platform = "macos" if platform == "linux" else "linux"
    other_stage = "desktop" if stage == "core" else "core"
    for relative in (
        f"test-results/{other_platform}/{stage}/events.jsonl",
        f"test-results/{platform}/{other_stage}/events.jsonl",
    ):
        with pytest.raises(ValueError, match="manifest paths"):
            module.unpack(
                tmp_path,
                platform,
                stage,
                tmp_path / "unused",
                {"files": {relative: {}}},
            )


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_native_runtime_payload_omits_compilers_and_retains_products_and_notices(
    tmp_path, platform
):
    root = tmp_path / "original"
    repository(root)
    products = [
        "build/services/helper/ForesightHelper",
        "build/native/libforesight_native.dylib",
        "build/sdk/foresight-sdk.json",
        "build/sdk/share/foresight-sdk/licenses/LICENSE",
    ]
    excluded = [
        "build/_deps/compiler/big.o",
        "build/native/CMakeFiles/native.o",
        "build/sdk/include/grpc.h",
        "build/sdk/lib/libgrpc.a",
    ]
    for relative in [*products, *excluded]:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(relative.encode())
    worker = root / "build/services/helper/model_worker_fixture"
    worker.write_text("#!/bin/sh\nprintf '%s\\n' model-worker-fixture-ok\n")
    worker.chmod(0o755)
    output = tmp_path / "runtime"
    manifest = module.pack(root, platform, "native-runtime", output)
    assert not manifest["source_times"]
    target = tmp_path / "target"
    module.unpack(
        target, platform, "native-runtime", output / "payload.tar.gz", manifest
    )
    for relative in products:
        assert (target / relative).read_bytes() == relative.encode()
    for relative in excluded:
        assert not (target / relative).exists()
    restored_worker = target / worker.relative_to(root)
    assert restored_worker.stat().st_mode & 0o111 == 0o111
    assert (
        subprocess.check_output([str(restored_worker)], text=True, timeout=10).strip()
        == "model-worker-fixture-ok"
    )


def test_runtime_manifest_cannot_restore_compiler_objects(tmp_path):
    with pytest.raises(ValueError, match="manifest paths"):
        module.unpack(
            tmp_path,
            "linux",
            "native-runtime",
            tmp_path / "unused",
            {"files": {"build/_deps/object.o": {}}},
        )


@pytest.mark.parametrize("value", [-1, True, "123", 2**63])
def test_invalid_output_timestamp_inventory_is_rejected(tmp_path, value):
    with pytest.raises(ValueError, match="output timestamp"):
        module.unpack(
            tmp_path,
            "linux",
            "native",
            tmp_path / "unused",
            {
                "files": {"build/native/file.o": {"kind": "file"}},
                "output_times": {"build/native/file.o": value},
            },
        )
