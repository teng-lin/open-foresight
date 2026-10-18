#!/usr/bin/env python3
"""Verify the real Hyprland global key through a private microphone/profile.

Requires an explicit private runtime/config, uses the product binding installer,
then removes only the test binding. Leaves host source/sink defaults alone.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(*argv, **kwargs):
    return subprocess.check_output(
        argv, text=True, timeout=kwargs.pop("timeout", 300), **kwargs
    ).strip()


def wait_for(check, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.2)
    raise AssertionError("Timed out waiting for shortcut acceptance")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--keyboard", required=True, type=Path)
    parser.add_argument("--dart", default="dart")
    parser.add_argument(
        "--model-python",
        type=Path,
        default=Path(
            os.environ.get("FORESIGHT_MODEL_PYTHON", ROOT / ".venv/bin/python")
        ),
    )
    parser.add_argument("--private-runtime", required=True, type=Path)
    parser.add_argument("--private-config", required=True, type=Path)
    parser.add_argument(
        "--report",
        type=Path,
        default=ROOT / "test-results/global-shortcut-private.json",
    )
    parser.add_argument(
        "--failure-log", type=Path, default=Path("/tmp/foresight-shortcut-failure.log")
    )
    parser.add_argument(
        "--model-manifest",
        type=Path,
        default=ROOT / "models/local/native/installed.json",
    )
    parser.add_argument("--expect-embedding-backend")
    args = parser.parse_args()
    runtime, private_config = (
        args.private_runtime.resolve(),
        args.private_config.resolve(),
    )
    assert runtime.is_relative_to(
        Path(tempfile.gettempdir())
    ) and private_config.is_relative_to(Path(tempfile.gettempdir())), (
        "Use owned temporary desktop/config directories"
    )
    assert os.environ.get("XDG_RUNTIME_DIR") == str(runtime)
    assert os.environ.get("XDG_CONFIG_HOME") == str(private_config)
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    assert signature and (runtime / "hypr" / signature / ".socket.sock").is_socket(), (
        "Private Hyprland IPC missing"
    )
    monitors = json.loads(run("hyprctl", "monitors", "-j"))
    assert monitors and all(
        monitor["name"].startswith(("WAYLAND-", "HEADLESS-")) for monitor in monitors
    ), "Physical output is outside acceptance scope"
    bundle = args.bundle.resolve()
    config = (
        Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
        / "hypr/bindings.lua"
    )
    original = config.read_text()
    assert "-- BEGIN FORESIGHT GLOBAL SHORTCUT" not in original, (
        "Disable existing Foresight shortcut before isolated acceptance"
    )
    before = json.loads(run("hyprctl", "activewindow", "-j"))
    assert before.get("pid") and before.get("class") != "io.openforesight.App", (
        "Focus a separate private sentinel window first"
    )
    audio_defaults = {
        kind: run("pactl", "get-default-" + kind) for kind in ("sink", "source")
    }
    sink = "foresight-shortcut-" + str(os.getpid())
    modules = []
    installed = False
    with tempfile.TemporaryDirectory(prefix="foresight-shortcut-") as temporary:
        root = Path(temporary)
        launcher = root / "foresight test launcher"
        env = os.environ.copy()
        env.update(
            FORESIGHT_DATA=str(root / "data"),
            FORESIGHT_RUNTIME=str(root / "run"),
            FORESIGHT_MICROPHONE_TARGET=sink + "-microphone",
            FORESIGHT_PLAYBACK_TARGET=sink,
            FORESIGHT_MODEL_MANIFEST=str(args.model_manifest.resolve()),
        )
        launcher.write_text(
            "#!/bin/sh\n"
            + "\n".join(
                "export " + key + "=" + shlex.quote(env[key])
                for key in env
                if key.startswith("FORESIGHT_")
                or key
                in (
                    "PULSE_SERVER",
                    "PIPEWIRE_REMOTE",
                    "PATH",
                    "XDG_RUNTIME_DIR",
                    "XDG_CONFIG_HOME",
                    "WAYLAND_DISPLAY",
                    "HYPRLAND_INSTANCE_SIGNATURE",
                )
            )
            + "\nexec "
            + shlex.quote(str(bundle / "open-foresight"))
            + ' "$@" >>'
            + shlex.quote(str(root / "app.log"))
            + " 2>&1\n"
        )
        launcher.chmod(0o700)
        manage = [args.dart, "run", "tool/manage_hypr_shortcut.dart"]

        def meetings():
            db = root / "data/application.db"
            if not db.exists():
                return []
            try:
                with sqlite3.connect(db) as connection:
                    return connection.execute(
                        "SELECT id,state FROM meetings ORDER BY id"
                    ).fetchall()
            except sqlite3.OperationalError:
                return []

        def owner():
            return [
                client
                for client in json.loads(run("hyprctl", "clients", "-j"))
                if client.get("class") == "io.openforesight.App"
                and Path("/proc/" + str(client["pid"]) + "/environ").exists()
                and ("FORESIGHT_DATA=" + str(root / "data")).encode()
                in Path("/proc/" + str(client["pid"]) + "/environ")
                .read_bytes()
                .split(b"\0")
            ]

        def key():
            run(str(args.keyboard.resolve()))

        def helper_state():
            script = (
                "import sys,json,grpc;sys.path.insert(0,sys.argv[2]);"
                "from evaluate_models import control_snapshot;"
                "channel=grpc.insecure_channel('unix:'+sys.argv[1]);"
                "print(json.dumps(control_snapshot(channel)))"
            )
            return json.loads(
                subprocess.check_output(
                    [
                        str(args.model_python.expanduser().absolute()),
                        "-c",
                        script,
                        str(root / "run/helper.sock"),
                        str(ROOT / "tools"),
                    ],
                    env=env,
                    text=True,
                    stderr=subprocess.DEVNULL,
                    timeout=300,
                )
            )

        def configured_model():
            try:
                state = helper_state()
            except subprocess.CalledProcessError:
                return None  # Startup can precede the helper's IPC listener.
            if (
                state.get("pipeline") == "ready"
                and state.get("model", {}).get("backend")
                == args.expect_embedding_backend
            ):
                return state
            return None

        try:
            modules.append(
                run(
                    "pactl",
                    "load-module",
                    "module-null-sink",
                    "sink_name=" + sink,
                    "channels=1",
                    "rate=48000",
                    "sink_properties=priority.session=0",
                )
            )
            modules.append(
                run(
                    "pactl",
                    "load-module",
                    "module-remap-source",
                    "master=" + sink + ".monitor",
                    "source_name=" + sink + "-microphone",
                    "channels=1",
                    "source_properties=priority.session=0",
                )
            )
            run(*manage, "install", str(launcher), cwd=ROOT / "apps/desktop")
            installed = True
            print("Installed binding; testing cold launch", flush=True)
            cold_started = time.monotonic()
            key()
            key()  # A second launch while model registration is still pending.
            wait_for(lambda: len(meetings()) == 1 and meetings()[0][1] == "recording")
            cold_capture_seconds = time.monotonic() - cold_started
            print("Cold capture started", flush=True)
            first = wait_for(owner)
            assert len(first) == 1
            app_pid = first[0]["pid"]
            wait_for(
                lambda: (
                    json.loads(run("hyprctl", "activewindow", "-j")).get("pid")
                    == app_pid
                )
            )
            model_state = None
            if args.expect_embedding_backend:
                model_state = wait_for(configured_model)
            subprocess.run(
                [str(launcher), "--stop-meeting"], env=env, check=True, timeout=15
            )
            wait_for(lambda: meetings()[0][1] == "empty")
            if before.get("pid"):
                run(
                    "hyprctl",
                    "eval",
                    f'hl.dispatch(hl.dsp.focus({{window="pid:{before["pid"]}"}}))',
                )
                wait_for(
                    lambda: (
                        json.loads(run("hyprctl", "activewindow", "-j")).get("pid")
                        == before["pid"]
                    )
                )
            key()
            wait_for(lambda: len(meetings()) == 2 and meetings()[-1][1] == "recording")
            wait_for(
                lambda: (
                    json.loads(run("hyprctl", "activewindow", "-j")).get("pid")
                    == app_pid
                )
            )
            assert len(owner()) == 1 and owner()[0]["pid"] == app_pid
            key()
            time.sleep(1)
            assert len(meetings()) == 2, (
                "Repeated shortcut created a competing recording"
            )
            subprocess.run(
                [str(launcher), "--stop-meeting"], env=env, check=True, timeout=15
            )
            wait_for(lambda: meetings()[-1][1] == "empty")
            report = {
                "desktop": "Hyprland Lua / Omarchy",
                "key": "CTRL + SHIFT + F",
                "cold_launch_started_capture": True,
                "cold_launch_capture_seconds": cold_capture_seconds,
                "unfocused_key_raised_existing_owner": True,
                "single_instance": True,
                "rapid_cold_launch_did_not_duplicate_owner": True,
                "repeated_key_did_not_duplicate_recording": True,
                "stop_command_finalized_capture": True,
                "meetings": meetings(),
                "private_virtual_microphone": True,
                "private_nested_desktop": True,
                "separate_focus_target_verified": True,
                "host_audio_defaults_preserved": all(
                    run("pactl", "get-default-" + kind) == device
                    for kind, device in audio_defaults.items()
                ),
            }
            if model_state is not None:
                report["embedding_backend"] = model_state["model"]["backend"]
                report["embedding_dimensions"] = model_state["model"]["dimensions"]
                report["helper_build_id"] = model_state["build_id"]
                report["model_digest"] = model_state["model"]["model_digest"]
            assert report["host_audio_defaults_preserved"]
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report))
        except Exception:
            if (root / "app.log").exists():
                args.failure_log.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / "app.log", args.failure_log)
                print(
                    "Retained application diagnostics: " + str(args.failure_log),
                    flush=True,
                )
            print(
                json.dumps(
                    {
                        "meetings_at_failure": meetings(),
                        "owners_at_failure": len(owner()),
                    }
                ),
                flush=True,
            )
            raise
        finally:
            try:
                if installed:
                    run(*manage, "remove", str(launcher), cwd=ROOT / "apps/desktop")
                    assert config.read_text().strip() == original.strip(), (
                        "Unrelated desktop configuration changed"
                    )
            finally:
                for process in Path("/proc").iterdir():
                    if not process.name.isdigit():
                        continue
                    try:
                        process_env = (process / "environ").read_bytes().split(b"\0")
                        if (
                            "FORESIGHT_DATA=" + str(root / "data")
                        ).encode() in process_env:
                            os.kill(int(process.name), signal.SIGTERM)
                    except (ProcessLookupError, FileNotFoundError, PermissionError):
                        pass
                for module in reversed(modules):
                    subprocess.run(
                        ["pactl", "unload-module", module], check=False, timeout=300
                    )
            if before.get("pid"):
                run(
                    "hyprctl",
                    "eval",
                    f'hl.dispatch(hl.dsp.focus({{window="pid:{before["pid"]}"}}))',
                )


if __name__ == "__main__":
    main()
