"""Package real fixture files; replace signing, relocation and native launches."""

import hashlib
import json
from pathlib import Path
import plistlib
import sys
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import package_macos as package


def put(path, content=b"fixture"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


@pytest.fixture
def packaging(tmp_path, monkeypatch):
    build, flutter, output = (
        tmp_path / "build",
        tmp_path / "Flutter.app",
        tmp_path / "dist/Packaged.app",
    )
    for relative in (
        "services/inference/foresight-model",
        "services/inference/foresight-query",
        "services/helper/ForesightHelper",
        "native/libforesight_native.dylib",
        "native/foresight-audio",
        "macos/foresight-notifications",
        "macos/foresight-file-parser",
        "macos/foresight-model-crypto",
        "application/foresight-service",
        "application/foresight-mcp",
    ):
        put(build / relative, relative.encode())
    put(flutter / "Contents/MacOS/open-foresight")
    put(
        flutter / "Contents/Info.plist",
        plistlib.dumps({"CFBundleIdentifier": "io.openforesight.App"}),
    )
    whisper = put(tmp_path / "whisper/whisper-cli")
    put(whisper.parent / "foresight-whisper-worker")
    license = put(tmp_path / "whisper/LICENSE", b"whisper terms")
    sdk = tmp_path / "sdk"
    put(sdk / "foresight-sdk.json", b'{"verified":"fixture"}')
    put(sdk / "share/foresight-sdk/licenses/grpc-LICENSE")
    monkeypatch.setattr(package.sys, "platform", "darwin")
    monkeypatch.setattr(
        package,
        "release_google_client",
        lambda *a, **kw: {"installed": {"client_id": "fixture"}},
    )
    monkeypatch.setattr(
        package,
        "release_web_search_keys",
        lambda: {"FORESIGHT_SEARCH_API_KEY": "bundled-key"},
    )
    monkeypatch.setattr(
        package, "verify_extensions_manifest", lambda *a, **kw: {"verified": True}
    )
    monkeypatch.setattr(
        package,
        "copy_macos_extension_dependencies",
        lambda manifest, target: put(
            target / "liblitert-lm.dylib", b"relocated library"
        ),
    )
    monkeypatch.setattr(
        package,
        "write_extension_provenance",
        lambda manifest, path: put(path, b'{"verified":true}'),
    )
    monkeypatch.setattr(package, "relocate_dependencies", Mock())
    monkeypatch.setattr(
        package, "audit_dependencies", lambda app: [{"path": "lib", "dependencies": []}]
    )
    monkeypatch.setattr(package, "read_version", lambda: ("1.2.3", 42))
    commands = []
    state = {"notary": "Accepted"}

    def run(*args):
        commands.append(tuple(map(str, args)))
        if args[:3] == ("xcrun", "notarytool", "submit"):
            return json.dumps({"status": state["notary"]})
        return "a" * 40

    monkeypatch.setattr(package, "run", run)
    launches = []

    def launch(command, **kwargs):
        launches.append((command, kwargs))
        if command[0] == "ditto":
            put(Path(command[-1]), b"archive")

    monkeypatch.setattr(package.subprocess, "run", launch)

    def sign(app, identity, entitlements, *, before_seal):
        before_seal()
        # Receipts describe the library bytes at sealing time.
        receipt = json.loads((app / "Contents/Resources/manifest.json").read_text())
        assert (
            receipt["gemma_runtime"]["sha256"]
            == hashlib.sha256(b"relocated library").hexdigest()
        )

    monkeypatch.setattr(package, "sign_application", sign)
    args = [
        "--build",
        str(build),
        "--flutter-app",
        str(flutter),
        "--output",
        str(output),
        "--litert-extensions-manifest",
        str(tmp_path / "extensions.json"),
    ]
    return args, output, whisper, license, sdk, commands, launches, state


@pytest.mark.parametrize("release", [False, True])
def test_package_assembles_relative_runtime_config_licenses_and_sealed_receipts(
    packaging, monkeypatch, release
):
    args, app, whisper, license, sdk, commands, launches, _ = packaging
    archive = app.parent / "application.zip"
    monkeypatch.setenv("FORESIGHT_QUERY_TERMS_URL", "https://example.invalid/terms")
    if release:
        args += [
            "--identity",
            "Developer ID fixture",
            "--whisper-runtime",
            str(whisper),
            "--whisper-license",
            str(license),
            "--sdk",
            str(sdk),
            "--notary-profile",
            "fixture",
            "--archive",
            str(archive),
            "--generation-backend",
            "gpu",
        ]
    package.main(args)
    resources = app / "Contents/Resources"
    config = json.loads((resources / "runtime.json").read_text())
    assert config["FORESIGHT_RUNTIME_REVISION"] == "a" * 40
    assert config["FORESIGHT_QUERY_RUNTIME"] == config["FORESIGHT_QUERY_WORKER"]
    assert config["FORESIGHT_LITERT_RUNNER"] == config["FORESIGHT_MODEL_WORKER"]
    assert config["FORESIGHT_QUERY_TERMS_URL"] == "https://example.invalid/terms"
    assert config["FORESIGHT_INSTALL_ROOT"] == "../.."
    assert (resources / config["FORESIGHT_HELPER"]).is_file()
    assert not Path(config["FORESIGHT_HELPER"]).is_absolute()
    service = resources / config["FORESIGHT_SERVICE"]
    nested = json.loads((service.parent.parent / "Resources/runtime.json").read_text())
    assert (
        service.parent.parent / "Resources" / nested["FORESIGHT_HELPER"]
    ).resolve() == (resources / config["FORESIGHT_HELPER"]).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["LSMinimumSystemVersion"] == "15.0"
    assert all(key in info for key in package.PURPOSES)
    report = json.loads((app.parent / "Packaged.manifest.json").read_text())
    assert report["notarized"] is release
    assert report["whisper_bundled"] is release
    assert report["build_number"] == 42
    assert report["python_bundled"] is False
    assert any(command[-1] == "--check" for command, _ in launches)
    if release:
        assert archive.read_bytes() == b"archive"
        assert not (app.parent / "Packaged.notary.zip").exists()
        assert (resources / "licenses/whisper-LICENSE").read_bytes() == b"whisper terms"
        assert (resources / "licenses/sdk/grpc-LICENSE").exists()
        assert any(
            command[:3] == ("xcrun", "stapler", "validate") for command in commands
        )


@pytest.mark.parametrize(
    "problem",
    [
        "host",
        "suffix",
        "exists",
        "notary-adhoc",
        "missing-whisper",
        "missing-notices",
        "missing-component",
        "sdk-manifest",
    ],
)
def test_packaging_rejects_incomplete_release_inputs(packaging, monkeypatch, problem):
    args, app, whisper, license, sdk, _, _, _ = packaging
    if problem == "host":
        monkeypatch.setattr(package.sys, "platform", "linux")
    elif problem == "suffix":
        args[args.index("--output") + 1] = str(app.with_suffix(".zip"))
    elif problem == "exists":
        app.mkdir(parents=True)
    elif problem == "notary-adhoc":
        args += ["--notary-profile", "fixture"]
    elif problem == "missing-whisper":
        args += ["--identity", "Developer ID fixture"]
    elif problem == "missing-notices":
        args += [
            "--identity",
            "Developer ID fixture",
            "--whisper-runtime",
            str(whisper),
        ]
    elif problem == "missing-component":
        (Path(args[1]) / "native/foresight-audio").unlink()
    else:
        (sdk / "foresight-sdk.json").unlink()
        args += ["--sdk", str(sdk)]
    with pytest.raises(SystemExit, match="2"):
        package.main(args)


@pytest.mark.parametrize("problem", ["notary", "existing-archive"])
def test_packaging_retains_failure_and_removes_notary_submission(packaging, problem):
    args, app, whisper, license, sdk, _, _, state = packaging
    args += [
        "--identity",
        "Developer ID fixture",
        "--whisper-runtime",
        str(whisper),
        "--whisper-license",
        str(license),
        "--sdk",
        str(sdk),
    ]
    if problem == "notary":
        state["notary"] = "Rejected"
        args += ["--notary-profile", "fixture"]
    else:
        archive = put(app.parent / "existing.zip", b"preserve me")
        args += ["--archive", str(archive)]
    with pytest.raises(
        (RuntimeError, ValueError), match="Notarization failed|already exists"
    ):
        package.main(args)
    assert not (app.parent / "Packaged.notary.zip").exists()
    assert not (app.parent / "Packaged.manifest.json").exists()
    if problem == "existing-archive":
        assert archive.read_bytes() == b"preserve me"
