"""Assemble tiny real bundles; stub only native probes and compiler products."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import package  # noqa: E402


@pytest.fixture
def bundle(tmp_path, monkeypatch):
    build, flutter, output = (
        tmp_path / "build",
        tmp_path / "flutter",
        tmp_path / "output",
    )
    names = [
        "services/helper/ForesightHelper",
        "native/libforesight_native.so",
        "application/foresight-service",
        "application/foresight-mcp",
        "services/inference/foresight-model",
        "lib/liblitert-lm.so",
    ]
    for dependency in ("sentencepiece", "flatbuffers"):
        names.append(f"_deps/{dependency}-src/LICENSE")
    for dependency in ("protobuf-lite", "esaxx", "darts_clone", "absl"):
        names.append(f"_deps/sentencepiece-src/third_party/{dependency}/LICENSE")
    for relative in names:
        path = build / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(relative.encode())
    flutter.mkdir()
    (flutter / "open-foresight").write_bytes(b"desktop")
    library = build / "lib/liblitert-lm.so"
    identity = hashlib.sha256(library.read_bytes()).hexdigest()
    monkeypatch.setattr(package, "LIBRARY_SHA256", identity)
    monkeypatch.setattr(package, "read_version", lambda: ("1.2.3", 42))
    monkeypatch.delenv("FORESIGHT_GOOGLE_CLIENT_JSON", raising=False)
    commands = []

    def run(command, **kwargs):
        commands.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(package.subprocess, "run", run)
    monkeypatch.setattr(package.subprocess, "check_output", lambda *a, **kw: "")
    args = [
        "package",
        "--build",
        str(build),
        "--flutter-bundle",
        str(flutter),
        "--output",
        str(output),
        "--litert-library",
        str(library),
        "--revision",
        "a" * 40,
    ]
    monkeypatch.setattr(sys, "argv", args)
    return SimpleNamespace(
        build=build,
        flutter=flutter,
        output=output,
        library=library,
        args=args,
        commands=commands,
        identity=identity,
        root=tmp_path,
    )


@pytest.mark.parametrize(
    "failure",
    [
        "revision",
        "device",
        "application",
        "helper",
        "exists",
        "worker",
        "extension",
        "whisper",
        "speech-worker",
        "linkage",
    ],
)
def test_packaging_rejects_incomplete_or_incompatible_products(
    bundle, monkeypatch, failure
):
    case = bundle
    if failure == "revision":
        case.args[-1] = "main"
    elif failure == "device":
        case.args += ["--whisper-gpu-device", "-1"]
    elif failure == "application":
        (case.build / "application/foresight-mcp").unlink()
    elif failure == "helper":
        (case.build / "services/helper/ForesightHelper").unlink()
    elif failure == "worker":
        (case.build / "services/inference/foresight-model").unlink()
    elif failure == "exists":
        case.output.mkdir()
        (case.output / "precious").write_text("successful package")
    elif failure == "extension":
        case.args += ["--litert-extensions-manifest", "fixture.json"]
        monkeypatch.setattr(
            package,
            "verify_extensions_manifest",
            lambda *a, **kw: SimpleNamespace(manifest={"library_sha256": "0" * 64}),
        )
    elif failure in ("whisper", "speech-worker"):
        whisper = case.root / "whisper-cli"
        if failure == "speech-worker":
            whisper.write_bytes(b"runtime")
        case.args += ["--whisper-gpu-runtime", str(whisper)]
    else:
        monkeypatch.setattr(
            package.subprocess, "check_output", lambda *a, **kw: "libgrpc => not found"
        )
    with pytest.raises(ValueError):
        package.main()
    if failure != "linkage":
        if failure == "exists":
            assert (case.output / "precious").read_text() == "successful package"
        else:
            assert not case.output.exists()
    assert not any("build" == token for cmd, _ in case.commands for token in cmd)


@pytest.mark.parametrize("extensions", [False, True])
def test_complete_gpu_bundle_keeps_dependency_closure_and_receipts(
    bundle, monkeypatch, extensions
):
    case = bundle
    whisper = case.root / "speech/whisper-cli"
    whisper.parent.mkdir()
    for name in (
        "whisper-cli",
        "foresight-whisper-worker",
        "LICENSE",
        "provenance.json",
    ):
        (whisper.parent / name).write_bytes(name.encode())
    case.args += [
        "--whisper-gpu-runtime",
        str(whisper),
        "--query-python-runtime",
        str(case.root / "python"),
        "--generation-backend",
        "gpu",
    ]
    monkeypatch.setenv(
        "FORESIGHT_GOOGLE_CLIENT_JSON",
        '{"installed":{"client_id":"123-fixture.apps.googleusercontent.com"}}',
    )

    def copy_python(source, destination, licenses):
        (destination / "bin").mkdir(parents=True)
        (destination / "bin/python3").write_bytes(b"standalone interpreter fixture")

    monkeypatch.setattr(package, "copy_query_runtime", copy_python)
    dependencies = case.root / "libraries"
    dependencies.mkdir()
    for name in ("libgrpc.so", "libsqlite3.so.0"):
        (dependencies / name).write_bytes(name.encode())
    monkeypatch.setattr(
        package.subprocess,
        "check_output",
        lambda *a, **kw: "\n".join(
            f" {name} => {dependencies / name} (0x01)"
            for name in ("libgrpc.so", "libsqlite3.so.0")
        ),
    )
    probe = Mock()
    monkeypatch.setattr(package, "probe_native_extensions", probe)
    if extensions:
        case.args += ["--litert-extensions-manifest", "fixture.json"]
        verified = SimpleNamespace(
            manifest={"library_sha256": case.identity, "upstream_commit": "b" * 40}
        )
        monkeypatch.setattr(
            package, "verify_extensions_manifest", lambda *a, **kw: verified
        )
        monkeypatch.setattr(
            package,
            "copy_linux_extension_dependencies",
            lambda *a: [case.output / "lib/liblitert-lm.so"],
        )
        monkeypatch.setattr(
            package,
            "validate_linux_extension_dependencies",
            lambda *a: {"LD_LIBRARY_PATH": str(case.output / "lib")},
        )
        monkeypatch.setattr(
            package,
            "write_extension_provenance",
            lambda value, path: path.write_text(json.dumps(value.manifest)),
        )
    package.main()
    manifest = json.loads((case.output / "manifest.json").read_text())
    assert manifest["query_detector_runtime"]["bundled"] is True
    assert manifest["whisper_runtime"] == "vulkan"
    assert manifest["revision"] == "a" * 40
    configuration = json.loads((case.output / "share/open-foresight/runtime.json").read_text())
    assert configuration["FORESIGHT_INSTALL_ROOT"] == "../.."
    assert configuration["FORESIGHT_RUNTIME_REVISION"] == manifest["revision"]
    assert configuration["FORESIGHT_NATIVE"] == "../../lib/libforesight_native.so"
    assert configuration["FORESIGHT_LITERT_BACKEND"] == "gpu"
    assert configuration["FORESIGHT_WHISPER_RUNTIME"] == "../../bin/whisper-cli-vulkan"
    assert configuration["FORESIGHT_LITERT_PYTHON"] == "../../bin/query-python"
    assert "share/open-foresight/runtime.json" in {entry["path"] for entry in manifest["files"]}
    assert set(manifest["bundled_libraries"]) == {"libgrpc.so", "libsqlite3.so.0"}
    assert (case.output / "lib/libsqlite3.so").is_symlink()
    assert (case.output / "bin/query-python").stat().st_mode & 0o111
    for entry in manifest["files"]:
        assert (
            hashlib.sha256((case.output / entry["path"]).read_bytes()).hexdigest()
            == entry["sha256"]
        )
    assert probe.called is extensions
    assert case.commands[0][0][-1] == "--check"
