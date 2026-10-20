"""Failed reuse/recovery validation preserves existing compiler and release work."""

import base64
import json
from unittest.mock import Mock
import zipfile

import pytest
from tools import candidate_identity as candidates
from tools import build_sequence as sequence
from tools import release_inputs as inputs
from tools import release_upload as uploads
from tools import reuse_release_acceptance as acceptance
from tools import verify_app_dependency_reuse as reuse
from test_reuse_release_acceptance import fixture as acceptance_fixture

SOURCE = "a" * 40


@pytest.mark.parametrize("failure", ["symlink", "make-path", "make-graph"])
def test_dependency_guard_rejects_unqualified_backend_without_compiling(
    tmp_path, failure
):
    dependencies = tmp_path / "_deps"
    dependencies.mkdir()
    for name in ("flatbuffers-build", "sentencepiece-build"):
        (dependencies / name).mkdir()
    precious = dependencies / "sentencepiece-build/object.o"
    precious.write_bytes(b"verified expensive object")
    if failure == "symlink":
        (dependencies / "extra-build").symlink_to(dependencies / "flatbuffers-build")
    cache = "CMAKE_MAKE_PROGRAM:FILEPATH=" + (
        "make" if failure == "make-path" else "/usr/bin/make"
    )
    message = {
        "symlink": "must be regular directories",
        "make-path": "configured Make executable",
        "make-graph": "Make ALL graph is missing",
    }[failure]
    with pytest.raises(ValueError, match=message):
        reuse.dependency_dry_runs(tmp_path, cache, "Unix Makefiles")
    assert precious.read_bytes() == b"verified expensive object"


@pytest.mark.parametrize(
    "failure", ["unstable-source", "version", "number", "below-minimum"]
)
def test_candidate_recovery_never_relabels_surviving_platforms(monkeypatch, failure):
    monkeypatch.setattr(
        candidates.subprocess,
        "check_output",
        lambda *a, **kw: (
            "version: 1.2.3+4\n"
            if failure != "unstable-source"
            else "version: 1.2.3-dev+4\n"
        ),
    )
    candidate_runs = Mock(return_value={"macos-app": 41})
    monkeypatch.setattr(candidates, "candidate_runs", candidate_runs)
    allocate = Mock(side_effect=AssertionError("must retain allocated identity"))
    monkeypatch.setattr(candidates, "allocate", allocate)
    monkeypatch.setattr(
        candidates,
        "application_descriptor",
        lambda repo, component, *a, **kw: {
            "version": "9.9.9" if failure == "version" else "1.2.3",
            "build_number": True
            if failure == "number"
            else 3
            if failure == "below-minimum"
            else 5,
        },
    )
    message = {
        "unstable-source": "must declare a stable version",
        "version": "distribution identity is incompatible",
        "number": "distribution identity is incompatible",
        "below-minimum": "distribution identity is incompatible",
    }[failure]
    with pytest.raises(ValueError, match=message):
        candidates.number("owner/repo", SOURCE, "linux")
    allocate.assert_not_called()
    if failure != "unstable-source":
        candidate_runs.assert_called_once_with(
            "owner/repo", SOURCE, consumer="release-candidate"
        )


def test_explicit_candidate_replacement_records_reason_before_allocating(
    monkeypatch, capsys
):
    monkeypatch.setattr(candidates, "source_version", lambda *a: ("1.2.3", 4))
    candidate_runs = Mock(return_value={"macos-app": 41})
    monkeypatch.setattr(candidates, "candidate_runs", candidate_runs)
    allocate = Mock(return_value=7)
    monkeypatch.setattr(candidates, "allocate", allocate)
    assert (
        candidates.number(
            "owner/repo", SOURCE, "macos", "Changed embedded OAuth registration"
        )
        == 7
    )
    assert "Changed embedded OAuth registration" in capsys.readouterr().out
    allocate.assert_called_once_with("owner/repo", 4)
    candidate_runs.assert_called_once_with(
        "owner/repo", SOURCE, consumer="release-candidate"
    )


@pytest.mark.parametrize("failure", ["negative", "conflicts", "permission"])
def test_build_number_allocation_bounds_retries_and_propagates_authorization(
    monkeypatch, failure
):
    mutations = []

    def request(repo, route, method="GET", payload=None, optional=False):
        if route.startswith("git/ref/"):
            return {"object": {"sha": SOURCE}}
        if route.startswith("contents/"):
            return {"content": base64.b64encode(b'{"build":4}').decode()}
        if method == "PATCH":
            mutations.append(payload)
            raise RuntimeError("HTTP 409" if failure == "conflicts" else "HTTP 403")
        return {"sha": SOURCE}

    monkeypatch.setattr(sequence, "request", request)
    delay = Mock()
    monkeypatch.setattr(sequence.time, "sleep", delay)
    with pytest.raises((ValueError, RuntimeError)):
        sequence.allocate("owner/repo", -1 if failure == "negative" else 4)
    assert len(mutations) == (
        0 if failure == "negative" else 10 if failure == "conflicts" else 1
    )
    assert delay.call_count == (10 if failure == "conflicts" else 0)
    assert all(value == {"sha": SOURCE, "force": False} for value in mutations)


@pytest.mark.parametrize("failure", ["draft", "format", "digest", "source"])
def test_release_input_binding_rejects_changed_existing_installer(monkeypatch, failure):
    draft = {
        "draft": failure != "draft",
        "target_commitish": SOURCE,
        "body": "<!-- foresight-package-release: 2 -->",
        "assets": [
            {
                "name": "app.deb",
                "digest": "bad" if failure == "digest" else "sha256:" + "0" * 64,
            },
            {"name": "app.deb.sha256"},
            {"name": "app.deb.build.json", "id": 7},
        ],
    }
    monkeypatch.setattr(inputs, "release_source", lambda *a: SOURCE)
    monkeypatch.setattr(inputs, "release_for_tag", lambda *a: draft)
    monkeypatch.setattr(
        inputs,
        "api",
        lambda *a: {"commit": {"committer": {"date": "2026-10-19T00:00:00Z"}}},
    )
    monkeypatch.setattr(inputs.subprocess, "check_output", lambda *a, **kw: b"{}")
    monkeypatch.setattr(inputs, "source_revision", lambda *a: "b" * 40)
    message = {
        "draft": "exact source-bound unpublished draft",
        "format": "Unknown installer format",
        "digest": "no verified API digest",
        "source": "another product source",
    }[failure]
    with pytest.raises(ValueError, match=message):
        inputs.resolve(
            "owner/repo",
            "v1.2.3",
            SOURCE,
            formats="unknown" if failure == "format" else "deb",
        )


@pytest.mark.parametrize("failure", ["missing-summary", "archive", "status"])
def test_acceptance_reuse_requires_exact_successful_summary(monkeypatch, failure):
    run, job, artifact, assets = acceptance_fixture(monkeypatch)
    if failure == "missing-summary":
        artifact["name"] = "unrelated"
    else:
        report = {
            "tag": "other" if failure == "status" else "v0.1.2",
            "status": "failed",
        }

        def download(repo, metadata, destination):
            with zipfile.ZipFile(destination, "w") as archive:
                archive.writestr(
                    "untrusted" if failure == "archive" else "release-acceptance.json",
                    json.dumps(report),
                )

        monkeypatch.setattr(acceptance, "download_zip", download)
    message = {
        "missing-summary": "summary is missing or ambiguous",
        "archive": "Invalid acceptance archive",
        "status": "incomplete or for another release",
    }[failure]
    with pytest.raises(ValueError, match=message):
        acceptance.restore("owner/repo", "v0.1.2", 42)


@pytest.mark.parametrize("failure", ["missing", "source", "changed-remote"])
def test_upload_preserves_existing_assets_on_conflict(tmp_path, monkeypatch, failure):
    local = tmp_path / "app.deb"
    local.write_bytes(b"installer")
    monkeypatch.setattr(
        uploads,
        "release_for_tag",
        lambda *a: {
            "draft": True,
            "target_commitish": SOURCE,
            "assets": [{"name": local.name, "id": 7, "size": 1}],
        },
    )
    monkeypatch.setattr(uploads, "api", lambda *a: {"sha": SOURCE})
    monkeypatch.setattr(uploads, "verify_checksum", lambda *a: "0" * 64)
    (tmp_path / "app.deb.build.json").write_text("{}")
    monkeypatch.setattr(
        uploads,
        "source_revision",
        lambda *a: "b" * 40 if failure == "source" else SOURCE,
    )
    commands = []

    def command(args, **kw):
        commands.append(args)
        assert args[:2] == ["gh", "api"]  # Never reach upload on a conflict.
        kw["stdout"].write(b"other existing bytes")

    monkeypatch.setattr(uploads.subprocess, "run", command)
    message = {
        "missing": "Missing or duplicate package asset",
        "source": "immutable release source",
        "changed-remote": "Draft already contains different bytes",
    }[failure]
    with pytest.raises(ValueError, match=message):
        uploads.upload(
            "owner/repo",
            "v1.2.3",
            [tmp_path / "absent"] if failure == "missing" else [local],
        )
    assert local.read_bytes() == b"installer"
    assert bool(commands) == (failure == "changed-remote")
