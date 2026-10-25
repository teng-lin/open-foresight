"""Native package byte/provenance mechanics; synthetic bytes are not acceptance."""

from copy import deepcopy
import json

import pytest

from tools import runtime_package_support as package


@pytest.fixture
def source_build(tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.mkdir()
    build = tmp_path / "native"
    build.mkdir()
    receipt = {
        "schema": 1,
        "kind": "runtime-support-build",
        "target": "linux-x86_64",
        "native_id": "a" * 64,
        "sql_source_id": "b" * 64,
        "artifacts": {},
    }
    for name in package._layout(receipt["target"]):
        path = build / name
        path.write_bytes(
            b"synthetic byte fixture: " + name.encode() + package._marker(name, receipt)
        )
        path.chmod(0o755)
        receipt["artifacts"][name] = package._read(path)[1]
    metadata = {
        "diagnostic-products.json": {
            "schema": 1,
            "available": True,
            "native_id": receipt["native_id"],
        },
        "diagnostic-native-inputs.json": {"fixture": "not compiler evidence"},
        "diagnostic-toolchain-metadata.json": {"fixture": "synthetic public metadata"},
        "diagnostic-sql-inputs.json": {"fixture": "synthetic SQL record"},
    }
    for name, record in metadata.items():
        (build / name).write_text(json.dumps(record) + "\n")
    for name, field in (
        ("diagnostic-native-inputs.json", "native_inputs_sha256"),
        ("diagnostic-toolchain-metadata.json", "toolchain_metadata_sha256"),
        ("diagnostic-sql-inputs.json", "sql_inputs_sha256"),
    ):
        receipt[field] = package._digest((build / name).read_bytes())
    (build / "runtime-support-build.json").write_text(json.dumps(receipt) + "\n")

    def verify(root, native):
        assert root == source and native == build
        return deepcopy(receipt)

    # Only source receipt verification is mocked. Real file modes, copied bytes,
    # marker identity and postprocessing/provenance checks execute below.
    monkeypatch.setattr(package, "verify_products", verify)
    return source, build, receipt


def test_three_products_and_public_metadata_are_bound_to_final_package(
    source_build, tmp_path
):
    source, build, receipt = source_build
    prepared = package.prepare(source, build, "linux-x86_64")
    payload = tmp_path / "payload"
    package.stage(payload, prepared)
    result = package.seal(payload, prepared, transformed=False)
    assert result["processing"] == "unmodified-copy"
    assert result["source_receipt_sha256"] == package._digest(
        (build / "runtime-support-build.json").read_bytes()
    )
    assert set(result["artifacts"]) == set(package._layout(receipt["target"]).values())
    for name, relative in package._layout(receipt["target"]).items():
        assert (payload / relative).read_bytes() == (build / name).read_bytes()
    for name in package.METADATA:
        assert (payload / package.METADATA_DIRECTORY / name).read_bytes() == (
            build / name
        ).read_bytes()


@pytest.mark.parametrize("change", ["bytes", "marker", "mode", "symlink", "missing"])
def test_changed_or_unsafe_source_product_refuses_packaging(source_build, change):
    source, build, _ = source_build
    path = build / "libforesight_sql_support.so"
    if change == "bytes":
        with path.open("ab") as stream:
            stream.write(b"changed")
    elif change == "marker":
        path.write_bytes(path.read_bytes().replace(b"b" * 64, b"c" * 64))
    elif change == "mode":
        path.chmod(0o777)
    elif change == "symlink":
        target = build / "other"
        path.rename(target)
        path.symlink_to(target)
    else:
        path.unlink()
    with pytest.raises((package.PackageSupportError, OSError)):
        package.prepare(source, build, "linux-x86_64")


def test_source_metadata_cannot_change_after_receipt_verification(source_build):
    source, build, _ = source_build
    (build / "diagnostic-native-inputs.json").write_text('{"changed":true}')
    with pytest.raises(package.PackageSupportError, match="build_metadata_mismatch"):
        package.prepare(source, build, "linux-x86_64")


def test_relocation_or_signature_bytes_are_separate_from_source_build_bytes(
    source_build, tmp_path
):
    source, build, _ = source_build
    prepared = package.prepare(source, build, "linux-x86_64")
    payload = tmp_path / "payload"
    package.stage(payload, prepared)
    library = payload / "lib/libforesight_sql_support.so"
    with library.open("ab") as stream:
        stream.write(b"simulated signing bytes; not an actual signature")
    with pytest.raises(package.PackageSupportError, match="copy_changed"):
        package.seal(payload, prepared, transformed=False)
    sealed = package.seal(payload, prepared, transformed=True)
    artifact = sealed["artifacts"]["lib/libforesight_sql_support.so"]
    assert artifact["sha256"] != artifact["source_build_sha256"]
    assert sealed["processing"] == "relocated-signed"


def test_changed_marker_or_provenance_cannot_be_sealed(source_build, tmp_path):
    source, build, _ = source_build
    prepared = package.prepare(source, build, "linux-x86_64")
    payload = tmp_path / "payload"
    package.stage(payload, prepared)
    metadata = payload / package.METADATA_DIRECTORY / "diagnostic-products.json"
    metadata.write_text('{"changed":true}')
    with pytest.raises(package.PackageSupportError, match="provenance_changed"):
        package.seal(payload, prepared, transformed=True)


def test_destination_products_are_never_silently_overwritten(source_build, tmp_path):
    source, build, _ = source_build
    prepared = package.prepare(source, build, "linux-x86_64")
    payload = tmp_path / "payload"
    destination = payload / "lib/libforesight_sql_support.so"
    destination.parent.mkdir(parents=True)
    destination.write_bytes(b"existing output")
    with pytest.raises(FileExistsError):
        package.stage(payload, prepared)
    assert destination.read_bytes() == b"existing output"


def test_stage_refuses_symlink_output_directory(source_build, tmp_path):
    source, build, _ = source_build
    prepared = package.prepare(source, build, "linux-x86_64")
    payload = tmp_path / "payload"
    payload.mkdir()
    unrelated = tmp_path / "unrelated"
    unrelated.mkdir()
    (payload / "lib").symlink_to(unrelated, target_is_directory=True)
    with pytest.raises(
        package.PackageSupportError, match="unsafe_package_support_directory"
    ):
        package.stage(payload, prepared)
    assert not list(unrelated.iterdir())
