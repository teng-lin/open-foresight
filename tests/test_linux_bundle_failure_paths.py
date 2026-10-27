"""Assemble tiny real bundles; stub only native probes and compiler products."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from tests.media_package_fixture import media_product_patches

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import package  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def diagnostic_products(build, sdk):
    """Write the finished runtime-support and worker builds packaging consumes.

    As in tests/test_runtime_package_support.py, product bytes, markers, modes and
    receipt digests are real; only the two source verifiers, which need the actual
    compiled products and AOT toolchain, are replaced by checks of the exact
    roots they receive. Returns (owner, attribute, replacement) to patch.
    """
    support = sys.modules[package.prepare_worker.__module__]
    native = build / "native"
    native.mkdir(parents=True, exist_ok=True)
    products = {
        "schema": 1,
        "kind": "runtime-support-build",
        "target": "linux-x86_64",
        "native_id": "a" * 64,
        "sql_source_id": "b" * 64,
        "artifacts": {},
    }
    for name in support._layout(products["target"]):
        path = native / name
        path.write_bytes(
            b"synthetic byte fixture: "
            + name.encode()
            + support._marker(name, products)
        )
        path.chmod(0o755)
        products["artifacts"][name] = support._read(path)[1]
    metadata = {
        "diagnostic-products.json": {
            "schema": 1,
            "available": True,
            "native_id": products["native_id"],
        },
        "diagnostic-native-inputs.json": {"fixture": "not compiler evidence"},
        "diagnostic-toolchain-metadata.json": {"fixture": "synthetic public metadata"},
        "diagnostic-sql-inputs.json": {"fixture": "synthetic SQL record"},
    }
    for name, record in metadata.items():
        (native / name).write_text(json.dumps(record) + "\n")
    for name, field in (
        ("diagnostic-native-inputs.json", "native_inputs_sha256"),
        ("diagnostic-toolchain-metadata.json", "toolchain_metadata_sha256"),
        ("diagnostic-sql-inputs.json", "sql_inputs_sha256"),
    ):
        products[field] = support._digest((native / name).read_bytes())
    (native / "runtime-support-build.json").write_text(json.dumps(products) + "\n")

    def verify_products(root, actual_native):
        assert root == ROOT and actual_native == native
        return json.loads(json.dumps(products))

    target = build / "application/foresight-diagnostic-worker"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"synthetic AOT fixture, not product qualification")
    target.chmod(0o755)
    receipt = {
        "schema": 1,
        "kind": "standalone-worker-build",
        "mode": "aot",
        "native_id": "a" * 64,
        "worker_id": "b" * 64,
        "catalog_id": "c" * 64,
        "artifact": {
            "path": "application/foresight-diagnostic-worker",
            **support._read(target)[1],
        },
        "defines": {"fixture": "exact recipe owned by source verifier"},
    }
    (build / "application/diagnostic-worker-build.json").write_bytes(
        support._canonical(receipt) + b"\n"
    )
    (native / "diagnostic-worker-inputs.json").write_bytes(b'{"synthetic":"context"}\n')
    dart = sdk / "bin/dart"
    dart.parent.mkdir(parents=True)
    dart.write_text(f"#!{sys.executable}\nprint({str(dart)!r})\n")
    dart.chmod(0o755)
    which = support.shutil.which

    def select(name, *args, **kwargs):
        return str(dart) if name == "dart" else which(name, *args, **kwargs)

    def verify(root, actual_build, actual_sdk):
        assert (
            root == ROOT
            and actual_build == build
            and actual_sdk == sdk.resolve(strict=True)
        )
        return json.loads(json.dumps(receipt))

    return [
        (support, "verify_products", verify_products),
        (support.shutil, "which", select),
        (support, "_verify_worker", verify),
        *media_product_patches(package, "linux-x86_64"),
    ]


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
    for target, name, value in diagnostic_products(build, tmp_path / "sdk"):
        monkeypatch.setattr(target, name, value)
    flutter.mkdir()
    (flutter / "open-foresight").write_bytes(b"desktop")
    library = build / "lib/liblitert-lm.so"
    identity = hashlib.sha256(library.read_bytes()).hexdigest()
    monkeypatch.setattr(package, "LIBRARY_SHA256", identity)
    monkeypatch.setattr(package, "read_version", lambda: ("1.2.3", 42))
    monkeypatch.delenv("FORESIGHT_GOOGLE_CLIENT_JSON", raising=False)
    commands = []
    real_run = subprocess.run

    def run(command, **kwargs):
        if command[0] == str(tmp_path / "sdk/bin/dart"):
            return real_run(command, **kwargs)
        commands.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(package.subprocess, "run", run)
    monkeypatch.setattr(package.subprocess, "check_output", lambda *a, **kw: "")
    args = [
        "package",
        "--build",
        str(build),
        "--media-worker-build",
        str(build / "media-worker"),
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
    configuration = json.loads(
        (case.output / "share/open-foresight/runtime.json").read_text()
    )
    assert configuration["FORESIGHT_INSTALL_ROOT"] == "../.."
    assert configuration["FORESIGHT_RUNTIME_REVISION"] == manifest["revision"]
    assert configuration["FORESIGHT_NATIVE"] == "../../lib/libforesight_native.so"
    assert configuration["FORESIGHT_LITERT_BACKEND"] == "gpu"
    assert configuration["FORESIGHT_WHISPER_RUNTIME"] == "../../bin/whisper-cli-vulkan"
    assert configuration["FORESIGHT_LITERT_PYTHON"] == "../../bin/query-python"
    assert "share/open-foresight/runtime.json" in {
        entry["path"] for entry in manifest["files"]
    }
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


def test_model_and_diagnostic_workers_keep_their_own_source_bytes(bundle):
    case = bundle
    package.main()
    manifest = {
        entry["path"]: entry["sha256"]
        for entry in json.loads((case.output / "manifest.json").read_text())["files"]
    }
    for packaged, source in (
        ("bin/foresight-model", "services/inference/foresight-model"),
        ("bin/foresight-diagnostic-worker", "application/foresight-diagnostic-worker"),
    ):
        data = (case.build / source).read_bytes()
        assert (case.output / packaged).read_bytes() == data
        assert manifest[packaged] == hashlib.sha256(data).hexdigest()
    assert (
        case.output / "bin/foresight-diagnostic-worker"
    ).stat().st_mode & 0o777 == 0o755
