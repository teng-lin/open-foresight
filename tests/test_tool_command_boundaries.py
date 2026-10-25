"""Offline checks of generation, lint and sanitizer command boundaries."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from google.protobuf import descriptor_pb2
from tools import check_build_cache, check_dart_bindings, generate_bindings

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import ci_verify_dependency as dependency
import build_macos_sdk as sdk
import build_macos_vendor as vendor
import build_macos_runtimes as runtimes
import verify_native_sanitizers as asan
import verify_thread_sanitizer as tsan


def test_cached_python_requires_an_executable_file(tmp_path):
    cache = tmp_path / "CMakeCache.txt"
    check_build_cache.verify(cache)
    cache.write_text("OTHER:FILEPATH=irrelevant\n")
    check_build_cache.verify(cache)
    python = tmp_path / "python with spaces"
    cache.write_text(f"Python3_EXECUTABLE:FILEPATH={python}\n")
    for state in ("missing", "directory", "non-executable", "executable"):
        if state == "directory":
            python.mkdir()
        elif state == "non-executable":
            python.rmdir()
            python.write_text("interpreter")
        elif state == "executable":
            python.chmod(0o700)
        if state == "executable":
            check_build_cache.verify(cache)
        else:
            with pytest.raises(ValueError, match="reconfigure"):
                check_build_cache.verify(cache)


@pytest.mark.parametrize(
    "language,plugin",
    [("cpp", "/plugin with spaces"), ("dart", None), ("python", None)],
)
def test_binding_generation_preserves_owned_descriptor_and_command_arguments(
    tmp_path, monkeypatch, language, plugin
):
    commands = []
    original = generate_bindings.production_descriptor()

    def run(command, **kwargs):
        source = Path(
            next(
                c.split("=", 1)[1]
                for c in command
                if c.startswith("--descriptor_set_in=")
            )
        )
        descriptor = descriptor_pb2.FileDescriptorSet.FromString(source.read_bytes())
        assert descriptor.file[0] == original
        commands.append(command)
        assert kwargs == {"check": True, "timeout": 300}

    monkeypatch.setattr(generate_bindings.subprocess, "run", run)
    argv = [
        "bindings",
        "--language",
        language,
        "--output",
        str(tmp_path / "output directory"),
        "--protoc",
        "/compiler path/protoc",
    ]
    if plugin:
        argv += ["--grpc-plugin", plugin]
    monkeypatch.setattr(sys, "argv", argv)
    generate_bindings.main()
    command = commands[0]
    assert command[0] == "/compiler path/protoc"
    assert command[-1] == "rag_service.proto"
    assert (
        f"--{language}_out={'grpc:' if language == 'dart' else ''}{tmp_path / 'output directory'}"
        in command
    )
    assert any(c.startswith("--grpc_out=") for c in command) == bool(plugin)


def test_binding_generation_rejects_schema_without_package(tmp_path, monkeypatch):
    source = tmp_path / "proto/rag"
    source.mkdir(parents=True)
    real = generate_bindings.ROOT / "proto/rag/rag_service.descriptor.pb"
    (source / real.name).write_bytes(real.read_bytes())
    (source / "rag_service.proto").write_text('syntax = "proto3";')
    monkeypatch.setattr(generate_bindings, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="package"):
        generate_bindings.production_descriptor()


@pytest.mark.parametrize("mode", ["same", "drift", "write", "stale"])
def test_dart_binding_gate_detects_drift_and_keeps_forwarding_exports(
    tmp_path, monkeypatch, capsys, mode
):
    core, desktop = tmp_path / "core", tmp_path / "desktop"
    core.mkdir()
    desktop.mkdir()
    expected = "// generated\nclass Message {}\n"
    (core / "api.dart").write_text(expected if mode == "same" else "// old\n")
    (desktop / "api.dart").write_text(
        "export 'package:foresight_core/src/generated/api.dart';\n"
    )
    if mode == "stale":
        (desktop / "removed.dart").write_text("// stale\n")

    def run(command, **kwargs):
        if "--output" in command:
            output = Path(command[command.index("--output") + 1])
            (output / "api.dart").write_text(expected)
            (output / "new.dart").write_text("// new\n")

    monkeypatch.setattr(check_dart_bindings, "ROOT", tmp_path)
    monkeypatch.setattr(check_dart_bindings, "DESTINATIONS", [core, desktop])
    monkeypatch.setattr(check_dart_bindings.subprocess, "run", run)
    # "same" includes the new core binding but deliberately has no desktop export.
    if mode == "same":
        (core / "new.dart").write_text("// new\n")
    monkeypatch.setattr(
        sys, "argv", ["check", *(["--write"] if mode == "write" else [])]
    )
    if mode in ("drift", "stale"):
        with pytest.raises(SystemExit, match="Stale" if mode == "stale" else "drifted"):
            check_dart_bindings.main()
        assert (core / "api.dart").read_text() == "// old\n"
        if mode == "drift":
            assert "regenerated/api.dart" in capsys.readouterr().out
    else:
        check_dart_bindings.main()
        assert (core / "api.dart").read_text() == expected
        assert not (desktop / "new.dart").exists()


def test_imported_dependency_verifies_manifest_files_and_generator(
    tmp_path, monkeypatch
):
    manifest = dict(
        grpc_commit=sdk.GRPC_COMMIT,
        protobuf_commit=sdk.PROTOBUF_COMMIT,
        protobuf_version="libprotoc 35.1",
        json_commit=sdk.JSON_COMMIT,
        architecture="arm64",
        minimum_macos="15.0",
        static=True,
    )
    stamp = tmp_path / "foresight-sdk.json"
    stamp.write_text(json.dumps(manifest))
    monkeypatch.setattr(
        dependency.subprocess, "check_output", lambda *a, **kw: "libprotoc 35.1\n"
    )
    with pytest.raises(ValueError, match="incomplete"):
        dependency.verify("macos-sdk", tmp_path)
    for relative in (
        "bin/protoc",
        "bin/grpc_cpp_plugin",
        "lib/cmake/grpc/gRPCConfig.cmake",
        "share/cmake/nlohmann_json/nlohmann_jsonConfig.cmake",
        "share/foresight-sdk/licenses",
    ):
        path = tmp_path / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    dependency.verify("macos-sdk", tmp_path)
    monkeypatch.setattr(
        dependency.subprocess, "check_output", lambda *a, **kw: "libprotoc wrong"
    )
    with pytest.raises(ValueError, match="version"):
        dependency.verify("macos-sdk", tmp_path)
    stamp.write_text("{}")
    with pytest.raises(ValueError, match="provenance"):
        dependency.verify("macos-sdk", tmp_path)
    for module, component in ((vendor, "macos-vendor"), (runtimes, "macos-runtime")):
        verify = Mock()
        monkeypatch.setattr(module, "verify", verify)
        dependency.verify(component, tmp_path)
        verify.assert_called_once_with(tmp_path)


@pytest.mark.parametrize("compiler", ["g++ fixture", "CLANG fixture"])
@pytest.mark.parametrize("failure", [None, "zero-exit", "no-diagnostic"])
def test_asan_probe_requires_fatal_diagnostic_and_retains_log(
    tmp_path, monkeypatch, compiler, failure
):
    monkeypatch.setattr(sys, "argv", ["probe", "--output", str(tmp_path)])
    monkeypatch.setattr(asan.subprocess, "check_output", lambda *a, **kw: compiler)
    monkeypatch.setattr(
        asan, "address_runtime", lambda *a: tmp_path / "runtime/libasan.so"
    )
    monkeypatch.setenv("LD_PRELOAD", "/must/not/be/inherited")
    commands = []
    seen_probes = []

    def run(command, **kwargs):
        commands.append((command, kwargs))
        if "capture_output" not in kwargs:
            source = Path(command[-3]).read_text()
            assert source in [
                *(code for code, _ in asan.CASES.values()),
                asan.HOST_LIBRARY,
            ]
            return subprocess.CompletedProcess(command, 0)
        if command[0] == sys.executable:
            mode = command[-1]
            name, (_, diagnostics) = next(
                (name, case)
                for name, case in asan.HOST_CASES.items()
                if case[0] == mode
            )
            assert kwargs["env"]["LD_PRELOAD"] == str(
                tmp_path / "runtime/libasan.so"
            )
        else:
            assert "LD_PRELOAD" not in kwargs["env"]
            name = Path(command[0]).name
            diagnostics = asan.CASES[name][1]
        seen_probes.append(name)
        diagnostic = "\n".join(diagnostics or ())
        return subprocess.CompletedProcess(
            command,
            0 if diagnostics is None or failure == "zero-exit" else 1,
            "stdout evidence\n",
            "wrong" if failure == "no-diagnostic" else diagnostic,
        )

    monkeypatch.setattr(asan.subprocess, "run", run)
    if failure:
        with pytest.raises(RuntimeError, match="fatal-report"):
            asan.main()
    else:
        asan.main()
        assert (tmp_path / "undefined.log").is_file()
        assert seen_probes == [
            *asan.CASES,
            *(asan.HOST_CASES if "CLANG" in compiler else ()),
        ]
        for name in seen_probes:
            assert (tmp_path / (name + ".log")).read_text().startswith(
                "stdout evidence"
            )
    assert (tmp_path / "address.log").read_text().startswith("stdout evidence")
    assert ("-shared-libasan" in commands[0][0]) == ("CLANG" in compiler)


@pytest.mark.parametrize(
    "returncode,diagnostic,passed",
    [
        (66, "ThreadSanitizer: data race", True),
        (0, "ThreadSanitizer: data race", False),
        (66, "unsupported runtime", False),
    ],
)
def test_tsan_probe_records_unsupported_runtime_and_requires_a_race(
    tmp_path, monkeypatch, returncode, diagnostic, passed
):
    monkeypatch.setattr(sys, "argv", ["probe", "--output", str(tmp_path)])
    monkeypatch.setattr(
        tsan, "address_runtime", lambda **kw: tmp_path / "runtime/libtsan.so"
    )

    def run(command, **kwargs):
        if "capture_output" in kwargs:
            assert kwargs["env"]["TSAN_OPTIONS"] == "halt_on_error=1:exitcode=66"
        return subprocess.CompletedProcess(command, returncode, "stdout\n", diagnostic)

    monkeypatch.setattr(tsan.subprocess, "run", run)
    if passed:
        tsan.main()
    else:
        with pytest.raises(SystemExit, match="retained runtime diagnostics"):
            tsan.main()
    report = json.loads((tmp_path / "result.json").read_text())
    assert report["race_detected"] is passed
    assert report["exit_code"] == returncode
    assert (tmp_path / "race.log").read_text() == "stdout\n" + diagnostic


@pytest.mark.parametrize("kind", ["deb", "rpm", "arch", "unknown"])
def test_preview_comparator_requires_native_ordering(tmp_path, monkeypatch, kind):
    spec = importlib.util.spec_from_file_location(
        "preview_comparator_test",
        Path(__file__).resolve().parents[1] / "packaging/check_preview_version.py",
    )
    sys.path.insert(0, str(Path(spec.origin).parent))
    try:
        comparator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(comparator)
    finally:
        sys.path.pop(0)
    monkeypatch.setattr(comparator.subprocess, "run", Mock())
    monkeypatch.setattr(comparator.subprocess, "check_output", lambda *a, **kw: "-1\n")
    rpm = SimpleNamespace(labelCompare=Mock(return_value=-1))
    monkeypatch.setitem(sys.modules, "rpm", rpm)
    comparator.verify(kind, "1.2.3")  # Stable versions require no comparator.
    if kind == "unknown":
        # native_version rejects unsupported formats before any native command.
        with pytest.raises(ValueError):
            comparator.verify(kind, "1.2.3~nightly.20261019.4")
        return
    comparator.verify(kind, "1.2.3~nightly.20261019.4")
    if kind == "rpm":
        rpm.labelCompare.return_value = 0
    elif kind == "arch":
        monkeypatch.setattr(comparator.subprocess, "check_output", lambda *a, **kw: "0")
    else:
        comparator.subprocess.run.assert_called_once()
        return
    with pytest.raises(ValueError, match="sort below"):
        comparator.verify(kind, "1.2.3~nightly.20261019.4")
