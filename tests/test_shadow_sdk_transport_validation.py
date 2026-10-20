"""Opt-in transport validation forwards verified bytes, never produces an SDK."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

import pytest
import yaml

from tools import ci_linux_shadow_sdk as shadow
from tools import ci_app_dependency_seed as seed
from tools import ci_linux_handoff as handoff
from tests.test_ci_app_dependency_seed import archive, file, PREFIX
from tests.test_linux_sdk_artifacts import IMAGE_ID, REGISTRY_IMAGE, write_archive

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "a" * 40


@pytest.fixture
def context(monkeypatch, tmp_path):
    for name, value in {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/153/merge",
        "GITHUB_REPOSITORY": "example/foresight",
        "GITHUB_RUN_ID": "154",
        "GITHUB_RUN_ATTEMPT": "3",
        "CI_TIER": "pr",
        "SHADOW_PREVIEW": "false",
        "GITHUB_OUTPUT": str(tmp_path / "outputs"),
    }.items():
        monkeypatch.setenv(name, value)


@pytest.mark.parametrize("transport", ["registry", "archive"])
@pytest.mark.parametrize(
    "qualification", ["source-qualification.json", "approved-source.json"]
)
def test_enabled_transport_retains_actual_envelope_and_original_provenance(
    context, tmp_path, transport, qualification, capsys
):
    directory = tmp_path / "sdk"
    prefix = directory / "verified"
    original = {
        "producer_run": 91,
        "artifact_id": 92,
        "artifact_digest": "sha256:" + "d" * 64,
        "source_receipt": {
            "schema": 1,
            "component": "linux-sdk",
            "identity": shadow.artifacts.fingerprint("linux-sdk"),
            "sha256": "c" * 64,
            "source_commit": "b" * 40,
            "source_run_attempt": 2,
        },
    }
    if qualification == "approved-source.json":
        original["original_source_receipt"] = original.pop("source_receipt")
    payload = b"saved Docker image fixture"

    def fetch(*args, **kwargs):
        if transport == "archive":
            write_archive(prefix)
        else:
            prefix.mkdir(parents=True)
            (prefix / "image.json").write_text(json.dumps({"image": REGISTRY_IMAGE}))
        (prefix / qualification).write_text(json.dumps(original))
        return True

    def save(command):
        assert command[:4] == ["docker", "image", "save", "--output"]
        assert command[-1] == IMAGE_ID
        Path(command[4]).write_bytes(payload)

    with (
        patch.object(shadow.waiter, "fetch", side_effect=fetch),
        patch.object(
            shadow.sdk,
            "resolve",
            return_value=REGISTRY_IMAGE
            if transport == "registry"
            else "foresight-sdk:pr",
        ),
        patch.object(shadow.sdk, "inspect", return_value=IMAGE_ID),
        patch.object(shadow.sdk, "produce") as produce,
        patch.object(shadow.sdk, "run", side_effect=save) as docker,
        patch.object(
            shadow.artifacts,
            "api",
            return_value={
                "id": 92,
                "workflow_run": {"id": 91},
                "digest": original["artifact_digest"],
            },
        ),
        patch.object(
            shadow.application.subprocess, "check_output", return_value=SOURCE
        ),
    ):
        assert shadow.prepare(
            "example/foresight", SOURCE, 153, False, directory, validate_in_run=True
        )
        produce.assert_not_called()
        assert docker.call_count == (1 if transport == "registry" else 0)
    receipt = json.loads((directory / "in-run/identity.json").read_text())
    assert receipt["tier"] == "pr" and receipt["label"] == ""
    assert receipt["source_commit"] == SOURCE and receipt["source_run_attempt"] == 3
    assert receipt["reused_from"] == original
    restored = tmp_path / "restored"
    shadow.artifacts.unpack(
        "linux-sdk",
        shadow.artifacts.fingerprint("linux-sdk"),
        directory / "in-run",
        restored,
    )
    assert (restored / "image.tar").read_bytes() == payload
    assert json.loads((restored / qualification).read_text()) == original
    descriptor = shadow.sdk.record(restored, "linux-sdk")
    assert descriptor["image_id"] == IMAGE_ID and descriptor["source_scope"] == SOURCE
    assert not prefix.exists()
    output = (tmp_path / "outputs").read_text()
    assert "producer_run=91\n" in output and "producer_artifact_id=92\n" in output
    assert "producer_artifact_digest=" + original["artifact_digest"] in output
    assert "in_run=true\n" in output
    assert "not an SDK compilation" in capsys.readouterr().out
    producer_image = next(
        line.removeprefix("image=")
        for line in output.splitlines()
        if line.startswith("image=")
    )
    with (
        patch.object(shadow.sdk, "run"),
        patch.object(shadow.sdk, "inspect", return_value=IMAGE_ID),
    ):
        consumer_image = shadow.sdk.resolve(restored)
    layer = archive(tmp_path / "seed-layer.gz", [file(PREFIX + "/flatc", b"compiler")])
    identities = []
    with patch.object(
        seed, "REQUIRED", {PREFIX + "/flatc": hashlib.sha256(b"compiler").hexdigest()}
    ):
        for name, image in (("producer", producer_image), ("consumer", consumer_image)):
            destination = tmp_path / name
            seed.materialize(
                [layer], destination, {"image_id": IMAGE_ID, "requested_image": image}
            )
            with patch.object(
                handoff.subprocess, "check_output", return_value=IMAGE_ID
            ):
                identities.append(
                    handoff.input_identity(
                        image,
                        destination / "qualification.json",
                        ROOT / "packaging/build.Dockerfile",
                        "20261001T000000Z",
                    )
                )
    assert identities[0] == identities[1]


def test_forward_rejects_a_local_tag_for_a_different_sdk(context, tmp_path):
    prefix = tmp_path / "verified"
    prefix.mkdir()
    with (
        patch.object(
            shadow.sdk, "inspect", side_effect=[IMAGE_ID, "sha256:" + "f" * 64]
        ),
        patch.object(shadow.application, "save_sdk") as save,
    ):
        with pytest.raises(ValueError, match="local tag"):
            shadow.forward(
                prefix, tmp_path, SOURCE, REGISTRY_IMAGE, reuse_archive=False
            )
        save.assert_not_called()
    assert prefix.is_dir()


@pytest.mark.parametrize(
    "name,value",
    [
        ("GITHUB_EVENT_NAME", "push"),
        ("GITHUB_EVENT_NAME", "workflow_dispatch"),
        ("GITHUB_EVENT_NAME", "schedule"),
        ("GITHUB_REF", "refs/heads/main"),
        ("GITHUB_REF", "refs/pull/987/merge"),
        ("GITHUB_REF", ""),
        ("CI_TIER", "release"),
        ("CI_TIER", "preview"),
        ("CI_TIER", "sweep"),
        ("CI_TIER", ""),
        ("SHADOW_PREVIEW", "true"),
    ],
)
def test_validation_rejects_wrong_context_before_sdk_access(
    context, tmp_path, monkeypatch, name, value
):
    monkeypatch.setenv(name, value)
    with (
        patch.object(shadow.waiter, "fetch") as fetch,
        patch.object(shadow.sdk, "produce") as produce,
    ):
        with pytest.raises(ValueError, match="requires this PR"):
            shadow.prepare(
                "example/foresight",
                SOURCE,
                153,
                True,
                tmp_path / "sdk",
                validate_in_run=True,
            )
        fetch.assert_not_called()
        produce.assert_not_called()


@pytest.mark.parametrize("fork", [False, True])
def test_validation_miss_never_produces_an_sdk(context, tmp_path, fork):
    with (
        patch.object(shadow.waiter, "fetch", return_value=False),
        patch.object(shadow.sdk, "produce") as produce,
    ):
        with pytest.raises(RuntimeError, match="no SDK build"):
            shadow.prepare(
                "example/foresight",
                SOURCE,
                153,
                fork,
                tmp_path / "sdk",
                validate_in_run=True,
            )
        produce.assert_not_called()


@pytest.mark.parametrize("corruption", ["archive", "qualification"])
def test_invalid_verified_payload_is_not_forwarded(context, tmp_path, corruption):
    prefix = tmp_path / "sdk/verified"
    write_archive(prefix)
    (prefix / "source-qualification.json").write_text(
        json.dumps(
            {
                "producer_run": 91,
                "artifact_id": 92,
                "artifact_digest": "sha256:" + "d" * 64,
            }
        )
    )
    (
        prefix
        / ("image.tar" if corruption == "archive" else "source-qualification.json")
    ).write_bytes(b"corrupt")
    with (
        patch.object(shadow.waiter, "fetch", return_value=True),
        patch.object(shadow.sdk, "produce") as produce,
        patch.object(shadow.application, "save_sdk") as save,
    ):
        with pytest.raises((ValueError, json.JSONDecodeError)):
            shadow.prepare(
                "example/foresight",
                SOURCE,
                153,
                False,
                tmp_path / "sdk",
                validate_in_run=True,
            )
        produce.assert_not_called()
        save.assert_not_called()


@pytest.mark.parametrize("enabled", [False, True])
def test_workflow_shell_passes_validation_flag_only_when_enabled(tmp_path, enabled):
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    step = next(s for s in jobs["linux-build"]["steps"] if s.get("id") == "sdk")
    assert step["env"]["VALIDATE_SDK_TRANSPORT"] == (
        "${{ github.event_name == 'pull_request' && contains(github.event.pull_request.labels.*.name, 'ci:validate-sdk-transport') }}"
    )
    assert step["env"]["CI_TIER"] == (
        "${{ inputs.tier || (inputs.preview && 'preview' || (github.event_name == 'pull_request' && 'pr' || 'sweep')) }}"
    )
    assert step["env"]["SHADOW_PREVIEW"] == "${{ inputs.preview && 'true' || 'false' }}"
    tools = tmp_path / "tools"
    tools.mkdir()
    (tools / "ci_linux_shadow_sdk.py").write_text(
        "import json,sys\nprint(json.dumps(sys.argv[1:]))\n"
    )
    result = subprocess.run(
        ["bash", "-e", "-c", step["run"]],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"],
            "FORK_PR": "false",
            "VALIDATE_SDK_TRANSPORT": "true" if enabled else "false",
            "OWN_HEAD": SOURCE,
            "OWN_PR": "153",
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert ("--validate-in-run-transport" in json.loads(result.stdout)) is enabled


def test_benchmark_label_is_explicit_and_only_changes_shadow_test():
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    matches = [
        (name, step)
        for name, job in jobs.items()
        for step in job.get("steps", [])
        if "ci:benchmark-core" in str(step)
    ]
    assert len(matches) == 1 and matches[0][0] == "linux-test"
    assert matches[0][1]["env"]["FORESIGHT_CORE_COVERAGE_BENCHMARK"] == (
        "${{ (inputs.core_coverage_benchmark || (github.event_name == 'pull_request' && contains(github.event.pull_request.labels.*.name, 'ci:benchmark-core'))) && '1' || '0' }}"
    )
    assert (
        jobs["linux-native"]["with"]["core_coverage_benchmark"]
        == "${{ inputs.core_coverage_benchmark || false }}"
    )
    assert "macos-stages" not in jobs
    assert "FORESIGHT_CORE_COVERAGE_BENCHMARK" not in str(jobs["macos"])
    assert (
        jobs["macos"]["env"]["FORESIGHT_COVERAGE"]
        == "${{ (inputs.tier == 'release' || inputs.macos_coverage) && github.event_name != 'pull_request' && '1' || '0' }}"
    )
    sdk_restore = next(s for s in jobs["linux-test"]["steps"] if s.get("id") == "sdk")
    assert (
        sdk_restore["env"]["HEAD_REPOSITORY"]
        == "${{ github.event.pull_request.head.repo.full_name }}"
    )
