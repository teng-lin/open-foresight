#!/usr/bin/env python3
"""Prepare an isolated original detector oracle; never run implicitly.

build and check-isolation do not copy or load original code. prepare performs
owned-copy conversion/signing only after successful isolation checks. run is a
separate explicit command and repeats those checks before loading the copy.
"""

from typing import Any

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
APP = Path("/Applications/Foresight.app")
APP_SHA = "fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326"
MODEL_SHA = "889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f"
DEFAULT_ROOT = REPO / "test-results/reference-functions/oracle-preparation"
_spec = importlib.util.spec_from_file_location("oracle_fixups", HERE / "fixups.py")
if _spec is None or _spec.loader is None:
    raise RuntimeError("Oracle fixups have no loader")
_fixups = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixups)


def sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def private_root(path):
    path = path.absolute()
    if path.is_symlink():
        raise ValueError("Root cannot be a symlink")
    path = path.resolve(strict=False)
    if path == APP or APP in path.parents:
        raise ValueError("Root cannot be inside original application")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = path.resolve(strict=True)
    metadata = path.stat()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise ValueError("Root must be owned by this user and mode 0700")
    if path == APP or APP in path.parents:
        raise ValueError("Root cannot be inside original application")
    return path


def build(root):
    output = root / "original-query-harness"
    subprocess.run(
        [
            "/usr/bin/clang++",
            "-std=c++20",
            "-fobjc-arc",
            "-Wno-deprecated-declarations",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            str(HERE / "harness.mm"),
            "-framework",
            "Metal",
            "-framework",
            "Foundation",
            "-o",
            str(output),
        ],
        check=True,
        timeout=300,
    )
    output.chmod(0o700)
    return output


def environment(root):
    # No DYLD injection, user preferences, cloud SDK environment or credentials.
    return {
        "TMPDIR": str(root) + "/",
        "CFFIXED_USER_HOME": str(root),
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
    }


def sandbox_command(root, harness, arguments):
    return [
        "/usr/bin/sandbox-exec",
        "-f",
        str(HERE / "isolation.sb"),
        "-D",
        "ROOT=" + str(root),
        "-D",
        "HARNESS=" + str(harness),
        str(harness),
        *arguments,
    ]


def isolation(root):
    harness = root / "original-query-harness"
    if not harness.is_file() or harness.is_symlink():
        raise ValueError("Build harness first")
    # This public canary is outside the allowed root; even if a profile fails,
    # the harness only opens it and never reads or writes its contents.
    fd, name = tempfile.mkstemp(prefix="oracle-outside-canary-", dir=root.parent)
    os.close(fd)
    canary = Path(name)
    try:
        with (
            (root / "isolation.stdout").open("w") as out,
            (root / "isolation.stderr").open("w") as err,
        ):
            result = subprocess.run(
                sandbox_command(root, harness, ["--self-test", str(root), str(canary)]),
                stdout=out,
                stderr=err,
                env=environment(root),
                cwd=root,
                timeout=45,
            )
        report = {
            "exit": result.returncode,
            "original_loaded": False,
            "harness_sha256": sha(harness),
            "profile_sha256": sha(HERE / "isolation.sb"),
            "stdout": (root / "isolation.stdout").read_text(),
            "stderr": (root / "isolation.stderr").read_text(),
        }
        try:
            value = json.loads(report["stdout"])
        except ValueError:
            value = {}
        report["passed"] = result.returncode == 0 and value == {
            "isolation": True,
            "metal": True,
            "original_loaded": False,
        }
        (root / "isolation-report.json").write_text(json.dumps(report, indent=2))
        if not report["passed"]:
            raise RuntimeError(
                "Isolation/Metal canaries failed; original loading remains blocked. "
                "See private isolation-report.json"
            )
        return report
    finally:
        canary.unlink()


def bundle_copy(data):
    """Experimental owned-image conversion. Does not run dyld or any target code."""
    result = bytearray(data)
    if len(result) < 32:
        raise ValueError("Truncated Mach-O header")
    magic, cpu, _, filetype, count, size, flags, _ = struct.unpack_from("<8I", result)
    if magic != 0xFEEDFACF or cpu != 0x100000C or filetype != 2:
        raise ValueError("Expected pinned arm64 MH_EXECUTE")
    if 32 + size > len(result) or count > size // 8:
        raise ValueError("Invalid Mach-O command table bounds")
    position, commands, removed, segments, dyld_infos = 32, [], [], [], []
    for _ in range(count):
        command, length = struct.unpack_from("<II", result, position)
        if length < 8 or length % 8 or position + length > 32 + size:
            raise ValueError("Invalid Mach-O load commands")
        block = bytes(result[position : position + length])
        pagezero = command == 0x19 and block[8:24].rstrip(b"\0") == b"__PAGEZERO"
        if command == 0x19:
            if length < 72:
                raise ValueError("Truncated segment command")
            vmaddr, vmsize = struct.unpack_from("<QQ", block, 24)
            nsects = struct.unpack_from("<I", block, 64)[0]
            if length != 72 + nsects * 80:
                raise ValueError("Invalid segment section table")
            for index in range(nsects):
                if struct.unpack_from("<I", block, 72 + index * 80 + 60)[0]:
                    raise ValueError("Section relocation tables are unsupported")
            initprot = struct.unpack_from("<I", block, 60)[0]
            segments.append(dict(vmaddr=vmaddr, vmsize=vmsize, initprot=initprot))
            if pagezero and (
                len(segments) != 1 or struct.unpack_from("<I", block, 64)[0]
            ):
                raise ValueError("PAGEZERO must be first and have no sections")
        if command in (0x22, 0x80000022):
            if length != 48:
                raise ValueError("Invalid dyld info command")
            dyld_infos.append(struct.unpack_from("<12I", block))
        if command == 0x80000034:
            raise ValueError("Chained fixups are unsupported for segment removal")
        if command == 0x1E:
            if length != 16:
                raise ValueError("Invalid segment split info command")
            if struct.unpack_from("<I", block, 12)[0]:
                raise ValueError(
                    "Segment split info is unsupported for segment removal"
                )
        if command == 0xB:
            if length != 80:
                raise ValueError("Invalid dynamic symbol command")
            fields = struct.unpack_from("<20I", block)
            if fields[17] or fields[19]:
                raise ValueError("External/local relocation tables are unsupported")
        if command in (0xE, 0x80000028) or pagezero:
            removed.append(command)  # LC_LOAD_DYLINKER, LC_MAIN, __PAGEZERO.
        else:
            commands.append(block)
        position += length
    if (
        removed.count(0xE) != 1
        or removed.count(0x80000028) != 1
        or removed.count(0x19) != 1
    ):
        raise ValueError("Pinned executable load commands changed")
    if position != 32 + size or len(dyld_infos) > 1:
        raise ValueError("Inconsistent or duplicate dyld load commands")
    # VM addresses, section ordinals and export offsets remain unchanged. Only
    # the segment selections inside the four legacy opcode streams move down.
    ranges: list[Any] = []
    for info in dyld_infos:
        for kind, index in [("rebase", 2), ("bind", 4), ("weak", 6), ("lazy", 8)]:
            offset, length = info[index : index + 2]
            if not length:
                continue
            if offset < 32 + size or offset + length > len(result):
                raise ValueError("Dyld opcode stream outside file bounds")
            if any(offset < end and offset + length > start for start, end in ranges):
                raise ValueError("Overlapping dyld opcode streams")
            ranges.append((offset, offset + length))
            patched, _ = _fixups.remap_stream(
                bytes(result[offset : offset + length]), kind, segments
            )
            result[offset : offset + length] = patched
    packed = b"".join(commands)
    result[32 : 32 + size] = packed + bytes(size - len(packed))
    struct.pack_into("<I", result, 12, 8)  # MH_BUNDLE
    struct.pack_into("<III", result, 16, len(commands), len(packed), flags & ~0x200000)
    return bytes(result)


def prepare(root, model):
    isolation(root)  # Fail closed before copying or modifying original code.
    if (root / "receipt.json").exists() or (root / "image").exists():
        raise ValueError("Use a new private root; existing preparation is preserved")
    source = APP / "Contents/MacOS/Foresight"
    with (APP / "Contents/Info.plist").open("rb") as handle:
        identity = plistlib.load(handle).get("CFBundleIdentifier")
    if identity != "com.google.AIEdgeForesight" or sha(source) != APP_SHA:
        raise ValueError("Original application identity/digest mismatch")
    model = model.resolve(strict=True)
    if model.stat().st_size != 179437568 or sha(model) != MODEL_SHA:
        raise ValueError("Already-decrypted dedicated model digest mismatch")
    # No keychain/config/decryption discovery exists in this tool.
    image_dir = root / "image"
    (image_dir / "MacOS").mkdir(parents=True, mode=0o700)
    (image_dir / "Frameworks").mkdir(mode=0o700)
    image = image_dir / "MacOS/Foresight.bundle"
    image.write_bytes(bundle_copy(source.read_bytes()))
    image.chmod(0o700)
    shutil.copytree(
        APP / "Contents/Frameworks/FlutterMacOS.framework",
        image_dir / "Frameworks/FlutterMacOS.framework",
        symlinks=True,
    )
    # Explicit owned framework path: @executable_path points to the harness.
    subprocess.run(
        [
            "/usr/bin/install_name_tool",
            "-add_rpath",
            str(image_dir / "Frameworks"),
            str(image),
        ],
        check=True,
        timeout=300,
    )
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(image)],
        check=True,
        timeout=300,
    )
    fixture = root / "detector.tflite"
    shutil.copyfile(model, fixture)
    fixture.chmod(0o600)
    receipt = {
        "original_sha256": APP_SHA,
        "model_sha256": sha(fixture),
        "owned_image_sha256": sha(image),
        "original_loaded": False,
        "harness_sha256": sha(root / "original-query-harness"),
        "profile_sha256": sha(HERE / "isolation.sb"),
    }
    (root / "receipt.json").write_text(json.dumps(receipt, indent=2))
    return receipt


def run(root, prompt):
    isolation(root)
    receipt = json.loads((root / "receipt.json").read_text())
    if receipt["original_sha256"] != APP_SHA or receipt["model_sha256"] != MODEL_SHA:
        raise ValueError("Preparation receipt identity mismatch")
    if receipt["harness_sha256"] != sha(root / "original-query-harness") or receipt[
        "profile_sha256"
    ] != sha(HERE / "isolation.sb"):
        raise ValueError("Harness/profile changed; prepare a new private root")
    fixture = root / "prompt.txt"
    fixture.write_text(prompt)
    fixture.chmod(0o600)
    fd, name = tempfile.mkstemp(prefix="oracle-outside-canary-", dir=root.parent)
    os.close(fd)
    try:
        arguments = [
            "--run",
            str(root),
            name,
            str(root / "image/MacOS/Foresight.bundle"),
            receipt["owned_image_sha256"],
            str(root / "detector.tflite"),
            str(fixture),
        ]
        with (
            (root / "answer.txt").open("w") as out,
            (root / "run.stderr").open("w") as err,
        ):
            result = subprocess.run(
                sandbox_command(root, root / "original-query-harness", arguments),
                env=environment(root),
                cwd=root,
                stdout=out,
                stderr=err,
                timeout=90,
            )
        (root / "run-report.json").write_text(
            json.dumps(
                {
                    "exit": result.returncode,
                    "original_loaded_attempted": True,
                    "answer_sha256": sha(root / "answer.txt"),
                },
                indent=2,
            )
        )
        if result.returncode:
            raise RuntimeError("Controlled oracle failed; inspect private run.stderr")
    finally:
        Path(name).unlink()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation", choices=["build", "check-isolation", "prepare", "run"]
    )
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--model", type=Path)
    parser.add_argument(
        "--prompt",
        default=" <ctrl1>We will review the launch tomorrow. What is the launch date?",
    )
    args = parser.parse_args()
    root = private_root(args.root)
    if args.operation == "build":
        build(root)
    elif args.operation == "check-isolation":
        isolation(root)
    elif args.operation == "prepare":
        if args.model is None:
            parser.error("prepare requires an already-decrypted --model")
        prepare(root, args.model)
    else:
        run(root, args.prompt)
    print(json.dumps({"operation": args.operation, "root": str(root), "ok": True}))


if __name__ == "__main__":
    main()
