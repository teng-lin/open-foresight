"""A qualified bundle carries an exact SDK lookup, never a newest-compatible hint."""

import json
from pathlib import Path
import sys
from unittest.mock import Mock

import pytest
import yaml

from tools import ci_linux_sdk_reference as reference

SOURCE = "a" * 40
REPOSITORY = "example/foresight"
DIGEST = "sha256:" + "b" * 64
ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def sdk_reference(monkeypatch, tmp_path):
    for key, value in {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_RUN_ID": "100",
        "GITHUB_RUN_ATTEMPT": "3",
        "SDK_RUN": "10",
        "SDK_ID": "20",
        "SDK_DIGEST": DIGEST,
        "HEAD_REPOSITORY": "fork/foresight",
        "FORK_SDK_ID": "",
    }.items():
        monkeypatch.setenv(key, value)
    return tmp_path / "packages/sdk-reference.json"


@pytest.mark.parametrize("fork", [False, True])
def test_reference_records_the_actual_ordinary_or_source_scoped_route(
    sdk_reference, monkeypatch, fork
):
    if fork:
        monkeypatch.setenv("FORK_SDK_ID", "200")
        monkeypatch.setenv("FORK_SDK_DIGEST", DIGEST)
    value = reference.write(sdk_reference, REPOSITORY, SOURCE)
    assert json.loads(sdk_reference.read_text()) == value
    assert value["source"] == SOURCE and value["repository"] == REPOSITORY
    assert value["run_id"] == (100 if fork else 10)
    assert value["artifact_id"] == (200 if fork else 20)
    assert value["artifact_digest"] == DIGEST
    assert value["route"] == ("in-run" if fork else "producer")
    if fork:
        assert value["attempt"] == 3 and value["head_repository"] == "fork/foresight"
    else:
        assert "head_repository" not in value and "attempt" not in value


@pytest.mark.parametrize(
    "field,value",
    [
        ("schema", 2),
        ("source", "c" * 40),
        ("repository", "untrusted/repo"),
        ("route", "latest"),
        ("run_id", True),
        ("artifact_id", 0),
        ("artifact_digest", "b" * 64),
    ],
)
def test_qualified_reference_identity_cannot_be_substituted(
    sdk_reference, field, value
):
    record = reference.write(sdk_reference, REPOSITORY, SOURCE)
    record[field] = value
    with pytest.raises(ValueError, match="exact SDK reference"):
        reference.validate(record, REPOSITORY, SOURCE)


@pytest.mark.parametrize(
    "field,value", [("attempt", True), ("head_repository", "malformed")]
)
def test_source_scoped_reference_retains_original_attempt_and_repository(
    sdk_reference, monkeypatch, field, value
):
    monkeypatch.setenv("FORK_SDK_ID", "200")
    monkeypatch.setenv("FORK_SDK_DIGEST", DIGEST)
    record = reference.write(sdk_reference, REPOSITORY, SOURCE)
    record[field] = value
    with pytest.raises(ValueError, match="source-scoped"):
        reference.validate(record, REPOSITORY, SOURCE)


@pytest.mark.parametrize("fork", [False, True])
def test_restore_delegates_to_existing_full_qualifier_with_exact_original_reference(
    sdk_reference, monkeypatch, tmp_path, fork
):
    if fork:
        monkeypatch.setenv("FORK_SDK_ID", "200")
        monkeypatch.setenv("FORK_SDK_DIGEST", DIGEST)
    reference.write(sdk_reference, REPOSITORY, SOURCE)
    pull = Mock(return_value=True)
    retrieve = Mock()
    resolve = Mock(return_value="sha256:" + "d" * 64)
    output = Mock()
    monkeypatch.setattr(reference.artifacts, "pull", pull)
    monkeypatch.setattr(reference.application, "retrieve", retrieve)
    monkeypatch.setattr(reference.sdk, "resolve", resolve)
    monkeypatch.setattr(reference.sdk, "write_outputs", output)
    directory = tmp_path / "sdk"
    directory.mkdir()
    (directory / "image.tar").write_bytes(
        b"verified transport no longer needed after load"
    )
    reference.restore(sdk_reference, directory, REPOSITORY, SOURCE, 123)
    assert not (directory / "image.tar").exists()
    if fork:
        pull.assert_not_called()
        retrieve.assert_called_once_with(
            REPOSITORY,
            "fork/foresight",
            SOURCE,
            100,
            200,
            3,
            "b" * 64,
            directory,
            component="linux-sdk",
            shadow=True,
        )
    else:
        retrieve.assert_not_called()
        pull.assert_called_once_with(
            REPOSITORY,
            "linux-sdk",
            reference.artifacts.fingerprint("linux-sdk"),
            directory,
            own_head=SOURCE,
            own_pr=123,
            source_run=10,
            artifact_id=20,
            artifact_digest=DIGEST,
        )
    resolve.assert_called_once_with(directory, load_registry=True)
    output.assert_called_once_with(resolve.return_value)


def test_missing_exact_sdk_never_selects_a_different_artifact_or_build(
    sdk_reference, monkeypatch, tmp_path
):
    reference.write(sdk_reference, REPOSITORY, SOURCE)
    monkeypatch.setattr(reference.artifacts, "pull", Mock(return_value=False))
    resolve = Mock()
    monkeypatch.setattr(reference.sdk, "resolve", resolve)
    with pytest.raises(ValueError, match="exact verified SDK artifact is unavailable"):
        reference.restore(sdk_reference, tmp_path / "sdk", REPOSITORY, SOURCE)
    resolve.assert_not_called()


@pytest.mark.parametrize("change", ["missing", "symlink", "oversized"])
def test_restore_requires_one_regular_verified_bundle_entry(
    sdk_reference, tmp_path, change
):
    reference.write(sdk_reference, REPOSITORY, SOURCE)
    if change == "missing":
        sdk_reference.unlink()
    elif change == "symlink":
        target = tmp_path / "other.json"
        sdk_reference.rename(target)
        sdk_reference.symlink_to(target)
    else:
        sdk_reference.write_bytes(b" " * (64 * 1024 + 1))
    with pytest.raises(ValueError, match="regular qualified"):
        reference.restore(sdk_reference, tmp_path / "sdk", REPOSITORY, SOURCE)


@pytest.mark.parametrize("command", ["write", "restore"])
def test_cli_binds_reference_source_and_repository(sdk_reference, monkeypatch, command):
    operation = Mock()
    monkeypatch.setattr(reference, command, operation)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "sdk-reference",
            command,
            "--source",
            SOURCE,
            "--reference",
            str(sdk_reference),
        ],
    )
    reference.main()
    if command == "write":
        operation.assert_called_once_with(sdk_reference, REPOSITORY, SOURCE)
    else:
        operation.assert_called_once_with(
            sdk_reference, Path("build/consumer-sdk"), REPOSITORY, SOURCE, 0
        )


def test_weekly_audit_and_acceptance_restore_exact_build_sdk_references():
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    build_steps = jobs["linux-build"]["steps"]
    record = next(
        step
        for step in build_steps
        if "ci_linux_sdk_reference.py write" in step.get("run", "")
    )
    pack = next(step for step in build_steps if step.get("id") == "receipt")
    assert build_steps.index(record) < build_steps.index(pack)
    assert "steps.sdk.outputs.producer_run" in record["env"]["SDK_RUN"]
    assert "steps.fork-sdk.outputs.artifact-id" in record["env"]["FORK_SDK_ID"]
    for gate in ("acceptance-cpu", "acceptance-audio", "acceptance-deb"):
        setup = next(
            step
            for step in jobs[gate]["steps"]
            if step.get("uses") == "./.github/actions/setup-linux-consumer"
        )
        for key, output in (
            ("producer-sdk-run", "producer_sdk_run"),
            ("producer-sdk-id", "producer_sdk_id"),
            ("producer-sdk-digest", "producer_sdk_digest"),
        ):
            assert (
                setup["with"][key] == "${{ needs.linux-build.outputs." + output + " }}"
            )
    weekly = yaml.safe_load(
        (ROOT / ".github/workflows/preview-packages.yml").read_text()
    )["jobs"]["weekly-external-audit"]
    assert "ci_linux_sdk_reference.py restore" in str(weekly)
    assert "ci_dependency_wait.py" not in str(weekly)
