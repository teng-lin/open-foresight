"""Isolated CMake mechanics with synthetic public metadata, not host acceptance."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from tools import sql_support_identity as sql

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def product(tmp_path):
    source = tmp_path / "source"
    for name in sql.INPUTS:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    # The actual selected compiler runs. Only OS/toolchain fingerprinting is a
    # clearly synthetic provider so closure mechanics run on unsupported hosts.
    (source / "tools/diagnostic_toolchain_metadata.py").write_text(
        "import hashlib,json,sys\n"
        "args=sys.argv[1:]\n"
        "record={'target':args[args.index('--target')+1], 'compiler':{'fixture':'synthetic public metadata'}}\n"
        "raw=json.dumps(record,sort_keys=True,separators=(',',':')).encode()\n"
        "print(json.dumps({'record':record,'fingerprint':hashlib.sha256(raw).hexdigest()}))\n"
    )
    build = tmp_path / "build"
    return source, build


def configure(source, build, extra="", before=""):
    (source / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.24)\n"
        "project(sql_identity_fixture LANGUAGES C)\n"
        + before
        + "\ninclude(cmake/ForesightSqlSupport.cmake)\n"
        + extra
        + "\n"
    )
    args = [
        "cmake",
        "-S",
        str(source),
        "-B",
        str(build),
        "-G",
        "Ninja",
        "-DBUILD_TESTING=OFF",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_C_COMPILER=/usr/bin/cc",
        f"-DPython3_EXECUTABLE={sys.executable}",
    ]
    if sys.platform == "darwin":
        args.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0")
    result = subprocess.run(args, text=True, capture_output=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr


def compile_product(build, environment=None):
    result = subprocess.run(
        ["cmake", "--build", str(build), "--target", "foresight_sql_support"],
        env=environment,
        text=True,
        capture_output=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    suffix = "dylib" if sys.platform == "darwin" else "so"
    artifact = build / f"libforesight_sql_support.{suffix}"
    record = json.loads((build / "diagnostic-sql-inputs.json").read_text())
    blob = artifact.read_bytes()
    marker = (
        b"\0FORESIGHT_SQL_SUPPORT_SOURCE_ID:v1:"
        + record["sql_source_id"].encode()
        + b":end\0"
    )
    assert blob.count(marker) == 1
    assert artifact.stat().st_mode & 0o777 == 0o755
    return record, blob


def test_isolated_source_record_and_byte_marker(product):
    source, build = product
    configure(source, build)
    record, _ = compile_product(build)
    assert sql.verify_record(source, record) == record["sql_source_id"]


@pytest.mark.parametrize(
    "extra",
    [
        'set_source_files_properties("${CMAKE_SOURCE_DIR}/native/sql_support.c" PROPERTIES HEADER_FILE_ONLY TRUE)',
        'set_source_files_properties("${CMAKE_SOURCE_DIR}/native/sql_support.c" PROPERTIES LANGUAGE CXX)',
        'set_property(DIRECTORY PROPERTY RULE_LAUNCH_COMPILE "${CMAKE_COMMAND} -E false")',
        'set_property(GLOBAL PROPERTY RULE_LAUNCH_LINK "${CMAKE_COMMAND} -E false")',
        "set_property(TARGET Threads::Threads APPEND PROPERTY INTERFACE_COMPILE_OPTIONS -DUNREVIEWED=1)",
    ],
)
def test_parent_source_usage_and_rule_state_cannot_reach_compiler(product, extra):
    source, build = product
    configure(source, build, extra)
    record, blob = compile_product(build)
    assert sql.verify_record(source, record) == record["sql_source_id"]
    assert b"fs_sql_support_early_init" in blob


def test_compiler_make_and_link_environment_are_absent_from_child(product, tmp_path):
    source, build = product
    configure(source, build)
    poison = tmp_path / "poison"
    poison.mkdir()
    (poison / "time.h").write_text(
        '#error "ambient include escaped into SQL product"\n'
    )
    makefile = poison / "makefile"
    makefile.write_text("$(error ambient makefile escaped into SQL product)\n")
    environment = {
        **os.environ,
        "CPATH": str(poison),
        "C_INCLUDE_PATH": str(poison),
        "LIBRARY_PATH": str(poison),
        "MAKEFILES": str(makefile),
        "MAKEFLAGS": "--no-builtin-rules",
        "CCC_OVERRIDE_OPTIONS": "invalid-fixture-option",
        "CMAKE_C_COMPILER_LAUNCHER": "/absent/fixture-launcher",
        "LD_RUN_PATH": "/fixture-ambient-run-path",
    }
    record, blob = compile_product(build, environment)
    assert sql.verify_record(source, record) == record["sql_source_id"]
    assert b"/fixture-ambient-run-path" not in blob


@pytest.mark.parametrize("reason", ["metadata-unavailable", "unknown-flags"])
def test_unqualified_mandatory_sql_still_builds_without_a_product_claim(
    product, reason
):
    source, build = product
    before = ""
    if reason == "metadata-unavailable":
        (source / "tools/diagnostic_toolchain_metadata.py").write_text(
            "import sys\nsys.exit(2)\n"
        )
    else:
        before = 'set(CMAKE_C_FLAGS "-DUNREVIEWED=1")'
    configure(source, build, before=before)
    result = subprocess.run(
        ["cmake", "--build", str(build), "--target", "foresight_sql_support"],
        text=True,
        capture_output=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((build / "diagnostic-sql-inputs.json").read_text()) == {
        "schema": 1,
        "available": False,
    }
    suffix = "dylib" if sys.platform == "darwin" else "so"
    blob = (build / f"libforesight_sql_support.{suffix}").read_bytes()
    assert b"\0FORESIGHT_SQL_SUPPORT_SOURCE_ID:v1:" not in blob
