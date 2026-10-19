"""Package-only CI consumes reviewed fixtures and never starts build workflows."""

from unittest.mock import patch

import pytest

from tools import package_contract_candidate as contract
from test_ci_promotion import candidate

SHA = "a" * 40
BASE = "b" * 40


@pytest.mark.parametrize("ref", ["refs/pull/987/merge", "refs/heads/main", ""])
@pytest.mark.parametrize("producer", [0, 42])
def test_acceptance_selects_original_product_not_controller_head(
    tmp_path, monkeypatch, ref, producer
):
    monkeypatch.setenv("GITHUB_REF", ref)
    artifact, run, job = candidate(tmp_path, monkeypatch)
    run.update(head_sha=BASE, event="workflow_dispatch")
    original = contract.ci_artifacts.api

    def api(repository, route):
        if route.startswith("compare/"):
            assert route == f"compare/{SHA}...{BASE}"
            return {"status": "ahead"}
        if route.startswith("actions/runs/42/artifacts?"):
            return {"artifacts": [artifact]}
        return original(repository, route)

    monkeypatch.setattr(contract.ci_artifacts, "api", api)
    result = contract.retrieve("owner/repo", BASE, tmp_path / "restored", producer)
    assert result == {"source": SHA, "version": "0.1.2", "producer_run": "42"}
    assert (
        tmp_path / "restored/application"
    ).read_bytes() == b"verified compiled fixture"


def test_explicit_producer_cannot_select_another_run(tmp_path, monkeypatch):
    artifact, run, job = candidate(tmp_path, monkeypatch)
    original = contract.ci_artifacts.api

    def api(repository, route):
        if route.startswith("compare/"):
            return {"status": "ahead"}
        if route.startswith("actions/runs/43/artifacts?"):
            return {"artifacts": [artifact]}
        return original(repository, route)

    monkeypatch.setattr(contract.ci_artifacts, "api", api)
    with pytest.raises(ValueError, match="never compile"):
        contract.retrieve("owner/repo", BASE, tmp_path / "restored", 43)


def test_fixture_is_the_original_successful_candidate_on_reviewed_main(tmp_path):
    artifact = {
        "name": "ci-linux-app-" + SHA,
        "expired": False,
        "workflow_run": {"id": 42},
    }

    def api(repo, route):
        if "artifacts?" in route:
            return {"artifacts": [artifact]}
        if route.startswith("compare/"):
            return {"status": "ahead"}
        if route == "actions/runs/42":
            return {"head_sha": SHA}
        raise AssertionError(route)

    with (
        patch.object(contract.ci_artifacts, "api", side_effect=api),
        patch.object(
            contract.ci_artifacts,
            "application_jobs",
            return_value=[{"conclusion": "success"}],
        ),
        patch.object(contract.ci_artifacts, "pull", return_value=True) as pull,
        patch.object(
            contract.ci_artifacts,
            "application_distribution",
            return_value={"version": "0.1.2", "build_number": 10},
        ),
    ):
        assert contract.retrieve("owner/repo", BASE, tmp_path) == {
            "source": SHA,
            "version": "0.1.2",
            "producer_run": "42",
        }
    pull.assert_called_once_with(
        "owner/repo", "linux-app", SHA, tmp_path, source_run=42
    )


@pytest.mark.parametrize("invalid", ["expired", "unreviewed", "failed", "missing"])
def test_missing_qualified_fixture_fails_without_compilation(tmp_path, invalid):
    artifact = {
        "name": "ci-linux-app-" + SHA,
        "expired": invalid == "expired",
        "workflow_run": {"id": 42},
    }

    def api(repo, route):
        if "artifacts?" in route:
            return {"artifacts": [] if invalid == "missing" else [artifact]}
        if route.startswith("compare/"):
            return {"status": "diverged" if invalid == "unreviewed" else "ahead"}
        return {"head_sha": SHA}

    with (
        patch.object(contract.ci_artifacts, "api", side_effect=api),
        patch.object(
            contract.ci_artifacts,
            "application_jobs",
            return_value=[] if invalid == "failed" else [{}],
        ),
        patch.object(contract.ci_artifacts, "pull") as pull,
        patch.object(contract.ci_artifacts.subprocess, "run") as command,
    ):
        with pytest.raises(ValueError, match="never compile"):
            contract.retrieve("owner/repo", BASE, tmp_path)
    pull.assert_not_called()
    command.assert_not_called()
