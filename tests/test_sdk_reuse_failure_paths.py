"""A failed qualification must never turn into permission to rebuild an SDK."""

import copy
import hashlib
import io
import json
import runpy
import subprocess
import sys
import zipfile
from unittest.mock import Mock

import pytest

from tools import ci_artifacts as artifacts
from tools import ci_registry as registry
from tools import sdk_approval_bridge as bridge
from tools import sdk_producer_trust as trust
from test_sdk_approval_bridge import original as original
from test_sdk_approval_bridge import FINAL, PRODUCER, REPOSITORY, SEMANTIC
from test_sdk_producer_trust import git_api


@pytest.fixture(autouse=True, params=[None, "refs/heads/main", "refs/pull/987/merge"])
def ci_context(request, monkeypatch):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_SHA", FINAL)
    monkeypatch.setenv("GITHUB_RUN_ID", "1234")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    if request.param:
        monkeypatch.setenv("GITHUB_REF", request.param)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)


def approve(original):
    return bridge.approved(
        original["entry"],
        REPOSITORY,
        "linux-core",
        SEMANTIC,
        api=artifacts.api,
        read_source=artifacts.producer_trust.read_source,
        merged_source=artifacts.merged_source,
    )


@pytest.mark.parametrize(
    "failure",
    [
        "repository",
        "source",
        "producer",
        "identity",
        "fork",
        "diverged",
        "missing-member",
        "mode",
    ],
)
def test_approval_rejects_invalid_final_source_without_downloading(original, failure):
    entry = original["entry"]
    entry["producer_pr"] = entry["approved_pr"]
    if failure in ("repository", "source", "producer", "identity"):
        field = {
            "repository": "repository",
            "source": "approved_source",
            "producer": "producer_source",
            "identity": "legacy_identity",
        }[failure]
        entry[field] = "invalid"
    elif failure == "fork":
        original["records"]["pulls/111"]["base"]["repo"]["full_name"] = "fork/repo"
    elif failure == "diverged":
        original["records"][f"compare/{PRODUCER}...{FINAL}"]["status"] = "diverged"
    elif failure == "missing-member":
        original["records"]["pulls/111/commits?per_page=100&page=1"] = []
    else:
        mode, data = original["source"][FINAL]["packaging/sdk-core.Dockerfile"]
        original["source"][FINAL]["packaging/sdk-core.Dockerfile"] = ("100755", data)
    assert not approve(original)
    assert original["downloads"] == []


@pytest.mark.parametrize("member", [True, False])
def test_approval_paginates_commit_membership_and_caps_unbounded_history(
    original, member
):
    original["entry"]["producer_pr"] = 111
    records = original["records"]
    for page in range(1, 31):
        records[f"pulls/111/commits?per_page=100&page={page}"] = [
            {"sha": "0" * 40}
        ] * 100
    if member:
        records["pulls/111/commits?per_page=100&page=2"] = [{"sha": PRODUCER}]
    assert approve(original) is member


def test_legacy_definition_is_data_and_parent_lock_comments_do_not_change_identity():
    definition = b"FILES = {'child':['requirements-dev.lock'], 'parent':['recipe']}\nPRODUCER_INPUTS = ()\nPARENTS = {'child':['parent']}\nignored = 1\nignored.attribute = 2\na = b = 3\nraise RuntimeError('never execute historical source')\n"
    source = {
        "tools/ci_artifacts.py": definition,
        "recipe": b"compiler",
        "requirements-dev.lock": b"# generated\npkg==1 \\\n    --hash=sha256:abc\n",
    }
    first, proof = bridge.legacy_proof("child", source.__getitem__)
    assert bridge.legacy_paths("child", bridge.legacy_definition(definition)) == {
        "requirements-dev.lock",
        "recipe",
    }
    source["requirements-dev.lock"] = source["requirements-dev.lock"].replace(
        b"# generated", b"# regenerated"
    )
    second, changed_proof = bridge.legacy_proof("child", source.__getitem__)
    assert first == second
    assert proof != changed_proof  # Approval still binds the exact historical bytes.
    source["recipe"] = b"different compiler"
    assert bridge.legacy_proof("child", source.__getitem__)[0] != first
    with pytest.raises(ValueError, match="Unsupported legacy"):
        bridge.legacy_definition("FILES = {}")
    for path in ("/absolute", "../outside"):
        source["tools/ci_artifacts.py"] = (
            f"FILES = {{'child': [{path!r}]}}\nPRODUCER_INPUTS = ()\nPARENTS = {{}}\n".encode()
        )
        with pytest.raises(ValueError, match="Invalid legacy input"):
            bridge.legacy_proof("child", source.__getitem__)


def test_missing_or_unknown_manifest_does_not_authorize_legacy_reuse(original):
    bridge.MANIFEST.unlink()
    assert bridge.entries(REPOSITORY, "linux-core", SEMANTIC) == []
    bridge.MANIFEST.write_text('{"schema":2,"entries":[]}')
    with pytest.raises(ValueError, match="Unsupported SDK migration"):
        bridge.entries(REPOSITORY, "linux-core", SEMANTIC)


@pytest.mark.parametrize(
    "failure",
    ["extra-file", "oversized", "reference", "timestamp", "expired", "outside-job"],
)
def test_original_sidecar_rejected_after_real_checksum_verification(original, failure):
    records = original["records"]
    if failure in ("extra-file", "oversized", "reference"):
        with zipfile.ZipFile(io.BytesIO(original["payloads"][6])) as archive:
            data = archive.read("receipt.json")
        if failure == "oversized":
            data += b" " * 16385
        elif failure == "reference":
            value = json.loads(data)
            value["artifact_id"] = 987
            data = json.dumps(value).encode()
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            archive.writestr("receipt.json", data)
            if failure == "extra-file":
                archive.writestr("unexpected", b"untrusted")
        original["payloads"][6] = output.getvalue()
        digest = "sha256:" + hashlib.sha256(output.getvalue()).hexdigest()
        records["actions/artifacts/6"]["digest"] = digest
        original["entry"]["sidecar_digest"] = digest
        original["save"]()
    elif failure == "timestamp":
        records["actions/artifacts/6"]["created_at"] = "invalid"
    elif failure == "expired":
        records["actions/artifacts/5"]["expires_at"] = "2020-01-01T00:00:00Z"
    else:
        records["actions/artifacts/6"]["created_at"] = "2026-10-18T02:00:00Z"
    assert not artifacts.probe(REPOSITORY, "linux-core", SEMANTIC)
    assert original["downloads"] == [6]


@pytest.mark.parametrize(
    "mutation",
    [
        "commit-sha",
        "tree-sha",
        "directory",
        "blob-id",
        "blob-encoding",
        "missing-input",
    ],
)
def test_source_proof_rejects_invalid_git_objects(mutation):
    base = git_api({"recipe": b"verified recipe"})

    def api(repository, route):
        value = copy.deepcopy(base(repository, route))
        if route.startswith("git/commits/") and mutation == "commit-sha":
            value["sha"] = "0" * 40
        elif route.startswith("git/trees/"):
            if mutation == "tree-sha":
                value["sha"] = "0" * 40
            elif mutation == "directory":
                value["tree"].insert(0, {"path": "directory", "type": "tree"})
            elif mutation == "blob-id":
                value["tree"][0]["sha"] = "mutable"
        elif route.startswith("git/blobs/") and mutation == "blob-encoding":
            value["encoding"] = "raw"
        return value

    if mutation == "directory":
        assert trust.read_source(REPOSITORY, PRODUCER, api=api) == {
            "recipe": ("100644", b"verified recipe")
        }
    else:
        with pytest.raises(ValueError):
            trust.read_source(
                REPOSITORY,
                PRODUCER,
                api=api,
                paths=("absent",) if mutation == "missing-input" else None,
            )


@pytest.mark.parametrize("commit", ["main", None, "a" * 39])
def test_fingerprint_rejects_mutable_revision_before_api(commit):
    api = Mock(side_effect=AssertionError("must not read mutable source"))
    with pytest.raises(ValueError, match="Invalid SDK producer commit"):
        trust.source_fingerprint(
            REPOSITORY,
            commit,
            "child",
            api=api,
            fingerprint=Mock(),
            files={},
            parents={},
        )
    with pytest.raises(ValueError, match="Invalid SDK producer commit"):
        trust.read_source(REPOSITORY, commit, api=api)
    api.assert_not_called()


@pytest.mark.parametrize(
    "diagnostic",
    ["unauthorized", "forbidden", "connection timed out", "manifest unknown"],
)
def test_registry_transport_or_missing_pinned_digest_cannot_authorize_build(
    monkeypatch, diagnostic
):
    monkeypatch.setattr(
        registry.subprocess,
        "run",
        lambda *a, **kw: subprocess.CompletedProcess(a, 1, "", diagnostic),
    )
    with pytest.raises(RuntimeError):
        registry.inspect("ghcr.io/owner/sdk@sha256:" + "a" * 64)


@pytest.mark.parametrize(
    "state", ["present", "absent", "required-missing", "bad-digest"]
)
def test_registry_cli_writes_build_decision_only_after_successful_lookup(
    tmp_path, monkeypatch, state
):
    destination = tmp_path / "output"
    destination.write_text("existing=true\n")
    monkeypatch.setenv("GITHUB_OUTPUT", str(destination))
    args = ["ci_registry.py", "ghcr.io/owner/sdk:current"]
    if state == "required-missing":
        args.append("--require")
    monkeypatch.setattr(sys, "argv", args)
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *a, **kw: subprocess.CompletedProcess(
            a,
            int(state in ("absent", "required-missing")),
            json.dumps(
                {"digest": "bad" if state == "bad-digest" else "sha256:" + "a" * 64}
            ),
            "manifest unknown",
        ),
    )
    if state in ("required-missing", "bad-digest"):
        with pytest.raises((SystemExit, ValueError)):
            runpy.run_path(registry.__file__, run_name="__main__")
        assert destination.read_text() == "existing=true\n"
    else:
        runpy.run_path(registry.__file__, run_name="__main__")
        output = destination.read_text()
        assert ("build=true" in output) == (state == "absent")
        assert ("image=ghcr.io/owner/sdk@sha256:" in output) == (state == "present")
