"""Build recipes exercise real file/receipt transitions at the compiler boundary.

No SDK is downloaded or compiled. Command doubles materialize tiny output files,
so reuse, provenance and failed-install behavior are checked independently.
"""

import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import Mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_macos_sdk as sdk
import build_macos_vendor as vendor
import build_macos_runtimes as runtimes
import build_sanitizer_sdk as sanitizer
import build_whisper_vulkan as vulkan


def put(path, content=b"fixture"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def sdk_fixture(tmp_path, monkeypatch, failure=None):
    prefix, sources = tmp_path / "sdk with spaces", tmp_path / "sources"
    required = (
        "bin/protoc",
        "bin/grpc_cpp_plugin",
        "lib/cmake/grpc/gRPCConfig.cmake",
        "share/cmake/nlohmann_json/nlohmann_jsonConfig.cmake",
    )
    commands = []

    def checkout(path, repository, commit):
        put(path / "LICENSE", (repository + commit).encode())
        if path.name == "grpc":
            for name in sdk.MODULES:
                put(path / "third_party" / name / "NOTICE")
                put(path / "third_party" / name / "source.cc")
            (path / "LICENSE.directory").mkdir(exist_ok=True)

    def run(*args, **kwargs):
        commands.append((tuple(map(str, args)), kwargs))
        if args[:2] == ("cmake", "--install") and failure != "incomplete":
            for relative in required:
                put(prefix / relative)

    def output(args, **kwargs):
        if args[0] == "git":
            return "wrong" if failure == "protobuf" else sdk.PROTOBUF_COMMIT
        if args[0] == "xcrun":
            return "minos 14.0" if failure == "target" else "minos 15.0\n"
        if args[0] == "otool":
            return (
                "/opt/homebrew/lib/libbad.dylib"
                if failure == "external"
                else "/usr/lib/libSystem.B.dylib"
            )
        return "libprotoc 35.1\n"

    monkeypatch.setattr(sdk.sys, "platform", "darwin")
    monkeypatch.setattr(sdk.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(sdk, "checkout", checkout)
    monkeypatch.setattr(sdk, "require_clean_sources", Mock())
    monkeypatch.setattr(sdk, "run", run)
    monkeypatch.setattr(sdk.subprocess, "check_output", output)
    monkeypatch.setattr(
        sys,
        "argv",
        ["sdk", "--prefix", str(prefix), "--sources", str(sources), "--jobs", "2"],
    )
    return prefix, sources, commands


def test_macos_sdk_build_records_identity_and_reuses_without_compilation(
    tmp_path, monkeypatch
):
    prefix, sources, commands = sdk_fixture(tmp_path, monkeypatch)
    for key in (
        "CMAKE_PREFIX_PATH",
        "PKG_CONFIG_PATH",
        "CPATH",
        "LIBRARY_PATH",
        "CPLUS_INCLUDE_PATH",
        "LDFLAGS",
        "CPPFLAGS",
    ):
        monkeypatch.setenv(key, "/untrusted/homebrew")
    sdk.main()
    receipt = json.loads((prefix / "foresight-sdk.json").read_text())
    assert receipt["protobuf_commit"] == sdk.PROTOBUF_COMMIT
    assert receipt["static"] is True
    assert receipt["minimum_macos"] == "15.0"
    assert len(list((prefix / "share/foresight-sdk/licenses").iterdir())) == 7
    configure = [item for item in commands if item[0][:2] == ("cmake", "-S")]
    assert len(configure) == 2
    for command, options in configure:
        assert "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0" in command
        assert options["env"]["MACOSX_DEPLOYMENT_TARGET"] == "15.0"
        assert "CPATH" not in options["env"]
        assert "LDFLAGS" not in options["env"]
    assert (sources / "sdk-project.cmake").is_file()
    commands.clear()
    sdk.main()
    assert commands == []
    (prefix / "bin/protoc").unlink()
    sdk.main()
    assert commands  # An incomplete install cannot qualify as a cache hit.


@pytest.mark.parametrize(
    "failure,message",
    [
        ("protobuf", "gitlink"),
        ("target", "deployment target"),
        ("external", "External runtime"),
        ("incomplete", "incomplete"),
    ],
)
def test_macos_sdk_never_stamps_unverified_install(
    tmp_path, monkeypatch, failure, message
):
    prefix, _, _ = sdk_fixture(tmp_path, monkeypatch, failure)
    with pytest.raises(RuntimeError, match=message):
        sdk.main()
    assert not (prefix / "foresight-sdk.json").exists()


def test_macos_sdk_rejects_foreign_stamp_before_build(tmp_path, monkeypatch):
    prefix, _, commands = sdk_fixture(tmp_path, monkeypatch)
    put(prefix / "foresight-sdk.json", b"{}")
    with pytest.raises(SystemExit, match="2"):
        sdk.main()
    assert not commands


@pytest.mark.parametrize(
    "system,machine,jobs",
    [("linux", "arm64", "2"), ("darwin", "x86_64", "2"), ("darwin", "arm64", "0")],
)
def test_sdk_platform_and_job_validation(monkeypatch, system, machine, jobs):
    monkeypatch.setattr(sdk.sys, "platform", system)
    monkeypatch.setattr(sdk.platform, "machine", lambda: machine)
    monkeypatch.setattr(sys, "argv", ["sdk", "--jobs", jobs])
    with pytest.raises(SystemExit, match="2"):
        sdk.main()


@pytest.mark.parametrize("present", [False, True])
def test_sdk_checkout_fetches_only_missing_revision(tmp_path, monkeypatch, present):
    path = tmp_path / "checkout"
    if present:
        (path / ".git").mkdir(parents=True)
    command = Mock()
    monkeypatch.setattr(sdk, "run", command)
    monkeypatch.setattr(sdk, "require_clean_sources", Mock())
    monkeypatch.setattr(
        sdk.subprocess,
        "check_output",
        lambda *a, **kw: "https://example.invalid/repo\n",
    )
    monkeypatch.setattr(
        sdk.subprocess,
        "run",
        lambda *a, **kw: subprocess.CompletedProcess(a, 0 if present else 1),
    )
    sdk.checkout(path, "https://example.invalid/repo", "a" * 40)
    calls = [tuple(map(str, c.args)) for c in command.call_args_list]
    assert any("fetch" in c for c in calls) is not present
    assert calls[-1][-3:] == ("checkout", "--detach", "a" * 40)


def test_vendor_download_retains_verified_bytes_on_corrupt_replacement(
    tmp_path, monkeypatch
):
    destination = put(tmp_path / "bazel", b"old verified binary")
    monkeypatch.setattr(
        vendor.urllib.request, "urlopen", lambda *a, **kw: io.BytesIO(b"corrupt")
    )
    with pytest.raises(ValueError, match="checksum"):
        vendor.download("https://example.invalid/tool", destination, "0" * 64)
    assert destination.read_bytes() == b"old verified binary"
    assert not destination.with_suffix(".download").exists()
    expected = hashlib.sha256(b"corrupt").hexdigest()
    vendor.download("https://example.invalid/tool", destination, expected)
    assert destination.read_bytes() == b"corrupt"
    monkeypatch.setattr(
        vendor.urllib.request,
        "urlopen",
        Mock(side_effect=AssertionError("unnecessary download")),
    )
    vendor.download("https://example.invalid/tool", destination, expected)


def test_vendor_checkout_pins_revision_and_disables_lfs_smudge(tmp_path, monkeypatch):
    command = Mock()
    monkeypatch.setattr(vendor, "run", command)
    monkeypatch.setattr(
        vendor.subprocess, "check_output", lambda *a, **kw: vendor.WHISPER_COMMIT
    )
    vendor.checkout(
        tmp_path / "whisper", "https://example.invalid/whisper", vendor.WHISPER_COMMIT
    )
    assert command.call_args.kwargs["env"]["GIT_LFS_SKIP_SMUDGE"] == "1"
    monkeypatch.setattr(vendor.subprocess, "check_output", lambda *a, **kw: "wrong")
    with pytest.raises(ValueError, match="revision"):
        vendor.checkout(
            tmp_path, "https://example.invalid/whisper", vendor.WHISPER_COMMIT
        )


def vendor_fixture(tmp_path, monkeypatch, existing_extensions=False):
    prefix, sources = tmp_path / "vendor", tmp_path / "sources"
    commands = []
    monkeypatch.setattr(vendor.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(vendor.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(vendor, "download", lambda url, path, expected: put(path))
    monkeypatch.setattr(vendor, "checkout", lambda path, *a: put(path / "LICENSE"))
    monkeypatch.setattr(vendor, "verify_extensions_manifest", Mock())
    monkeypatch.setattr(vendor.subprocess, "check_output", lambda *a, **kw: b"")
    if existing_extensions:
        put(prefix / "litert-extensions/build-manifest.json", b"{}")

    def run(*args, **kwargs):
        commands.append(tuple(map(str, args)))
        if args[:2] == ("cmake", "--build"):
            put(sources / "whisper-build/bin/whisper-cli", b"whisper binary")
        if args[:2] == ("cmake", "--install"):
            for relative in (
                "include/whisper.h",
                "lib/libwhisper.a",
                "lib/cmake/whisper/whisper-config.cmake",
                "lib/cmake/ggml/ggml-config.cmake",
            ):
                put(prefix / "whisper-sdk" / relative)

    monkeypatch.setattr(vendor, "run", run)
    monkeypatch.setattr(
        sys, "argv", ["vendor", "--prefix", str(prefix), "--sources", str(sources)]
    )
    return prefix, sources, commands


@pytest.mark.parametrize("extensions", [False, True])
def test_vendor_build_preserves_extensions_and_reuses_verified_install(
    tmp_path, monkeypatch, extensions
):
    prefix, _, commands = vendor_fixture(tmp_path, monkeypatch, extensions)
    vendor.main()
    assert (
        json.loads((prefix / "vendor-manifest.json").read_text())["whisper_sha256"]
        == hashlib.sha256(b"whisper binary").hexdigest()
    )
    assert any("shutdown" in c for c in commands) is not extensions
    commands.clear()
    vendor.main()
    assert commands == [(str(prefix / "whisper/whisper-cli"), "--help")]


@pytest.mark.parametrize("problem", ["identity", "checksum", "missing-sdk"])
def test_vendor_verify_rejects_stale_corrupt_and_incomplete_cache(
    tmp_path, monkeypatch, problem
):
    prefix, _, _ = vendor_fixture(tmp_path, monkeypatch)
    vendor.main()
    stamp = prefix / "vendor-manifest.json"
    if problem == "identity":
        data = json.loads(stamp.read_text())
        data["inference_runtime"] = "obsolete"
        stamp.write_text(json.dumps(data))
    elif problem == "checksum":
        (prefix / "whisper/whisper-cli").write_bytes(b"corrupt")
    else:
        (prefix / "whisper-sdk/include/whisper.h").unlink()
    with pytest.raises(ValueError):
        vendor.verify(prefix)


def test_vendor_verification_failure_removes_only_completion_stamp(
    tmp_path, monkeypatch
):
    prefix, sources, _ = vendor_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(vendor, "verify", Mock(side_effect=ValueError("bad install")))
    with pytest.raises(ValueError, match="bad install"):
        vendor.main()
    assert not (prefix / "vendor-manifest.json").exists()
    assert (sources / "whisper-build/bin/whisper-cli").exists()


def test_vendor_dirty_sources_and_unsupported_host_fail_before_build(
    tmp_path, monkeypatch
):
    prefix, _, commands = vendor_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(
        vendor.subprocess, "check_output", lambda *a, **kw: b" M source.cc"
    )
    with pytest.raises(ValueError, match="clean"):
        vendor.main()
    assert not any(c[:2] == ("cmake", "--build") for c in commands)
    assert not (prefix / "vendor-manifest.json").exists()
    monkeypatch.setattr(vendor.platform, "system", lambda: "Linux")
    with pytest.raises(SystemExit, match="2"):
        vendor.main()


def runtime_fixture(tmp_path, monkeypatch):
    prefix, source = tmp_path / "runtime", tmp_path / "vendor"
    put(source / "whisper/whisper-cli", b"cli")
    put(source / "litert-extensions/build-manifest.json", b"{}")
    monkeypatch.setattr(runtimes, "verify_vendor", Mock())
    monkeypatch.setattr(runtimes, "verify_extensions_manifest", Mock())
    calls = []

    def run(*args, **kwargs):
        calls.append(tuple(map(str, args)))
        if args[:2] == ("cmake", "--build"):
            put(prefix / "worker-build/bin/foresight-whisper-worker", b"worker")

    monkeypatch.setattr(runtimes, "run", run)
    monkeypatch.setattr(
        sys,
        "argv",
        ["runtime", "--prefix", str(prefix), "--vendor-prefix", str(source)],
    )
    return prefix, calls


def test_runtime_assembly_reuses_vendor_and_checks_copied_bytes(tmp_path, monkeypatch):
    prefix, calls = runtime_fixture(tmp_path, monkeypatch)
    runtimes.main()
    data = json.loads((prefix / "runtime-manifest.json").read_text())
    assert data["whisper_worker_sha256"] == hashlib.sha256(b"worker").hexdigest()
    assert not (prefix / "worker-build").exists()
    calls.clear()
    runtimes.main()
    assert calls == [(str(prefix / "whisper/whisper-cli"), "--help")]
    (prefix / "whisper/foresight-whisper-worker").write_bytes(b"broken")
    with pytest.raises(ValueError, match="checksum"):
        runtimes.main()
    data["inference_runtime"] = "obsolete"
    (prefix / "runtime-manifest.json").write_text(json.dumps(data))
    with pytest.raises(ValueError, match="Stale"):
        runtimes.verify(prefix)


def test_runtime_failure_retains_vendor_and_removes_stamp(tmp_path, monkeypatch):
    prefix, _ = runtime_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(runtimes, "verify", Mock(side_effect=ValueError("bad worker")))
    with pytest.raises(ValueError, match="bad worker"):
        runtimes.main()
    assert not (prefix / "runtime-manifest.json").exists()
    assert (tmp_path / "vendor/whisper/whisper-cli").read_bytes() == b"cli"


@pytest.mark.parametrize("kind", ["address", "thread"])
def test_sanitizer_sdk_identity_flags_runtime_and_reuse(tmp_path, monkeypatch, kind):
    prefix, sources = tmp_path / "sdk", tmp_path / "sources"
    calls = []
    monkeypatch.setenv("LD_LIBRARY_PATH", "/previous/lib")
    monkeypatch.setattr(
        sanitizer, "address_runtime", lambda **kw: tmp_path / "clang/lib/runtime.so"
    )
    monkeypatch.setattr(sanitizer, "checkout", Mock())
    monkeypatch.setattr(sanitizer, "require_clean_sources", Mock())
    monkeypatch.setattr(
        sanitizer.subprocess,
        "check_output",
        lambda a, **kw: (
            "clang version fixture\n"
            if a[0] == "clang++"
            else sanitizer.PROTOBUF_COMMIT
        ),
    )

    def run(*args, **kwargs):
        calls.append((tuple(map(str, args)), kwargs))
        if args[:2] == ("cmake", "--install"):
            for relative in (
                "bin/protoc",
                "bin/grpc_cpp_plugin",
                "lib/cmake/grpc/gRPCConfig.cmake",
                "lib/libprotobufd.so",
                "lib/libgrpc++.so",
            ):
                put(prefix / relative)

    monkeypatch.setattr(sanitizer, "run", run)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "sdk",
            "--prefix",
            str(prefix),
            "--sources",
            str(sources),
            "--sanitizer",
            kind,
        ],
    )
    sanitizer.main()
    stamp = prefix / "sanitizer-sdk.json"
    data = json.loads(stamp.read_text())
    assert data["sanitizer"] == kind
    assert len(data["recipe_sha256"]) == 64
    assert (
        "-fsanitize=thread" if kind == "thread" else "-fsanitize=address,undefined"
    ) in data["flags"]
    configure, options = next(c for c in calls if c[0][:2] == ("cmake", "-S"))
    assert "-DBUILD_SHARED_LIBS=ON" in configure
    assert options["env"]["LD_LIBRARY_PATH"].endswith(":/previous/lib")
    calls.clear()
    sanitizer.main()
    assert len(calls) == 1 and calls[0][0][-1] == "--version"
    (prefix / "lib/libprotobufd.so").unlink()
    sanitizer.main()
    assert len(calls) > 1
    data["compiler"] = "different compiler"
    stamp.write_text(json.dumps(data))
    calls.clear()
    with pytest.raises(SystemExit, match="2"):
        sanitizer.main()
    assert not calls


def test_sanitizer_sdk_rejects_wrong_protobuf_and_bad_jobs(tmp_path, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["sdk", "--jobs", "0"])
    with pytest.raises(SystemExit, match="2"):
        sanitizer.main()
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "sdk",
            "--prefix",
            str(tmp_path / "out"),
            "--sources",
            str(tmp_path / "source"),
        ],
    )
    monkeypatch.setattr(
        sanitizer, "address_runtime", lambda **kw: tmp_path / "runtime.so"
    )
    monkeypatch.setattr(sanitizer.subprocess, "check_output", lambda *a, **kw: "wrong")
    monkeypatch.setattr(sanitizer, "checkout", Mock())
    monkeypatch.setattr(sanitizer, "require_clean_sources", Mock())
    command = Mock()
    monkeypatch.setattr(sanitizer, "run", command)
    with pytest.raises(ValueError, match="protobuf submodule"):
        sanitizer.main()
    assert not any(c.args[0] == "cmake" for c in command.call_args_list)


@pytest.mark.parametrize(
    "options",
    [
        [],
        [
            "--vulkan-include",
            "include path",
            "--vulkan-library",
            "lib path",
            "--spirv-prefix",
            "spirv path",
        ],
    ],
)
def test_whisper_vulkan_configure_and_hash_provenance(tmp_path, monkeypatch, options):
    source, build, output = tmp_path / "src", tmp_path / "build", tmp_path / "out"
    put(source / "LICENSE")
    put(build / "bin/whisper-cli", b"vulkan binary")
    run = Mock()
    monkeypatch.setattr(vulkan.subprocess, "run", run)
    monkeypatch.setattr(
        vulkan.subprocess,
        "check_output",
        lambda a, **kw: "system libs" if a[0] == "ldd" else "a" * 40,
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "build",
            "--source",
            str(source),
            "--build",
            str(build),
            "--output",
            str(output),
            *options,
        ],
    )
    vulkan.main()
    data = json.loads((output / "provenance.json").read_text())
    assert data["sha256"] == hashlib.sha256(b"vulkan binary").hexdigest()
    assert data["commit"] == "a" * 40
    assert "-DGGML_NATIVE=OFF" in data["configure"]
    assert any("Vulkan_INCLUDE_DIR" in c for c in data["configure"]) == bool(options)
    assert run.call_count == 3
    monkeypatch.setattr(
        vulkan.subprocess, "check_output", lambda *a, **kw: "libmissing.so => not found"
    )
    (output / "provenance.json").unlink()
    with pytest.raises(RuntimeError, match="not found"):
        vulkan.main()
    assert not (output / "provenance.json").exists()
