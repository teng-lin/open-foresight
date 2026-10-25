"""Receipt mechanics use synthetic bytes; they do not qualify compiled products."""

import json
from pathlib import Path
import shutil

import pytest

from tools import diagnostic_build_identity as identity
from tools import diagnostic_product_receipt as products

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def built(tmp_path):
    root = tmp_path / "source"
    build = tmp_path / "build"
    build.mkdir()
    config = json.loads((ROOT / identity.DEFAULT_CONTRACT).read_text())
    names = [row["path"] for row in config["native"]["inputs"]]
    for name in [identity.DEFAULT_CONTRACT, *names, *products.SQL_INPUTS]:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    toolchain_record = {"fixture": "synthetic metadata, not attestation"}
    fingerprint = products._digest(
        json.dumps(toolchain_record, sort_keys=True, separators=(",", ":")).encode()
    )
    (build / "diagnostic-toolchain-metadata.json").write_text(
        json.dumps({"record": toolchain_record, "fingerprint": fingerprint})
    )
    native = identity.Contract(root).native_identity(
        "linux-x86_64",
        identity.Compiler("clang", "22.1.8", "a" * 64, fingerprint),
        ["-std=c11", "-O2"],
    )
    (build / "diagnostic-native-inputs.json").write_text(json.dumps(native))
    (build / "diagnostic-products.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "available": True,
                "native_id": native["native_id"],
            }
        )
    )
    for name in (
        "libforesight_sql_support.so",
        "libforesight_diagnostic_support.so",
        "foresight-diagnostic-launcher",
    ):
        path = build / name
        marker = b"" if "sql_support" in name else (
            b"\0FORESIGHT_DIAGNOSTIC_NATIVE_ID:v1:"
            + native["native_id"].encode("ascii") + b":end\0"
        )
        path.write_bytes(b"synthetic fixture bytes: " + name.encode() + marker)
        path.chmod(0o755)
    return root, build


def test_finished_bytes_receipt_and_exact_verification(built):
    root, build = built
    receipt = products.write(root, build)
    assert products.verify(root, build) == receipt
    assert set(receipt["artifacts"]) == {
        "libforesight_sql_support.so",
        "libforesight_diagnostic_support.so",
        "foresight-diagnostic-launcher",
    }
    assert receipt["sql_inputs"] == {
        name: products._digest((root / name).read_bytes())
        for name in products.SQL_INPUTS
    }
    # A native byte receipt never supplies the missing Dart worker closure.
    with pytest.raises(identity.IdentityError, match="missing_worker_closure"):
        identity.Contract(root).worker_identity(receipt["native_id"], "aot")


@pytest.mark.parametrize("alteration", ["missing", "duplicate", "stale"])
def test_embedded_native_identity_must_match_exactly_once(built, alteration):
    root, build = built
    path = build / "foresight-diagnostic-launcher"
    native_id = json.loads((build / "diagnostic-products.json").read_text())["native_id"]
    marker = b"\0FORESIGHT_DIAGNOSTIC_NATIVE_ID:v1:" + native_id.encode() + b":end\0"
    data = path.read_bytes()
    if alteration == "missing":
        data = data.replace(marker, b"")
    elif alteration == "duplicate":
        data += marker
    else:
        data = data.replace(marker, marker.replace(native_id.encode(), b"0" * 64))
    path.write_bytes(data)
    with pytest.raises(products.ProductError, match="product_embedded_identity_mismatch"):
        products.write(root, build)


@pytest.mark.parametrize(
    "name",
    [
        "libforesight_sql_support.so",
        "libforesight_diagnostic_support.so",
        "foresight-diagnostic-launcher",
    ],
)
def test_changed_or_missing_artifact_refuses_existing_receipt(built, name):
    root, build = built
    products.write(root, build)
    path = build / name
    path.write_bytes(b"older or changed bytes" + path.read_bytes())
    with pytest.raises(products.ProductError, match="receipt_mismatch"):
        products.verify(root, build)
    path.unlink()
    with pytest.raises(FileNotFoundError):
        products.verify(root, build)


@pytest.mark.parametrize("name", products.SQL_INPUTS)
def test_sql_source_changes_refuse_receipt(built, name):
    root, build = built
    products.write(root, build)
    with (root / name).open("a") as stream:
        stream.write("\n/* changed source */\n")
    with pytest.raises(products.ProductError, match="receipt_mismatch"):
        products.verify(root, build)


def test_native_source_change_cannot_be_relabelled(built):
    root, build = built
    products.write(root, build)
    with (root / "native/diagnostic_protocol.c").open("a") as stream:
        stream.write("\n/* changed source */\n")
    with pytest.raises(products.ProductError, match="inputs_mismatch"):
        products.write(root, build)


@pytest.mark.parametrize(
    "state",
    [
        {"schema": 1, "available": False},
        {"schema": True, "available": True, "native_id": "a" * 64},
        {"schema": 1, "available": True, "native_id": "a" * 64, "extra": True},
    ],
)
def test_unavailable_or_invalid_configuration_never_uses_leftover_bytes(built, state):
    root, build = built
    products.write(root, build)
    (build / "diagnostic-products.json").write_text(json.dumps(state))
    with pytest.raises(products.ProductError):
        products.verify(root, build)
    assert (build / "libforesight_diagnostic_support.so").exists()


def test_native_identity_mismatch_and_fixture_scope_refused(built):
    root, build = built
    native_path = build / "diagnostic-native-inputs.json"
    native = json.loads(native_path.read_text())
    native["record"]["scope"] = "fixture"
    native_path.write_text(json.dumps(native))
    with pytest.raises(products.ProductError, match="nonproduction"):
        products.write(root, build)


@pytest.mark.parametrize("unsafe", ["symlink", "public", "nonexecutable", "empty"])
def test_unsafe_artifact_is_refused(built, unsafe):
    root, build = built
    path = build / "foresight-diagnostic-launcher"
    if unsafe == "symlink":
        other = build / "unrelated"
        path.rename(other)
        path.symlink_to(other)
    elif unsafe == "public":
        path.chmod(0o777)
    elif unsafe == "nonexecutable":
        path.chmod(0o644)
    else:
        path.write_bytes(b"")
    with pytest.raises((OSError, products.ProductError)):
        products.write(root, build)


def test_duplicate_metadata_refuses(built):
    root, build = built
    (build / "diagnostic-products.json").write_text('{"schema":1,"schema":1}')
    with pytest.raises(products.ProductError, match="duplicate"):
        products.write(root, build)


@pytest.mark.parametrize("mutation", ["fingerprint", "record"])
def test_toolchain_metadata_must_match_native_id(built, mutation):
    root, build = built
    products.write(root, build)
    path = build / "diagnostic-toolchain-metadata.json"
    metadata = json.loads(path.read_text())
    metadata[mutation] = "changed" if mutation == "fingerprint" else {"changed": True}
    path.write_text(json.dumps(metadata))
    with pytest.raises(products.ProductError, match="toolchain_metadata_mismatch"):
        products.verify(root, build)
