"""Application-only heads retain compatible main SDK producers within the cap."""

from unittest.mock import patch

import pytest

from tools import ci_artifacts as artifacts
from tools import ci_macos_dependencies as macos


@pytest.mark.parametrize("consumer", ["linux", "macos"])
@pytest.mark.parametrize("actual_conclusion", [None, "success", "failure"])
def test_skipped_alternative_does_not_hide_a_not_yet_created_producer(
    consumer, actual_conclusion
):
    head = "a" * 40
    component = "linux-sdk" if consumer == "linux" else "macos-sdk"
    module = macos
    candidate = {
        "id": 10,
        "head_sha": head,
        "head_branch": "feature",
        "event": "pull_request",
        "pull_requests": [{"number": 23}],
        "path": artifacts.WORKFLOW,
        "head_repository": {"full_name": "owner/repo"},
        "status": "in_progress",
        "run_attempt": 1,
    }
    # GitHub lists the skipped registry alternative immediately, before the
    # PR archive job materializes after its prerequisite component jobs finish.
    jobs = [{"name": artifacts.JOBS[component], "conclusion": "skipped"}]
    if actual_conclusion is not None:
        jobs.append(
            {"name": artifacts.JOBS[component], "conclusion": actual_conclusion}
        )

    def request(repository, route):
        return {
            "workflow_runs": [candidate]
            if f"head_sha={head}" in route
            and ("status=" not in route or "status=in_progress" in route)
            else []
        }

    with (
        patch.object(module, "api", side_effect=request),
        patch.object(module, "dependency_jobs", return_value=jobs),
        patch.object(
            module,
            "producer_identity",
            return_value="identity",
        ),
        patch.object(macos, "fingerprint", return_value="identity"),
    ):
        waiting = macos.waiting_producers("owner/repo", component, head, 23)
    assert waiting == ([10] if actual_conclusion is None else [])


@pytest.mark.parametrize("consumer", ["linux", "macos"])
def test_waits_for_verified_main_identity_without_waiting_for_another_pr(consumer):
    head, previous, incompatible = "a" * 40, "b" * 40, "c" * 40
    component = "linux-sdk" if consumer == "linux" else "macos-sdk"
    job_name = artifacts.JOBS[component]
    base = {
        "id": 10,
        "head_sha": previous,
        "head_branch": "main",
        "event": "push",
        "path": artifacts.WORKFLOW,
        "head_repository": {"full_name": "owner/repo"},
        "status": "in_progress",
        "run_attempt": 2,
    }
    candidates = [
        base,
        base | {"id": 11, "head_sha": incompatible},
        base
        | {
            "id": 12,
            "head_branch": "other-pr",
            "event": "pull_request",
            "pull_requests": [{"number": 999}],
        },
        base | {"id": 13, "head_repository": {"full_name": "fork/repo"}},
        base | {"id": 14, "event": "pull_request", "pull_requests": [{"number": 999}]},
        base | {"id": 15},
        base | {"id": 16, "path": ".github/workflows/untrusted.yml"},
    ]
    inspected = []

    def request(repository, route):
        assert repository == "owner/repo"
        return {
            "workflow_runs": candidates
            if "branch=main" in route
            and ("status=" not in route or "status=in_progress" in route)
            else []
        }

    def jobs(repository, run_id):
        return [
            {
                "name": job_name,
                "run_attempt": 2,
                "conclusion": "success" if run_id == 15 else None,
            }
        ]

    def source(repository, sha, name, *args):
        inspected.append(sha)
        return "different" if sha == incompatible else "identity"

    module = artifacts if consumer == "linux" else macos
    with (
        patch.object(module, "api", side_effect=request),
        patch.object(module, "dependency_jobs", side_effect=jobs),
        patch.object(
            module,
            "source_fingerprint_at" if consumer == "linux" else "producer_identity",
            side_effect=source,
        ),
        patch.object(macos, "fingerprint", return_value="identity"),
    ):
        waiting = (
            artifacts.waiting_for_dependency(
                "owner/repo", component, "identity", head, 23
            )
            if consumer == "linux"
            else macos.waiting_producers("owner/repo", component, head, 23)
        )
    assert waiting == [10]
    assert set(inspected) == {previous, incompatible}


def test_main_producer_disappearing_fails_without_a_build_fallback(tmp_path):
    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "waiting_producers", side_effect=[[10], []]),
        patch.object(macos.time, "sleep") as sleep,
        patch.object(macos.subprocess, "run") as build,
        pytest.raises(RuntimeError, match="compatible main producer"),
    ):
        macos.ensure("macos-sdk", tmp_path, "owner/repo", "a" * 40, 23)
    sleep.assert_called_once()
    build.assert_not_called()


@pytest.mark.parametrize("consumer", ["linux", "macos"])
def test_compatible_main_producer_lookup_paginates(consumer):
    component = "linux-sdk" if consumer == "linux" else "macos-sdk"
    module = artifacts if consumer == "linux" else macos
    base = {
        "id": 10,
        "head_sha": "b" * 40,
        "head_branch": "main",
        "event": "push",
        "path": artifacts.WORKFLOW,
        "head_repository": {"full_name": "owner/repo"},
        "status": "queued",
    }

    def request(repository, route):
        return {
            "workflow_runs": (
                [base] * 100 if route.endswith("&page=1") else [base | {"id": 11}]
            )
            if "branch=main" in route
            and ("status=" not in route or "status=queued" in route)
            else []
        }

    with (
        patch.object(module, "api", side_effect=request),
        patch.object(module, "dependency_jobs", return_value=[]),
        patch.object(
            module,
            "source_fingerprint_at" if consumer == "linux" else "producer_identity",
            return_value="identity",
        ),
        patch.object(macos, "fingerprint", return_value="identity"),
    ):
        waiting = (
            artifacts.waiting_for_dependency(
                "owner/repo", component, "identity", "a" * 40, 23
            )
            if consumer == "linux"
            else macos.waiting_producers("owner/repo", component, "a" * 40, 23)
        )
    assert waiting == [10, 11]
