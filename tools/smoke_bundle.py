#!/usr/bin/env python3
"""Relocate and launch the desktop bundle, then verify its private helper RPC."""

from typing import IO, cast
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import select
import subprocess
import tempfile
import time
import grpc
from evaluate_models import PACKAGE, messages, control_snapshot


def mcp_roundtrip(bundle, env):
    process = subprocess.Popen(
        [str(bundle / "open-foresight-mcp")],
        env=env,
        cwd="/",
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )

    def request(identifier, method, params):
        cast(IO[bytes], process.stdin).write(
            (
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": identifier,
                        "method": method,
                        "params": params,
                    }
                )
                + "\n"
            ).encode()
        )
        cast(IO[bytes], process.stdin).flush()
        if not (select.select([cast(IO[bytes], process.stdout)], [], [], 20)[0]):
            raise RuntimeError("Packaged MCP timed out")
        value = json.loads(cast(IO[bytes], process.stdout).readline())
        if not (value.get("id") == identifier and "error" not in value):
            raise RuntimeError(value)
        return value["result"]

    try:
        request(
            1,
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "bundle-smoke", "version": "1"},
            },
        )
        cast(IO[bytes], process.stdin).write(
            (
                json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"})
                + "\n"
            ).encode()
        )
        status = request(2, "tools/call", {"name": "get_status", "arguments": {}})
        if not (not status.get("isError")):
            raise RuntimeError(status)
        note = request(
            3,
            "tools/call",
            {
                "name": "save_note",
                "arguments": {
                    "title": "Relocation smoke",
                    "body": "Shared local service",
                },
            },
        )
        if not (not note.get("isError")):
            raise RuntimeError(note)
        result = status["structuredContent"]["result"]
        cast(IO[bytes], process.stdin).close()
        if not (process.wait(timeout=5) == 0):
            raise RuntimeError(cast(IO[bytes], process.stderr).read().decode())
        return result
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=30)
        cast(IO[bytes], process.stdout).close()
        cast(IO[bytes], process.stderr).close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="foresight-relocation-") as temp:
        root = Path(temp)
        relocated = root / "relocated bundle"
        shutil.copytree(args.bundle, relocated)
        env = os.environ.copy()
        env["FORESIGHT_DATA"] = str(root / "data")
        env["FORESIGHT_RUNTIME"] = str(root / "run")
        # Deliberately drop the build-time library path: test bundled resolution.
        env["LD_LIBRARY_PATH"] = (
            str(relocated / "lib") + ":" + str(relocated / "app/lib")
        )
        forbidden = [
            str(p.relative_to(relocated))
            for p in relocated.rglob("*")
            if p.is_file()
            and (
                p.suffix in (".py", ".pyc", ".pyo")
                or p.name.startswith(("python", "libpython"))
            )
        ]
        if not (not forbidden):
            raise RuntimeError(forbidden)
        subprocess.run(
            [str(relocated / "bin/foresight-model"), "--check"],
            env=env,
            check=True,
            timeout=300,
        )
        linkage = {}
        for relative in [
            "bin/ForesightHelper",
            "bin/foresight-service",
            "bin/foresight-mcp",
            "lib/libforesight_native.so",
            "bin/foresight-model",
            "lib/liblitert-lm.so",
            "app/open-foresight",
        ]:
            value = subprocess.check_output(
                ["ldd", str(relocated / relative)], env=env, text=True, timeout=300
            )
            if not ("not found" not in value):
                raise RuntimeError(value)
            if not ("libpython" not in value):
                raise RuntimeError(value)
            linkage[relative] = value.splitlines()
        log = root / "desktop.log"
        socket = str(root / "run/helper.sock")
        with log.open("w") as output:
            process = subprocess.Popen(
                [str(relocated / "open-foresight")],
                env=env,
                cwd="/",
                stdout=output,
                stderr=output,
                start_new_session=True,
            )
            channel = grpc.insecure_channel("unix:" + socket)
            try:
                grpc.channel_ready_future(channel).result(timeout=30)
                classes = messages()
                rpc = channel.unary_unary(
                    "/" + PACKAGE + ".RagService/Ping",
                    request_serializer=lambda value: value.SerializeToString(),
                    response_deserializer=classes["PingResponse"].FromString,
                )
                ping = rpc(classes["PingRequest"](), timeout=5)
                if not (ping.success and ping.version == "1.0.3"):
                    raise RuntimeError("Verification failed")
                state = control_snapshot(channel)
                if not (state["pipeline"] == "unconfigured"):
                    raise RuntimeError(state)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(
                            f"App exit code: {process.poll()}\n{log.read_text()}"
                        )
                    time.sleep(0.25)
                if not ((root / "data/application.db").is_file()):
                    raise RuntimeError("Application DB was not created")
                if not ((root / "run").stat().st_mode & 0o077 == 0):
                    raise RuntimeError("Verification failed")
                if not ((root / "data").stat().st_mode & 0o077 == 0):
                    raise RuntimeError("Verification failed")
                google_configuration = (
                    relocated / "share/open-foresight/google-client.json"
                )
                if google_configuration.exists():
                    config = json.loads(google_configuration.read_text())
                    if not (set(config) == {"installed"}):
                        raise RuntimeError("Verification failed")
                    if not (set(config["installed"]) <= {"client_id", "client_secret"}):
                        raise RuntimeError("Verification failed")
                    if not (google_configuration.stat().st_mode & 0o077 == 0):
                        raise RuntimeError("Verification failed")
                shared = mcp_roundtrip(relocated, env)
                owner = json.loads(
                    subprocess.check_output(
                        [str(relocated / "open-foresight-service"), "--status"],
                        env=env,
                        text=True,
                        timeout=300,
                    )
                )
                if not (shared["pid"] == owner["pid"]):
                    raise RuntimeError("Desktop and packaged MCP have different owners")
                headless_env = {
                    **env,
                    "FORESIGHT_DATA": str(root / "headless-data"),
                    "FORESIGHT_RUNTIME": str(root / "headless-run"),
                }
                try:
                    headless = mcp_roundtrip(relocated, headless_env)
                    if not (headless["pid"] != owner["pid"]):
                        raise RuntimeError("Independent profiles shared an owner")
                finally:
                    subprocess.run(
                        [str(relocated / "open-foresight-service"), "--stop"],
                        env=headless_env,
                        capture_output=True,
                        timeout=20,
                        check=True,
                    )
                report = {
                    "no_python_files_or_linkage": True,
                    "native_runtime_check": True,
                    "mcp_same_profile_owner": True,
                    "headless_mcp_startup": True,
                    "mcp_launcher_relocation": True,
                    "relocation": "passed with spaces in bundle path and cwd=/",
                    "desktop_process_alive": True,
                    "startup_observation_seconds": 10,
                    "application_database_created": True,
                    "ping": {"success": ping.success, "version": ping.version},
                    "state_without_models": state,
                    "private_paths": True,
                    "google_application_configuration_packaged": google_configuration.exists(),
                    "google_account_tokens_packaged": False,
                    "linkage": linkage,
                    "limitations": [
                        "Same Linux host; independent clean machine not tested"
                    ],
                    "log": log.read_text(),
                }
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                print(
                    json.dumps({"relocation": "passed", "ping": True, "desktop": True})
                )
            finally:
                subprocess.run(
                    [str(relocated / "open-foresight-service"), "--stop"],
                    env=env,
                    capture_output=True,
                    timeout=20,
                    check=True,
                )
                channel.close()
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=30)


if __name__ == "__main__":
    main()
