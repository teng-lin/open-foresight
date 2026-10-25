"""Closed input identities must remain deterministic without a Git checkout."""

from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest import mock

import pytest

from tools import diagnostic_build_identity as identity

ROOT = Path(__file__).resolve().parents[1]
COMPILER = identity.Compiler("clang", "22.1.8", "a" * 64, "b" * 64)
FLAGS = ["-std=c11", "-O2"]


@pytest.fixture
def source(tmp_path):
    config = json.loads((ROOT / identity.DEFAULT_CONTRACT).read_text())
    config["scope"] = "fixture"
    names = [
        "diagnostic_protocol.c",
        "diagnostic_protocol.h",
        "diagnostic_kernel_linux.c",
        "diagnostic_kernel_darwin.c",
        "diagnostic_support.c",
        "diagnostic_support.h",
    ]
    config["native"]["inputs"] = [
        {
            "path": f"native/{name}",
            "targets": ["linux-x86_64"]
            if "linux" in name
            else ["darwin-arm64"]
            if "darwin" in name
            else ["linux-x86_64", "darwin-arm64"],
        }
        for name in names
    ]
    files = {
        row["path"]: f"/* synthetic {row['path']} */\n"
        for row in config["native"]["inputs"]
    }
    files.update(
        {
            "app/worker.dart": "void main() {}\n",
            "app/runtime.dart": "const runtime = 1;\n",
            "catalog/locations.json": '{"locations":["app/runtime.dart"]}\n',
        }
    )
    config["worker"].update(
        status="fixture",
        required=[
            "app/worker.dart",
            "native/diagnostic_support.c",
            "native/diagnostic_support.h",
        ],
        roots=["app", "native", "catalog"],
        inputs=sorted(files),
        catalog=["catalog/locations.json"],
    )
    config["worker"]["external_imports"] = ["dart:io"]
    config["worker"]["sdk"].update(compiler_sha256="c" * 64, toolchain_sha256="d" * 64)
    for name, text in files.items():
        p = tmp_path / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    save(tmp_path, config)
    return tmp_path, config


def save(root, config):
    p = root / identity.DEFAULT_CONTRACT
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(config))


def native(root):
    return identity.Contract(root).native_identity("linux-x86_64", COMPILER, FLAGS)


def worker(root, native_id=None, mode="aot"):
    return identity.Contract(root).worker_identity(
        native_id or native(root)["native_id"], mode
    )


def cli(root, *extra, environment=None):
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "tools.diagnostic_build_identity",
            "native",
            "--root",
            str(root),
            "--target",
            "linux-x86_64",
            "--compiler-family",
            "clang",
            "--compiler-version",
            "22.1.8",
            "--compiler-sha256",
            "a" * 64,
            "--toolchain-sha256",
            "b" * 64,
            "--flag=-std=c11",
            "--flag=-O2",
            *extra,
        ],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        timeout=15,
    )


def test_git_free_deterministic_native_and_worker_ids(source):
    root, _ = source
    assert not (root / ".git").exists()
    first = native(root)
    result = cli(
        root,
        environment={
            **os.environ,
            "GIT_DIR": str(root / "missing-git"),
            "FORESIGHT_DISTRIBUTION_API_KEY": "synthetic-secret",
            "UNRELATED_SECRET": "canary",
        },
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == first
    assert "canary" not in result.stdout and "synthetic-secret" not in result.stdout
    assert worker(root) == worker(root)
    assert worker(root)["kind"] == "fixture-worker"
    assert len(first["native_id"]) == 64
    assert identity.HEX64.fullmatch(worker(root)["worker_id"])


def test_dart_only_edit_changes_worker_not_native_or_catalog(source):
    root, _ = source
    n, w = native(root), worker(root)
    (root / "app/runtime.dart").write_text("const runtime = 2;\n")
    assert native(root) == n
    changed = worker(root)
    assert changed["worker_id"] != w["worker_id"]
    assert changed["catalog_id"] == w["catalog_id"]


def test_catalog_mode_sdk_and_expected_native_are_bound(source):
    root, config = source
    before = worker(root)
    (root / "catalog/locations.json").write_text('{"locations":["app/worker.dart"]}')
    changed = worker(root)
    assert changed["catalog_id"] != before["catalog_id"]
    assert changed["worker_id"] != before["worker_id"]
    assert worker(root, mode="jit")["worker_id"] != changed["worker_id"]
    assert worker(root, native_id="e" * 64)["worker_id"] != changed["worker_id"]
    config["worker"]["sdk"]["compiler_sha256"] = "f" * 64
    save(root, config)
    assert worker(root)["worker_id"] != changed["worker_id"]
    config["worker"]["sdk"]["dart"] = "3.9.3"
    save(root, config)
    with pytest.raises(identity.IdentityError, match="invalid_sdk"):
        worker(root)


def test_selected_platform_source_compiler_and_flags_change_native(source):
    root, _ = source
    n = native(root)
    (root / "native/diagnostic_kernel_darwin.c").write_text("/* different darwin */")
    assert native(root) == n
    (root / "native/diagnostic_kernel_linux.c").write_text("/* different linux */")
    changed = native(root)
    assert changed["native_id"] != n["native_id"]
    contract = identity.Contract(root)
    for c in [
        identity.Compiler("clang", "22.1.9", "a" * 64, "b" * 64),
        identity.Compiler("clang", "22.1.8", "c" * 64, "b" * 64),
        identity.Compiler("clang", "22.1.8", "a" * 64, "c" * 64),
    ]:
        assert (
            contract.native_identity("linux-x86_64", c, FLAGS)["native_id"]
            != changed["native_id"]
        )
    assert (
        contract.native_identity("linux-x86_64", COMPILER, ["-std=c11", "-O0"])[
            "native_id"
        ]
        != changed["native_id"]
    )
    mac = contract.native_identity(
        "darwin-arm64",
        identity.Compiler("apple-clang", "2100.1.1", "a" * 64, "b" * 64),
        ["-std=c11", "-mmacosx-version-min=15.0"],
    )
    assert mac["record"]["floor"] == "macos-15.0-arm64"
    assert mac["native_id"] != changed["native_id"]


@pytest.mark.parametrize(
    "filename",
    [
        "diagnostic_unclassified.c",
        "diagnostic_unclassified.h",
        "diagnostic_unclassified.cpp",
    ],
)
def test_new_diagnostic_native_path_fails_closed(source, filename):
    root, _ = source
    (root / "native" / filename).write_text("/* omitted */")
    with pytest.raises(identity.IdentityError, match="unclassified_native_input"):
        native(root)


@pytest.mark.parametrize("change", ["duplicate", "outside", "traversal", "absolute"])
def test_native_inventory_rejects_duplicate_or_out_of_root_inputs(source, change):
    root, config = source
    row = deepcopy(config["native"]["inputs"][0])
    row["path"] = {
        "duplicate": row["path"],
        "outside": "app/diagnostic_rogue.c",
        "traversal": "native/../app/diagnostic_rogue.c",
        "absolute": "/native/diagnostic_rogue.c",
    }[change]
    config["native"]["inputs"].append(row)
    save(root, config)
    with pytest.raises(identity.IdentityError):
        native(root)


def test_symlink_and_hardlink_candidates_never_read_secret_bytes(source):
    root, _ = source
    candidate = root / "native/diagnostic_protocol.c"
    secret = root / "private-canary"
    secret.write_text("SYNTHETIC_CREDENTIAL_CANARY")
    candidate.unlink()
    candidate.symlink_to(secret)
    with pytest.raises(identity.IdentityError, match="unsafe_source_path"):
        native(root)
    candidate.unlink()
    os.link(secret, candidate)
    original = os.read
    secret_inode = secret.stat().st_ino

    def guarded(fd, count):
        assert os.fstat(fd).st_ino != secret_inode, "excluded content read"
        return original(fd, count)

    with (
        mock.patch.object(identity.os, "read", side_effect=guarded),
        pytest.raises(identity.IdentityError, match="unsafe_source_path"),
    ):
        native(root)


def test_directory_symlink_is_refused(source):
    root, _ = source
    (root / "native/nested").symlink_to(root / "app", target_is_directory=True)
    with pytest.raises(identity.IdentityError, match="unsafe_source_path"):
        native(root)


def test_unreviewed_default_worker_closure_is_not_a_production_identity():
    contract = identity.Contract(ROOT)
    with (
        mock.patch.object(
            identity,
            "_read",
            side_effect=AssertionError("must not read unreviewed runtime"),
        ),
        pytest.raises(identity.IdentityError, match="worker_closure_not_reviewed"),
    ):
        contract.worker_identity("a" * 64, "aot")


def test_missing_worker_entry_refuses_before_reading_other_runtime(source):
    root, _ = source
    (root / "app/worker.dart").unlink()
    contract = identity.Contract(root)
    with (
        mock.patch.object(
            identity, "_read", side_effect=AssertionError("runtime read")
        ),
        pytest.raises(identity.IdentityError, match="missing_worker_closure"),
    ):
        contract.worker_identity("a" * 64, "aot")


def test_present_stubs_cannot_promote_unreviewed_worker_closure(source):
    root, config = source
    config["scope"] = "components"
    config["worker"]["status"] = "pending"
    save(root, config)
    with pytest.raises(identity.IdentityError, match="worker_closure_not_reviewed"):
        worker(root, native_id="a" * 64)


def test_new_runtime_file_requires_classification_or_reasoned_exception(source):
    root, config = source
    (root / "app/new.dart").write_text("class NewRuntime {}")
    with pytest.raises(identity.IdentityError, match="unclassified_worker_input"):
        worker(root)
    config["worker"]["exceptions"]["app/new.dart"] = (
        "Synthetic non-runtime fixture input."
    )
    save(root, config)
    worker(root)


def test_excluded_distribution_inputs_and_rejected_defines_are_never_echoed(source):
    root, config = source
    blocked = root / "tools/reference_distribution_config.py"
    blocked.write_text("SYNTHETIC_CREDENTIAL_CANARY")
    with (
        mock.patch.object(
            identity.os, "open", side_effect=AssertionError("excluded file opened")
        ),
        pytest.raises(identity.IdentityError, match="excluded_input"),
    ):
        identity.Contract(root, "tools/reference_distribution_config.py")
    result = cli(root, "-DAPI_KEY=SYNTHETIC_CREDENTIAL_CANARY")
    assert result.returncode == 2
    assert "SYNTHETIC_CREDENTIAL_CANARY" not in result.stdout + result.stderr
    assert json.loads(result.stderr)["error"] == "invalid_arguments"
    config["native"]["flags"].append("-DAPI_KEY=SYNTHETIC_CREDENTIAL_CANARY")
    save(root, config)
    with pytest.raises(identity.IdentityError, match="invalid_flags"):
        native(root)


def test_unknown_worker_options_reject_before_content_hashing(source):
    root, config = source
    config["worker"]["options"]["credential"] = "SYNTHETIC_CREDENTIAL_CANARY"
    save(root, config)
    original = identity._read

    def guarded(root, name, **kwargs):
        assert name == identity.DEFAULT_CONTRACT, "content read before option rejection"
        return original(root, name, **kwargs)

    with (
        mock.patch.object(identity, "_read", side_effect=guarded),
        pytest.raises(identity.IdentityError, match="invalid_contract"),
    ):
        identity.Contract(root)


def test_generated_header_lives_outside_source_hash_and_expected_id_is_verified(source):
    root, _ = source
    before = native(root)
    result = cli(root, "--format", "header")
    assert result.returncode == 0, result.stderr
    assert before["native_id"] in result.stdout
    assert "WORKER" not in result.stdout
    output = root / "build/generated/diagnostic_identity.h"
    output.parent.mkdir(parents=True)
    output.write_text(result.stdout)
    assert native(root) == before
    assert cli(root, "--expected-id", before["native_id"]).returncode == 0
    assert cli(root, "--expected-id", "f" * 64).returncode == 2


def test_real_native_inventory_current_components_only(tmp_path):
    config = json.loads((ROOT / identity.DEFAULT_CONTRACT).read_text())
    assert {"native/diagnostic_support.c", "native/diagnostic_support.h"} <= {
        row["path"] for row in config["native"]["inputs"]
    }
    # The owned native checkpoint contains every declared source. Copy its
    # actual text into a Git-free fixture, without a missing-source fallback.
    config["scope"] = "fixture"
    for row in config["native"]["inputs"]:
        p = tmp_path / row["path"]
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes((ROOT / row["path"]).read_bytes())
    save(tmp_path, config)
    value = native(tmp_path)
    assert value["kind"] == "native-components"
    assert value["record"]["scope"] == "fixture"
    assert "native/diagnostic_launcher.c" in value["record"]["inputs"]
    assert "native/diagnostic_kernel_darwin.c" not in value["record"]["inputs"]


def test_real_native_components_match_closed_inventory():
    value = native(ROOT)
    assert value["kind"] == "native-components"
    assert value["record"]["scope"] == "components"
    assert len(value["record"]["inputs"]) == 11  # Darwin C is classified, not selected.
    assert "native/diagnostic_support.c" in value["record"]["inputs"]


def test_native_quoted_dependency_cannot_escape_inventory(source):
    root, _ = source
    (root / "native/diagnostic_protocol.c").write_text('#include "not_classified.h"\n')
    with pytest.raises(identity.IdentityError, match="unclassified_native_include"):
        native(root)


@pytest.mark.parametrize("prefix", ["\ufeff", "/* comment */ ", "%:", "#\\\ninclude "])
def test_native_dependency_check_handles_preprocessor_spellings(source, prefix):
    root, _ = source
    line = (
        prefix + '#include "not_classified.h"\n'
        if prefix in {"\ufeff", "/* comment */ "}
        else prefix + 'include "not_classified.h"\n'
        if prefix == "%:"
        else prefix + '"not_classified.h"\n'
    )
    (root / "native/diagnostic_protocol.c").write_text(line)
    with pytest.raises(identity.IdentityError, match="unclassified_native_include"):
        native(root)


def test_native_macro_include_is_not_silently_unclassified(source):
    root, _ = source
    (root / "native/diagnostic_protocol.c").write_text(
        '#define HEADER "not_classified.h"\n#include HEADER\n'
    )
    with pytest.raises(identity.IdentityError, match="unsupported_native_include"):
        native(root)


@pytest.mark.parametrize(
    "directive",
    [
        "import '../private/credential_value.dart';",
        "import 'runtime.dart' if (dart.library.io) '../private/credential_value.dart';",
        "export '../private/search_service.dart';",
        "part '../private/reference_distribution.dart';",
    ],
)
def test_worker_imports_reject_excluded_paths_before_target_read(source, directive):
    root, _ = source
    (root / "app/worker.dart").write_text(directive + "\nvoid main() {}")
    contract = identity.Contract(root)
    original = identity._read

    def guarded(root, name, **kwargs):
        assert "/private/" not in name, "forbidden target read"
        return original(root, name, **kwargs)

    with (
        mock.patch.object(identity, "_read", side_effect=guarded),
        pytest.raises(identity.IdentityError, match="excluded_worker_input"),
    ):
        contract.worker_identity("a" * 64, "aot")


def test_unknown_runtime_import_does_not_open_application_graph(source):
    root, _ = source
    (root / "app/worker.dart").write_text(
        "import 'package:foresight_core/src/web_content.dart';\nvoid main() {}"
    )
    contract = identity.Contract(root)
    original = identity._read

    def guarded(root, name, **kwargs):
        assert not name.endswith("web_content.dart"), "application graph read"
        return original(root, name, **kwargs)

    with (
        mock.patch.object(identity, "_read", side_effect=guarded),
        pytest.raises(identity.IdentityError, match="out_of_root_worker_import"),
    ):
        contract.worker_identity("a" * 64, "aot")


@pytest.mark.parametrize(
    "header",
    [
        "\ufeff",
        "#!/usr/bin/env dart\n",
        "// nested comment\n/* one /* two */ three */\n",
        "// comment\n" * 2000,
        "// comment\r",
        "// comment\r\n",
        "#!/usr/bin/env dart\r",
        "#!/usr/bin/env dart\r\n",
    ],
)
def test_worker_headers_cannot_hide_a_dependency(source, header):
    root, _ = source
    (root / "app/worker.dart").write_text(
        header + "import '../outside.dart';\nvoid main() {}"
    )
    with pytest.raises(identity.IdentityError, match="out_of_root_worker_import"):
        worker(root)


@pytest.mark.parametrize("prefix", ["// comment\r", "#!/usr/bin/env dart\r"])
def test_cr_only_worker_source_cannot_hide_a_dependency(source, prefix):
    root, _ = source
    (root / "app/worker.dart").write_bytes(
        (prefix + "import '../outside.dart';\rvoid main() {}\r").encode()
    )
    with pytest.raises(identity.IdentityError, match="out_of_root_worker_import"):
        worker(root)


def test_comments_and_body_strings_are_not_imports(source):
    root, _ = source
    (root / "app/worker.dart").write_text(
        "// import '../private/credential.dart';\nimport 'runtime.dart';\nvoid main() { print(\"import '../private/credential.dart';\"); }"
    )
    worker(root)


def test_relative_export_and_part_dependencies_are_hashed(source):
    root, config = source
    (root / "app/worker.dart").write_text(
        "import 'dart:io';\nexport 'runtime.dart';\npart 'part.dart';\nvoid main() {}"
    )
    (root / "app/part.dart").write_text("part of 'worker.dart';\n")
    config["worker"]["inputs"].append("app/part.dart")
    save(root, config)
    first = worker(root)
    (root / "app/part.dart").write_text("part of 'worker.dart';\n// changed")
    assert worker(root)["worker_id"] != first["worker_id"]


def test_worker_cannot_infer_mode_or_accept_unknown_external_package(source):
    root, _ = source
    with pytest.raises(identity.IdentityError, match="invalid_worker_options"):
        worker(root, mode="flutter-release")
    (root / "app/worker.dart").write_text("import 'package:unknown/source.dart';")
    with pytest.raises(identity.IdentityError, match="unsupported_worker_import"):
        worker(root)


def test_native_command_rejects_worker_only_mode(source):
    root, _ = source
    result = cli(root, "--mode", "jit")
    assert result.returncode == 2
    assert json.loads(result.stderr) == {"error": "invalid_arguments"}


@pytest.mark.parametrize(
    "field,value",
    [
        ("root", "outside"),
        ("prefix", "other"),
        ("targets", {}),
        ("inputs", "not-an-inventory"),
        ("flags", "not-a-list"),
    ],
)
def test_malformed_native_contract_does_not_yield_identity(source, field, value):
    root, config = source
    config["native"][field] = value
    save(root, config)
    with pytest.raises(identity.IdentityError):
        native(root)


@pytest.mark.parametrize(
    "flags",
    [
        [],
        ["-std=c11", "-std=c11"],
        ["-DPRIVATE_VALUE=canary"],
        ["-std=c11", "-mmacosx-version-min=15.0"],
    ],
)
def test_unreviewed_native_flag_vector_is_refused(source, flags):
    root, _ = source
    with pytest.raises(identity.IdentityError, match="invalid_flags"):
        identity.Contract(root).native_identity("linux-x86_64", COMPILER, flags)


def test_compiler_metadata_and_missing_source_fail_before_identity(source):
    root, config = source
    for compiler in [
        identity.Compiler("apple-clang", "22.1.8", "a" * 64, "b" * 64),
        identity.Compiler("clang", "private-canary", "a" * 64, "b" * 64),
    ]:
        with pytest.raises(identity.IdentityError, match="invalid_toolchain"):
            identity.Contract(root).native_identity("linux-x86_64", compiler, FLAGS)
    config["native"]["inputs"][0]["targets"] = []
    save(root, config)
    with pytest.raises(identity.IdentityError, match="invalid_native_inventory"):
        native(root)
    config["native"]["inputs"][0]["targets"] = ["linux-x86_64"]
    save(root, config)
    (root / config["native"]["inputs"][0]["path"]).unlink()
    with pytest.raises(identity.IdentityError, match="missing_native_input"):
        native(root)


@pytest.mark.parametrize(
    "text",
    [
        "{",
        '{"schema":1,"schema":1}',
        '{"schema":true,"scope":"fixture","native":{},"worker":{}}',
    ],
)
def test_malformed_or_ambiguous_json_contract_is_refused(source, text):
    root, _ = source
    (root / identity.DEFAULT_CONTRACT).write_text(text)
    with pytest.raises(identity.IdentityError, match="invalid_contract"):
        identity.Contract(root)


@pytest.mark.parametrize("scope", [[], {"canary": "SCOPE_PRIVATE_CANARY"}, None])
def test_invalid_scope_is_a_closed_cli_failure(source, scope):
    root, config = source
    config["scope"] = scope
    save(root, config)
    result = cli(root)
    assert result.returncode == 2
    assert result.stdout == ""
    assert json.loads(result.stderr) == {"error": "invalid_contract"}
    assert "SCOPE_PRIVATE_CANARY" not in result.stderr


def test_contract_aliases_and_special_files_are_not_read(source):
    root, _ = source
    with pytest.raises(identity.IdentityError, match="unsafe_source_path"):
        identity.Contract(root / "missing")
    with pytest.raises(identity.IdentityError, match="invalid_contract_path"):
        identity.Contract(root, "other.json")
    contract = root / identity.DEFAULT_CONTRACT
    contract.unlink()
    os.mkfifo(contract)
    with pytest.raises(identity.IdentityError, match="unsafe_source_path"):
        identity.Contract(root)


@pytest.mark.parametrize(
    "field,value",
    [
        ("roots", ["app", "app/nested", "native", "catalog"]),
        ("exceptions", ["not-a-reasoned-map"]),
        ("exceptions", {"outside/file.dart": "Outside the owned worker."}),
        ("exceptions", {"app/worker.dart": "Cannot exclude an included input."}),
        ("catalog", []),
        ("external_imports", ["package:unreviewed/code.dart"]),
        ("options", {"record_schema": True}),
    ],
)
def test_worker_inventory_and_options_are_closed(source, field, value):
    root, config = source
    config["worker"][field] = value
    save(root, config)
    with pytest.raises(identity.IdentityError):
        worker(root)


def test_explicit_worker_file_roots_work_without_scanning_siblings(source):
    root, config = source
    config["worker"]["roots"] = ["app", "native", "catalog/locations.json"]
    (root / "catalog/private_credential.json").write_text(
        "synthetic value excluded by the file root"
    )
    save(root, config)
    worker(root)
    (root / "catalog/locations.json").rename(root / "catalog/moved.json")
    with pytest.raises(identity.IdentityError, match="unsafe_source_path"):
        worker(root)


def test_worker_directory_aliases_are_rejected(source):
    root, _ = source
    (root / "app/alias").symlink_to(root / "catalog", target_is_directory=True)
    with pytest.raises(identity.IdentityError, match="unsafe_source_path"):
        worker(root)


@pytest.mark.parametrize(
    "data",
    [
        b"\xff",
        b"/* unterminated",
        b"@Unclassified() library;",
        b"import ",
        b"import '''runtime.dart''';",
        b"import 'unterminated",
        b"import '${value}.dart';",
    ],
)
def test_unsupported_dart_header_cannot_hide_dependencies(source, data):
    root, _ = source
    (root / "app/worker.dart").write_bytes(data)
    with pytest.raises(identity.IdentityError, match="unsupported_worker"):
        worker(root)


@pytest.mark.parametrize(
    "data", [b"\xff", b'??=include "private.h"', b"/* unterminated", b"#\n"]
)
def test_unsupported_native_preprocessing_fails_closed(source, data):
    root, _ = source
    (root / "native/diagnostic_protocol.c").write_bytes(data)
    with pytest.raises(identity.IdentityError, match="unsupported_native_include"):
        native(root)


@pytest.mark.parametrize(
    "data,error",
    [
        (b'// comment\r#include "unclassified.h"\n', "unclassified_native_include"),
        (b'#inc\\\rlude "unclassified.h"\n', "unclassified_native_include"),
        (b'#inc\\ \nlude "unclassified.h"\n', "unsupported_native_include"),
        (b'#inc\\\t\r\nlude "unclassified.h"\n', "unsupported_native_include"),
        (
            b"#warning don't\n#define A '/*'\n#include \"unclassified.h\"\n#define B '*/'\n",
            "unsupported_native_include",
        ),
        (b"#if 0\n'unterminated\n#endif\n", "unsupported_native_include"),
        (b'#import "unclassified.h"\n', "unsupported_native_include"),
        (b'#include_next "unclassified.h"\n', "unsupported_native_include"),
        (b'#embed "unclassified.h"\n', "unsupported_native_include"),
        (b"#include <unclassified.h>\n", "unclassified_native_include"),
        (b'\v#include "unclassified.h"\n', "unclassified_native_include"),
        (b'\f#include "unclassified.h"\n', "unclassified_native_include"),
    ],
)
def test_native_lexical_forms_cannot_hide_dependencies(source, data, error):
    root, _ = source
    (root / "native/diagnostic_protocol.c").write_bytes(data)
    with pytest.raises(identity.IdentityError, match=error):
        native(root)


def test_native_system_headers_are_closed_and_line_endings_preserved(source):
    root, _ = source
    (root / "native/diagnostic_protocol.c").write_bytes(
        b'#include <stdint.h>\r#include "diagnostic_protocol.h"\r\n'
    )
    native(root)


@pytest.mark.parametrize("target", ["native", "worker"])
def test_inventory_walk_errors_refuse_incomplete_identity(source, target):
    root, _ = source

    def unreadable_walk(*args, onerror=None, **kwargs):
        if onerror is not None:
            onerror(PermissionError("synthetic unreadable inventory"))
        return iter([])

    with (
        mock.patch.object(identity.os, "walk", side_effect=unreadable_walk),
        pytest.raises(identity.IdentityError, match="unsafe_source_path"),
    ):
        native(root) if target == "native" else worker(root, "a" * 64)


@pytest.mark.parametrize(
    "name",
    [
        "tools/\x00/diagnostic_build_inputs.json",
        "tools/\x1f/diagnostic_build_inputs.json",
    ],
)
def test_control_characters_in_contract_path_refused_before_open(source, name):
    root, _ = source
    with (
        mock.patch.object(
            identity.os, "open", side_effect=AssertionError("source opened")
        ),
        pytest.raises(identity.IdentityError, match="unsafe_source_path"),
    ):
        identity.Contract(root, name)


def test_explicit_exception_on_a_file_root_is_not_hashed(source):
    root, config = source
    skipped = root / "owned/omitted.dart"
    skipped.parent.mkdir()
    skipped.write_text("This is a classified synthetic non-runtime fixture.\n")
    config["worker"]["roots"].append("owned/omitted.dart")
    config["worker"]["exceptions"] = {
        "owned/omitted.dart": "Synthetic non-runtime input excluded by reviewed fixture contract."
    }
    save(root, config)
    first = worker(root)
    skipped.write_text("Changed explicitly excluded fixture.\n")
    assert worker(root) == first


def test_source_changed_during_read_cannot_produce_a_mixed_receipt(source):
    root, _ = source
    path = root / "native/diagnostic_protocol.c"
    inode = path.stat().st_ino
    original = os.read
    changed = False

    def mutate(fd, count):
        nonlocal changed
        data = original(fd, count)
        if not changed and os.fstat(fd).st_ino == inode:
            changed = True
            with path.open("ab") as stream:
                stream.write(b"/* concurrent source change */")
        return data

    with (
        mock.patch.object(identity.os, "read", side_effect=mutate),
        pytest.raises(identity.IdentityError, match="input_changed"),
    ):
        native(root)
    assert changed


def test_source_content_size_is_bounded_before_read(source):
    root, _ = source
    path = root / "native/diagnostic_protocol.c"
    with path.open("wb") as stream:
        stream.truncate(16 * 1024 * 1024 + 1)
    with pytest.raises(identity.IdentityError, match="unsafe_source_path"):
        native(root)


def test_direct_cli_works_in_export_from_unrelated_directory(source):
    import shutil

    root, _ = source
    script = root / "tools/diagnostic_build_identity.py"
    shutil.copyfile(ROOT / "tools/diagnostic_build_identity.py", script)
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "native",
            "--target",
            "linux-x86_64",
            "--compiler-family",
            "clang",
            "--compiler-version",
            "22.1.8",
            "--compiler-sha256",
            "a" * 64,
            "--toolchain-sha256",
            "b" * 64,
            "--flag=-std=c11",
            "--flag=-O2",
        ],
        cwd=root.parent,
        env={**os.environ, "PATH": "", "GIT_DIR": str(root / "no-git-metadata")},
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == native(root)


def test_distinct_read_admissions_cannot_reuse_one_source_inode(source):
    root, _ = source
    seen = set()
    assert identity._read(root, "app/runtime.dart", seen=seen)
    with pytest.raises(identity.IdentityError, match="duplicate_input"):
        identity._read(root, "app/runtime.dart", seen=seen)


def test_production_native_id_binds_its_producer_recipe_without_worker_inputs(source):
    root, config = source
    config["scope"] = "components"
    save(root, config)
    for name in identity.NATIVE_RECIPE_INPUTS:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / name).read_bytes())
    before = native(root)
    assert set(before["record"]["producer_inputs"]) == set(
        identity.NATIVE_RECIPE_INPUTS
    )
    (root / "app/worker.dart").write_text("void main() { print('changed worker'); }")
    assert native(root) == before
    recipe = root / "cmake/DiagnosticProducts/CMakeLists.txt"
    recipe.write_text(recipe.read_text() + "\n# changed native compile recipe\n")
    after = native(root)
    assert after["native_id"] != before["native_id"]
    assert after["record"]["inputs"] == before["record"]["inputs"]
