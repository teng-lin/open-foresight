#!/usr/bin/env python3
"""Assemble the Mac application, standalone service/MCP, and local runtimes."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

from google_client_release import release_google_client, write_google_client
from app_version import read_version
from query_worker_packaging import (
    copy_worker as copy_query_worker,
    copy_licenses as copy_query_licenses,
    inspect_runtime as inspect_query_runtime,
)
from web_search_release import release_web_search_keys
from macos_bundle import (
    audit_dependencies,
    relocate_dependencies,
    run,
    sign_application,
)
from litert_extensions import (
    verify_extensions_manifest,
    install_extension_wheel,
    probe_python_extensions,
    write_extension_provenance,
)

ROOT = Path(__file__).resolve().parents[1]
PURPOSES = {
    "NSMicrophoneUsageDescription": "Transcribe your microphone during meetings you start.",
    "NSAudioCaptureUsageDescription": "Transcribe meeting audio playing on this Mac when you start recording.",
}


def helper_bundle(path, executable, identifier):
    macos = path / "Contents/MacOS"
    macos.mkdir(parents=True)
    destination = macos / executable.name
    shutil.copy2(executable, destination)
    name = "Open Foresight" if identifier.endswith(".service") else path.stem
    version, build_number = read_version()
    with (path / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleExecutable": executable.name,
                "CFBundleIdentifier": identifier,
                "CFBundleName": name,
                "CFBundleDisplayName": name,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": str(build_number),
                "CFBundleShortVersionString": version,
                "LSMinimumSystemVersion": "15.0",
                "LSUIElement": True,
                **PURPOSES,
            },
            stream,
        )
    return destination


def write_runtime(resources, values):
    resources.mkdir(parents=True, exist_ok=True)
    config = {
        key: os.path.relpath(path, resources) if isinstance(path, Path) else path
        for key, path in values.items()
    }
    (resources / "runtime.json").write_text(json.dumps(config, indent=2) + "\n")


def copy_python(source, resources, values, extensions=None):
    """Copy a relocatable standalone Python install, not a Homebrew framework."""
    python = source / "bin/python3"
    if not python.is_file():
        raise ValueError("--python-runtime must contain bin/python3")
    query = 'import sys,json,sysconfig; print(json.dumps([sys.base_prefix,sysconfig.get_path("stdlib")]))'
    base, stdlib = json.loads(run(python, "-I", "-c", query))
    if not Path(base).resolve().is_relative_to(source.resolve()) or not Path(
        stdlib
    ).resolve().is_relative_to(source.resolve()):
        raise ValueError(
            "Use a standalone Python runtime, not a venv linked to system/Homebrew Python"
        )
    lock = ROOT / "requirements-litert-macos.lock"
    expected = dict(
        re.findall(r"^([A-Za-z0-9_.-]+)==([^\s\\]+)", lock.read_text(), re.MULTILINE)
    )
    query = (
        "import sys,json,importlib.metadata as m; "
        "print(json.dumps([list(sys.version_info[:2]),"
        "{name:m.version(name) for name in sys.argv[1:]}]))"
    )
    version, installed = json.loads(run(python, "-I", "-c", query, *expected))
    if version != [3, 13] or installed != expected:
        raise ValueError(
            "Use Python 3.13 with the exact requirements-litert-macos.lock dependencies"
        )
    target = resources / "python"
    shutil.copytree(
        source,
        target,
        symlinks=True,
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.a", "test", "tests"),
    )
    for path in target.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(target.resolve()):
            raise ValueError(f"Python runtime symlink escapes bundle: {path}")
    runtime = target / "bin/python3"
    if extensions is not None:
        purelib = Path(
            run(
                python,
                "-I",
                "-c",
                'import sysconfig; print(sysconfig.get_path("purelib"))',
            ).strip()
        )
        relative = purelib.resolve(strict=True).relative_to(source.resolve(strict=True))
        install_extension_wheel(
            extensions,
            site_packages=target / relative,
            source_prefix=source,
            destination_prefix=target,
        )
        probe_python_extensions(runtime, run)
    adapters = resources / "adapters"
    for kind in ("litert-runner", "litert-python"):
        launcher = adapters / kind
        args = (
            '"$task_resources/adapters/litert_runner.py" "$@"'
            if kind == "litert-runner"
            else '"$@"'
        )
        launcher.write_text(
            "#!/bin/bash\nset -euo pipefail\n"
            'task_resources=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)\n'
            "export PYTHONDONTWRITEBYTECODE=1\n"
            'exec "$task_resources/python/bin/python3" -I -B ' + args + "\n"
        )
        launcher.chmod(0o755)
    values.update(
        FORESIGHT_LITERT_RUNNER=adapters / "litert-runner",
        FORESIGHT_LITERT_PYTHON=adapters / "litert-python",
        FORESIGHT_MODEL_PYTHON=runtime,
    )
    notices = resources / "licenses"
    notices.mkdir(exist_ok=True)
    shutil.copy2(lock, notices / lock.name)
    if extensions is not None:
        write_extension_provenance(extensions, notices / "LiteRT-LM-extension.json")
    copy_query_licenses(runtime, notices)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=ROOT / "build")
    parser.add_argument(
        "--flutter-app",
        type=Path,
        default=ROOT
        / "apps/desktop/build/macos/Build/Products/Release/Open Foresight.app",
    )
    parser.add_argument("--output", type=Path, default=ROOT / "dist/Open Foresight.app")
    parser.add_argument(
        "--python-runtime",
        type=Path,
        help="Standalone relocatable Python prefix with pinned LiteRT dependencies installed",
    )
    parser.add_argument(
        "--litert-extensions-manifest",
        type=Path,
        help="Verified source-built API wheel manifest to overlay into the bundled Python copy",
    )
    parser.add_argument(
        "--sdk",
        type=Path,
        help="Pinned source SDK prefix; includes its static dependency licenses",
    )
    parser.add_argument("--whisper-runtime", type=Path)
    parser.add_argument(
        "--whisper-license",
        type=Path,
        help="LICENSE from the source used to build the Whisper runtime",
    )
    parser.add_argument("--google-client", type=Path)
    parser.add_argument(
        "--require-google-client",
        action="store_true",
        help="Reject a release that would send users to Cloud Console setup",
    )
    parser.add_argument("--generation-backend", choices=("cpu", "gpu"), default="cpu")
    parser.add_argument(
        "--identity",
        default="-",
        help="Developer ID Application identity; default is ad-hoc development only",
    )
    parser.add_argument(
        "--notary-profile",
        help="Existing notarytool keychain profile; requires a Developer ID identity",
    )
    parser.add_argument(
        "--archive",
        type=Path,
        help="Create a distributable ZIP after signing/notarization",
    )
    args = parser.parse_args(argv)
    if args.litert_extensions_manifest and not args.python_runtime:
        parser.error("--litert-extensions-manifest requires --python-runtime")
    if args.python_runtime and not args.litert_extensions_manifest:
        parser.error(
            "Bundled note enhancement requires --litert-extensions-manifest "
            "from tools/build_litert_extensions.py; the stock runtime lacks native stop sequences"
        )
    extensions = (
        verify_extensions_manifest(
            args.litert_extensions_manifest, platform_name="darwin"
        )
        if args.litert_extensions_manifest
        else None
    )
    google_client = release_google_client(
        args.google_client, required=args.require_google_client
    )
    web_search_keys = release_web_search_keys()
    if sys.platform != "darwin":
        parser.error("Mac application packaging requires macOS")
    if args.output.suffix != ".app" or args.output.exists():
        parser.error("Choose a new output path ending in .app")
    if args.notary_profile and args.identity == "-":
        parser.error(
            "Notarization requires --identity with a Developer ID Application identity"
        )
    if args.identity != "-" and (not args.python_runtime or not args.whisper_runtime):
        parser.error(
            "Developer ID release requires bundled --python-runtime and --whisper-runtime; use ad-hoc signing for incomplete developer builds"
        )
    if args.identity != "-" and (not args.sdk or not args.whisper_license):
        parser.error(
            "Developer ID release requires --sdk and --whisper-license to include third-party notices"
        )
    if args.generation_backend == "gpu" and not args.python_runtime:
        parser.error("GPU generation requires a validated --python-runtime")
    required = {
        "FORESIGHT_HELPER": args.build / "services/helper/ForesightHelper",
        "FORESIGHT_NATIVE": args.build / "native/libforesight_native.dylib",
        "FORESIGHT_AUDIO_DEVICES": args.build / "native/foresight-audio",
        "FORESIGHT_NOTIFICATIONS": args.build / "macos/foresight-notifications",
        "FORESIGHT_FILE_PARSER": args.build / "macos/foresight-file-parser",
        "FORESIGHT_MODEL_CRYPTO": args.build / "macos/foresight-model-crypto",
    }
    service = args.build / "application/foresight-service"
    mcp = args.build / "application/foresight-mcp"
    for path in [args.flutter_app, service, mcp, *required.values()]:
        if not path.exists():
            parser.error(f"Build all components first: missing {path}")
    app = args.output.absolute()
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(args.flutter_app, app, symlinks=True)
    contents = app / "Contents"
    resources = contents / "Resources"
    values = {}
    service_path = helper_bundle(
        contents / "Library/Services/Open Foresight Service.app",
        service,
        "io.openforesight.App.service",
    )
    values["FORESIGHT_SERVICE"] = service_path
    values["FORESIGHT_INSTALL_ROOT"] = app
    values["FORESIGHT_RUNTIME_REVISION"] = run(
        "git", "-C", ROOT, "rev-parse", "HEAD"
    ).strip()
    shutil.copy2(mcp, contents / "MacOS/foresight-mcp")
    for key, source in required.items():
        target = (
            resources / ("lib" if source.suffix == ".dylib" else "bin") / source.name
        )
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        values[key] = target
    # Notifications require a stable bundle identity as well.
    notification = helper_bundle(
        contents / "Library/Services/Open Foresight Notifications.app",
        required["FORESIGHT_NOTIFICATIONS"],
        "io.openforesight.App.notifications",
    )
    values["FORESIGHT_NOTIFICATIONS"] = notification
    adapters = resources / "adapters"
    adapters.mkdir(exist_ok=True)
    for name in (
        "litert_embedding_adapter.py",
        "litert_runner.py",
        "grounded_generation.py",
    ):
        shutil.copy2(ROOT / "services/inference/macos" / name, adapters / name)
    query_worker = copy_query_worker(adapters)
    values["FORESIGHT_QUERY_WORKER"] = query_worker
    shutil.copy2(
        ROOT / "services/inference/macos/foresight-model", adapters / "foresight-model"
    )
    values.update(
        FORESIGHT_MODEL_WORKER=adapters / "foresight-model",
        FORESIGHT_LITERT_EMBEDDING_ADAPTER=adapters / "litert_embedding_adapter.py",
        FORESIGHT_LITERT_BACKEND=args.generation_backend,
    )
    if args.whisper_runtime:
        target = resources / "bin/whisper-cli"
        shutil.copy2(args.whisper_runtime, target)
        values["FORESIGHT_WHISPER_RUNTIME"] = target
        if args.whisper_license:
            notices = resources / "licenses"
            notices.mkdir(exist_ok=True)
            shutil.copy2(args.whisper_license, notices / "whisper-LICENSE")
    if args.sdk:
        sdk_manifest = args.sdk / "foresight-sdk.json"
        if not sdk_manifest.is_file():
            parser.error("--sdk must be a completed source SDK with foresight-sdk.json")
        shutil.copytree(
            args.sdk / "share/foresight-sdk/licenses", resources / "licenses/sdk"
        )
        shutil.copy2(sdk_manifest, resources / "licenses/sdk-provenance.json")
    if google_client is not None:
        target = resources / "google-client.json"
        write_google_client(target, google_client, mode=0o644)
        values["FORESIGHT_GOOGLE_CLIENT"] = target
    if args.python_runtime:
        copy_python(args.python_runtime, resources, values, extensions)
    values.update(web_search_keys)
    write_runtime(resources, values)
    write_runtime(service_path.parent.parent / "Resources", values)
    info = contents / "Info.plist"
    with info.open("rb") as stream:
        metadata = plistlib.load(stream)
    metadata.update(PURPOSES)
    metadata["LSMinimumSystemVersion"] = "15.0"
    with info.open("wb") as stream:
        plistlib.dump(metadata, stream)
    relocate_dependencies(app)
    entitlements = ROOT / "packaging/macos/Release.entitlements"
    sign_application(app, args.identity, entitlements)
    if extensions is not None:
        probe_python_extensions(resources / "python/bin/python3", run)
    if args.python_runtime:
        run(resources / "adapters/litert-runner", "--check")
        run(
            resources / "adapters/litert-python",
            "-I",
            adapters / "litert_embedding_adapter.py",
            "--check",
        )
        inspect_query_runtime(resources / "adapters/litert-python")
    notarized = False
    if args.notary_profile:
        submission = app.parent / (app.stem + ".notary.zip")
        subprocess.run(
            ["ditto", "-c", "-k", "--keepParent", str(app), str(submission)],
            check=True,
            timeout=300,
        )
        try:
            result = json.loads(
                run(
                    "xcrun",
                    "notarytool",
                    "submit",
                    submission,
                    "--keychain-profile",
                    args.notary_profile,
                    "--wait",
                    "--output-format",
                    "json",
                )
            )
            if result.get("status") != "Accepted":
                raise RuntimeError(f"Notarization failed: {result}")
            run("xcrun", "stapler", "staple", app)
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
            notarized = True
        finally:
            submission.unlink(missing_ok=True)
    if args.archive:
        if args.archive.exists():
            raise ValueError("Archive path already exists")
        args.archive.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["ditto", "-c", "-k", "--keepParent", str(app), str(args.archive)],
            check=True,
            timeout=300,
        )
    report = {
        "app": str(app),
        "revision": run("git", "-C", ROOT, "rev-parse", "HEAD").strip(),
        "architecture": "arm64",
        "minimum_macos": "15.0",
        "signing": "ad-hoc-development" if args.identity == "-" else "developer-id",
        "notarized": notarized,
        "python_bundled": bool(args.python_runtime),
        "whisper_bundled": bool(args.whisper_runtime),
        "query_worker_runtime_bundled": bool(args.python_runtime),
        "linkage": audit_dependencies(app),
    }
    # A report outside the sealed bundle avoids invalidating its signature.
    report_path = app.parent / (app.stem + ".manifest.json")
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "linkage"}))


if __name__ == "__main__":
    main()
