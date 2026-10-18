#!/usr/bin/env python3
"""Assemble the Mac application, standalone service/MCP, and local runtimes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from google_client_release import release_google_client, write_google_client
from app_version import read_version
from web_search_release import release_web_search_keys
from macos_bundle import (
    audit_dependencies,
    relocate_dependencies,
    run,
    sign_application,
)
from litert_extensions import (
    verify_extensions_manifest,
    copy_macos_extension_dependencies,
    write_extension_provenance,
)

ROOT = Path(__file__).resolve().parents[1]
PURPOSES = {
    "NSMicrophoneUsageDescription": "Transcribe your microphone during meetings you start.",
    "NSAudioCaptureUsageDescription": "Transcribe meeting audio playing on this Mac when you start recording.",
}


def write_litert_manifests(app, library, service):
    """Bind every runtime host to the relocated and signed library bytes."""
    with library.open("rb") as stream:
        runtime = {
            "version": "0.18.0",
            "sha256": hashlib.file_digest(stream, "sha256").hexdigest(),
        }
    # UI/MCP and the nested service resolve identity from Contents/Resources;
    # resource-bin workers share the main app receipt. Keep JSON out of the
    # Contents root, where codesign treats unknown files as code subcomponents.
    for manifest in (
        app / "Contents/Resources/manifest.json",
        service.parent.parent / "Resources/manifest.json",
    ):
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({"gemma_runtime": runtime}, indent=2) + "\n")


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
        "--litert-extensions-manifest",
        type=Path,
        required=True,
        help="Verified source-built native LiteRT C API runtime manifest",
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
    extensions = verify_extensions_manifest(
        args.litert_extensions_manifest, platform_name="darwin"
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
    if args.identity != "-" and not args.whisper_runtime:
        parser.error(
            "Developer ID release requires bundled --whisper-runtime; use ad-hoc signing for incomplete developer builds"
        )
    if args.identity != "-" and (not args.sdk or not args.whisper_license):
        parser.error(
            "Developer ID release requires --sdk and --whisper-license to include third-party notices"
        )
    required = {
        "FORESIGHT_MODEL_WORKER": args.build / "services/inference/foresight-model",
        "FORESIGHT_QUERY_WORKER": args.build / "services/inference/foresight-query",
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
    values.update(
        FORESIGHT_QUERY_RUNTIME=values["FORESIGHT_QUERY_WORKER"],
        FORESIGHT_LITERT_RUNNER=values["FORESIGHT_MODEL_WORKER"],
        FORESIGHT_LITERT_BACKEND=args.generation_backend,
    )
    library_directory = resources / "lib"
    library_directory.mkdir(exist_ok=True)
    copy_macos_extension_dependencies(extensions, library_directory)
    values["FORESIGHT_LITERT_LIBRARY"] = library_directory / "liblitert-lm.dylib"
    notices = resources / "licenses"
    notices.mkdir(exist_ok=True)
    write_extension_provenance(extensions, notices / "LiteRT-LM-extension.json")
    shutil.copy2(ROOT / "third_party/litert_lm/LICENSE", notices / "LiteRT-LM-LICENSE")
    shutil.copy2(
        ROOT / "third_party/sentencepiece/LICENSE", notices / "sentencepiece-LICENSE"
    )
    if args.whisper_runtime:
        target = resources / "bin/whisper-cli"
        shutil.copy2(args.whisper_runtime, target)
        values["FORESIGHT_WHISPER_RUNTIME"] = target
        shutil.copy2(
            args.whisper_runtime.parent / "foresight-whisper-worker",
            resources / "bin/foresight-whisper-worker",
        )
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
    sign_application(
        app,
        args.identity,
        entitlements,
        before_seal=lambda: write_litert_manifests(
            app, values["FORESIGHT_LITERT_LIBRARY"], service_path
        ),
    )
    environment = dict(
        os.environ, FORESIGHT_LITERT_LIBRARY=str(values["FORESIGHT_LITERT_LIBRARY"])
    )
    subprocess.run(
        [str(values["FORESIGHT_MODEL_WORKER"]), "--check"],
        env=environment,
        check=True,
        timeout=30,
    )
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
        "python_bundled": False,
        "whisper_bundled": bool(args.whisper_runtime),
        "inference_runtime": "native-c-api",
        "linkage": audit_dependencies(app),
    }
    # A report outside the sealed bundle avoids invalidating its signature.
    report_path = app.parent / (app.stem + ".manifest.json")
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "linkage"}))


if __name__ == "__main__":
    main()
