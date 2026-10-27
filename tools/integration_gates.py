#!/usr/bin/env python3
"""Explicit, fail-closed integration groups; only disposable profiles/virtual audio."""

import argparse
import base64
from contextlib import contextmanager
import hashlib
import importlib
import json
import os
from pathlib import Path
import select
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time

from test_macos_release_models import MODELS

ROOT = Path(__file__).resolve().parents[1]


def check_events(path, expected):
    events = [
        json.loads(line) for line in path.read_text().splitlines() if line.strip()
    ]
    done = [
        event
        for event in events
        if event.get("type") == "testDone" and not event.get("hidden")
    ]
    if (
        len(done) != expected
        or any(
            event.get("skipped") or event.get("result") != "success" for event in done
        )
        or not events
        or events[-1].get("type") != "done"
        or events[-1].get("success") is not True
    ):
        raise RuntimeError(
            f"Expected {expected} executed passing tests with no skips: {path}"
        )
    return {"passed": len(done), "skipped": 0}


def widget_test_alias(relative):
    """Return a test/ path for one integration_test file.

    Flutter 3.35 runs every file under integration_test/ on a connected device.
    The acceptance image has no display, so the same source runs as a widget test.
    """
    desktop = ROOT / "apps/desktop"
    alias = desktop / "test" / ("private_pipewire_" + Path(relative).name)
    if alias.is_symlink() or alias.exists():
        alias.unlink()
    alias.symlink_to(Path("..") / relative)
    return str(alias.relative_to(desktop))


def _worker_sdk(dart, env):
    """Locate the selected VM without loading the application's package graph."""
    executable = shutil.which(dart, path=env.get("PATH"))
    if executable is None:
        raise RuntimeError("Dart is required to verify the integration worker")
    with tempfile.TemporaryDirectory(prefix="fs-dart-", dir="/var/tmp") as temporary:
        probe = Path(temporary) / "locate.dart"
        probe.write_text(
            "import 'dart:io';\n"
            "void main() => stdout.writeln(Platform.resolvedExecutable);\n"
        )
        try:
            result = subprocess.run(
                [str(Path(executable).absolute()), str(probe)],
                cwd=temporary,
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            for output in (error.stdout, error.stderr):
                if output:
                    sys.stderr.write(
                        output.decode(errors="replace")
                        if isinstance(output, bytes)
                        else output
                    )
            raise
        if result.returncode:
            sys.stderr.write(result.stdout + result.stderr)
            raise RuntimeError("Integration worker SDK probe failed")
        vm = Path(result.stdout.strip())
        if not vm.is_absolute() or not vm.is_file():
            raise RuntimeError("Invalid integration worker SDK probe")
        return vm.resolve(strict=True).parent.parent


def _source_worker_defines(env, dart):
    """Use the finished source worker's exact public compilation context."""
    native = env.get("FORESIGHT_NATIVE_LIBRARY") or env.get("FORESIGHT_NATIVE")
    build = ROOT / "build"
    if native is not None and Path(native).parent.name == "native":
        build = Path(native).resolve(strict=True).parent.parent
    sdk = _worker_sdk(dart, env)
    module = importlib.import_module(
        "tools.build_diagnostic_worker" if __package__ else "build_diagnostic_worker"
    )
    receipt = module.verify_worker_build(
        ROOT,
        build,
        sdk,
        ROOT / "packages/foresight_core/.dart_tool/package_config.json",
        "aot",
    )
    return receipt["defines"]


def run_tests(
    package,
    files,
    expected,
    env,
    output,
    name,
    flutter="flutter",
    dart="dart",
    *,
    device=None,
    timeout=2400,
    model_fixture_catalog=None,
):
    output.mkdir(parents=True, exist_ok=True)
    events = output / f"{name}.events.jsonl"
    events.unlink(missing_ok=True)
    defines = (
        _source_worker_defines(env, dart)
        if package == "desktop"
        and any(path.startswith("integration_test/") for path in files)
        else {}
    )
    if model_fixture_catalog is not None:
        if package != "desktop" or files != [
            "integration_test/first_run_models_test.dart"
        ]:
            raise ValueError(
                "Compiled model fixture is restricted to the first-run journey"
            )
        defines.update(
            FORESIGHT_ENABLE_TEST_HOOKS="true",
            FORESIGHT_MODEL_CATALOG_TEST_BASE64=base64.b64encode(
                json.dumps(model_fixture_catalog, separators=(",", ":")).encode()
            ).decode("ascii"),
        )
    aliases = []
    command_files = []
    for relative in files:
        if (
            package == "desktop"
            and device is None
            and relative.startswith("integration_test/")
        ):
            command_files.append(widget_test_alias(relative))
            aliases.append(ROOT / "apps/desktop" / command_files[-1])
        else:
            command_files.append(relative)
    command = [
        flutter if package == "desktop" else dart,
        "test",
        *command_files,
        "--concurrency=1",
        "--reporter=expanded",
        "--file-reporter=json:" + str(events),
    ]
    if package == "desktop":
        command.extend(
            f"--dart-define={key}={value}" for key, value in sorted(defines.items())
        )
        command.append("--no-pub")
        if device is not None:
            command.extend(["-d", device])
    cwd = ROOT / ("apps/desktop" if package == "desktop" else "packages/foresight_core")
    try:
        with (output / f"{name}.log").open("w") as log:
            result = subprocess.run(
                command,
                cwd=cwd,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
        if result.returncode:
            print((output / f"{name}.log").read_text()[-12000:], flush=True)
            raise RuntimeError(f"{name} failed with exit {result.returncode}")
        return check_events(events, expected)
    finally:
        for alias in aliases:
            alias.unlink(missing_ok=True)


def model_file(directory, kind):
    _, _, filename, digest = MODELS[kind]
    path = (directory / filename).resolve(strict=True)
    with path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
            raise ValueError(f"Wrong {kind} fixture digest")
    return str(path)


def bundle_environment(bundle, inherited):
    # Do not inherit profile paths, account configuration, capture routes or developer overrides.
    env = {
        key: value
        for key, value in inherited.items()
        if not key.startswith("FORESIGHT_")
    }
    bundle = bundle.resolve(strict=True)
    if bundle.suffix == ".app":
        resources = bundle / "Contents/Resources"
        config = json.loads((resources / "runtime.json").read_text())
        env["FORESIGHT_TEST_SQL_SUPPORT_LIBRARY"] = str(
            resources / "lib/libforesight_sql_support.dylib"
        )
        keys = [
            "FORESIGHT_NATIVE",
            "FORESIGHT_HELPER",
            "FORESIGHT_LITERT_RUNNER",
            "FORESIGHT_MODEL_WORKER",
            "FORESIGHT_LITERT_LIBRARY",
            "FORESIGHT_QUERY_RUNTIME",
            "FORESIGHT_QUERY_WORKER",
        ]
        for key in keys:
            if key in config:
                env[key] = str((resources / config[key]).resolve(strict=True))
    else:
        env.update(
            FORESIGHT_NATIVE=str(bundle / "lib/libforesight_native.so"),
            FORESIGHT_TEST_SQL_SUPPORT_LIBRARY=str(
                bundle / "lib/libforesight_sql_support.so"
            ),
            FORESIGHT_HELPER=str(bundle / "bin/ForesightHelper"),
            FORESIGHT_LITERT_RUNNER=str(bundle / "bin/foresight-model"),
            FORESIGHT_MODEL_WORKER=str(bundle / "bin/foresight-model"),
            FORESIGHT_LITERT_LIBRARY=str(bundle / "lib/liblitert-lm.so"),
            FORESIGHT_QUERY_WORKER=str(
                bundle / "share/open-foresight/adapters/legacy_query_worker.py"
            ),
            FORESIGHT_LITERT_PYTHON=str(bundle / "bin/query-python"),
            # The compiled debug integration application owns its Flutter engine.
            # Loading the packaged release engine here prevents VM startup.
            LD_LIBRARY_PATH=str(bundle / "lib"),
        )
    for key in [
        "FORESIGHT_NATIVE",
        "FORESIGHT_HELPER",
        "FORESIGHT_LITERT_RUNNER",
        "FORESIGHT_TEST_SQL_SUPPORT_LIBRARY",
    ]:
        if not Path(env[key]).is_file():
            raise ValueError(f"Missing bundle runtime: {key}")
    env.update(FORESIGHT_LITERT_BACKEND="cpu", FORESIGHT_GENERATION_BACKEND="litert_lm")
    return env


def models_gate(args, env):
    env.update(
        FORESIGHT_INTEGRATION="1",
        FORESIGHT_GOOGLE_REAL_HELPER="1",
        FORESIGHT_GEMMA_TEST="1",
        FORESIGHT_WEB_MODEL_TEST="1",
        FORESIGHT_EMBEDDING_GPU="0",
        FORESIGHT_GENERATION_MODEL=model_file(args.models, "generation"),
        FORESIGHT_EMBEDDING=model_file(args.models, "embedding"),
        FORESIGHT_GEMMA_REPORT=str(args.output / "gemma.json"),
        FORESIGHT_GOOGLE_REPORT=str(args.output / "google-helper.json"),
        FORESIGHT_WEB_MODEL_REPORT=str(args.output / "web-model.json"),
    )
    env["FORESIGHT_GEMMA_MODEL"] = env["FORESIGHT_GENERATION_MODEL"]
    env["FORESIGHT_GENERATION_RUNNER"] = env["FORESIGHT_LITERT_RUNNER"]
    results, errors = {}, []
    for package, files, expected in [
        (
            "desktop",
            [
                "test/integration_test.dart",
                "test/native_load_test.dart",
                "test/meeting_citation_test.dart",
                "test/google_real_helper_test.dart",
                "test/gemma_native_test.dart",
            ],
            5,
        ),
        ("core", ["test/web_model_test.dart"], 1),
    ]:
        try:
            results[package] = run_tests(
                package,
                files,
                expected,
                env,
                args.output,
                "models-" + package,
                args.flutter,
                args.dart,
            )
        except Exception as error:
            errors.append(str(error))
    if errors:
        raise RuntimeError("; ".join(errors))
    return results


@contextmanager
def private_pipewire(env, output):
    if sys.platform != "linux" or Path("/dev/snd").exists():
        raise RuntimeError("Virtual audio requires Linux without host sound devices")
    if not env.get("DBUS_SESSION_BUS_ADDRESS"):
        raise RuntimeError("Run virtual-audio under dbus-run-session")
    processes, streams = [], []
    with tempfile.TemporaryDirectory(prefix="of-audio-", dir="/tmp") as directory:
        root = Path(directory)
        runtime, home = root / "run", root / "home"
        runtime.mkdir(mode=0o700)
        home.mkdir(mode=0o700)
        private = dict(
            env,
            PUB_CACHE=env.get(
                "PUB_CACHE", str(Path(env.get("HOME", str(Path.home()))) / ".pub-cache")
            ),
            FLUTTER_SUPPRESS_ANALYTICS="true",
            HOME=str(home),
            XDG_RUNTIME_DIR=str(runtime),
            PIPEWIRE_RUNTIME_DIR=str(runtime),
            PIPEWIRE_REMOTE="pipewire-0",
            PULSE_SERVER=f"unix:{runtime}/pulse/native",
            XDG_CONFIG_HOME=str(home / ".config"),
            XDG_STATE_HOME=str(home / ".state"),
        )
        # Ubuntu 24.04's WirePlumber 0.4 otherwise probes logind/Bluetooth.
        # This session only manages virtual nodes, with no hardware monitors.
        config = home / ".config/wireplumber"
        for group, settings in {
            "main": "alsa_monitor.enabled = false\nv4l2_monitor.enabled = false\nlibcamera_monitor.enabled = false\n",
            "bluetooth": "bluez_monitor.enabled = false\nbluez_midi_monitor.enabled = false\n",
        }.items():
            folder = config / f"{group}.lua.d"
            folder.mkdir(parents=True)
            (folder / "51-virtual-only.lua").write_text(settings)
        try:
            for daemon in ["pipewire", "pipewire-pulse", "wireplumber"]:
                log = (output / f"{daemon}.log").open("w")
                streams.append(log)
                processes.append(
                    subprocess.Popen(
                        [daemon],
                        env=private,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                )
            deadline = time.monotonic() + 30
            while True:
                try:
                    ready = subprocess.run(
                        ["pactl", "info"],
                        env=private,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=5,
                    )
                    if ready.returncode == 0:
                        break
                except subprocess.TimeoutExpired:
                    pass
                if time.monotonic() > deadline or any(
                    process.poll() is not None for process in processes
                ):
                    raise RuntimeError(
                        "Private PipeWire did not become ready; inspect daemon logs"
                    )
                time.sleep(0.1)
            sink = f"foresight-ci-{os.getpid()}"
            source = sink + "-microphone"
            for command in [
                [
                    "load-module",
                    "module-null-sink",
                    "sink_name=" + sink,
                    "channels=1",
                    "rate=48000",
                ],
                [
                    "load-module",
                    "module-remap-source",
                    "master=" + sink + ".monitor",
                    "source_name=" + source,
                    "channels=1",
                ],
            ]:
                subprocess.run(
                    ["pactl", *command],
                    env=private,
                    check=True,
                    stdout=subprocess.DEVNULL,
                    timeout=15,
                )
            # Pulse can accept module loads before WirePlumber publishes default metadata.
            for kind, target in [("sink", sink), ("source", source)]:
                deadline = time.monotonic() + 15
                while True:
                    result = subprocess.run(
                        ["pactl", f"set-default-{kind}", target],
                        env=private,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=5,
                    )
                    if result.returncode == 0:
                        break
                    if time.monotonic() > deadline or any(
                        process.poll() is not None for process in processes
                    ):
                        raise RuntimeError(
                            f"Private PipeWire default {kind} did not become ready"
                        )
                    time.sleep(0.1)
            private.update(FORESIGHT_MICROPHONE_TARGET=source, FORESIGHT_LIVE_SINK=sink)
            yield private
        finally:
            for process in reversed(processes):
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            for stream in streams:
                stream.close()


def meeting_environment(args, env, private):
    # The compiled integration app has its own native Debug executable. A sealed
    # installed service correctly accepts only its installed Release desktop.
    # Reuse identical service bytes outside the installation for this explicitly
    # development-only fixture; installed package acceptance remains separate.
    service_source = args.bundle.resolve() / "bin/foresight-service"
    service = args.output.resolve() / "meeting-service"
    if service.is_relative_to(args.bundle.resolve()):
        raise ValueError("Meeting integration output must be outside the bundle")
    mode = stat.S_IMODE(service_source.stat().st_mode)
    if not service_source.is_file() or not mode & 0o111:
        raise ValueError("Meeting integration requires an executable service")
    with service_source.open("rb") as source, service.open("xb") as target:
        shutil.copyfileobj(source, target)
    service.chmod(mode)
    original_digest = hashlib.sha256(service_source.read_bytes()).hexdigest()
    copied_digest = hashlib.sha256(service.read_bytes()).hexdigest()
    if copied_digest != original_digest:
        raise RuntimeError("Meeting integration service copy differs from bundle")
    desktop = (
        ROOT / "apps/desktop/build/linux/x64/debug/bundle/open-foresight"
    ).resolve()
    (args.output / "meeting-service-identity.json").write_text(
        json.dumps(
            {
                "source": str(service_source),
                "copy": str(service),
                "sha256": copied_digest,
                "mode": mode,
                "desktop": str(desktop),
                "scope": "Unbundled native Debug integration; installed package acceptance is separate",
            }
        )
        + "\n"
    )
    data = args.output / "meeting-data"
    screenshots = args.output / "meeting-screenshots"
    # File reveal is observed by a test-only FileManager1 receiver on the
    # runner's private session bus; production executable paths stay trusted.
    screenshots.mkdir(parents=True, exist_ok=True)
    speech = env["FORESIGHT_SPEECH_MODEL"]
    generation = model_file(args.models, "generation")
    embedding = model_file(args.models, "embedding")
    manifest = args.output / "meeting-models.json"
    manifest.write_text(
        json.dumps(
            {
                "speech": {
                    "model": speech,
                    "runtime": env["FORESIGHT_SPEECH_RUNNER"],
                    "sha256": MODELS["speech"][3],
                },
                "generation": {
                    "model": generation,
                    "runtime": env.get("FORESIGHT_LITERT_RUNNER", ""),
                    "sha256": MODELS["generation"][3],
                    "backend": "litert_lm",
                },
                "embedding": {
                    "model": embedding,
                    "runtime": "",
                    "sha256": MODELS["embedding"][3],
                    "backend": "litert_lm_embedding_cpu",
                },
            }
        )
        + "\n"
    )
    meeting = dict(private)
    # The meeting registers a bounded speech wrapper to observe pending ASR.
    # Its initial manifest still names the pinned real runtime; a process-wide
    # override would silently bypass subsequent model runtime registrations.
    meeting.pop("FORESIGHT_WHISPER_RUNTIME", None)
    meeting.update(
        FORESIGHT_PLAYBACK_TARGET=private["FORESIGHT_LIVE_SINK"],
        FORESIGHT_DATA=str(data),
        FORESIGHT_REFERENCE_SCREENSHOTS=str(screenshots),
        FORESIGHT_MEETING_SCREENSHOT=str(args.output / "meetings.png"),
        FORESIGHT_COPILOT_SCREENSHOT=str(args.output / "copilot.png"),
        FORESIGHT_MEETING_REPORT=str(args.output / "meeting-workflow.json"),
        FORESIGHT_LINK_OPEN_REPORT=str(args.output / "link-open.json"),
        FORESIGHT_MODEL_MANIFEST=str(manifest),
        FORESIGHT_SERVICE=str(service),
        FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES=json.dumps([str(desktop)]),
    )
    return meeting


@contextmanager
def private_x11(env, output):
    """Own an X server; never capture an inherited user's desktop."""
    if sys.platform != "linux" or env.get("FORESIGHT_PRIVATE_PIPEWIRE") != "1":
        raise RuntimeError("Native meeting UI requires the private Linux audio session")
    private = {
        key: value
        for key, value in env.items()
        if key
        not in (
            "DISPLAY",
            "WAYLAND_DISPLAY",
            "XAUTHORITY",
            "GDK_BACKEND",
            "HYPRLAND_INSTANCE_SIGNATURE",
            "XDG_ACTIVATION_TOKEN",
            "DESKTOP_STARTUP_ID",
            "FORESIGHT_PRIVATE_X11",
        )
    }
    read_fd, write_fd = os.pipe()
    process = None
    try:
        with (output / "xvfb.log").open("w") as log:
            process = subprocess.Popen(
                [
                    "Xvfb",
                    "-displayfd",
                    str(write_fd),
                    "-screen",
                    "0",
                    "1280x720x24",
                    "-nolisten",
                    "tcp",
                ],
                env=private,
                pass_fds=(write_fd,),
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            os.close(write_fd)
            write_fd = -1
            if not select.select([read_fd], [], [], 30)[0]:
                raise RuntimeError("Private X display did not start; inspect xvfb.log")
            display = os.read(read_fd, 32).decode().strip()
            if not display.isdecimal() or process.poll() is not None:
                raise RuntimeError("Private X display failed; inspect xvfb.log")
            private.update(
                DISPLAY=":" + display,
                GDK_BACKEND="x11",
                FORESIGHT_PRIVATE_X11=":" + display,
            )
            yield private
    finally:
        os.close(read_fd)
        if write_fd != -1:
            os.close(write_fd)
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)


def audio_gate(args, env):
    runner = args.bundle.resolve() / "bin/whisper-cli-vulkan"
    if not runner.is_file():
        raise ValueError("Linux bundle must include Whisper")
    env.update(
        FORESIGHT_SPEECH_RUNNER=str(runner),
        FORESIGHT_WHISPER_RUNTIME=str(runner),
        FORESIGHT_WHISPER_BACKEND="cpu",
        FORESIGHT_SPEECH_MODEL=model_file(args.models, "speech"),
        FORESIGHT_AUDIO_FIXTURE=str(ROOT / "tests/fixtures/audio/jfk.wav"),
        FORESIGHT_LIVE_TEST="1",
        FORESIGHT_LIVE_GAP_TEST="1",
        FORESIGHT_PRIVATE_PIPEWIRE="1",
        FORESIGHT_LIVE_REPORT=str(args.output / "live.json"),
        FORESIGHT_LIVE_GAP_REPORT=str(args.output / "live-gap.json"),
        FORESIGHT_PIPEWIRE_REPORT=str(args.output / "pipewire.json"),
    )
    with private_pipewire(env, args.output) as private:
        desktop = run_tests(
            "desktop",
            ["test/live_recording_test.dart", "test/live_gap_recording_test.dart"],
            2,
            private,
            args.output,
            "audio-desktop",
            args.flutter,
            args.dart,
        )
        inspector_env = dict(private)
        # The PCM inspector supplies its own runner and a dummy model, not Whisper.
        inspector_env.pop("FORESIGHT_WHISPER_RUNTIME", None)
        core = run_tests(
            "core",
            ["test/recording_pipewire_test.dart"],
            1,
            inspector_env,
            args.output,
            "audio-core",
            args.flutter,
            args.dart,
        )
        with private_x11(private, args.output) as display:
            meeting = run_tests(
                "desktop",
                ["integration_test/meeting_workflow_test.dart"],
                1,
                meeting_environment(args, env, display),
                args.output,
                "audio-meeting",
                args.flutter,
                args.dart,
                device="linux",
            )
    return {
        "desktop": desktop,
        "core": core,
        "meeting": meeting,
        "meeting_runner": "compiled-linux-desktop",
        "screenshots": "private-x11",
        "physical_audio": "not_run",
    }


def fast_gate(args, env):
    with tempfile.TemporaryDirectory(prefix="of-fail-", dir="/var/tmp") as directory:
        runner = Path(directory) / "pw-record"
        runner.write_text("#!/bin/sh\nexit 1\n")
        runner.chmod(0o700)
        env = dict(env, PATH=directory + os.pathsep + env["PATH"])
        files = ["test/answer_failure_test.dart"]
        if sys.platform == "linux":
            if args.native is None or not args.native.is_file():
                raise ValueError("--native is required on Linux")
            native = args.native.resolve(strict=True)
            sql = native.parent / "libforesight_sql_support.so"
            if sql.is_symlink() or not sql.is_file():
                raise ValueError("The selected native build requires its SQL support library")
            env.update(
                FORESIGHT_CAPTURE_STATE_TEST="1",
                FORESIGHT_NATIVE=str(native),
                FORESIGHT_TEST_SQL_SUPPORT_LIBRARY=str(sql),
            )
            files.append("test/capture_failure_test.dart")
        return run_tests(
            "desktop",
            files,
            len(files),
            env,
            args.output,
            "fast",
            args.flutter,
            args.dart,
        )


def reference_gate(args, env):
    if args.suite == "reference-models":
        if args.query_model is None:
            raise ValueError(
                "--query-model must point to an already authorized local asset"
            )
        env.update(
            FORESIGHT_QUERY_MODEL_TEST="1",
            FORESIGHT_PROACTIVE_MODEL_TEST="1",
            FORESIGHT_QUERY_MODEL=str(args.query_model.resolve(strict=True)),
            FORESIGHT_QUERY_PYTHON=env.get(
                "FORESIGHT_QUERY_RUNTIME", env.get("FORESIGHT_LITERT_PYTHON", "")
            ),
            FORESIGHT_QUERY_WORKER=env["FORESIGHT_QUERY_WORKER"],
        )
        return run_tests(
            "core",
            ["test/dedicated_query_model_test.dart", "test/proactive_model_test.dart"],
            5,
            env,
            args.output,
            "reference-models",
            args.flutter,
            args.dart,
        )
    if not args.original_socket or not args.port_socket:
        raise ValueError("Both existing tokenizer sockets are required")
    env.update(
        FORESIGHT_ORIGINAL_TOKENIZER_SOCKET=args.original_socket,
        FORESIGHT_PORT_TOKENIZER_SOCKET=args.port_socket,
    )
    return run_tests(
        "core",
        ["test/reference_tokenizer_live_test.dart"],
        1,
        env,
        args.output,
        "reference-tokenizer",
        args.flutter,
        args.dart,
    )


def publish_report_tree(path):
    """Let the host artifact uploader read profiles created mode 0700.

    The service refuses a profile other users can read, so the suite keeps that
    mode while tests run. Upload then scans the same tree as another user and
    fails with EACCES on the private directory. This runs only after the suite.
    """
    if not path.exists():
        return

    def relax(entry, bits):
        # The report root is the container mount, owned by the host user.
        # chmod there is EPERM when the container drops CAP_FOWNER. Profiles
        # created by this process are owned here and must still be relaxed.
        try:
            entry.chmod(entry.stat().st_mode | bits)
        except OSError:
            return

    for current, _dirnames, filenames in os.walk(path):
        directory = Path(current)
        if directory.is_symlink():
            continue
        relax(directory, 0o755)
        for name in filenames:
            file = directory / name
            if file.is_symlink():
                continue
            relax(file, 0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--suite",
        required=True,
        choices=[
            "fast",
            "models",
            "virtual-audio",
            "reference-models",
            "reference-tokenizer",
        ],
    )
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--native", type=Path)
    parser.add_argument("--models", type=Path)
    parser.add_argument("--query-model", type=Path)
    parser.add_argument("--original-socket")
    parser.add_argument("--port-socket")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--dart", default="dart")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"suite": args.suite, "status": "failed"}
    try:
        if args.suite in ("models", "virtual-audio") and args.models is None:
            parser.error("--models is required")
        if args.suite != "fast" and args.bundle is None:
            parser.error("--bundle is required")
        parent = Path(
            os.environ.get("FORESIGHT_TEST_TEMP_ROOT")
            or os.environ.get("TMPDIR")
            or "/var/tmp"  # noqa: S108 - mkdtemp creates an owned private child.
        ).resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix="of-ci-", dir=parent) as directory:
            env = (
                dict(os.environ)
                if args.suite == "fast"
                else bundle_environment(args.bundle, os.environ)
            )
            env.update(TMPDIR=directory, FORESIGHT_TEST_TEMP_ROOT=directory)
            # Model fixtures are mounted read-only; compilation caches are disposable.
            env["FORESIGHT_LITERT_CACHE"] = str(Path(directory) / "litert-cache")
            if args.suite == "fast":
                result = fast_gate(args, env)
            elif args.suite == "models":
                result = models_gate(args, env)
            elif args.suite == "virtual-audio":
                result = audio_gate(args, env)
            else:
                result = reference_gate(args, env)
        report.update(status="passed", result=result)
    finally:
        publish_report_tree(args.output)
        (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
