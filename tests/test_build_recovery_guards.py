"""Failed reuse/recovery validation preserves existing compiler and release work."""

import base64
import hashlib
import io
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


def test_unstable_candidate_source_stops_before_lookup_or_allocation(monkeypatch):
    monkeypatch.setattr(
        candidates.subprocess, "check_output", lambda *a, **kw: "version: 1.2.3-dev+4\n"
    )
    lookup, allocate = Mock(), Mock()
    monkeypatch.setattr(candidates, "candidate_runs", lookup)
    monkeypatch.setattr(candidates, "allocate", allocate)
    with pytest.raises(ValueError, match="must declare a stable version"):
        candidates.number("owner/repo", SOURCE)
    lookup.assert_not_called()
    allocate.assert_not_called()


def test_new_candidate_allocates_only_after_tested_candidate_lookup(monkeypatch):
    monkeypatch.setattr(candidates, "source_version", lambda *a: ("1.2.3", 4))
    candidate_runs = Mock(return_value={})
    monkeypatch.setattr(candidates, "candidate_runs", candidate_runs)
    allocate = Mock(return_value=7)
    monkeypatch.setattr(candidates, "allocate", allocate)
    assert candidates.number("owner/repo", SOURCE) == 7
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
    state = acceptance_fixture(monkeypatch)
    if failure == "missing-summary":
        state.items[42][0]["name"] = "unrelated"
    elif failure == "archive":
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            archive.writestr("untrusted", json.dumps(state.report))
        raw = payload.getvalue()
        state.blobs[42] = raw
        state.items[42][0].update(
            digest="sha256:" + hashlib.sha256(raw).hexdigest(), size_in_bytes=len(raw)
        )
    else:
        state.add(42, {**state.report, "status": "failed"})
    message = {
        "missing-summary": "Missing or expired original upload",
        "archive": "Unexpected candidate evidence archive members",
        "status": "Original automated acceptance is incomplete or obsolete",
    }[failure]
    with pytest.raises(ValueError, match=message):
        acceptance.restore("owner/repo", "v0.1.2", 42)
    assert state.downloads == ([] if failure == "missing-summary" else [42])


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
