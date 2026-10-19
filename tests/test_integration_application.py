"""A failed acceptance attempt must reuse its successful, byte-verified producer."""

import copy
import io
import importlib.util
import json
import os
from pathlib import Path
import tarfile
from unittest.mock import patch
import zipfile

import pytest

from tools import ci_artifacts as artifacts
from tools import integration_application as application

SOURCE = "a" * 40
REPOSITORY = "example/foresight"
RUN, ARTIFACT, JOB = 100, 200, 300


@pytest.fixture(params=[False, True], ids=["original", "verified-copy"])
def producer(tmp_path, request):
    payload = tmp_path / "original"
    payload.mkdir()
    # Exercise the real tar/receipt format with a complete portable archive.
    portable = payload / "application.tar.gz"
    with tarfile.open(portable, "w:gz") as archive:
        entry = tarfile.TarInfo("open-foresight/executable")
        entry.mode = 0o755
        data = b"immutable original application"
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
    (payload / "application.tar.gz.sha256").write_text(
        artifacts.digest(portable) + "  application.tar.gz\n"
    )
    (payload / "application.tar.gz.build.json").write_text(
        json.dumps(
            {
                "revision": SOURCE,
                "version": "0.1.2",
                "build_number": 3,
            }
        )
    )
    packed = tmp_path / "packed"
    with (
        patch.object(artifacts.subprocess, "check_output", return_value=SOURCE + "\n"),
        patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"}),
    ):
        artifacts.pack("linux-app", SOURCE, payload, packed)
    if request.param:
        original_zip = tmp_path / "original.zip"
        with zipfile.ZipFile(original_zip, "w") as archive:
            for name in ("identity.json", "payload.tar.gz"):
                archive.write(packed / name, name)
        history = {
            "schema": 1,
            "source_receipt": json.loads((packed / "identity.json").read_text()),
            "producer_run": 90,
            "producer_job": 270,
            "producer_attempt": 1,
            "artifact_id": 180,
            "artifact_digest": "sha256:" + artifacts.digest(original_zip),
        }
        (payload / "source-qualification.json").write_text(json.dumps(history))
        with (
            patch.object(
                artifacts.subprocess, "check_output", return_value=SOURCE + "\n"
            ),
            patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"}),
        ):
            artifacts.pack("linux-app", SOURCE, payload, packed)
    saved = tmp_path / "application.zip"
    with zipfile.ZipFile(saved, "w") as archive:
        for name in ("identity.json", "payload.tar.gz"):
            archive.write(packed / name, name)
    checksum = artifacts.digest(saved)
    run = {
        "id": RUN,
        "path": ".github/workflows/integration-acceptance.yml",
        "event": "pull_request",
        "head_sha": SOURCE,
        "run_attempt": 2,
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
    }
    artifact = {
        "id": ARTIFACT,
        "name": artifacts.name("linux-app", SOURCE),
        "digest": "sha256:" + checksum,
        "expired": False,
        "workflow_run": {"id": RUN, "head_sha": SOURCE},
        "created_at": "2025-01-01T00:01:00Z",
    }
    job = {
        "id": JOB,
        "name": "ubuntu-application",
        "run_id": RUN,
        "head_sha": SOURCE,
        "run_attempt": 1,
        "conclusion": "success",
        "status": "completed",
        "started_at": "2025-01-01T00:00:00Z",
        "completed_at": "2025-01-01T00:02:00Z",
    }
    return payload, saved, checksum, run, artifact, job


def restore(tmp_path, producer, *, head_repository=REPOSITORY, component="linux-app"):
    payload, saved, checksum, run, artifact, job = producer

    def api(repository, route):
        assert repository == REPOSITORY
        if route == f"actions/runs/{RUN}":
            return run
        if route == f"actions/artifacts/{ARTIFACT}":
            return artifact
        if route == f"actions/runs/{RUN}/jobs?filter=all&per_page=100&page=1":
            return {
                "jobs": [
                    job,
                    {**job, "id": JOB + 1, "run_attempt": 2, "conclusion": "failure"},
                ]
            }
        raise AssertionError(route)

    def download(arguments, *, stdout, **kwargs):
        assert arguments == [
            "gh",
            "api",
            f"repos/{REPOSITORY}/actions/artifacts/{ARTIFACT}/zip",
        ]
        assert kwargs["check"] and kwargs["timeout"] == 300
        stdout.write(saved.read_bytes())

    destination = tmp_path / "restored"
    with (
        patch.object(artifacts, "api", side_effect=api),
        patch.object(artifacts.subprocess, "run", side_effect=download),
    ):
        result = application.retrieve(
            REPOSITORY,
            head_repository,
            SOURCE,
            RUN,
            ARTIFACT,
            1,
            checksum,
            destination,
            component=component,
        )
    return payload, destination, result


@pytest.mark.parametrize("ref", ["refs/pull/98765/merge", "refs/heads/main", None])
def test_retried_consumer_retains_successful_original_attempt_and_actual_bytes(
    tmp_path, producer, monkeypatch, ref
):
    if ref is None:
        monkeypatch.delenv("GITHUB_REF", raising=False)
    else:
        monkeypatch.setenv("GITHUB_REF", ref)
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "2")
    original, restored, qualification = restore(tmp_path, producer)
    assert (restored / "application.tar.gz").read_bytes() == (
        original / "application.tar.gz"
    ).read_bytes()
    assert qualification["producer_attempt"] == 1
    assert qualification["producer_job"] == JOB
    assert qualification["source_receipt"]["source_run_attempt"] == 1
    assert qualification["artifact_digest"] == "sha256:" + producer[2]
    assert (
        json.loads((restored / "source-qualification.json").read_text())
        == qualification
    )
    if (original / "source-qualification.json").exists():
        assert qualification["source_receipt"]["reused_from"] == json.loads(
            (original / "source-qualification.json").read_text()
        )


@pytest.mark.parametrize(
    "record,key,value",
    [
        (3, "path", ".github/workflows/other.yml"),
        (3, "event", "workflow_dispatch"),
        (3, "head_sha", "b" * 40),
        (3, "repository", {"full_name": "untrusted/other"}),
        (3, "head_repository", {"full_name": "untrusted/other"}),
        (4, "id", ARTIFACT + 1),
        (4, "expired", True),
        (4, "name", "wrong-name"),
        (4, "digest", "sha256:" + "b" * 64),
        (4, "workflow_run", {"id": RUN + 1, "head_sha": SOURCE}),
        (5, "conclusion", "failure"),
        (5, "status", "in_progress"),
        (5, "name", "other-job"),
        (5, "run_attempt", 3),
        (5, "run_id", RUN + 1),
        (5, "head_sha", "b" * 40),
        (5, "completed_at", "2025-01-01T00:00:30Z"),
    ],
)
def test_wrong_provenance_never_downloads_application(
    tmp_path, producer, record, key, value
):
    changed = copy.deepcopy(producer)
    changed[record][key] = value
    with pytest.raises(ValueError):
        restore(tmp_path, changed)
    assert not (tmp_path / "restored").exists()


@pytest.mark.parametrize(
    "bad_field", [None, "source_scope", "local_recipe_sha256", "archive_sha256"]
)
def test_fork_sdk_is_saved_without_building_and_reused_only_in_its_successful_source_scope(
    tmp_path, producer, bad_field
):
    fixture_path = Path(__file__).with_name("test_linux_sdk_artifacts.py")
    spec = importlib.util.spec_from_file_location("sdk_fixture", fixture_path)
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    tiny = tmp_path / "tiny-sdk"
    image_id, _, _ = fixture.oci_archive(tiny, nested=True)
    saved_sdk = tmp_path / "sdk-artifact"

    def save(arguments):
        assert arguments[:4] == ["docker", "image", "save", "--output"]
        assert arguments[-1] == image_id
        Path(arguments[4]).write_bytes((tiny / "image.tar").read_bytes())

    with (
        patch.object(artifacts.subprocess, "check_output", return_value=SOURCE + "\n"),
        patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"}),
        patch.object(application.sdk, "inspect", return_value=image_id),
        patch.object(application.sdk, "run", side_effect=save) as commands,
    ):
        application.save_sdk(SOURCE, "foresight-sdk:pr", saved_sdk)
    assert commands.call_count == 1  # Save existing bytes; no SDK build/run.
    prefix = tmp_path / "sdk-prefix"
    artifacts.unpack("linux-sdk", artifacts.fingerprint("linux-sdk"), saved_sdk, prefix)
    if bad_field:
        descriptor = json.loads((prefix / "image.json").read_text())
        descriptor[bad_field] = "b" * (40 if bad_field == "source_scope" else 64)
        (prefix / "image.json").write_text(json.dumps(descriptor))
        with (
            patch.object(
                artifacts.subprocess, "check_output", return_value=SOURCE + "\n"
            ),
            patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"}),
        ):
            artifacts.pack(
                "linux-sdk", artifacts.fingerprint("linux-sdk"), prefix, saved_sdk
            )
    saved = tmp_path / "sdk.zip"
    with zipfile.ZipFile(saved, "w") as archive:
        for name in ("identity.json", "payload.tar.gz"):
            archive.write(saved_sdk / name, name)
    checksum = artifacts.digest(saved)
    run, artifact, job = copy.deepcopy(producer[3:])
    run["head_repository"]["full_name"] = "fork/foresight"
    artifact.update(name=f"integration-sdk-{SOURCE}-1", digest="sha256:" + checksum)
    values = (prefix, saved, checksum, run, artifact, job)
    if bad_field:
        with pytest.raises(ValueError, match="source-scoped recipe|archive checksum"):
            restore(
                tmp_path,
                values,
                head_repository="fork/foresight",
                component="linux-sdk",
            )
    else:
        _, restored, qualification = restore(
            tmp_path, values, head_repository="fork/foresight", component="linux-sdk"
        )
        assert (restored / "image.tar").read_bytes() == (
            tiny / "image.tar"
        ).read_bytes()
        assert qualification["producer_attempt"] == 1
        assert qualification["source_receipt"]["source_run_attempt"] == 1


def test_zip_corruption_is_rejected_before_installation(tmp_path, producer):
    producer[1].write_bytes(producer[1].read_bytes() + b"corrupt bytes")
    with pytest.raises(ValueError, match="ZIP digest"):
        restore(tmp_path, producer)
    assert not (tmp_path / "restored").exists()


def test_receipt_cannot_relabel_original_attempt(tmp_path, producer):
    payload, saved, _, run, artifact, job = producer
    with zipfile.ZipFile(saved) as original:
        receipt = json.loads(original.read("identity.json"))
        data = original.read("payload.tar.gz")
    receipt["source_run_attempt"] = 2
    with zipfile.ZipFile(saved, "w") as changed:
        changed.writestr("identity.json", json.dumps(receipt))
        changed.writestr("payload.tar.gz", data)
    checksum = artifacts.digest(saved)
    artifact["digest"] = "sha256:" + checksum
    with pytest.raises(ValueError, match="original attempt"):
        restore(tmp_path, (payload, saved, checksum, run, artifact, job))
    assert not (tmp_path / "restored").exists()


def test_fork_source_is_explicit_and_does_not_change_the_producer_repository(
    tmp_path, producer
):
    producer[3]["head_repository"]["full_name"] = "fork/foresight"
    _, _, qualification = restore(tmp_path, producer, head_repository="fork/foresight")
    assert qualification["producer_repository"] == REPOSITORY
    assert qualification["source_repository"] == "fork/foresight"


def test_duplicate_successful_producer_attempt_is_rejected(tmp_path, producer):
    job = producer[5]
    with patch.object(
        artifacts, "dependency_jobs", return_value=[job, {**job, "id": JOB + 1}]
    ):
        with pytest.raises(ValueError, match="one successful original"):
            restore(tmp_path, producer)
    assert not (tmp_path / "restored").exists()


@pytest.mark.parametrize("unexpected_member", [False, True])
def test_api_zip_digest_cannot_replace_payload_integrity_or_archive_inventory(
    tmp_path, producer, unexpected_member
):
    payload, saved, _, run, artifact, job = producer
    with zipfile.ZipFile(saved) as original:
        receipt = original.read("identity.json")
        data = original.read("payload.tar.gz")
    with zipfile.ZipFile(saved, "w") as changed:
        changed.writestr("identity.json", receipt)
        changed.writestr(
            "payload.tar.gz", data if unexpected_member else data + b"corrupt"
        )
        if unexpected_member:
            changed.writestr("../unexpected", b"escape")
    checksum = artifacts.digest(saved)
    artifact["digest"] = "sha256:" + checksum
    with pytest.raises(ValueError, match="artifact members|payload checksum"):
        restore(tmp_path, (payload, saved, checksum, run, artifact, job))
    assert not (tmp_path / "restored").exists()
