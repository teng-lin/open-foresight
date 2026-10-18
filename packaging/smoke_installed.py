#!/usr/bin/env python3
"""Exercise installed files as an ordinary user in a disposable Xvfb session.

A pinned Tiny model and public speech fixture exercise CPU decoding only in a
temporary directory. No account, microphone, physical display, or host profile
is used. GPU/audio/portal acceptance belongs to separate hardware tests.
"""

import json
import hashlib
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request


# These reconstructed worker sources are shipped deliberately. They do not add
# a Python interpreter or enable a fallback to host Python in native releases.
QUERY_WORKER_SOURCES = frozenset(
    "share/open-foresight/adapters/" + name
    for name in (
        "legacy_query_worker.py",
        "legacy_query_executor.py",
        "legacy_query_weights.py",
    )
)


def validate_native_python_payload(root):
    unexpected = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if relative in QUERY_WORKER_SOURCES:
            continue
        if path.suffix in (".py", ".pyc", ".pyo") or path.name.startswith(
            ("python", "libpython")
        ):
            unexpected.append(relative)
    if unexpected:
        raise ValueError(
            "Unexpected Python payload in native package: "
            + ", ".join(sorted(unexpected))
        )


def main():
    root = Path("/opt/open-foresight")
    if not (os.getuid() != 0):
        raise RuntimeError("Run the application smoke test as a normal user")
    env = dict(
        os.environ,
        LD_LIBRARY_PATH=f"{root}/lib:{root}/app/lib",
        FORESIGHT_LITERT_LIBRARY=str(root / "lib/liblitert-lm.so"),
        LIBGL_ALWAYS_SOFTWARE="1",
        GDK_BACKEND="x11",
    )
    # Check all runtime ELFs, including dlopen-only inference libraries. This
    # catches host dependencies that an executable-only ldd check misses.
    manifest = json.loads((root / "manifest.json").read_text())
    for entry in manifest["files"]:
        with (root / entry["path"]).open("rb") as stream:
            if not (
                hashlib.file_digest(stream, "sha256").hexdigest() == entry["sha256"]
            ):
                raise RuntimeError(entry["path"])
    count = 0
    for file in root.rglob("*"):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        linked = subprocess.run(
            ["ldd", str(file)], env=env, capture_output=True, text=True, timeout=300
        )
        if not ("not found" not in linked.stdout + linked.stderr):
            raise RuntimeError(
                (
                    file,
                    linked.stdout,
                    linked.stderr,
                )
            )
        count += 1
    if not (count > 0):
        raise RuntimeError("Verification failed")
    validate_native_python_payload(root)
    subprocess.run(
        [str(root / "bin/foresight-model"), "--check"], env=env, check=True, timeout=30
    )
    subprocess.run(
        [str(root / "bin/whisper-cli-vulkan"), "--help"],
        env=env,
        check=True,
        capture_output=True,
        timeout=30,
    )
    with tempfile.TemporaryDirectory(prefix="foresight-install-") as temp:
        private = Path(temp)
        model = private / "ggml-tiny.bin"
        request = urllib.request.Request(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/"
            "5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.bin",
            headers={"User-Agent": "open-foresight-ci"},
        )
        with (
            urllib.request.urlopen(request, timeout=90) as response,  # noqa: S310 - URL scheme is fixed or validated before opening.
            model.open("wb") as output,
        ):
            while block := response.read(1024 * 1024):
                output.write(block)
        with model.open("rb") as stream:
            if not (
                hashlib.file_digest(stream, "sha256").hexdigest()
                == "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
            ):
                raise RuntimeError("Verification failed")
        fixture = Path(__file__).resolve().parents[1] / "tests/fixtures/audio/jfk.wav"
        decoded = subprocess.run(
            [
                str(root / "bin/whisper-cli-vulkan"),
                "-ng",
                "-t",
                "2",
                "-m",
                str(model),
                "-f",
                str(fixture),
                "-l",
                "en",
                "-nt",
            ],
            env=env,
            check=True,
            capture_output=True,
            text=True,
            timeout=90,
        )
        if "country" not in decoded.stdout.lower():
            raise RuntimeError(decoded.stdout + decoded.stderr)
        data, runtime = private / "data", private / "run"
        env.update(FORESIGHT_DATA=str(data), FORESIGHT_RUNTIME=str(runtime))
        log = private / "desktop.log"
        with log.open("w") as output:
            app = subprocess.Popen(
                ["/usr/bin/open-foresight"],
                env=env,
                cwd="/",
                stdout=output,
                stderr=output,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    if app.poll() is not None:
                        raise RuntimeError(log.read_text())
                    if (data / "application.db").exists() and (
                        runtime / "helper.sock"
                    ).exists():
                        break
                    time.sleep(0.25)
                else:
                    raise TimeoutError(log.read_text())
                with socket.socket(socket.AF_UNIX) as command:
                    command.settimeout(5)
                    command.connect(str(runtime / "commands.sock"))
                    command.sendall(b'{"version":1,"command":"activate"}\n')
                    if command.recv(128).strip() not in {b"queued", b"accepted"}:
                        raise RuntimeError("Verification failed")
                with sqlite3.connect(data / "application.db") as db:
                    if not (db.execute("PRAGMA quick_check").fetchone()[0] == "ok"):
                        raise RuntimeError("Verification failed")
                    if not (
                        db.execute("SELECT count(*) FROM models").fetchone()[0] == 0
                    ):
                        raise RuntimeError("Verification failed")
                if not (data.stat().st_mode & 0o077 == 0):
                    raise RuntimeError("Verification failed")
                if not (runtime.stat().st_mode & 0o077 == 0):
                    raise RuntimeError("Verification failed")
                time.sleep(3)
                if app.poll() is not None:
                    raise RuntimeError(log.read_text())
                print(
                    json.dumps(
                        {
                            "installed_startup": True,
                            "installed_manifest": True,
                            "activation_ipc": True,
                            "elf_linkage_files": count,
                            "private_profile": True,
                            "native_litert_runtime": True,
                            "no_bundled_python_runtime": True,
                            "whisper_cli": True,
                            "whisper_cpu_fixture": True,
                            "physical_audio_or_gpu_inference_tested": False,
                        }
                    )
                )
            finally:
                os.killpg(app.pid, signal.SIGTERM) if app.poll() is None else None
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait(timeout=30)


if __name__ == "__main__":
    main()
