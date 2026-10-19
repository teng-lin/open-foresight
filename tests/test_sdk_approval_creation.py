"""Approval creation retains real archive checksums and original provenance."""

import hashlib
import io
import json
from pathlib import Path
import sys
import zipfile

import pytest
from tools import ci_artifacts as artifacts
from tools import create_sdk_approval as create
from test_sdk_approval_bridge import original as original
from test_sdk_approval_bridge import REPOSITORY, PRODUCER, FINAL


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


@pytest.fixture
def application_receipt(original):
    records = original["records"]
    source = PRODUCER
    component = "linux-app"
    record = rewrite_receipt(
        original,
        lambda value: value.update(
            component=component,
            identity=source,
            source_receipt={
                **value["source_receipt"],
                "component": component,
                "identity": source,
                "source_commit": source,
                "distribution": {"version": "1.2.3", "build_number": 42},
            },
        ),
    )
    payload, sidecar, run = (
        records["actions/artifacts/5"],
        records["actions/artifacts/6"],
        records["actions/runs/99"],
    )
    payload["name"], sidecar["name"] = (
        artifacts.name(component, source),
        artifacts.receipt_name(component, source),
    )
    run.update(path=".github/workflows/macos.yml", event="push", head_branch="main")
    original["job"]["name"] = "linux-bundle"
    records[f"actions/artifacts?name={sidecar['name']}&per_page=100"] = {
        "artifacts": [sidecar]
    }
    return record


def test_application_descriptor_uses_real_verified_sidecar_not_large_payload(
    original, application_receipt
):
    assert artifacts.application_descriptor(REPOSITORY, "linux-app", PRODUCER, 99) == {
        "version": "1.2.3",
        "build_number": 42,
    }
    assert original["downloads"] == [6]


@pytest.mark.parametrize(
    "failure", ["digest", "receipt", "attempt", "version", "build-number", "archive"]
)
def test_application_descriptor_rejects_corrupt_or_unqualified_metadata(
    original, application_receipt, failure
):
    if failure == "digest":
        original["records"]["actions/artifacts/5"]["digest"] = "sha256:" + "0" * 64
    elif failure == "attempt":
        original["job"]["run_attempt"] = 2
    elif failure == "archive":
        rewrite_receipt(original, extra=True)
    else:

        def change(value):
            receipt = value["source_receipt"]
            if failure == "receipt":
                receipt["schema"] = 2
            else:
                receipt["distribution"][
                    "version" if failure == "version" else "build_number"
                ] = "bad" if failure == "version" else True

        rewrite_receipt(original, change)
    with pytest.raises(ValueError):
        artifacts.application_descriptor(REPOSITORY, "linux-app", PRODUCER, 99)


@pytest.mark.parametrize("available", [False, True])
def test_application_descriptor_legacy_fallback_still_requires_verified_payload(
    original, application_receipt, monkeypatch, available
):
    sidecar = original["records"]["actions/artifacts/6"]
    sidecar["expired"] = True

    def pull(repository, component, source, prefix, *, source_run):
        assert source_run == 99
        if available:
            prefix.mkdir()
            (prefix / "application.build.json").write_text(
                json.dumps(
                    {"revision": PRODUCER, "version": "1.2.3", "build_number": 42}
                )
            )
        return available

    monkeypatch.setattr(artifacts, "pull", pull)
    if available:
        assert (
            artifacts.application_descriptor(REPOSITORY, "linux-app", PRODUCER, 99)[
                "build_number"
            ]
            == 42
        )
    else:
        with pytest.raises(ValueError, match="unavailable"):
            artifacts.application_descriptor(REPOSITORY, "linux-app", PRODUCER, 99)
