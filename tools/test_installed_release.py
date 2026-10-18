#!/usr/bin/env python3
"""Functional acceptance through an installed app's own launchers and models."""

from typing import Any
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time

from build_macos_runtimes import download
from installed_documents import probe_installed_documents
from installed_runtime import (
    clean_environment,
    layout,
    process_path,
    service_command,
    wait_stopped,
)
from smoke_macos_bundle import McpPeer
from test_macos_release_models import MODELS

MANUAL_GATES = (
    "guided_setup_dialog",
    "physical_microphone_system_audio",
    "pause_resume_device_switch_sleep",
    "permission_denial_revocation",
    "gpu_inference",
    "native_save_dialog_export",
    "desktop_ui_screenshots",
    "macos_quarantine_finder_launch",
    "minimum_hardware_performance",
)


def prepare_models(directory):
    models = {}
    for name, (repo, revision, filename, checksum) in MODELS.items():
        path = directory / filename
        download(
            f"https://huggingface.co/{repo}/resolve/{revision}/{filename}",
            path,
            checksum,
        )
        models[name] = path.resolve()
    return models


def desktop_probe(bundle, output):
    """Start the actual installed GUI, attach MCP, and verify one service owner."""
    with tempfile.TemporaryDirectory(prefix="of-installed-", dir="/tmp") as temporary:
        root = Path(temporary)
        for name in ("home", "data", "run"):
            (root / name).mkdir(mode=0o700)
        env = clean_environment(root / "home", root / "data", root / "run")
        mcp_path, service = layout(bundle)
        if bundle.suffix == ".app":
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            executable = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
        else:
            executable = Path("/usr/bin/open-foresight")
        mcp = None
        desktop = None
        owner = None
        with (output / "desktop.log").open("wb") as log:
            try:
                desktop = subprocess.Popen(
                    [str(executable)],
                    env=env,
                    cwd="/",
                    stdout=log,
                    stderr=log,
                    start_new_session=True,
                )
                deadline = time.monotonic() + 90
                while not (root / "run/commands.sock").exists():
                    if desktop.poll() is not None:
                        raise RuntimeError("Installed GUI exited during startup")
                    if time.monotonic() >= deadline:
                        raise TimeoutError(
                            "Installed GUI did not establish its activation endpoint"
                        )
                    time.sleep(0.2)
                mcp = McpPeer(mcp_path, env)
                state = mcp.tool("get_status")
                owner = state["pid"]
                if process_path(owner) != service.resolve() or state[
                    "installation_root"
                ] != str(bundle):
                    raise RuntimeError(
                        "GUI/MCP did not use the selected installed service"
                    )
                if desktop.poll() is not None:
                    raise RuntimeError("GUI exited after MCP connection")
                return {
                    "status": "passed",
                    "service_pid": owner,
                    "runtime_revision": state.get("runtime_revision"),
                    "runtime_overrides": False,
                    "launch": "installed_executable",
                }
            finally:
                primary = sys.exc_info()[0]
                cleanup_error = None
                if mcp is not None:
                    try:
                        mcp.close()
                    except Exception as error:
                        cleanup_error = error
                if desktop is not None and desktop.poll() is None:
                    os.killpg(desktop.pid, signal.SIGTERM)
                    try:
                        desktop.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(desktop.pid, signal.SIGKILL)
                        desktop.wait(timeout=30)
                # Query the isolated profile even if startup failed before MCP.
                try:
                    current = service_command(service, env, "--status")
                except subprocess.CalledProcessError:
                    current = None
                if current:
                    if process_path(current["pid"]) != service.resolve():
                        raise RuntimeError("Refusing to stop an unrelated service")
                    service_command(service, env, "--stop")
                    wait_stopped(current["pid"], service)
                if cleanup_error is not None and primary is None:
                    raise cleanup_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prepare-models-only", action="store_true")
    parser.add_argument("--expected-revision")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.prepare_models_only and not args.bundle:
        parser.error("--bundle is required for functional acceptance")
    if args.prepare_models_only:
        prepare_models(args.models)
        return
    bundle = args.bundle.resolve(strict=True)
    report: dict[str, Any] = {
        "status": "failed",
        "gpu_inference": {"status": "manual_pending", "evidence": None},
        "manual_gates": {gate: "not_run" for gate in MANUAL_GATES},
    }
    private_models = None
    try:
        report["installed_document_import"] = probe_installed_documents(bundle)
        fixtures = prepare_models(args.models)
        private_models = tempfile.TemporaryDirectory(prefix="of-models-", dir="/tmp")
        models = {}
        for name, source in fixtures.items():
            models[name] = Path(private_models.name) / source.name
            shutil.copyfile(source, models[name])
        generation_options = (
            ["--generation-backend", "cpu"] if bundle.suffix != ".app" else []
        )
        report["functional_generation_backend"] = (
            "cpu" if generation_options else "package_default"
        )
        report["gui_startup"] = desktop_probe(bundle, args.output)
        if (
            args.expected_revision
            and report["gui_startup"]["runtime_revision"] != args.expected_revision
        ):
            raise RuntimeError(
                "Installed application revision differs from the release tag"
            )
        subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("test_packaged_note_enhancement.py")),
                "--acceptance",
                "--bundle",
                str(bundle),
                "--generation",
                str(models["generation"]),
                "--embedding",
                str(models["embedding"]),
                "--backend",
                "cpu",
                *generation_options,
                "--output",
                str(args.output / "application"),
            ],
            check=True,
            timeout=1800,
        )
        runtime = (
            bundle / "Contents/Resources/bin/whisper-cli"
            if bundle.suffix == ".app"
            else bundle / "bin/whisper-cli-vulkan"
        )
        with tempfile.TemporaryDirectory(prefix="of-speech-") as home:
            result = subprocess.run(
                [
                    str(runtime),
                    "--no-gpu",
                    "-t",
                    "2",
                    "-m",
                    str(models["speech"]),
                    "-f",
                    str(
                        Path(__file__).resolve().parents[1]
                        / "tests/fixtures/audio/jfk.wav"
                    ),
                    "-l",
                    "en",
                    "-nt",
                ],
                cwd="/",
                env={"HOME": home, "PATH": "/usr/bin:/bin"},
                capture_output=True,
                text=True,
                timeout=180,
            )
        (args.output / "speech.log").write_text(result.stdout + result.stderr)
        if (
            result.returncode
            or "ask not what your country" not in result.stdout.lower()
        ):
            raise RuntimeError(
                "Installed speech runtime failed the known audio fixture"
            )
        report["speech"] = "passed_cpu_real_fixture"
        report["status"] = "automated_passed_manual_pending"
    except BaseException as error:
        report["error_type"] = type(error).__name__
        raise
    finally:
        try:
            if private_models is not None:
                private_models.cleanup()
        except BaseException as error:
            report["status"] = "failed"
            report["cleanup_error_type"] = type(error).__name__
            raise
        finally:
            (args.output / "functional.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )


if __name__ == "__main__":
    main()
