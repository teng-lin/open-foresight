#!/usr/bin/env python3
"""Mount verified release DMG bytes and test a newly installed application copy."""

import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from install_macos import install, metadata, verify_signature
from release_asset_acceptance import verify_checksum
from test_installed_persistence import run as persistence_probe


def run(args):
    if platform.system() != "Darwin":
        raise ValueError("DMG installation acceptance requires macOS")
    dmg = args.dmg.resolve(strict=True)
    digest = verify_checksum(dmg, Path(str(dmg) + ".sha256"))
    destination = args.destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError(
            "Refusing to replace an existing installation; use a clean machine/destination"
        )
    if destination.suffix != ".app":
        raise ValueError("Destination must be an explicit new .app path")
    args.output.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "failed",
        "installer_sha256": digest,
        "os": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "destination": str(destination),
        "quarantine_finder_launch": "not_run",
        "fresh_os_account": "not_established_by_this_script",
    }
    mounted = created = False
    try:
        subprocess.run(["hdiutil", "verify", str(dmg)], check=True, timeout=300)
        with tempfile.TemporaryDirectory(prefix="of-dmg-", dir="/tmp") as temporary:
            mount = Path(temporary).resolve() / "volume"
            mount.mkdir()
            try:
                subprocess.run(
                    [
                        "hdiutil",
                        "attach",
                        "-readonly",
                        "-nobrowse",
                        "-mountpoint",
                        str(mount),
                        str(dmg),
                    ],
                    check=True,
                    timeout=300,
                )
                mounted = True
                source = mount / "Open Foresight.app"
                if not source.resolve(strict=True).is_relative_to(mount):
                    raise ValueError("DMG application escapes the mounted image")
                metadata(source)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.mkdir()  # Exclusive ownership of this disposable installation.
                created = True
                subprocess.run(
                    ["ditto", str(source), str(destination)], check=True, timeout=300
                )
                report["signature"] = verify_signature(destination)
                assessment = subprocess.run(
                    ["spctl", "--assess", "--type", "execute", str(destination)],
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                report["gatekeeper"] = {
                    "exit_code": assessment.returncode,
                    "expected_adhoc_rejection": bool(
                        assessment.returncode and report["signature"]["adhoc"]
                    ),
                }
                if assessment.returncode and not report["signature"]["adhoc"]:
                    raise RuntimeError("Signed release failed Gatekeeper assessment")
                subprocess.run(
                    [
                        sys.executable,
                        str(
                            Path(__file__).with_name("verify_macos_release_runtime.py")
                        ),
                        str(destination),
                        "--output",
                        str(args.output / "runtime.json"),
                    ],
                    check=True,
                    timeout=300,
                )
                functional = [
                    sys.executable,
                    str(Path(__file__).with_name("test_installed_release.py")),
                    "--bundle",
                    str(destination),
                    "--models",
                    str(args.models),
                    "--output",
                    str(args.output / "functional"),
                ]
                identity_path = dmg.parent / "installer.json"
                if not identity_path.is_file():
                    raise FileNotFoundError(
                        "Installer identity report is required for revision acceptance"
                    )
                identity = json.loads(identity_path.read_text())
                if identity["sha256"] != digest or identity["asset"] != dmg.name:
                    raise ValueError(
                        "Installer identity report names different DMG bytes"
                    )
                report["installer"] = identity
                functional += ["--expected-revision", identity["source_commit"]]
                subprocess.run(functional, check=True, timeout=2400)
                # The harness stops its isolated GUI/service before replacement.
                persistence_profile = Path(temporary).resolve() / "persistence"
                persistence_state = args.output / "persistence.json"
                persistence_probe(
                    destination, persistence_profile, persistence_state, "create"
                )
                install(source, destination, allow_adhoc=True)
                verify_signature(destination)
                persistence_probe(
                    destination, persistence_profile, persistence_state, "verify"
                )
                report["reinstall"] = "passed"
                report["status"] = "automated_passed_manual_pending"
            finally:
                if mounted:
                    primary_error = sys.exc_info()[0] is not None
                    detach_error: int | str | None = None
                    try:
                        detach = subprocess.run(
                            ["hdiutil", "detach", str(mount)], timeout=120
                        )
                        if detach.returncode:
                            detach = subprocess.run(
                                ["hdiutil", "detach", "-force", str(mount)], timeout=120
                            )
                        if detach.returncode:
                            detach_error = detach.returncode
                    except Exception as error:
                        detach_error = type(error).__name__
                    if detach_error is None:
                        mounted = False
                    else:
                        report["detach_error"] = detach_error
                        if not primary_error:
                            raise RuntimeError("Failed to detach the release DMG")
    except BaseException as error:
        report["status"] = "failed"
        report["error_type"] = type(error).__name__
        raise
    finally:
        try:
            if created:
                shutil.rmtree(destination)
                report["uninstall_owned_copy"] = not destination.exists()
        except BaseException as error:
            report["status"] = "failed"
            report["cleanup_error_type"] = type(error).__name__
            raise
        finally:
            (args.output / "installation.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    print(json.dumps(run(parser.parse_args()), indent=2))


if __name__ == "__main__":
    main()
