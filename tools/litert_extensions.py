"""Verify explicitly selected source-built LiteRT-LM release artifacts."""

from dataclasses import dataclass
from email.parser import BytesParser
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LITERT_VERSION = json.loads(Path(__file__).with_name("pins.json").read_text())[
    "litert_lm"
]
UPSTREAM_COMMIT = "b2f686e2ed4718fb84ec398a61dd59ca0f0aff27"
PATCH = ROOT / "third_party/litert_lm/stop-token-sequences.patch"
MACOS_ABI_PATCH = ROOT / "third_party/litert_lm/macos-trivial-abi.patch"
LINUX_ABI_PATCH = ROOT / "third_party/litert_lm/linux-trivial-abi.patch"
NATIVE_TEST = "EngineCTest.AppendStopTokenSequencesBeforeConversationConfigCopy"
LINUX_VENDOR_LIBRARIES = (
    "libGemmaModelConstraintProvider.so",
    "libLiteRt.so",
    "libLiteRtWebGpuAccelerator.so",
    "libLiteRtTopKWebGpuSampler.so",
    "libwebgpu_dawn.so",
)
MACOS_VENDOR_LIBRARIES = (
    "libGemmaModelConstraintProvider.dylib",
    "libLiteRt.dylib",
    "libLiteRtWebGpuAccelerator.dylib",
    "libLiteRtTopKWebGpuSampler.dylib",
    "libwebgpu_dawn.dylib",
    "libLiteRtMetalAccelerator.dylib",
    "libLiteRtTopKMetalSampler.dylib",
)
FORBIDDEN_LINUX_STDLIBS = (
    "libstdc++.so",
    "libc++.so",
    "libc++abi.so",
    "libunwind.so",
    "libunwind-",
)
REQUIRED_C_EXPORTS = (
    "litert_lm_engine_create",
    "litert_lm_embedding_engine_create",
    "litert_lm_session_config_add_stop_token_sequence",
)


def file_sha256(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def _artifact(parent, manifest, name):
    value = manifest.get(name)
    if (
        not isinstance(value, str)
        or value in ("", ".", "..")
        or Path(value).name != value
        or "/" in value
        or "\\" in value
    ):
        raise ValueError(f"Invalid LiteRT extension {name} filename")
    path = (parent / value).resolve(strict=True)
    if path.parent != parent:
        raise ValueError(f"LiteRT extension {name} escapes its manifest directory")
    if file_sha256(path) != manifest.get(name + "_sha256"):
        raise ValueError(f"LiteRT extension {name} checksum mismatch")
    return path


def _wheel_entries(archive):
    seen = set()
    for entry in archive.infolist():
        path = PurePosixPath(entry.filename)
        if (
            path.is_absolute()
            or ".." in path.parts
            or "\\" in entry.filename
            or path.as_posix() != entry.filename.rstrip("/")
            or entry.filename in seen
            or stat.S_ISLNK(entry.external_attr >> 16)
        ):
            raise ValueError("Unsafe or duplicate LiteRT extension wheel entry")
        if not path.parts or path.parts[0] not in (
            "litert_lm",
            f"litert_lm_api-{LITERT_VERSION}.dist-info",
        ):
            raise ValueError("Unexpected LiteRT extension wheel destination")
        seen.add(entry.filename)
    return seen


@dataclass(frozen=True)
class VerifiedExtensions:
    manifest: dict
    wheel: Path
    library: Path
    library_entry: str


def verify_extensions_manifest(path, *, platform_name):
    path = Path(path).resolve(strict=True)
    manifest = json.loads(path.read_text())
    if not isinstance(manifest, dict):
        raise ValueError("LiteRT extension manifest must be an object")
    if (
        manifest.get("upstream_commit") != UPSTREAM_COMMIT
        or manifest.get("patch_sha256") != file_sha256(PATCH)
        or manifest.get("distribution") != "litert-lm-api"
        or manifest.get("version") != LITERT_VERSION
    ):
        raise ValueError("LiteRT extension source, patch or version is not pinned")
    if platform_name == "darwin":
        if manifest.get("macos_abi_patch_sha256") != file_sha256(MACOS_ABI_PATCH):
            raise ValueError(
                "LiteRT extension macOS accelerator ABI patch is not pinned"
            )
        if manifest.get("linux_abi_patch_sha256") is not None:
            raise ValueError(
                "Linux accelerator ABI patch cannot describe a macOS build"
            )
    elif platform_name == "linux":
        if manifest.get("macos_abi_patch_sha256") is not None:
            raise ValueError(
                "macOS accelerator ABI patch cannot describe a Linux build"
            )
        if manifest.get("linux_abi_patch_sha256") != file_sha256(LINUX_ABI_PATCH):
            raise ValueError(
                "LiteRT extension Linux accelerator ABI patch is not pinned"
            )
    else:
        raise ValueError("Unsupported LiteRT extension release platform")
    abi_report = json.loads(
        _artifact(path.parent, manifest, "native_status_abi_report").read_text()
    )
    if (
        abi_report.get("status") != "passed"
        or abi_report.get("exit_code") != 0
        or abi_report.get("stdout", "").strip() != "vendor_register_return_callback_ok"
    ):
        raise ValueError("LiteRT extension Status callback ABI regression did not pass")
    export_text = _artifact(path.parent, manifest, "native_export_log").read_text()
    if platform_name == "darwin":
        symbols = set(export_text.splitlines())
        required_macos = {"_" + name for name in REQUIRED_C_EXPORTS}
        if not required_macos <= symbols or any(
            not name.startswith("_litert_lm_") for name in symbols
        ):
            raise ValueError("LiteRT extension macOS export report is invalid")
    else:
        _, separator, export_symbols = export_text.partition(
            "\nDefined dynamic exports:\n"
        )
        symbols = set(export_symbols.splitlines())
        loader_symbols = {"_init", "_fini", "__bss_start", "_edata", "_end"}
        if (
            not separator
            or not set(REQUIRED_C_EXPORTS) <= symbols
            or any(
                not re.fullmatch(r"litert_lm_[A-Za-z0-9_]+", name)
                and name not in loader_symbols
                for name in symbols
            )
            or any(
                token in export_text
                for token in (*FORBIDDEN_LINUX_STDLIBS, "GLIBCXX_", "CXXABI_")
            )
        ):
            raise ValueError("LiteRT extension Linux export/ABI report is invalid")
    wheel = _artifact(path.parent, manifest, "wheel")
    library = _artifact(path.parent, manifest, "library")
    test_log = _artifact(path.parent, manifest, "native_test_log")
    log = test_log.read_text()
    if (
        "[ RUN      ] " + NATIVE_TEST not in log
        or "[       OK ] " + NATIVE_TEST not in log
    ):
        raise ValueError("LiteRT extension native config-copy regression did not pass")
    if platform_name == "darwin":
        library_name, tag = "liblitert-lm.dylib", "py3-none-macosx_12_0_arm64"
    else:
        library_name, tag = "liblitert-lm.so", "py3-none-manylinux_2_27_x86_64"
    if library.name != library_name:
        raise ValueError("LiteRT extension library does not match the release platform")
    library_entry = "litert_lm/" + library_name
    with zipfile.ZipFile(wheel) as archive:
        entries = _wheel_entries(archive)
        metadata_name = f"litert_lm_api-{LITERT_VERSION}.dist-info/METADATA"
        wheel_metadata = f"litert_lm_api-{LITERT_VERSION}.dist-info/WHEEL"
        if (
            not {metadata_name, wheel_metadata, library_entry, "litert_lm/engine.py"}
            <= entries
        ):
            raise ValueError("Incomplete LiteRT extension API wheel")
        metadata = BytesParser().parsebytes(archive.read(metadata_name))
        if metadata["Name"] != "litert-lm-api" or metadata["Version"] != LITERT_VERSION:
            raise ValueError(
                f"LiteRT extension wheel metadata does not match {LITERT_VERSION}"
            )
        tags = BytesParser().parsebytes(archive.read(wheel_metadata)).get_all("Tag", [])
        if tags != [tag]:
            raise ValueError(
                "LiteRT extension wheel platform does not match this release"
            )
        required_vendors = (
            MACOS_VENDOR_LIBRARIES
            if platform_name == "darwin"
            else LINUX_VENDOR_LIBRARIES
        )
        vendor_hashes = manifest.get("vendor_libraries")
        if not isinstance(vendor_hashes, dict) or set(vendor_hashes) != set(
            required_vendors
        ):
            raise ValueError(
                "LiteRT extension manifest lacks the complete GPU runtime closure"
            )
        for name in required_vendors:
            entry = "litert_lm/" + name
            if entry not in entries or archive.getinfo(entry).file_size == 0:
                raise ValueError(
                    "LiteRT extension wheel lacks required GPU dependency: " + name
                )
            vendor_hash = hashlib.sha256()
            with archive.open(entry) as stream:
                first = stream.read(128)
                if first.startswith(b"version https://git-lfs.github.com/spec/v1\n"):
                    raise ValueError(
                        "LiteRT extension wheel contains a Git LFS pointer: " + name
                    )
                vendor_hash.update(first)
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    vendor_hash.update(chunk)
            if vendor_hash.hexdigest() != vendor_hashes[name]:
                raise ValueError(
                    "LiteRT extension GPU dependency checksum mismatch: " + name
                )
        native_hash = hashlib.sha256()
        with archive.open(library_entry) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                native_hash.update(chunk)
        if native_hash.hexdigest() != manifest["library_sha256"]:
            raise ValueError("LiteRT extension wheel/native library checksum mismatch")
    return VerifiedExtensions(manifest, wheel, library, library_entry)


def install_extension_wheel(
    bundle, *, site_packages, source_prefix, destination_prefix
):
    """Overlay only the already-copied standalone runtime, never its source."""
    source = Path(source_prefix).resolve(strict=True)
    destination = Path(destination_prefix).resolve(strict=True)
    target = Path(site_packages).resolve(strict=True)
    if (
        source == destination
        or source.is_relative_to(destination)
        or destination.is_relative_to(source)
        or not target.is_relative_to(destination)
    ):
        raise ValueError(
            "LiteRT extension installation requires an isolated copied prefix"
        )
    # Recheck at the mutation boundary, including archive paths and symlinks.
    if file_sha256(bundle.wheel) != bundle.manifest["wheel_sha256"]:
        raise ValueError("LiteRT extension wheel changed after verification")
    with zipfile.ZipFile(bundle.wheel) as archive:
        _wheel_entries(archive)
        for entry in archive.infolist():
            output = target.joinpath(*PurePosixPath(entry.filename).parts)
            if not output.resolve().is_relative_to(target):
                raise ValueError(
                    "LiteRT extension wheel target escapes the copied prefix"
                )
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True)
                continue
            output.parent.mkdir(parents=True, exist_ok=True)
            with (
                archive.open(entry) as input_stream,
                output.open("wb") as output_stream,
            ):
                shutil.copyfileobj(input_stream, output_stream)


PYTHON_CAPABILITY_PROBE = r"""
import ctypes, inspect, json, signal, sys
from pathlib import Path
import litert_lm
from litert_lm._ffi import _get_lib
# A real initialized SentencePiece processor reproduces the native protobuf
# symbol-coalescing deadlock; importing the Python modules alone does not.
# Bound this model-free child probe even if dlopen blocks in native code.
signal.alarm(15)
if '--native-first' in sys.argv:
    _get_lib()
import sentencepiece
processor = sentencepiece.SentencePieceProcessor(
    model_proto=b'\x0a\x09\x0a\x05<unk>\x18\x02\x0a\x05\x0a\x01a\x18\x01')
if processor.get_piece_size() != 2:
    raise RuntimeError('SentencePiece co-load fixture did not initialize')
prefix = Path(sys.executable).resolve().parents[1]
lib = _get_lib()
if not Path(litert_lm.__file__).resolve().is_relative_to(prefix):
    raise RuntimeError('LiteRT API escaped the bundled Python prefix')
if not Path(lib._name).resolve().is_relative_to(prefix):
    raise RuntimeError('LiteRT native library escaped the bundled Python prefix')
if 'stop_token_ids' not in inspect.signature(litert_lm.Engine.create_conversation).parameters:
    raise RuntimeError('Bundled LiteRT Python API lacks native stop-token sequences')
setter = lib.litert_lm_session_config_add_stop_token_sequence
setter.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32), ctypes.c_size_t]
setter.restype = ctypes.c_int
config = lib.litert_lm_session_config_create()
if not config:
    raise RuntimeError('Cannot create bundled LiteRT session config')
try:
    if setter(config, (ctypes.c_int32 * 2)(1, 2), 2):
        raise RuntimeError('Bundled LiteRT native stop-token setter failed')
finally:
    lib.litert_lm_session_config_delete(config)
print(json.dumps({'native_stop_token_sequences': True}))
"""


def probe_python_extensions(python, run):
    value = json.loads(run(python, "-I", "-c", PYTHON_CAPABILITY_PROBE))
    if value != {"native_stop_token_sequences": True}:
        raise ValueError("Bundled LiteRT native stop-token capability probe failed")


def probe_native_extensions(library):
    """Build-time Linux check through the documented extension C ABI."""
    lib = ctypes.CDLL(str(Path(library).resolve(strict=True)))
    create = lib.litert_lm_session_config_create
    create.argtypes, create.restype = [], ctypes.c_void_p
    delete = lib.litert_lm_session_config_delete
    delete.argtypes, delete.restype = [ctypes.c_void_p], None
    setter = lib.litert_lm_session_config_add_stop_token_sequence
    setter.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32), ctypes.c_size_t]
    setter.restype = ctypes.c_int
    config = create()
    if not config:
        raise ValueError("Cannot create native LiteRT session config")
    try:
        if setter(config, (ctypes.c_int32 * 2)(1, 2), 2):
            raise ValueError("Native LiteRT stop-token capability probe failed")
    finally:
        delete(config)


def _require_linux_x86_64(path):
    with Path(path).open("rb") as stream:
        header = stream.read(20)
    if (
        len(header) != 20
        or header[:6] != b"\x7fELF\x02\x01"
        or header[18:20] != b"\x3e\x00"
    ):
        raise ValueError(
            "LiteRT extension dependency must be a Linux x86_64 ELF library"
        )


def copy_linux_extension_dependencies(bundle, destination):
    """Copy only the pinned vendor payloads from the checksum-verified wheel."""
    destination = Path(destination).resolve(strict=True)
    if bundle.library_entry != "litert_lm/liblitert-lm.so":
        raise ValueError("A Linux API wheel is required for Linux dependencies")
    if file_sha256(bundle.wheel) != bundle.manifest["wheel_sha256"]:
        raise ValueError("LiteRT extension wheel changed after verification")
    native = destination / "liblitert-lm.so"
    if file_sha256(native) != bundle.manifest["library_sha256"]:
        raise ValueError("Copied LiteRT extension native library checksum mismatch")
    _require_linux_x86_64(native)
    copied = []
    with zipfile.ZipFile(bundle.wheel) as archive:
        entries = _wheel_entries(archive)
        for name in LINUX_VENDOR_LIBRARIES:
            entry = "litert_lm/" + name
            if entry not in entries:
                raise ValueError(
                    "LiteRT extension wheel lacks pinned dependency: " + name
                )
        for name in LINUX_VENDOR_LIBRARIES:
            output = destination / name
            if output.resolve().parent != destination:
                raise ValueError(
                    "LiteRT extension dependency escapes the bundle lib directory"
                )
            temporary = output.with_suffix(".so.part")
            with (
                archive.open("litert_lm/" + name) as source,
                temporary.open("wb") as target,
            ):
                shutil.copyfileobj(source, target)
            _require_linux_x86_64(temporary)
            temporary.replace(output)
            copied.append(output)
    return [native, *copied]


def validate_linux_extension_dependencies(libraries, destination):
    destination = Path(destination).resolve(strict=True)
    environment = dict(os.environ, LD_LIBRARY_PATH=str(destination))
    output = subprocess.check_output(
        ["ldd", *map(str, libraries)], text=True, env=environment, timeout=300
    )
    if "not found" in output:
        raise ValueError("LiteRT extension has missing bundled dependencies: " + output)
    pinned = {"liblitert-lm.so", *LINUX_VENDOR_LIBRARIES}
    system_roots = [
        Path(name).resolve() for name in ("/lib", "/lib64", "/usr/lib", "/usr/lib64")
    ]
    for name, location in re.findall(r"\s*(\S+) => (/\S+)", output):
        if name.startswith(FORBIDDEN_LINUX_STDLIBS):
            raise ValueError(
                "LiteRT extension must not dynamically link C++ standard library: "
                + name
            )
        path = Path(location).resolve()
        if name in pinned:
            if path != (destination / name).resolve():
                raise ValueError(
                    "LiteRT vendor dependency resolved outside the bundle: " + name
                )
        elif not path.is_relative_to(destination) and not any(
            path.is_relative_to(root) for root in system_roots
        ):
            raise ValueError(
                "LiteRT dependency is neither bundled nor a system library: " + location
            )
    return environment


def write_extension_provenance(bundle, destination):
    keys = (
        "upstream_commit",
        "patch_sha256",
        "distribution",
        "version",
        "wheel_sha256",
        "library_sha256",
        "native_test_log_sha256",
        "vendor_libraries",
        "macos_abi_patch_sha256",
        "linux_abi_patch_sha256",
        "native_status_abi_report_sha256",
        "native_export_log_sha256",
    )
    Path(destination).write_text(
        json.dumps(
            {key: bundle.manifest[key] for key in keys if key in bundle.manifest},
            indent=2,
        )
        + "\n"
    )


def copy_macos_extension_dependencies(bundle, destination):
    """Extract only native C API and vendor dylibs; never install Python code."""
    destination = Path(destination).resolve(strict=True)
    if bundle.library_entry != "litert_lm/liblitert-lm.dylib":
        raise ValueError("A macOS API wheel is required for macOS dependencies")
    if file_sha256(bundle.wheel) != bundle.manifest["wheel_sha256"]:
        raise ValueError("LiteRT extension wheel changed after verification")
    copied = []
    with zipfile.ZipFile(bundle.wheel) as archive:
        entries = _wheel_entries(archive)
        for name in ("liblitert-lm.dylib", *MACOS_VENDOR_LIBRARIES):
            entry = "litert_lm/" + name
            if entry not in entries:
                raise ValueError(
                    "LiteRT extension wheel lacks pinned dependency: " + name
                )
            output = destination / name
            if output.resolve().parent != destination:
                raise ValueError(
                    "LiteRT extension dependency escapes the bundle lib directory"
                )
            expected = (
                bundle.manifest["library_sha256"]
                if name == "liblitert-lm.dylib"
                else bundle.manifest["vendor_libraries"][name]
            )
            temporary = output.with_suffix(".dylib.part")
            try:
                with archive.open(entry) as source, temporary.open("wb") as target:
                    shutil.copyfileobj(source, target)
                if file_sha256(temporary) != expected:
                    raise ValueError(
                        "Copied LiteRT extension native library checksum mismatch"
                    )
                with temporary.open("rb") as stream:
                    header = stream.read(8)
                if header != b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01":
                    raise ValueError(
                        "LiteRT extension dependency must be a macOS arm64 Mach-O library"
                    )
                temporary.replace(output)
            finally:
                temporary.unlink(missing_ok=True)
            copied.append(output)
    return copied
