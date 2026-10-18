"""The stage runner must validate prerequisites before trusting cached work."""

import hashlib
import json
import subprocess
from unittest.mock import patch

import pytest

from tools import run_ci_stage as runner


def input_artifact(directory, source="a" * 40, identity="b" * 64):
    directory.mkdir()
    (directory / "payload.tar.gz").write_bytes(b"payload")
    receipt = {
        "platform": "linux",
        "stage": "native",
        "payload_kind": "native-runtime",
        "source_commit": source,
        "identity": identity,
        "sha256": hashlib.sha256(b"payload").hexdigest(),
        "content": {"files": {"fixture": {}}},
    }
    (directory / "identity.json").write_text(json.dumps(receipt))
    return receipt


@pytest.mark.parametrize(
    "field,value",
    [
        ("source_commit", "c" * 40),
        ("identity", "d" * 64),
        ("stage", "desktop"),
        ("platform", "macos"),
        ("payload_kind", "native"),
        ("sha256", "0" * 64),
    ],
)
def test_same_run_wrong_or_corrupt_parent_is_rejected_before_unpack(
    tmp_path, field, value
):
    directory = tmp_path / "input"
    receipt = input_artifact(directory)
    receipt[field] = value
    (directory / "identity.json").write_text(json.dumps(receipt))
    with patch.object(runner.payloads, "unpack") as unpack:
        with pytest.raises(ValueError):
            runner.restore_input(
                tmp_path, "linux", "native", directory, "b" * 64, "a" * 40
            )
    unpack.assert_not_called()


def test_same_run_valid_parent_is_unpacked_only_after_receipt_check(tmp_path):
    directory = tmp_path / "input"
    receipt = input_artifact(directory)
    with patch.object(runner.payloads, "unpack") as unpack:
        runner.restore_input(tmp_path, "linux", "native", directory, "b" * 64, "a" * 40)
    unpack.assert_called_once_with(
        tmp_path,
        "linux",
        "native-runtime",
        directory / "payload.tar.gz",
        receipt["content"],
    )


def test_native_hit_relinks_revision_and_checks_actual_compiled_identity(tmp_path):
    with (
        patch.object(runner.subprocess, "run") as command,
        patch.object(
            runner.subprocess,
            "check_output",
            return_value="open-foresight-0.1.1-aaaaaaaaaaaa\n",
        ) as identity,
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch("tools.app_version.read_version", return_value=("0.1.1", 1)),
    ):
        runner.execute(tmp_path, "linux", "native", True, ["-G", "Ninja"])
    assert command.call_count == 2
    assert command.call_args_list[0].args[0][0] == "cmake"
    assert command.call_args_list[1].args[0][:2] == ["cmake", "--build"]
    identity.assert_called_once()
    assert identity.call_args.args[0][-1] == "--build-id"


def test_native_hit_cannot_republish_stale_compiled_revision(tmp_path):
    with (
        patch.object(runner.subprocess, "run"),
        patch.object(
            runner.subprocess,
            "check_output",
            return_value="open-foresight-0.1.1-bbbbbbbbbbbb\n",
        ),
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch("tools.app_version.read_version", return_value=("0.1.1", 1)),
    ):
        with pytest.raises(ValueError, match="helper identity mismatch"):
            runner.execute(tmp_path, "linux", "native", True, [])


@pytest.mark.parametrize("stage", ["core", "desktop", "service"])
def test_verified_language_stage_hit_does_not_rerun_tests_or_compile(tmp_path, stage):
    with patch.object(runner.subprocess, "run") as command:
        runner.execute(tmp_path, "linux", stage, True, [])
    command.assert_not_called()


@pytest.mark.parametrize("stage", ["core", "desktop", "service"])
def test_language_miss_runs_its_selected_stage_only(tmp_path, stage):
    with patch.object(runner.subprocess, "run") as command:
        runner.execute(tmp_path, "linux", stage, False, [])
    assert command.call_args.args[0][-2:] == ["--stage", stage]


def test_missing_parent_never_looks_up_cached_green_result(tmp_path):
    with (
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(runner.cache, "find") as find,
    ):
        with pytest.raises(ValueError, match="requires input artifacts"):
            runner.run(
                tmp_path,
                "linux",
                "core",
                {"compiler": "fixture"},
                {"native": "b" * 64},
                {},
                "repo",
                1,
                "pull_request",
                False,
                [],
            )
    find.assert_not_called()


def test_runner_does_not_expose_validation_environment_in_receipt(
    tmp_path, monkeypatch
):
    secret = "private-build-setting"
    monkeypatch.setenv("FORESIGHT_COVERAGE", secret)
    monkeypatch.setenv("CFLAGS", secret)
    with (
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(
            runner.cache, "fingerprint", side_effect=RuntimeError("captured")
        ) as fingerprint,
    ):
        with pytest.raises(RuntimeError, match="captured"):
            runner.run(
                tmp_path,
                "linux",
                "native",
                {},
                {},
                {},
                "repo",
                1,
                "pull_request",
                False,
                [],
            )
    environment = fingerprint.call_args.kwargs["environment"]
    assert secret not in json.dumps(environment)
    digest = hashlib.sha256(secret.encode()).hexdigest()
    assert environment["validation_flags"]["FORESIGHT_COVERAGE"] == digest
    assert environment["validation_flags"]["CFLAGS"] == digest


def test_native_runner_publishes_distinct_runtime_and_compilation_archives(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, timeout=30)
    (tmp_path / ".gitignore").write_text("build/\n")
    (tmp_path / "native.cpp").write_text("implementation")
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True, timeout=30)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.test",
            "commit",
            "-qm",
            "fixture",
        ],
        cwd=tmp_path,
        check=True,
        timeout=30,
    )

    def build(*args):
        for name in (
            "build/services/helper/ForesightHelper",
            "build/native/libforesight_native.so",
            "build/_deps/compiler/object.o",
        ):
            target = tmp_path / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(name.encode())

    with (
        patch.object(runner.cache, "find", return_value={"hit": False}),
        patch.object(runner.cache, "find_native_work", return_value={"hit": False}),
        patch.object(runner, "execute", side_effect=build),
    ):
        result = runner.run(
            tmp_path,
            "linux",
            "native",
            {"compiler": "fixture"},
            {},
            {},
            "repo",
            1,
            "pull_request",
            False,
            [],
        )
    assert result["runtime_artifact_name"] == result["artifact_name"] + "-runtime"
    full = json.loads(
        (tmp_path / "build/ci-stage/linux-native/identity.json").read_text()
    )
    runtime_path = tmp_path / "build/ci-stage/linux-native-runtime"
    runtime = json.loads((runtime_path / "identity.json").read_text())
    assert full["identity"] == runtime["identity"] == result["identity"]
    assert (
        full["payload_kind"] == "native" and runtime["payload_kind"] == "native-runtime"
    )
    assert "build/_deps/compiler/object.o" in full["content"]["files"]
    assert "build/_deps/compiler/object.o" not in runtime["content"]["files"]
    target = tmp_path / "consumer"
    runner.restore_input(
        target,
        "linux",
        "native",
        runtime_path,
        result["identity"],
        runtime["source_commit"],
    )
    assert (target / "build/services/helper/ForesightHelper").is_file()
    assert not (target / "build/_deps").exists()
