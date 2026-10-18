#!/usr/bin/env python3
"""Release-only real-model CPU acceptance; weights stay outside the shipped app."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from build_macos_runtimes import download
from verify_macos_release_runtime import runtime_paths

ROOT = Path(__file__).resolve().parents[1]
MODELS = {
    "generation": (
        "litert-community/gemma-4-E2B-it-litert-lm",
        "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1",
        "gemma-4-E2B-it.litertlm",
        "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
    ),
    "embedding": (
        "litert-community/embeddinggemma-2-740m-litert-lm",
        "24d962e906c7d332c6428e71c9676855024569e2",
        "embeddinggemma-2-740m.litertlm",
        "e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c",
    ),
    "speech": (
        "ggerganov/whisper.cpp",
        "5359861c739e955e79d9a303bcbc70fb988958b1",
        "ggml-tiny.bin",
        "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
    ),
}


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
    with tempfile.TemporaryDirectory(prefix="foresight-release-speech-") as home:
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
            env={"PATH": "/usr/bin:/bin", "HOME": home, "TMPDIR": home},
            cwd="/",
            capture_output=True,
            text=True,
            timeout=180,
        )
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
