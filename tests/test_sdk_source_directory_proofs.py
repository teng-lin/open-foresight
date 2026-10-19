"""Approval binds all copied speech sources, including files outside old lists."""

import copy
from pathlib import Path

import pytest
from tools import ci_artifacts as artifacts
from tools import create_sdk_approval as create
from tools import sdk_approval_bridge as bridge
from test_sdk_approval_bridge import original as original
from test_sdk_approval_bridge import PRODUCER, FINAL, REPOSITORY, SEMANTIC
from test_sdk_approval_creation import git_boundary


@pytest.fixture(autouse=True, params=[None, "refs/heads/main", "refs/pull/987/merge"])
def ci_context(request, monkeypatch):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_RUN_ID", "1234")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    if request.param:
        monkeypatch.setenv("GITHUB_REF", request.param)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)


def runtime_sources(original):
    sources = original["source"]
    for tree in sources.values():
        mode, data = tree["tools/ci_artifacts.py"]
        tree["tools/ci_artifacts.py"] = (
            mode,
            data.replace(b"linux-core", b"linux-sdk"),
        )
        tree["services/speech/new.h"] = ("100644", b"consumed speech header")
    return sources


@pytest.mark.parametrize("failure", [None, "added", "changed", "missing-input"])
def test_creation_checks_full_directory_before_accepting_sidecar(
    original, monkeypatch, failure
):
    sources = runtime_sources(original)
    if failure == "added":
        sources[FINAL]["services/speech/extra.h"] = ("100644", b"new consumed source")
    elif failure == "changed":
        sources[FINAL]["services/speech/new.h"] = ("100644", b"changed consumed source")
    elif failure == "missing-input":
        del sources[FINAL]["packaging/sdk-core.Dockerfile"]
    git_boundary(original, monkeypatch)
    with pytest.raises(
        ValueError,
        match="regular legacy source"
        if failure == "missing-input"
        else "source directories differ"
        if failure
        else "Sidecar does not match",
    ):
        create.build_entry(Path("."), REPOSITORY, "linux-sdk", PRODUCER, FINAL, 111, 6)
    assert not original["downloads"]


@pytest.mark.parametrize(
    "failure", [None, "changed-header", "removed-header", "executable-header"]
)
def test_bridge_approval_binds_entire_speech_directory(original, failure):
    sources = runtime_sources(original)
    entry = copy.deepcopy(original["entry"])
    entry["component"] = "linux-sdk"
    entry["legacy_identity"], entry["legacy_inputs"] = bridge.legacy_proof(
        "linux-sdk", lambda path: sources[PRODUCER][path][1]
    )
    if failure == "changed-header":
        sources[FINAL]["services/speech/new.h"] = ("100644", b"changed")
    elif failure == "removed-header":
        del sources[FINAL]["services/speech/new.h"]
    elif failure == "executable-header":
        sources[FINAL]["services/speech/new.h"] = ("100755", b"consumed speech header")
    assert bridge.approved(
        entry,
        REPOSITORY,
        "linux-sdk",
        SEMANTIC,
        api=artifacts.api,
        read_source=lambda repo, source, **kw: sources[source],
        merged_source=lambda *a: True,
    ) is (failure is None)
