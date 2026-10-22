#!/usr/bin/env python3
"""Reject incomplete Mac releases and exercise their own isolated runtimes."""

from typing import Any
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def runtime_paths(app):
    app = app.resolve(strict=True)
    resources = app / "Contents/Resources"
    config = json.loads((resources / "runtime.json").read_text())
    paths = {}
    if (resources / "python").exists() or any(resources.rglob("*.py")):
        raise ValueError(
            "Release must not bundle a Python runtime or inference scripts"
        )
    for key in (
        "FORESIGHT_MODEL_WORKER",
        "FORESIGHT_LITERT_RUNNER",
        "FORESIGHT_LITERT_LIBRARY",
        "FORESIGHT_WHISPER_RUNTIME",
        "FORESIGHT_QUERY_WORKER",
        "FORESIGHT_QUERY_RUNTIME",
        "FORESIGHT_SQLITE_LIBRARY",
    ):
        relative = config.get(key)
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
        ):
            raise ValueError("Release lacks bundled " + key)
        path = (resources / relative).resolve(strict=True)
        if not path.is_file() or not path.is_relative_to(app):
            raise ValueError("Release runtime escapes bundle: " + key)
        paths[key] = path
    if paths["FORESIGHT_LITERT_RUNNER"] != paths["FORESIGHT_MODEL_WORKER"]:
        raise ValueError("Generation and embedding must share the native worker")
    if paths["FORESIGHT_QUERY_RUNTIME"] != paths["FORESIGHT_QUERY_WORKER"]:
        raise ValueError("Question detection must use the native worker directly")
    service_resources = (
        app / "Contents/Library/Services/Open Foresight Service.app/Contents/Resources"
    )
    service_config = json.loads((service_resources / "runtime.json").read_text())
    relative = service_config.get("FORESIGHT_SQLITE_LIBRARY")
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError("Service lacks bundled FORESIGHT_SQLITE_LIBRARY")
    service_sqlite = (service_resources / relative).resolve(strict=True)
    if (
        not service_sqlite.is_relative_to(app)
        or service_sqlite != paths["FORESIGHT_SQLITE_LIBRARY"]
    ):
        raise ValueError("Service SQLite runtime must share the owned bundled library")
    for notice in (
        "LiteRT-LM-extension.json",
        "LiteRT-LM-LICENSE",
        "sentencepiece-LICENSE",
        "whisper-LICENSE",
        "sqlite-LICENSE",
        "sqlite-provenance.json",
    ):
        if not (resources / "licenses" / notice).is_file():
            raise ValueError("Release lacks runtime provenance/license: " + notice)
    provenance = json.loads((resources / "licenses/sqlite-provenance.json").read_text())
    expected = provenance.get("bundled_library", {})
    sqlite_library = paths["FORESIGHT_SQLITE_LIBRARY"]
    with sqlite_library.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    if (
        expected.get("path") != config["FORESIGHT_SQLITE_LIBRARY"]
        or expected.get("sha256") != checksum
    ):
        raise ValueError("Bundled SQLite does not match its sealed provenance")
    return paths


def verify(app, output):
    paths = runtime_paths(app)
    report: dict[str, Any] = {"status": "failed", "checks": {}}
    with tempfile.TemporaryDirectory(prefix="foresight-release-runtime-") as home:
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": home,
            "TMPDIR": home,
            "FORESIGHT_LITERT_LIBRARY": str(paths["FORESIGHT_LITERT_LIBRARY"]),
        }
        commands = {
            "native_generation_embedding": [paths["FORESIGHT_MODEL_WORKER"], "--check"],
            "native_query": [paths["FORESIGHT_QUERY_WORKER"], "--check"],
            "whisper": [paths["FORESIGHT_WHISPER_RUNTIME"], "--help"],
        }
        try:
            for name, command in commands.items():
                result = subprocess.run(
                    [str(arg) for arg in command],
                    env=env,
                    cwd="/",
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                report["checks"][name] = {
                    "exit_code": result.returncode,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                }
                if result.returncode:
                    raise RuntimeError("Packaged runtime failed: " + name)
            report["status"] = "passed"
        finally:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(report, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    verify(args.app, args.output)


if __name__ == "__main__":
    main()
