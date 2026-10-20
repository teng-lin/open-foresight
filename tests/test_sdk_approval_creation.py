"""Approval creation retains real archive checksums and original provenance."""

import hashlib
import io
import json
from pathlib import Path
import sys
import zipfile

import pytest
import test_ci_release_candidates as candidate_fixtures
from tools import ci_artifacts as artifacts
from tools import create_sdk_approval as create
from test_sdk_approval_bridge import original as original
from test_sdk_approval_bridge import REPOSITORY, PRODUCER, FINAL
from test_ci_release_candidates import (
    SOURCE as CANDIDATE_SOURCE,
    REPOSITORY as CANDIDATE_REPOSITORY,
)


# Expose the imported real fixture under the dependency name used below.
tested_producer = candidate_fixtures.producer


@pytest.fixture(autouse=True, params=[None, "refs/heads/main", "refs/pull/987/merge"])
def explicit_ci_metadata(request, monkeypatch):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_SHA", PRODUCER)
    monkeypatch.setenv("GITHUB_RUN_ID", "99")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    if request.param:
        monkeypatch.setenv("GITHUB_REF", request.param)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)
    return request.param


@pytest.fixture
def producer(tested_producer, explicit_ci_metadata, monkeypatch):
    # Packing supplies original attempt 1; the consuming rerun remains attempt 7.
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "7")
    if explicit_ci_metadata:
        monkeypatch.setenv("GITHUB_REF", explicit_ci_metadata)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)
    return tested_producer


def git_boundary(original, monkeypatch):
    sources = original["source"]

    def output(command, **kwargs):
        if command[:2] == ["git", "ls-tree"]:
            source = sources[command[-1]]
            return (
                b"".join(
                    f"{mode} blob {'a' * 40}\t{name}\0".encode()
                    for name, (mode, content) in source.items()
                )
                + b"160000 commit ignored\tsubmodule\0"
            )
        assert command[:2] == ["git", "show"]
        commit, name = command[-1].split(":", 1)
        return sources[commit][name][1]

    monkeypatch.setattr(create.subprocess, "check_output", output)


def rewrite_receipt(original, change=None, *, extra=False):
    raw = original["payloads"][6]
    with zipfile.ZipFile(io.BytesIO(raw)) as source:
        value = json.loads(source.read("receipt.json"))
    if change:
        change(value)
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr("receipt.json", json.dumps(value))
        if extra:
            archive.writestr("unexpected", "not permitted")
    original["payloads"][6] = stream.getvalue()
    original["records"]["actions/artifacts/6"]["digest"] = (
        "sha256:" + hashlib.sha256(stream.getvalue()).hexdigest()
    )
    return value


def test_approval_creation_proves_inputs_and_preserves_producer_receipt(
    original, monkeypatch
):
    git_boundary(original, monkeypatch)
    entry = create.build_entry(
        Path("."), REPOSITORY, "linux-core", PRODUCER, FINAL, 111, 6
    )
    assert entry == {
        **original["entry"],
        "producer_pr": 111,
        "producer_event": "pull_request",
        "producer_branch": "feature",
    }
    assert original["downloads"] == [6]
    assert entry["source_receipt"]["source_commit"] != FINAL
    assert (
        entry["artifact_digest"] == original["records"]["actions/artifacts/5"]["digest"]
    )


@pytest.mark.parametrize(
    "failure",
    [
        "recipe",
        "mode",
        "sidecar-expired",
        "sidecar-name",
        "archive-extra",
        "receipt",
        "payload-expired",
        "digest",
        "workflow",
        "repository",
        "head",
        "job",
        "attempt",
        "upload",
    ],
)
def test_approval_creation_rejects_every_unproven_boundary(
    original, monkeypatch, failure
):
    git_boundary(original, monkeypatch)
    records = original["records"]
    if failure in ("recipe", "mode"):
        original["source"][FINAL]["packaging/sdk-core.Dockerfile"] = (
            "100755" if failure == "mode" else "100644",
            b"changed" if failure == "recipe" else b"FROM pinned@sha256:abc\n",
        )
    elif failure == "sidecar-expired":
        records["actions/artifacts/6"]["expired"] = True
    elif failure == "sidecar-name":
        records["actions/artifacts/6"]["name"] = "wrong"
    elif failure == "archive-extra":
        rewrite_receipt(original, extra=True)
    elif failure == "receipt":
        rewrite_receipt(
            original, lambda value: value["source_receipt"].update(schema=2)
        )
    elif failure == "payload-expired":
        records["actions/artifacts/5"]["expired"] = True
    elif failure == "digest":
        records["actions/artifacts/5"]["digest"] = "sha256:" + "0" * 64
    elif failure in ("workflow", "repository", "head"):
        run = records["actions/runs/99"]
        if failure == "workflow":
            run["path"] = "other-workflow"
        elif failure == "repository":
            run["head_repository"]["full_name"] = "fork/repo"
        else:
            run["head_sha"] = FINAL
    elif failure == "job":
        original["job"]["conclusion"] = "failure"
    elif failure == "attempt":
        original["job"]["run_attempt"] = 2
    else:
        records["actions/artifacts/5"]["created_at"] = "2026-10-18T02:00:00Z"
    with pytest.raises(ValueError):
        create.build_entry(Path("."), REPOSITORY, "linux-core", PRODUCER, FINAL, 111, 6)


def test_git_source_rejects_nonimmutable_commit_before_git(monkeypatch):
    command = []
    monkeypatch.setattr(
        create.subprocess, "check_output", lambda *a, **kw: command.append(a)
    )
    with pytest.raises(ValueError, match="exact commit"):
        create.git_source(Path("."), "main")
    assert not command


@pytest.mark.parametrize("existing", [False, True])
def test_approval_cli_replaces_only_requested_component(
    tmp_path, monkeypatch, existing
):
    output = tmp_path / "approvals.json"
    if existing:
        output.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "entries": [
                        {"component": "linux-core", "old": True},
                        {"component": "macos-sdk", "original": True},
                    ],
                }
            )
        )
    entry = {"component": "linux-core", "producer_source": PRODUCER}
    monkeypatch.setattr(create, "build_entry", lambda *a: entry)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "create",
            "--component",
            "linux-core",
            "--producer-source",
            PRODUCER,
            "--approved-source",
            FINAL,
            "--approved-pr",
            "111",
            "--sidecar-id",
            "6",
            "--output",
            str(output),
        ],
    )
    create.main()
    entries = json.loads(output.read_text())["entries"]
    assert entries[-1] == entry
    assert len(entries) == (2 if existing else 1)
    if existing:
        assert entries[0] == {"component": "macos-sdk", "original": True}


def test_application_descriptor_uses_real_verified_sidecar_not_large_payload(producer):
    payload = producer.item(artifacts.name("linux-app", CANDIDATE_SOURCE))
    sidecar = producer.item(artifacts.receipt_name("linux-app", CANDIDATE_SOURCE))
    assert artifacts.application_descriptor(
        CANDIDATE_REPOSITORY,
        "linux-app",
        CANDIDATE_SOURCE,
        42,
        consumer="release-preparation",
    ) == {"version": "1.2.3", "build_number": 7}
    assert sidecar["id"] in producer.downloads
    assert payload["id"] not in producer.downloads


@pytest.mark.parametrize(
    "failure", ["digest", "receipt", "attempt", "version", "build-number", "archive"]
)
def test_application_descriptor_rejects_corrupt_or_unqualified_metadata(
    producer, failure
):
    sidecar = producer.item(artifacts.receipt_name("linux-app", CANDIDATE_SOURCE))
    if failure == "digest":
        producer.item(artifacts.name("linux-app", CANDIDATE_SOURCE))["digest"] = (
            "sha256:" + "0" * 64
        )
    elif failure == "attempt":
        producer.jobs[0]["run_attempt"] = 2
    elif failure == "archive":
        buffer = io.BytesIO(producer.blobs[sidecar["id"]])
        with zipfile.ZipFile(buffer, "a") as bundle:
            bundle.writestr("unexpected.json", "{}")
        producer.blobs[sidecar["id"]] = buffer.getvalue()
        sidecar["digest"] = "sha256:" + hashlib.sha256(buffer.getvalue()).hexdigest()
        sidecar["size_in_bytes"] = len(buffer.getvalue())
    else:

        def change(record):
            receipt = record["source_receipt"]
            if failure == "receipt":
                receipt["schema"] = 2
            else:
                receipt["distribution"][
                    "version" if failure == "version" else "build_number"
                ] = "bad" if failure == "version" else True

        producer.change(sidecar["name"], change)
    expected = {
        "digest": "sidecar does not bind its original payload",
        "receipt": "mismatched.*original receipt",
        "attempt": "Candidate index differs from required source, tier, original receipt job or latest gates",
        "version": "no stamped distribution identity",
        "build-number": "no stamped distribution identity",
        "archive": "Unexpected candidate evidence archive members",
    }[failure]
    with pytest.raises(ValueError, match=expected):
        artifacts.application_descriptor(
            CANDIDATE_REPOSITORY,
            "linux-app",
            CANDIDATE_SOURCE,
            42,
            consumer="release-preparation",
        )
    if failure != "attempt":
        assert sidecar["id"] in producer.downloads
    assert "actions/runs/42" in producer.requests


def test_application_descriptor_missing_sidecar_fails_without_payload_fallback(
    producer, monkeypatch
):
    producer.item(artifacts.receipt_name("linux-app", CANDIDATE_SOURCE))["expired"] = (
        True
    )
    from unittest.mock import Mock

    pull = Mock()
    monkeypatch.setattr(artifacts, "pull", pull)
    with pytest.raises(ValueError, match="Missing or expired original upload"):
        artifacts.application_descriptor(
            CANDIDATE_REPOSITORY,
            "linux-app",
            CANDIDATE_SOURCE,
            42,
            consumer="release-preparation",
        )
    pull.assert_not_called()
    assert (
        producer.item(artifacts.name("linux-app", CANDIDATE_SOURCE))["id"]
        not in producer.downloads
    )
