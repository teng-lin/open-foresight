#!/usr/bin/env python3
"""Build the pinned, relocatable inference payload used by macOS CI."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request

from litert_extensions import verify_extensions_manifest

ROOT = Path(__file__).resolve().parents[1]
PYTHON_ARCHIVE = "cpython-3.13.16+20261013-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_URL = (
    "https://github.com/astral-sh/python-build-standalone/releases/download/20261013/"
    + PYTHON_ARCHIVE
)
PYTHON_SHA256 = "ca0e6a70fb75a0984751bd75493e3de77680aef7fbd0fea9b903c299537b3423"
BAZEL_URL = "https://github.com/bazelbuild/bazel/releases/download/7.6.1/bazel-7.6.1-darwin-arm64"
BAZEL_SHA256 = "45cca81a839d7495258b19ee8371c7b891f350586ef37b9940f7b531eb654cc8"
WHISPER_COMMIT = "0c7be696371069e0baa2515ed7aa08d5a5473aa6"
LITERT_COMMIT = "b2f686e2ed4718fb84ec398a61dd59ca0f0aff27"


def run(*args, **kwargs):
    subprocess.run(
        [str(arg) for arg in args],
        check=True,
        timeout=kwargs.pop("timeout", 3600),
        **kwargs,
    )


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(url, destination, expected):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() or digest(destination) != expected:
        partial = destination.with_suffix(".download")
        try:
            with (
                urllib.request.urlopen(url, timeout=120) as response,  # noqa: S310 - URL scheme is fixed or validated before opening.
                partial.open("wb") as output,
            ):
                shutil.copyfileobj(response, output)
            if digest(partial) != expected:
                raise ValueError("Downloaded artifact checksum mismatch: " + url)
            partial.replace(destination)
        finally:
            partial.unlink(missing_ok=True)


def checkout(path, repository, commit):
    if not path.exists():
        run("git", "init", path)
        run("git", "-C", path, "remote", "add", "origin", repository)
        run("git", "-C", path, "fetch", "--depth=1", "origin", commit)
        run(
            "git",
            "-C",
            path,
            "checkout",
            "--detach",
            "FETCH_HEAD",
            env=dict(os.environ, GIT_LFS_SKIP_SMUDGE="1"),
        )
    actual = subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True, timeout=300
    ).strip()
    if actual != commit:
        raise ValueError("Wrong source revision: " + str(path))


def verify(prefix):
    manifest = json.loads((prefix / "runtime-manifest.json").read_text())
    if (
        manifest["python_sha256"] != PYTHON_SHA256
        or manifest["whisper_commit"] != WHISPER_COMMIT
    ):
        raise ValueError("Stale runtime cache")
    if digest(prefix / "whisper/whisper-cli") != manifest["whisper_sha256"]:
        raise ValueError("Whisper cache checksum mismatch")
    verify_extensions_manifest(
        prefix / "litert-extensions/build-manifest.json", platform_name="darwin"
    )
    run(
        prefix / "python/bin/python3",
        "-I",
        "-B",
        "-c",
        "import sys,numpy,sentencepiece; assert sys.version_info[:3] == (3,13,16)",
    )
    run(prefix / "whisper/whisper-cli", "--help")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / "build/macos-runtimes")
    parser.add_argument(
        "--sources", type=Path, default=ROOT / "build/macos-runtime-sources"
    )
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Build on an Apple Silicon Mac")
    prefix, sources = args.prefix.resolve(), args.sources.resolve()
    if (prefix / "runtime-manifest.json").exists():
        verify(prefix)
        return
    prefix.mkdir(parents=True, exist_ok=True)
    sources.mkdir(parents=True, exist_ok=True)
    archive = sources / PYTHON_ARCHIVE
    download(PYTHON_URL, archive, PYTHON_SHA256)
    if not (prefix / "python/bin/python3").exists():
        with tarfile.open(archive) as stream:
            stream.extractall(prefix, filter="data")
    python = prefix / "python/bin/python3"
    run(
        python,
        "-I",
        "-m",
        "pip",
        "install",
        "--only-binary=:all:",
        "-r",
        ROOT / "requirements-litert-macos.lock",
    )
    extension_manifest = prefix / "litert-extensions/build-manifest.json"
    if not extension_manifest.exists():
        bazel = sources / "bazel-7.6.1"
        download(BAZEL_URL, bazel, BAZEL_SHA256)
        bazel.chmod(0o755)
        litert = sources / "litert"
        checkout(
            litert, "https://github.com/google-ai-edge/LiteRT-LM.git", LITERT_COMMIT
        )
        run("git", "-C", litert, "lfs", "install", "--local")
        run(
            "git",
            "-C",
            litert,
            "lfs",
            "pull",
            "--include=prebuilt/macos_arm64/*",
            "--exclude=",
        )
        run(
            sys.executable,
            ROOT / "tools/build_litert_extensions.py",
            litert,
            "--bazel",
            bazel,
            "--output",
            prefix / "litert-extensions",
            "--output-user-root",
            sources / "bazel-cache",
            "--jobs",
            args.jobs,
        )
        # Release build memory before loading the packaged inference runtime.
        run(
            bazel,
            "--output_user_root=" + str(sources / "bazel-cache"),
            "shutdown",
            cwd=litert,
        )
    verify_extensions_manifest(extension_manifest, platform_name="darwin")
    whisper = sources / "whisper"
    checkout(whisper, "https://github.com/ggml-org/whisper.cpp.git", WHISPER_COMMIT)
    if subprocess.check_output(
        ["git", "-C", str(whisper), "status", "--porcelain", "--untracked-files=no"],
        timeout=300,
    ):
        raise ValueError("Whisper source must be clean")
    build = sources / "whisper-build"
    run(
        "cmake",
        "-S",
        whisper,
        "-B",
        build,
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DGGML_NATIVE=OFF",
        "-DGGML_METAL=ON",
        "-DGGML_METAL_EMBED_LIBRARY=ON",
        "-DWHISPER_BUILD_TESTS=OFF",
        "-DWHISPER_BUILD_EXAMPLES=ON",
    )
    run("cmake", "--build", build, "--target", "whisper-cli", "--parallel", args.jobs)
    (prefix / "whisper").mkdir(exist_ok=True)
    shutil.copy2(build / "bin/whisper-cli", prefix / "whisper/whisper-cli")
    shutil.copy2(whisper / "LICENSE", prefix / "whisper/LICENSE")
    manifest = {
        "python_sha256": PYTHON_SHA256,
        "whisper_commit": WHISPER_COMMIT,
        "whisper_sha256": digest(prefix / "whisper/whisper-cli"),
    }
    stamp = prefix / "runtime-manifest.json"
    stamp.write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        verify(prefix)
    except BaseException:
        stamp.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    main()
