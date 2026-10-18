"""Only reviewed final trees reachable through authoritative merges are promoted."""

from unittest.mock import patch

import pytest

from tools import ci_artifacts as artifacts

HEAD = "a" * 40
MERGE = "b" * 40
TREE = "c" * 40
REPOSITORY = "owner/repo"


def producer():
    return {
        "head_sha": HEAD,
        "head_branch": "feature",
        "event": "pull_request",
        "path": ".github/workflows/ci-dependencies.yml",
        "head_repository": {"full_name": REPOSITORY},
        "pull_requests": [{"number": 23}],
    }


def responses():
    return {
        "pulls/23": {
            "merged_at": "2026-10-18",
            "head": {"sha": HEAD},
            "base": {"repo": {"full_name": REPOSITORY}},
            "merge_commit_sha": MERGE,
        },
        f"compare/{HEAD}...main": {"status": "diverged"},
        f"compare/{MERGE}...main": {"status": "ahead"},
        f"git/commits/{HEAD}": {"sha": HEAD, "tree": {"sha": TREE}},
        f"git/commits/{MERGE}": {"sha": MERGE, "tree": {"sha": TREE}},
    }


def accepted(records, run=None):
    def api(repository, route):
        assert repository == REPOSITORY
        return records[route]

    with patch.object(artifacts, "api", side_effect=api):
        return artifacts.eligible_run(REPOSITORY, run or producer(), "macos-sdk")


@pytest.mark.parametrize("status", ["ahead", "identical"])
def test_rebase_merge_promotes_identical_final_tree_on_main(status):
    records = responses()
    records[f"compare/{MERGE}...main"]["status"] = status
    assert accepted(records)


@pytest.mark.parametrize("status", ["behind", "diverged"])
def test_equal_tree_outside_main_is_not_promoted(status):
    records = responses()
    records[f"compare/{MERGE}...main"]["status"] = status
    assert not accepted(records)


@pytest.mark.parametrize(
    "route,field,value",
    [
        (f"git/commits/{MERGE}", "tree", {"sha": "d" * 40}),
        (f"git/commits/{MERGE}", "tree", {"sha": "malformed"}),
        (f"git/commits/{MERGE}", "sha", "d" * 40),
        ("pulls/23", "merge_commit_sha", "main"),
        ("pulls/23", "merge_commit_sha", None),
        ("pulls/23", "head", {"sha": "d" * 40}),
        ("pulls/23", "merged_at", None),
        ("pulls/23", "base", {"repo": {"full_name": "other/repo"}}),
    ],
)
def test_rebase_merge_rejects_unproven_final_tree(route, field, value):
    records = responses()
    records[route][field] = value
    assert not accepted(records)


@pytest.mark.parametrize(
    "change",
    [
        {"head_repository": {"full_name": "fork/repo"}},
        {"path": ".github/workflows/untrusted.yml"},
        {"event": "push"},
        {"head_sha": "not-a-sha"},
    ],
)
def test_tree_equivalence_does_not_relax_workflow_or_repository_trust(change):
    assert not accepted(responses(), {**producer(), **change})
