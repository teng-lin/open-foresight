"""The stage runner must validate prerequisites before trusting cached work."""

import hashlib
import json
from unittest.mock import patch

import pytest

from tools import run_ci_stage as runner


def input_artifact(directory, source="a" * 40, identity="b" * 64):
    directory.mkdir()
    (directory / "payload.tar.gz").write_bytes(b"payload")
    receipt = {
        "platform": "linux",
        "stage": "native",
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
        tmp_path, "linux", "native", directory / "payload.tar.gz", receipt["content"]
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
