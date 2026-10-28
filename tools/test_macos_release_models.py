#!/usr/bin/env python3
"""Packaged macOS CPU/model acceptance; weights stay outside the shipped app."""

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from build_macos_runtimes import download
from model_pins import release_models
from verify_macos_release_runtime import runtime_paths

ROOT = Path(__file__).resolve().parents[1]
MODELS = release_models()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    paths = runtime_paths(args.app)
    models = {}
    for name, (repository, revision, filename, checksum) in MODELS.items():
        models[name] = args.models.resolve() / filename
        download(
            f"https://huggingface.co/{repository}/resolve/{revision}/{filename}",
            models[name],
            checksum,
        )
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            sys.executable,
            str(ROOT / "tools/test_packaged_model_runtime.py"),
            "--bundle",
            str(args.app.resolve()),
            "--generation",
            str(models["generation"]),
            "--embedding",
            str(models["embedding"]),
            "--backend",
            "cpu",
            "--output",
            str(args.output / "generation-embedding"),
        ],
        check=True,
        timeout=300,
    )
    parent = Path(
        os.environ.get("FORESIGHT_TEST_TEMP_ROOT")
        or os.environ.get("TMPDIR")
        or "/var/tmp"
    ).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="of-speech-", dir=parent) as home:
        try:
            result = subprocess.run(
                [
                    str(paths["FORESIGHT_WHISPER_RUNTIME"]),
                    "-m",
                    str(models["speech"]),
                    "-f",
                    str(ROOT / "tests/fixtures/audio/jfk.wav"),
                    "--no-gpu",
                    "--no-prints",
                    "--no-timestamps",
                    "-t",
                    "3",
                ],
                env={
                    "PATH": "/usr/bin:/bin",
                    "HOME": home,
                    "TMPDIR": home,
                    "FORESIGHT_TEST_TEMP_ROOT": home,
                },
                cwd="/",
                capture_output=True,
                text=True,
                timeout=180,
            )
        except subprocess.TimeoutExpired as error:
            report = {
                "exit_code": None,
                "timeout_seconds": error.timeout,
                "command": error.cmd,
            }
            for name in ("stdout", "stderr"):
                captured = getattr(error, name)
                report[name] = (
                    captured.decode("utf-8", errors="replace")
                    if isinstance(captured, bytes)
                    else captured
                )
                report[name + "_base64"] = (
                    base64.b64encode(captured).decode("ascii")
                    if isinstance(captured, bytes)
                    else None
                )
            (args.output / "speech.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )
            raise
        report = {
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
        (args.output / "speech.json").write_text(json.dumps(report, indent=2) + "\n")
        if (
            result.returncode
            or "ask not what your country" not in result.stdout.lower()
        ):
            raise RuntimeError(
                "Packaged Whisper failed the public JFK transcription fixture"
            )


if __name__ == "__main__":
    main()
