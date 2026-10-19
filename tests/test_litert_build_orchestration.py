"""LiteRT build receipt tests use tiny real wheels at the Bazel/ABI boundary."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import Mock
import zipfile

import pytest
from tools import build_litert_extensions as builder


@pytest.fixture
def build_fixture(tmp_path, monkeypatch):
    source, output = tmp_path / "source", tmp_path / "output"
    source.mkdir()
    wheel_dir = source / "bazel-bin/python/litert_lm"
    wheel_dir.mkdir(parents=True)
    log = source / "bazel-testlogs/c/engine_test/test.log"
    log.parent.mkdir(parents=True)
    selected = "EngineCTest.AppendStopTokenSequencesBeforeConversationConfigCopy"
    log.write_text(f"[ RUN      ] {selected}\n[       OK ] {selected}\n")
    state = {
        "platform": "Darwin",
        "machine": "arm64",
        "version": "bazel 7.6.1",
        "metadata": True,
        "package": "litert-lm-api",
        "library": True,
        "exports": True,
        "snapshot": True,
    }
    commands = []

    def make_wheel():
        suffix = ".dylib" if state["platform"] == "Darwin" else ".so"
        with zipfile.ZipFile(wheel_dir / "fixture.whl", "w") as archive:
            if state["metadata"]:
                archive.writestr(
                    "litert_lm_api.dist-info/METADATA",
                    f"Name: {state['package']}\nVersion: {builder.LITERT_VERSION}\n",
                )
            for name in (
                builder.MACOS_VENDOR_BASENAMES
                if state["platform"] == "Darwin"
                else builder.VENDOR_BASENAMES
            ):
                archive.writestr(
                    "litert_lm/" + name + suffix, (name + " verified").encode()
                )
            if state["library"]:
                archive.writestr("litert_lm/liblitert-lm" + suffix, b"native library")

    def run(directory, *args, capture=False):
        commands.append(tuple(map(str, args)))
        if args[:3] == ("git", "rev-parse", "HEAD"):
            return builder.COMMIT.encode()
        if args[0] == "git":
            return (
                builder.PATCH.read_bytes()
                + (
                    builder.MACOS_ABI_PATCH
                    if state["platform"] == "Darwin"
                    else builder.LINUX_ABI_PATCH
                ).read_bytes()
            )
        if args[-1] == "--version":
            return state["version"].encode()
        if "info" in args:
            return str(tmp_path / "bazel-base").encode()
        if "build" in args:
            make_wheel()
        return b""

    monkeypatch.setattr(builder, "run", run)
    monkeypatch.setattr(builder.platform, "system", lambda: state["platform"])
    monkeypatch.setattr(builder.platform, "machine", lambda: state["machine"])
    monkeypatch.setattr(
        builder.subprocess,
        "check_output",
        lambda *a, **kw: "\n".join(
            [
                "_litert_lm_engine_create",
                "_litert_lm_embedding_engine_create",
                "_litert_lm_session_config_add_stop_token_sequence",
            ]
            if state["exports"]
            else ["_unexpected"]
        ),
    )
    monkeypatch.setattr(
        builder, "verify_linux_library_abi", lambda library: "verified ELF C exports"
    )

    def abi(headers, directory):
        assert headers == tmp_path / "bazel-base/external/com_google_absl"
        directory.mkdir(parents=True)
        (directory / "report.json").write_text('{"passed":true}')

    monkeypatch.setitem(
        sys.modules,
        "test_litert_status_abi",
        SimpleNamespace(
            verify_status_abi=abi,
            find_linux_libcxx=lambda: (Path("/include/c++"), Path("/lib/c++")),
        ),
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "build",
            str(source),
            "--output",
            str(output),
            "--output-user-root",
            str(tmp_path / "retained-bazel-cache"),
            "--jobs",
            "2",
        ],
    )
    return source, output, state, commands


@pytest.mark.parametrize("platform", ["Darwin", "Linux"])
def test_litert_build_binds_wheel_library_vendor_abi_and_test_log(
    build_fixture, platform
):
    source, output, state, commands = build_fixture
    state["platform"] = platform
    state["machine"] = "arm64" if platform == "Darwin" else "x86_64"
    builder.main()
    manifest = json.loads((output / "build-manifest.json").read_text())
    for field in (
        "wheel",
        "library",
        "native_test_log",
        "native_status_abi_report",
        "native_export_log",
    ):
        assert (
            manifest[field + "_sha256"]
            == hashlib.sha256((output / manifest[field]).read_bytes()).hexdigest()
        )
    assert manifest["upstream_commit"] == builder.COMMIT
    assert manifest["version"] == builder.LITERT_VERSION
    assert len(manifest["vendor_libraries"]) == (7 if platform == "Darwin" else 5)
    assert any(
        arg.startswith("--output_user_root=") for arg in manifest["build_command"]
    )
    assert "--jobs=2" in manifest["build_command"]
    assert not any(
        "use_prebuilt_c_api" in arg for command in commands for arg in command
    )
    if platform == "Linux":
        assert "--force_pic" in manifest["build_command"]
        assert "--repo_env=CXX=clang++" in manifest["build_command"]
    assert not list(output.glob("*.part"))


@pytest.mark.parametrize(
    "failure,message",
    [
        ("version", "The pinned source requires Bazel 7.6.1"),
        ("machine", "Supported build hosts are macOS arm64 and Linux x86_64"),
        ("test-log", "regression"),
        ("metadata", "metadata"),
        ("package", "litert-lm-api"),
        ("library", "native C runtime"),
        ("exports", "public C API"),
    ],
)
def test_litert_build_never_publishes_receipt_for_unverified_outputs(
    build_fixture, failure, message, capsys
):
    source, output, state, _ = build_fixture
    if failure == "test-log":
        (source / "bazel-testlogs/c/engine_test/test.log").write_text("0 tests ran")
    elif failure == "machine":
        state["machine"] = "x86_64"
    elif failure == "version":
        state["version"] = "bazel 8.0"
    elif failure == "package":
        state["package"] = "different-distribution"
    else:
        state[failure] = False
    if failure in ("version", "machine"):
        with pytest.raises(SystemExit) as error:
            builder.main()
        assert error.value.code == 2
        assert message in capsys.readouterr().err
    else:
        with pytest.raises(RuntimeError, match=message):
            builder.main()
    assert not (output / "build-manifest.json").exists()


def test_litert_requires_materialized_prebuilts(tmp_path):
    prebuilt = tmp_path / "prebuilt/macos_arm64"
    prebuilt.mkdir(parents=True)
    library = prebuilt / "library.dylib"
    library.write_bytes(
        b"version https://git-lfs.github.com/spec/v1\nsha256:unmaterialized"
    )
    with pytest.raises(RuntimeError, match="git lfs pull"):
        builder.require_materialized_prebuilts(tmp_path, "macos_arm64", ".dylib")
    library.write_bytes(b"real library bytes")
    builder.require_materialized_prebuilts(tmp_path, "macos_arm64", ".dylib")


def test_build_subprocess_runner_checks_exit_and_timeout(tmp_path, monkeypatch):
    run = Mock(return_value=subprocess.CompletedProcess([], 0, b"captured"))
    monkeypatch.setattr(builder.subprocess, "run", run)
    assert (
        builder.run(tmp_path, "compiler", "argument with spaces", capture=True)
        == b"captured"
    )
    assert run.call_args.args == (("compiler", "argument with spaces"),)
    assert run.call_args.kwargs == {
        "cwd": tmp_path,
        "check": True,
        "stdout": subprocess.PIPE,
        "timeout": 3600,
    }
