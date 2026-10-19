"""Exercise original-run retries and fail-closed nightly status/issue transitions."""

import json

import pytest

from tools import ci_nightly as nightly
from test_pull_request_workflows import parse_workflow
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40


def transport(
    monkeypatch, runs=(), job_rows=(), open_issues=(), previous=(), label=True
):
    monkeypatch.setenv("GITHUB_RUN_ID", "100")
    calls = []

    def api(repository, route, method="GET", payload=None, **kwargs):
        calls.append((route, method, payload))
        if method != "GET":
            return {}
        if route.startswith("actions/workflows/"):
            return {"workflow_runs": list(runs)}
        if route.startswith("actions/runs/"):
            return {"jobs": list(job_rows)}
        if route.startswith("issues?"):
            return list(open_issues)
        if route.startswith("labels/"):
            return {"name": route} if label else None
        if route.startswith("compare/"):
            return {"commits": [{"sha": "b" * 40}]}
        if route.startswith("commits/"):
            return list(previous)
        raise AssertionError(route)

    return api, calls


def run(**updates):
    return {
        "id": 50,
        "head_sha": SHA,
        "status": "completed",
        "conclusion": "success",
        "run_attempt": 1,
        **updates,
    }


def test_original_red_night_retries_only_failed_jobs_once_and_never_waits(monkeypatch):
    api, calls = transport(
        monkeypatch,
        [run(conclusion="failure")],
        [{"name": "build / macos", "conclusion": "failure"}],
    )
    result = nightly.previous_nightly("owner/repo", SHA, False, request=api)
    assert "Retry requested" in result["summary"]
    assert [(route, method) for route, method, _ in calls if method != "GET"] == [
        ("actions/runs/50/rerun-failed-jobs", "POST")
    ]
    api, calls = transport(
        monkeypatch,
        [run(conclusion="failure", run_attempt=2)],
        [{"name": "build / macos", "conclusion": "failure"}],
    )
    with pytest.raises(ValueError, match="failed after its retry"):
        nightly.previous_nightly("owner/repo", SHA, False, request=api)
    assert not any(method != "GET" for _, method, _ in calls)


@pytest.mark.parametrize("state", ["queued", "in_progress"])
def test_live_original_producer_is_preserved(monkeypatch, state):
    api, calls = transport(monkeypatch, [run(status=state)])
    assert (
        "still active"
        in nightly.previous_nightly("r", SHA, False, request=api)["summary"]
    )
    assert not any(method != "GET" for _, method, _ in calls)


@pytest.mark.parametrize(
    "conclusion,skip", [("success", True), ("skipped", False), ("failure", False)]
)
def test_only_green_aggregate_counts_as_success_watermark(
    monkeypatch, conclusion, skip
):
    api, _ = transport(
        monkeypatch, [run()], [{"name": "nightly-checks", "conclusion": conclusion}]
    )
    assert bool(nightly.previous_nightly("r", SHA, False, request=api)) is skip


def test_skipped_trigger_cannot_hide_original_red_run_and_exercises_are_excluded(
    monkeypatch,
):
    api, calls = transport(
        monkeypatch,
        [
            run(id=60),
            run(conclusion="failure"),
            run(id=70, display_title="Nightly exercise abc"),
            run(id=100, conclusion="failure"),
            run(id=40, head_sha="b" * 40),
        ],
        [{"name": "build / macos", "conclusion": "failure"}],
    )
    nightly.previous_nightly("r", SHA, False, request=api)
    assert any(route == "actions/runs/50/rerun-failed-jobs" for route, _, _ in calls)
    assert not any("runs/70/" in route for route, _, _ in calls)
    assert nightly.previous_nightly("r", SHA, True, request=api) is None


def test_failed_planning_trigger_cannot_recursively_retry_an_exhausted_producer(
    monkeypatch,
):
    calls = []
    monkeypatch.setenv("GITHUB_RUN_ID", "300")

    def api(repo, route, method="GET", payload=None):
        calls.append((route, method))
        if "workflows/" in route:
            return {
                "workflow_runs": [
                    run(id=200, conclusion="failure"),
                    run(id=100, conclusion="failure", run_attempt=2),
                ]
            }
        return {
            "jobs": [
                {
                    "name": "plan" if "runs/200/" in route else "build / macos",
                    "conclusion": "failure",
                }
            ]
        }

    with pytest.raises(ValueError, match="failed after its retry"):
        nightly.previous_nightly("r", SHA, False, request=api)
    assert not any(method != "GET" for _, method in calls)
    api, _ = transport(monkeypatch, [run(conclusion="failure")])
    with pytest.raises(ValueError, match="planning failed"):
        nightly.previous_nightly("r", SHA, False, request=api)


def test_pagination_preserves_all_evidence():
    def api(repo, route):
        return {"items": list(range(100)) if "&page=1" in route else [100]}

    assert nightly.pages("r", "route", "items", request=api) == list(range(101))


@pytest.mark.parametrize("exercise", [False, True])
def test_aggregate_requires_every_selected_suite_and_writes_scope(
    tmp_path, monkeypatch, exercise
):
    summary = tmp_path / "summary"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    names = (
        ("plan", "exercise")
        if exercise
        else ("plan", "build", "linux", "macos", "publish")
    )
    results = {name: {"result": "success"} for name in names}
    nightly.aggregate(results, exercise)
    for name in names:
        broken = {**results, name: {"result": "skipped"}}
        with pytest.raises(ValueError, match=name):
            nightly.aggregate(broken, exercise)
    assert "Nightly scope" in summary.read_text()


@pytest.mark.parametrize("exercise", [False, True])
def test_issue_open_update_and_close_bind_run_source_and_failing_jobs(
    monkeypatch, exercise
):
    api, calls = transport(
        monkeypatch,
        job_rows=[{"name": "linux (deb)", "conclusion": "failure"}],
        label=False,
    )
    nightly.issue("r", 100, SHA, False, exercise, request=api)
    opened = next(
        payload
        for route, method, payload in calls
        if route == "issues" and method == "POST"
    )
    assert "linux (deb)" in opened["body"] and SHA in opened["body"]
    assert opened["labels"] == ["ci-nightly-exercise" if exercise else "ci-nightly"]
    api, calls = transport(monkeypatch, open_issues=[{"number": 7}])
    nightly.issue("r", 100, SHA, False, exercise, request=api)
    assert any(route == "issues/7" and method == "PATCH" for route, method, _ in calls)
    nightly.issue("r", 100, SHA, True, exercise, request=api)
    assert calls[-1] == ("issues/7", "PATCH", {"state": "closed"})


def test_red_issue_reports_range_and_merged_prs_since_actual_green(monkeypatch):
    api, calls = transport(
        monkeypatch,
        [run(head_sha="c" * 40)],
        [{"name": "nightly-checks", "conclusion": "success"}],
        previous=[{"number": 9, "title": "application fix"}],
    )
    nightly.issue("r", 100, SHA, False, request=api)
    body = calls[-1][2]["body"]
    assert "c" * 40 + "..." + SHA in body and "#9: application fix" in body


@pytest.mark.parametrize(
    "old_success,new_conclusion", [(True, "failure"), (False, "success")]
)
@pytest.mark.parametrize("exercise", [False, True])
def test_stale_results_cannot_close_or_overwrite_newer_nightly_issue(
    monkeypatch, old_success, new_conclusion, exercise
):
    newer = run(
        id=200,
        display_title="Nightly exercise new" if exercise else "Nightly preview new",
    )
    api, calls = transport(
        monkeypatch,
        [newer],
        [{"name": "nightly-checks", "conclusion": new_conclusion}],
        open_issues=[{"number": 7}],
    )
    nightly.issue("r", 100, SHA, old_success, exercise, request=api)
    assert not any(method != "GET" for _, method, _ in calls)


def test_cli_aggregate_and_issue(monkeypatch):
    monkeypatch.setattr("sys.argv", ["ci_nightly", "aggregate"])
    monkeypatch.setenv("EXERCISE", "true")
    monkeypatch.setenv(
        "RESULTS",
        json.dumps({"plan": {"result": "success"}, "exercise": {"result": "success"}}),
    )
    nightly.main()
    recorded = []
    monkeypatch.setattr("sys.argv", ["ci_nightly", "issue"])
    monkeypatch.setenv("GITHUB_REPOSITORY", "r")
    monkeypatch.setenv("GITHUB_RUN_ID", "100")
    monkeypatch.setenv("GITHUB_SHA", SHA)
    monkeypatch.setenv("RESULT", "success")
    monkeypatch.setattr(nightly, "issue", lambda *args: recorded.append(args))
    nightly.main()
    assert recorded == [("r", 100, SHA, True, True)]


def test_workflow_aggregate_exercise_and_permissions_are_explicit():
    workflow = parse_workflow(
        (ROOT / ".github/workflows/preview-packages.yml").read_text()
    )
    jobs = workflow["jobs"]
    assert "always()" in jobs["nightly-checks"]["if"]
    assert set(jobs["nightly-checks"]["needs"]) == {
        "plan",
        "build",
        "linux",
        "macos",
        "publish",
        "exercise",
    }
    assert jobs["plan"]["permissions"]["actions"] == "write"
    assert jobs["nightly-issue"]["permissions"]["issues"] == "write"
    assert jobs["exercise"]["needs"] == "plan"
    assert not {"reuse-linux", "reuse-macos", "revalidation"}.intersection(jobs)
    assert "recovery_run" not in json.dumps(workflow)
    for name in ("linux", "macos", "publish"):
        for step in jobs[name]["steps"]:
            if "actions/upload-artifact@" in step.get("uses", ""):
                assert step["with"]["overwrite"] is True
