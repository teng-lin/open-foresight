#!/usr/bin/env python3
"""Build the isolated codec worker from hash-pinned source, without system codecs.

Input justification: bundle pinned codecs for offline retained audio and MP3
export without a system FFmpeg dependency. This does not edit SDK trust inputs.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "opus-1.6.1": (
        "https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz",
        "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1",
    ),
    "libopusenc-0.3": (
        "https://downloads.xiph.org/releases/opus/libopusenc-0.3.tar.gz",
        "f616d3aff9b2034547894ccb8ab56c36cf1a4acb0d922c5d7119f97bbe58642c",
    ),
    "libogg-1.3.6": (
        "https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz",
        "83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638",
    ),
    "opusfile-0.12": (
        "https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz",
        "118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b",
    ),
    "lame-4.0": (
        "https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz",
        "3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb",
    ),
}


def sha(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(65536):
            value.update(block)
    return value.hexdigest()


def private_directory(path: Path) -> Path:
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o077
    ):
        raise ValueError("build directories must be private owned directories")
    return path.resolve()


def checked_archive(
    cache: Path, name: str, url: str, expected: str, fetch: bool
) -> Path:
    archive = cache / (name + ".tar.gz")
    if not archive.exists() and fetch:
        if not url.startswith("https://"):
            raise ValueError("source downloads require HTTPS")
        deadline = time.monotonic() + 120
        for attempt in range(3):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"source download budget exhausted: {name}")
            try:
                with tempfile.NamedTemporaryFile(
                    dir=cache, prefix="download-", delete=False
                ) as output:
                    partial = Path(output.name)
                    # Each attempt starts a private file; no partial response or
                    # unverified bytes can enter the content-addressed cache.
                    with urllib.request.urlopen(url, timeout=remaining) as response:  # noqa: S310 - reviewed hash-pinned HTTPS URLs
                        if not response.url.startswith("https://"):
                            raise ValueError("source download redirected outside HTTPS")
                        total = 0
                        while block := response.read(65536):
                            total += len(block)
                            if total > 64 * 1024 * 1024:
                                raise ValueError("source archive exceeds size limit")
                            output.write(block)
                if sha(partial) != expected:
                    raise ValueError(f"source checksum mismatch: {name}")
                partial.replace(archive)
                break
            except (OSError, http.client.IncompleteRead) as error:
                if attempt == 2 or not transient_source_failure(error):
                    raise
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise
                # Retain failed partial files and the transport failure. Retry
                # neither source/redirect policy nor checksum/ownership refusal.
                print(
                    f"Source download {name} attempt {attempt + 1} failed: {error}",
                    flush=True,
                )
                time.sleep(min(attempt + 1, remaining))
    info = archive.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
    ):
        raise ValueError("unsafe source archive")
    if sha(archive) != expected:
        raise ValueError(f"source checksum mismatch: {name}")
    return archive


def transient_source_failure(error: BaseException) -> bool:
    if isinstance(error, urllib.error.HTTPError):
        return error.code in (408, 429, 500, 502, 503, 504)
    if isinstance(error, urllib.error.URLError):
        return (
            transient_source_failure(error.reason)
            if isinstance(error.reason, BaseException)
            else False
        )
    if isinstance(error, socket.gaierror):
        return error.errno == socket.EAI_AGAIN
    if isinstance(error, ssl.SSLError):
        # An abrupt TLS close needs a fresh connection. Certificate and other
        # TLS policy failures remain permanent, regardless of numeric errno.
        return isinstance(error, ssl.SSLEOFError)
    if isinstance(error, (TimeoutError, http.client.IncompleteRead)):
        return True
    return isinstance(error, OSError) and error.errno in (
        errno.ECONNRESET,
        errno.ECONNABORTED,
        errno.ECONNREFUSED,
        errno.ETIMEDOUT,
        errno.EPIPE,
    )


def extract(archive: Path, destination: Path) -> None:
    with tarfile.open(archive) as stream:
        size = 0
        for member in stream.getmembers():
            path = Path(member.name)
            size += member.size
            if (
                path.is_absolute()
                or ".." in path.parts
                or not (member.isfile() or member.isdir())
            ):
                raise ValueError("unsafe source archive member")
            if size > 256 * 1024 * 1024:
                raise ValueError("expanded source exceeds size limit")
        stream.extractall(destination, filter="data")


def build(cache: Path, output: Path, *, fetch: bool, jobs: int) -> None:
    if (os.uname().sysname, os.uname().machine) not in (
        ("Darwin", "arm64"),
        ("Linux", "x86_64"),
    ):
        raise ValueError(
            "supported media worker targets are macOS arm64 and Linux x86_64"
        )
    cache = private_directory(cache)
    output = private_directory(output)
    if (output / "foresight-media-worker").exists():
        raise ValueError(
            "choose an unused output directory; existing products are never relabelled"
        )
    source_archives = {
        name: checked_archive(cache, name, url, checksum, fetch)
        for name, (url, checksum) in SOURCES.items()
    }
    # Keep failed build trees and logs, including all captured compiler output.
    work = Path(tempfile.mkdtemp(prefix="media-", dir=cache))
    stage = work / "stage"
    env = os.environ.copy()
    for name in (
        "CPPFLAGS",
        "LDFLAGS",
        "LIBS",
        "CPATH",
        "C_INCLUDE_PATH",
        "CPLUS_INCLUDE_PATH",
        "LIBRARY_PATH",
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "LD_LIBRARY_PATH",
    ):
        env.pop(name, None)
    env.update(
        TMPDIR=str(cache),
        FORESIGHT_TEST_TEMP_ROOT=str(cache),
        LC_ALL="C",
        PKG_CONFIG_PATH="",
        PKG_CONFIG_LIBDIR=str(stage / "lib/pkgconfig"),
    )
    compiler = shutil.which("c++")
    c_compiler = shutil.which("cc")
    if compiler is None or c_compiler is None:
        raise ValueError("C and C++ compilers are required")
    env.update(CC=c_compiler, CXX=compiler, CFLAGS="-O2 -fPIC", CXXFLAGS="-O2 -fPIC")
    if os.uname().sysname == "Darwin":
        env["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
        env["CFLAGS"] += " -mmacosx-version-min=15.0"
        env["CXXFLAGS"] += " -mmacosx-version-min=15.0"
    commands: list[list[str]] = []

    def run(args: list[str], cwd: Path = work, timeout: int = 3600) -> str:
        commands.append(args)
        with (work / "build.log").open("ab") as log:
            log.write(("COMMAND " + repr(args) + "\n").encode())
        try:
            result = subprocess.run(
                args,
                cwd=cwd,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            with (work / "build.log").open("ab") as log:
                log.write(error.output or b"")
                log.write(b"\nCOMMAND TIMED OUT\n")
            raise RuntimeError(
                f"media worker build timed out; retained output: {work / 'build.log'}"
            ) from error
        with (work / "build.log").open("ab") as log:
            log.write(result.stdout)
        if result.returncode:
            raise RuntimeError(
                f"media worker build failed; retained output: {work / 'build.log'}"
            )
        return result.stdout.decode(errors="replace")

    compiler_identity = run([compiler, "--version"], timeout=30)
    for archive in source_archives.values():
        extract(archive, work)
    for name in (
        "libogg-1.3.6",
        "opus-1.6.1",
        "libopusenc-0.3",
        "opusfile-0.12",
        "lame-4.0",
    ):
        args = [
            "./configure",
            f"--prefix={stage}",
            "--disable-shared",
            "--enable-static",
        ]
        args += {
            "libogg-1.3.6": [],
            "opus-1.6.1": ["--disable-doc", "--disable-extra-programs"],
            "libopusenc-0.3": ["--disable-doc", "--disable-examples"],
            "opusfile-0.12": ["--disable-doc", "--disable-examples", "--disable-http"],
            "lame-4.0": [
                "--disable-decoder",
                "--disable-frontend",
                "--disable-mp3x",
                "--disable-mp3rtp",
            ],
        }[name]
        run(args, work / name)
        run(["make", f"-j{jobs}"], work / name)
        run(["make", "install"], work / name)
    source_files = [
        ROOT / "native/media_worker.cpp",
        ROOT / "native/media_assembly.inc",
        ROOT / "native/media_pager_protocol.h",
        ROOT / "native/media_bootstrap.h",
        ROOT / "native/media_process.cpp",
        ROOT / "native/media_process.h",
        ROOT / "native/media_supervisor.cpp",
        ROOT / "native/media_supervisor.h",
        ROOT / "native/media_supervisor_protocol.h",
        ROOT / "native/portable_process.h",
        ROOT / "native/diagnostic_sha256.c",
        ROOT / "native/diagnostic_sha256.h",
        Path(__file__).resolve(),
    ]
    identity = {
        "protocol": 1,
        "sources": SOURCES,
        "application_sources": {str(p.relative_to(ROOT)): sha(p) for p in source_files},
        "compiler": compiler_identity,
        "platform": os.uname().sysname,
        "architecture": os.uname().machine,
        "deployment_target": env.get("MACOSX_DEPLOYMENT_TARGET"),
        "commands": [
            [
                part.replace(str(work), "<build>").replace(str(ROOT), "<source>")
                for part in command
            ]
            for command in commands
        ],
    }
    build_id = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    objects = output / "objects"
    objects.mkdir(mode=0o700)
    flags = ["-O2", "-fPIC"] + (
        ["-mmacosx-version-min=15.0"] if os.uname().sysname == "Darwin" else []
    )
    run(
        [
            c_compiler,
            *flags,
            "-std=c11",
            "-c",
            str(ROOT / "native/diagnostic_sha256.c"),
            "-o",
            str(objects / "diagnostic_sha256.o"),
        ]
    )
    run(
        [
            compiler,
            *flags,
            "-std=c++20",
            "-pthread",
            "-Wall",
            "-Wextra",
            "-Werror",
            f'-DFORESIGHT_MEDIA_BUILD_ID="{build_id}"',
            f"-I{stage / 'include'}",
            f"-I{stage / 'include/opus'}",
            "-c",
            str(ROOT / "native/media_worker.cpp"),
            "-o",
            str(objects / "media_worker.o"),
        ]
    )
    # Same trusted executable supervises its codec descendant, keeping waitpid
    # ownership outside Dart's process reaper. Platform Security/CoreFoundation
    # are existing deployment-SDK inputs, not a new downloaded toolchain.
    for source in ("media_process", "media_supervisor"):
        run(
            [
                compiler,
                *flags,
                "-std=c++20",
                "-pthread",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-DFORESIGHT_MEDIA_PROCESS_SUPERVISOR=1",
                "-c",
                str(ROOT / f"native/{source}.cpp"),
                "-o",
                str(objects / f"{source}.o"),
            ]
        )
    system_links = ["-pthread"] + (
        ["-framework", "Security", "-framework", "CoreFoundation"]
        if os.uname().sysname == "Darwin"
        else []
    )
    library_names = [
        "libopusenc.a",
        "libopusfile.a",
        "libopus.a",
        "libogg.a",
        "libmp3lame.a",
    ]
    libraries = [str(stage / "lib" / name) for name in library_names]
    binary = output / "foresight-media-worker"
    run(
        [
            compiler,
            *flags,
            str(objects / "media_worker.o"),
            str(objects / "diagnostic_sha256.o"),
            str(objects / "media_process.o"),
            str(objects / "media_supervisor.o"),
            *libraries,
            "-lm",
            *system_links,
            "-o",
            str(binary),
        ]
    )
    for folder in ("lib", "sources", "notices"):
        (output / folder).mkdir(mode=0o700)
    for name in library_names:
        shutil.copyfile(stage / "lib" / name, output / "lib" / name)
    shutil.copyfile(ROOT / "LICENSE", output / "notices/open-foresight-LICENSE")
    for name, archive in source_archives.items():
        shutil.copyfile(archive, output / "sources" / archive.name)
        shutil.copyfile(
            work / name / "COPYING", output / "notices" / (name + "-COPYING")
        )
    for file in source_files:
        shutil.copyfile(file, output / "sources" / file.name)
    description = json.loads(run([str(binary), "--describe"], timeout=30))
    if description.get("protocol") != 1 or description.get("build_id") != build_id:
        raise RuntimeError("compiled worker identity mismatch")
    closure = run(
        ["otool", "-L", str(binary)]
        if os.uname().sysname == "Darwin"
        else ["ldd", str(binary)],
        timeout=30,
    )
    if any(
        name in closure
        for name in ("libopus", "libogg", "libmp3lame", "libmpg123", "libopusfile")
    ):
        raise RuntimeError("worker unexpectedly loads an external codec")
    receipt = {
        **identity,
        "build_id": build_id,
        "binary_sha256": sha(binary),
        "binary_bytes": binary.stat().st_size,
        "static_library_sha256": {
            name: sha(output / "lib" / name) for name in library_names
        },
        "relink_object_sha256": {p.name: sha(p) for p in objects.glob("*.o")},
        "description": description,
        "commands": commands,
        "dynamic_dependencies": closure,
        "build_log": str(work / "build.log"),
        "relink": [
            compiler,
            *flags,
            "objects/media_worker.o",
            "objects/diagnostic_sha256.o",
            "objects/media_process.o",
            "objects/media_supervisor.o",
            *["lib/" + name for name in library_names],
            "-lm",
            *system_links,
            "-o",
            "foresight-media-worker",
        ],
    }
    (output / "media-worker-build.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )
    print(
        json.dumps(
            {
                "binary": str(binary),
                "build_id": build_id,
                "sha256": sha(binary),
                "build_log": str(work / "build.log"),
            }
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--fetch",
        action="store_true",
        help="explicitly allow fetching pinned source archives",
    )
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 32:
        parser.error("jobs must be between 1 and 32")
    build(args.cache, args.output, fetch=args.fetch, jobs=args.jobs)


if __name__ == "__main__":
    main()
