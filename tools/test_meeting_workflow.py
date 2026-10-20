#!/usr/bin/env python3
"""Exercise real meeting workflows on an owned headless desktop and private audio devices."""

import argparse
import hashlib
import html
import struct
import json
import os
import signal
import shutil
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def capture_gallery(directory, names):
    captures = []
    for name in sorted(names):
        data = (directory / name).read_bytes()
        assert data.startswith(b"\x89PNG\r\n\x1a\n"), "Invalid native capture"
        width, height = struct.unpack(">II", data[16:24])
        assert (width, height) == (1280, 720), "Unexpected private-display geometry"
        captures.append(
            {
                "file": name,
                "width": width,
                "height": height,
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )
    (directory / "index.json").write_text(
        json.dumps(
            {
                "method": "dedicated Agent Desktop headless native Flutter integration; disposable profile; private virtual audio",
                "comparison": "1280x720 supplementary captures, not matched-size pixel equality",
                "screenshots": captures,
            },
            indent=2,
        )
        + "\n"
    )
    figures = "".join(
        "<figure><figcaption>"
        + html.escape(item["file"])
        + '</figcaption><a href="'
        + html.escape(item["file"])
        + '"><img src="'
        + html.escape(item["file"])
        + '" width="960" alt="'
        + html.escape(item["file"])
        + '"></a></figure>'
        for item in captures
    )
    (directory / "index.html").write_text(
        '<!doctype html><meta charset="utf-8"><title>Private Linux meeting acceptance</title>'
        "<style>body{font:16px sans-serif;background:#eaEEF7;color:#24333c;margin:32px}"
        "img{max-width:100%;height:auto}figure{margin:24px 0}figcaption{margin-bottom:8px}</style>"
        "<h1>Private Linux meeting acceptance</h1><p>Actual native captures from a dedicated "
        "headless display, a disposable profile and known speech through private virtual "
        "microphone/playback devices. Physical spoken microphone acceptance remains separate.</p>"
        "<p>These captures show the current controls and recording workflow.</p>"
        + figures
        + "\n"
    )
    return len(captures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument(
        "--model-python",
        type=Path,
        default=Path(
            os.environ.get("FORESIGHT_MODEL_PYTHON", ROOT / ".venv/bin/python")
        ),
        help="Deprecated test-driver option; native inference does not use Python",
    )
    parser.add_argument(
        "--agent-desktop",
        type=Path,
        default=ROOT.parent / "agent-desktop",
        help="Agent Desktop checkout used for a dedicated headless display",
    )
    parser.add_argument(
        "--model-manifest",
        type=Path,
        default=ROOT / "models/local/native/installed.json",
    )
    parser.add_argument(
        "--helper-bundle",
        type=Path,
        default=ROOT / "dist/open-foresight",
        help="Packaged helper/runtime to exercise before replacing the default launcher",
    )
    parser.add_argument(
        "--report", type=Path, default=ROOT / "test-results/meeting-headless.json"
    )
    parser.add_argument(
        "--gallery",
        type=Path,
        help="Separate gallery for another evaluated model stack",
    )
    parser.add_argument("--expect-embedding-backend")
    parser.add_argument("--expect-generation-backend")
    parser.add_argument("--expect-preprocessing")
    parser.add_argument(
        "--real-inactivity",
        action="store_true",
        help="Wait five real minutes of silence without changing activity timestamps",
    )
    args = parser.parse_args()
    helper_bundle = args.helper_bundle.resolve()
    revision = subprocess.check_output(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True, timeout=300
    ).strip()
    flutter = shutil.which(args.flutter)
    assert flutter, "Flutter executable not found"
    desk = [
        "uv",
        "run",
        "--directory",
        str(args.agent_desktop),
        "--no-sync",
        "agent-desktop",
    ]

    def desktop(*arguments):
        return json.loads(
            subprocess.check_output(desk + list(arguments), text=True, timeout=300)
        )

    session = None
    default_devices = {
        kind: subprocess.check_output(
            ["pactl", "get-default-" + kind], text=True, timeout=300
        ).strip()
        for kind in ("sink", "source")
    }
    sink = f"foresight-test-{os.getpid()}"
    modules = []
    microphone = sink + "-microphone"
    try:
        modules.append(
            subprocess.check_output(
                [
                    "pactl",
                    "load-module",
                    "module-null-sink",
                    "sink_name=" + sink,
                    "channels=1",
                    "rate=48000",
                    "sink_properties=priority.session=0",
                ],
                text=True,
                timeout=300,
            ).strip()
        )
        modules.append(
            subprocess.check_output(
                [
                    "pactl",
                    "load-module",
                    "module-remap-source",
                    "master=" + sink + ".monitor",
                    "source_name=" + microphone,
                    "channels=1",
                    "source_properties=priority.session=0",
                ],
                text=True,
                timeout=300,
            ).strip()
        )
        session = desktop("create", "--mode", "headless", "--guard-host")["session"]
        with tempfile.TemporaryDirectory(prefix="foresight-meeting-ui-") as temporary:
            env = {
                "FORESIGHT_DATA": temporary + "/data",
                "FORESIGHT_RUNTIME": temporary + "/run",
                "FORESIGHT_SERVICE": str(helper_bundle / "bin/foresight-service"),
                "FORESIGHT_HELPER": str(helper_bundle / "bin/ForesightHelper"),
                "FORESIGHT_MODEL_WORKER": str(helper_bundle / "bin/foresight-model"),
                "FORESIGHT_LITERT_LIBRARY": str(helper_bundle / "lib/liblitert-lm.so"),
                "FORESIGHT_MODEL_MANIFEST": str(args.model_manifest.resolve()),
                "FORESIGHT_NATIVE": str(helper_bundle / "lib/libforesight_native.so"),
                "FORESIGHT_PLAYBACK_TARGET": sink,
                "FORESIGHT_MICROPHONE_TARGET": microphone,
                "FORESIGHT_AUDIO_FIXTURE": str(ROOT / "tests/fixtures/audio/jfk.wav"),
                "FORESIGHT_REFERENCE_SCREENSHOTS": temporary + "/ui",
                "FORESIGHT_MEETING_REPORT": temporary + "/report.json",
                "FORESIGHT_MEETING_SCREENSHOT": temporary + "/meetings.png",
                "FORESIGHT_COPILOT_SCREENSHOT": temporary + "/copilot.png",
                "LD_LIBRARY_PATH": str(helper_bundle / "lib")
                + ":"
                + os.environ.get("LD_LIBRARY_PATH", ""),
                "GDK_BACKEND": "wayland",
                "FORESIGHT_AGENT_DESKTOP_SESSION": session,
                "PIPEWIRE_REMOTE": "/run/user/" + str(os.getuid()) + "/pipewire-0",
                "PULSE_SERVER": "unix:/run/user/" + str(os.getuid()) + "/pulse/native",
                "FORESIGHT_LINK_OPEN_REPORT": temporary + "/link-open.json",
            }
            if args.real_inactivity:
                env["FORESIGHT_REAL_INACTIVITY"] = "1"
            bundled_runner = helper_bundle / "bin/foresight-model"
            if bundled_runner.is_file():
                env["FORESIGHT_LITERT_RUNNER"] = str(bundled_runner)
            for setting in (
                "FORESIGHT_LITERT_BACKEND",
                "FORESIGHT_WHISPER_BACKEND",
                "FORESIGHT_WHISPER_DEVICE",
                "FORESIGHT_WHISPER_RUNTIME",
            ):
                if setting in os.environ:
                    env[setting] = os.environ[setting]
            if args.expect_embedding_backend:
                env["FORESIGHT_EXPECT_EMBEDDING_BACKEND"] = (
                    args.expect_embedding_backend
                )
            if args.expect_generation_backend:
                env["FORESIGHT_EXPECT_GENERATION_BACKEND"] = (
                    args.expect_generation_backend
                )
            if args.expect_preprocessing:
                env["FORESIGHT_EXPECT_PREPROCESSING"] = args.expect_preprocessing
            if "CMAKE_PREFIX_PATH" in os.environ:
                env["CMAKE_PREFIX_PATH"] = os.environ["CMAKE_PREFIX_PATH"]
            try:
                launch = desktop(
                    "launch",
                    session,
                    "--",
                    "env",
                    "-C",
                    str(ROOT / "apps/desktop"),
                    *[key + "=" + value for key, value in env.items()],
                    flutter,
                    "test",
                    "--no-pub",
                    "-d",
                    "linux",
                    "integration_test/meeting_workflow_test.dart",
                    "--reporter",
                    "expanded",
                )
                test_pid = launch["pid"]
                print(
                    json.dumps(
                        {
                            "session": session,
                            "test_pid": test_pid,
                            "logs": launch["logs"],
                        }
                    ),
                    flush=True,
                )
                try:
                    timeout_seconds = 660 if args.real_inactivity else 360
                    deadline = time.monotonic() + timeout_seconds
                    while True:
                        state = desktop("status", session)
                        job = next(
                            (
                                job
                                for job in state["applications"]
                                if job["pid"] == test_pid
                            ),
                            None,
                        )
                        assert job is not None, (
                            "Tracked integration process disappeared"
                        )
                        if job["exit_code"] is not None:
                            code = job["exit_code"]
                            break
                        if time.monotonic() >= deadline:
                            raise TimeoutError(
                                f"Private integration process exceeded {timeout_seconds} seconds"
                            )
                        time.sleep(2)
                    if code != 0:
                        print(Path(launch["logs"]).read_text()[-12000:], flush=True)
                    assert code == 0, f"Flutter integration failed: {code}"
                    report_path = Path(temporary) / "report.json"
                    assert report_path.is_file(), (
                        "Flutter did not produce a completed workflow report"
                    )
                    report = json.loads(report_path.read_text())
                    report["helper_bundle"] = str(helper_bundle)
                    report["packaged_native_model_worker_sha256"] = hashlib.sha256(
                        (helper_bundle / "bin/foresight-model").read_bytes()
                    ).hexdigest()
                    gallery = (
                        args.gallery or ROOT / "test-results/ui/foresight-headless"
                    )
                    report["source_revision"] = revision
                    report["reference_screen_captures"] = str(gallery)
                    observed_devices = {
                        kind: subprocess.check_output(
                            ["pactl", "get-default-" + kind], text=True, timeout=300
                        ).strip()
                        for kind in default_devices
                    }
                    report["host_default_audio_devices_before"] = default_devices
                    report["host_default_audio_devices_after"] = observed_devices
                    report["host_default_audio_devices_preserved"] = (
                        observed_devices == default_devices
                    )
                    report["acceptance_passed"] = report[
                        "host_default_audio_devices_preserved"
                    ]
                    assert report[
                        "clear_workspace_cancel_preserved_data_and_confirm_removed_data"
                    ]
                    gallery.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(
                        Path(temporary) / "meetings.png",
                        gallery / "meetings-detail.png"
                        if args.gallery
                        else ROOT / "test-results/ui/meetings-headless.png",
                    )
                    shutil.copy2(
                        Path(temporary) / "copilot.png",
                        gallery / "copilot.png"
                        if args.gallery
                        else ROOT / "test-results/ui/copilot-headless.png",
                    )
                    shutil.copytree(Path(temporary) / "ui", gallery, dirs_exist_ok=True)
                    report["verified_capture_count"] = capture_gallery(
                        gallery,
                        [p.name for p in (Path(temporary) / "ui").glob("*.png")],
                    )
                    args.report.parent.mkdir(parents=True, exist_ok=True)
                    args.report.write_text(json.dumps(report, indent=2) + "\n")
                    # Retain evidence before this gate: external device changes must
                    # remain inspectable even though they fail acceptance.
                    assert report["host_default_audio_devices_preserved"], (
                        f"Host audio defaults changed: {default_devices} -> {observed_devices}"
                    )
                finally:
                    try:
                        os.killpg(test_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            finally:
                subprocess.run(
                    [str(helper_bundle / "open-foresight-service"), "--stop"],
                    env={**os.environ, **env},
                    capture_output=True,
                    # Allow 30 min finalization, 60 s status/release, and margin.
                    timeout=32 * 60,
                    check=False,
                )
                for process in Path("/proc").iterdir():
                    if not process.name.isdigit():
                        continue
                    try:
                        argv = (process / "cmdline").read_bytes().split(b"\0")
                        if (
                            len(argv) > 1
                            and argv[1] == (temporary + "/run/helper.sock").encode()
                        ):
                            os.kill(int(process.name), signal.SIGTERM)
                    except OSError:
                        pass
    finally:
        try:
            if session is not None:
                desktop("destroy", session)
        finally:
            for module in reversed(modules):
                subprocess.run(
                    ["pactl", "unload-module", module], check=False, timeout=300
                )


if __name__ == "__main__":
    main()
