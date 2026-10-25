"""Independent SQL source closure mechanics, separate from actual CMake proofs."""

import hashlib
from pathlib import Path
import shutil

import pytest

from tools import sql_support_identity as sql

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def inputs(tmp_path):
    for name in sql.INPUTS:
        target = tmp_path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    record = {"target": "linux-x86_64", "compiler": {"fixture": "synthetic"}}
    metadata = {
        "record": record,
        "fingerprint": hashlib.sha256(sql.canonical(record)).hexdigest(),
    }
    return (
        tmp_path,
        metadata,
        [
            "-O3",
            "-DNDEBUG",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-std=c11",
            "-fPIC",
            "-fvisibility=hidden",
        ],
    )


def test_exact_independent_record_and_native_source_changes_do_not_relabel_sql(inputs):
    root, metadata, flags = inputs
    record = sql.identity(root, metadata, flags)
    assert sql.verify_record(root, record) == record["sql_source_id"]
    assert len(record["sql_source_id"]) == 64
    unrelated = root / "native/diagnostic_protocol.c"
    unrelated.write_text("unrelated native source change")
    assert sql.identity(root, metadata, flags) == record


@pytest.mark.parametrize("name", sql.INPUTS)
def test_each_sql_input_is_part_of_the_exact_closure(inputs, name):
    root, metadata, flags = inputs
    record = sql.identity(root, metadata, flags)
    with (root / name).open("a") as stream:
        stream.write("\nchanged\n")
    with pytest.raises(sql.SqlIdentityError, match="record_mismatch"):
        sql.verify_record(root, record)


def test_record_recipe_and_source_cannot_be_relabelled(inputs):
    root, metadata, flags = inputs
    record = sql.identity(root, metadata, flags)
    record["record"]["recipe"]["visibility"] = "default"
    with pytest.raises(sql.SqlIdentityError, match="record_mismatch"):
        sql.verify_record(root, record)


def test_unknown_flags_and_mismatched_toolchain_metadata_refuse(inputs):
    root, metadata, flags = inputs
    with pytest.raises(sql.SqlIdentityError, match="unclosed_sql_compile_flags"):
        sql.identity(root, metadata, [*flags, "-DUNREVIEWED=1"])
    metadata["record"]["compiler"] = {"changed": True}
    with pytest.raises(sql.SqlIdentityError, match="metadata_mismatch"):
        sql.identity(root, metadata, flags)


def test_symlink_source_is_not_a_closed_sql_input(inputs):
    root, metadata, flags = inputs
    source = root / sql.INPUTS[0]
    original = source.with_suffix(".original")
    source.rename(original)
    source.symlink_to(original)
    with pytest.raises(sql.SqlIdentityError, match="unsafe_sql_source_input"):
        sql.identity(root, metadata, flags)


@pytest.mark.parametrize(
    "mutation", ["envelope-schema", "record-schema", "pic-number", "standard-float"]
)
def test_record_comparison_preserves_exact_json_types(inputs, mutation):
    root, metadata, flags = inputs
    record = sql.identity(root, metadata, flags)
    if mutation == "envelope-schema":
        record["schema"] = True
    elif mutation == "record-schema":
        record["record"]["schema"] = True
    elif mutation == "pic-number":
        record["record"]["recipe"]["pic"] = 1
    else:
        record["record"]["recipe"]["c_standard"] = 11.0
    with pytest.raises(sql.SqlIdentityError, match="record_mismatch"):
        sql.verify_record(root, record)
