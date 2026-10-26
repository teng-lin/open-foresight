"""Validation inventory and runtime checks cannot report success on partial inputs."""

import json
from pathlib import Path
import sys

from google.protobuf import descriptor_pb2
import pytest
from tools import check_integration_inventory as inventory
from tools import verify_descriptor as descriptor

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from tools import integration_gates as gates


@pytest.mark.parametrize(
    "failure",
    [
        "schema",
        "reason",
        "manual-index",
        "wiring",
        "mode",
        "skip-schema",
        "skip-entry",
        "skip-change",
    ],
)
def test_integration_inventory_requires_executable_or_documented_validation(
    tmp_path, failure
):
    tools = tmp_path / "tools"
    tools.mkdir()
    (tools / "accept_fixture.py").write_text("fixture")
    entry = {
        "path": "tools/accept_fixture.py",
        "reason": "Requires platform",
        "mode": "manual",
    }
    probes = {"schema": 1, "entries": [entry]}
    skips = {"schema": 1, "entries": []}
    docs = tmp_path / "docs/validation/integration-gates.md"
    docs.parent.mkdir(parents=True)
    docs.write_text("`tools/accept_fixture.py`")
    if failure == "schema":
        probes["schema"] = 2
    elif failure == "reason":
        entry["reason"] = " "
    elif failure == "manual-index":
        docs.write_text("missing")
    elif failure == "wiring":
        entry.update(mode="automated", wiring=["tools/runner.sh"])
        (tools / "runner.sh").write_text("unrelated executable")
    elif failure == "mode":
        entry["mode"] = "unknown"
    elif failure == "skip-schema":
        skips["schema"] = 2
    elif failure == "skip-entry":
        skips["entries"] = [
            {
                "path": "test.dart",
                "gate": "unknown",
                "reason": "reason",
                "conditions": [],
            }
        ]
    else:
        path = tmp_path / "apps/desktop/test/fixture.dart"
        path.parent.mkdir(parents=True)
        path.write_text("test('fixture', callback, skip: !hasNative,\n);")
    (tools / "integration_probes.json").write_text(json.dumps(probes))
    (tools / "integration_skips.json").write_text(json.dumps(skips))
    with pytest.raises(ValueError):
        inventory.verify(tmp_path)


@pytest.mark.parametrize(
    "failure",
    ["package", "messages", "services", "methods", "edition", "utf8", "transcription"],
)
def test_descriptor_guard_rejects_incompatible_recovered_or_transcribed_wire_shape(
    tmp_path, monkeypatch, failure
):
    original = descriptor.ROOT / "proto/rag/rag_service.descriptor.pb"
    recovered = descriptor_pb2.FileDescriptorProto.FromString(original.read_bytes())
    if failure == "package":
        recovered.package = "other"
    elif failure == "messages":
        del recovered.message_type[-1]
    elif failure == "services":
        del recovered.service[:]
    elif failure == "methods":
        recovered.service[0].method[0].name = "Other"
    elif failure == "edition":
        recovered.edition = 1000
    elif failure == "utf8":
        recovered.options.features.utf8_validation = descriptor_pb2.FeatureSet.VERIFY
    target = tmp_path / "proto/rag/rag_service.descriptor.pb"
    target.parent.mkdir(parents=True)
    target.write_bytes(recovered.SerializeToString())
    monkeypatch.setattr(descriptor, "ROOT", tmp_path)

    def protoc(command, **kw):
        assert kw == {"check": True, "timeout": 300}
        transcribed = descriptor_pb2.FileDescriptorSet()
        transcribed.file.add().CopyFrom(recovered)
        transcribed.file[0].message_type[0].field[0].number = 99
        path = Path(
            next(
                a.split("=", 1)[1]
                for a in command
                if a.startswith("--descriptor_set_out=")
            )
        )
        path.write_bytes(transcribed.SerializeToString())

    monkeypatch.setattr(descriptor.subprocess, "run", protoc)
    with pytest.raises(ValueError):
        descriptor.verify("fixture-protoc")


def test_mac_bundle_environment_resolves_only_current_packaged_products(tmp_path):
    app = tmp_path / "Fixture.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    (resources / "lib").mkdir()
    (resources / "lib/libforesight_sql_support.dylib").write_bytes(b"packaged SQL")
    config = {}
    for key in ("FORESIGHT_NATIVE", "FORESIGHT_HELPER", "FORESIGHT_LITERT_RUNNER"):
        (resources / key).write_bytes(b"packaged binary")
        config[key] = key
    (resources / "runtime.json").write_text(json.dumps(config))
    env = gates.bundle_environment(
        app, {"PATH": "/usr/bin", "FORESIGHT_HELPER": "stale"}
    )
    assert env["FORESIGHT_HELPER"] == str(resources / "FORESIGHT_HELPER")
    assert env["FORESIGHT_TEST_SQL_SUPPORT_LIBRARY"] == str(
        resources / "lib/libforesight_sql_support.dylib"
    )
    assert env["FORESIGHT_GENERATION_BACKEND"] == "litert_lm"
    (resources / "FORESIGHT_HELPER").unlink()
    with pytest.raises(FileNotFoundError):
        gates.bundle_environment(app, {})
    with pytest.raises(ValueError, match="Missing bundle runtime"):
        gates.bundle_environment(tmp_path, {})


def test_report_publication_skips_links_and_tolerates_unowned_mount(
    tmp_path, monkeypatch
):
    root = tmp_path / "report"
    root.mkdir(mode=0o700)
    (root / "fixture.json").write_text("{}")
    (root / "link").symlink_to(tmp_path / "outside")
    gates.publish_report_tree(tmp_path / "absent")
    original = Path.chmod

    def chmod(path, mode, **kw):
        if path == root:
            raise PermissionError("host-owned mount")
        return original(path, mode, **kw)

    monkeypatch.setattr(Path, "chmod", chmod)
    gates.publish_report_tree(root)
    assert (root / "fixture.json").stat().st_mode & 0o444 == 0o444
    assert not (tmp_path / "outside").exists()
