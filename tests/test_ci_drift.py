"""Scheduled drift consumes SDKs and preserves authoritative failure tracking."""

from pathlib import Path

import pytest

from tools import ci_drift_issue as drift
from tools import ci_sanitizer_artifacts as sanitizers
from test_pull_request_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "owner/repo"
SOURCE = "a" * 40


def run(identity=100, **updates):
    return {
        "id": identity,
        "path": ".github/workflows/arch-drift.yml",
        "head_branch": "main",
        "head_repository": {"full_name": REPOSITORY},
        "event": "schedule",
        "head_sha": SOURCE,
        "status": "completed",
        **updates,
    }


def api_fixture(*, current=None, newer=(), job_rows=None, issues=(), label=True):
    current = current or run()
    rows = (
        job_rows
        if job_rows is not None
        else {100: [{"name": "arch", "status": "completed", "conclusion": "failure"}]}
    )
    calls = []

    def request(repository, route, method="GET", payload=None, **kwargs):
        assert repository == REPOSITORY
        calls.append((route, method, payload))
        if method != "GET":
            return None
        if route == "actions/runs/100":
            return current
        if route.startswith("actions/workflows/"):
            return {"workflow_runs": list(newer)}
        if route.startswith("actions/runs/") and "/jobs?" in route:
            return {"jobs": rows.get(int(route.split("/")[2]), [])}
        if route.startswith("issues?"):
            return list(issues)
        if route.startswith("labels/"):
            return {} if label else None
        raise AssertionError(route)

    return request, calls


def test_open_update_and_close_one_drift_issue():
    request, calls = api_fixture(label=False)
    drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert calls[-1][0:2] == ("issues", "POST")
    assert calls[-1][2]["labels"] == ["ci-arch-drift"]
    assert "arch" in calls[-1][2]["body"] and SOURCE in calls[-1][2]["body"]
    assert any(route == "labels" and method == "POST" for route, method, _ in calls)
    request, calls = api_fixture(issues=[{"number": 9}])
    drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert calls[-1][0:2] == ("issues/9", "PATCH")
    request, calls = api_fixture(
        issues=[{"number": 9}],
        job_rows={
            100: [{"name": "arch", "status": "completed", "conclusion": "success"}]
        },
    )
    drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert calls[-1] == ("issues/9", "PATCH", {"state": "closed"})
    assert calls[-2][0:2] == ("issues/9/comments", "POST")


@pytest.mark.parametrize("success", [True, False])
@pytest.mark.parametrize("real_issue", [False, True])
def test_labeled_pr_is_never_mutated_by_drift_tracking(success, real_issue):
    request, calls = api_fixture(
        issues=[{"number": 99, "pull_request": {}}]
        + ([{"number": 7}] if real_issue else []),
        job_rows={
            100: [
                {
                    "name": "arch",
                    "status": "completed",
                    "conclusion": "success" if success else "failure",
                }
            ]
        },
    )
    drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert not any(
        route.startswith("issues/99") and method != "GET" for route, method, _ in calls
    )
    if real_issue:
        assert any(
            route == "issues/7" and method == "PATCH" for route, method, _ in calls
        )
    elif not success:
        assert calls[-1][0:2] == ("issues", "POST")


@pytest.mark.parametrize("conclusion", ["success", "failure", "skipped"])
def test_newer_authoritative_run_suppresses_stale_success_and_failure(conclusion):
    request, calls = api_fixture(
        newer=[run(200)],
        job_rows={
            200: [{"name": "arch", "status": "completed", "conclusion": conclusion}]
        },
    )
    drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert all(method == "GET" for _, method, _ in calls)


@pytest.mark.parametrize("new_jobs", [[], [{"name": "arch", "status": "queued"}]])
def test_newer_pending_run_does_not_hide_current_failure(new_jobs):
    request, calls = api_fixture(
        newer=[run(200, status="in_progress")],
        job_rows={100: [], 200: new_jobs},
    )
    drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert calls[-1][0:2] == ("issues", "POST")
    assert "missing suites: arch" in calls[-1][2]["body"]


@pytest.mark.parametrize(
    "change",
    [
        {"id": 101},
        {"head_sha": "b" * 40},
        {"event": "pull_request"},
        {"head_branch": "feature"},
        {"head_repository": {"full_name": "fork/repo"}},
        {"path": ".github/workflows/other.yml"},
    ],
)
def test_issue_writer_requires_its_own_reviewed_main_producer(change):
    request, calls = api_fixture(current=run(**change))
    with pytest.raises(ValueError, match="reviewed main"):
        drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert all(method == "GET" for _, method, _ in calls)


def test_probation_does_not_mask_actual_thread_failure():
    names = drift.WORKFLOWS["native-sanitizers.yml"][1]
    rows = [
        {
            "name": name,
            "status": "completed",
            "conclusion": "failure" if name == "native-thread-sanitizer" else "success",
        }
        for name in names
    ]
    request, calls = api_fixture(
        current=run(path=".github/workflows/native-sanitizers.yml"),
        job_rows={100: rows},
    )
    drift.reconcile(REPOSITORY, "native-sanitizers.yml", 100, SOURCE, request=request)
    assert calls[-1][2]["labels"] == ["ci-sanitizers"]
    assert "native-thread-sanitizer" in calls[-1][2]["body"]


def test_incomplete_current_job_fails_instead_of_closing_an_issue():
    request, calls = api_fixture(
        job_rows={100: [{"name": "arch", "status": "in_progress"}]}
    )
    with pytest.raises(ValueError, match="before its selected suites completed"):
        drift.reconcile(REPOSITORY, "arch-drift.yml", 100, SOURCE, request=request)
    assert all(method == "GET" for _, method, _ in calls)


def test_cli_uses_current_run_metadata(monkeypatch):
    recorded = []
    monkeypatch.setattr(drift.sys, "argv", ["ci_drift_issue.py", "arch-drift.yml"])
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_RUN_ID", "100")
    monkeypatch.setenv("GITHUB_SHA", SOURCE)
    monkeypatch.setattr(drift, "reconcile", lambda *args: recorded.append(args))
    drift.main()
    assert recorded == [(REPOSITORY, "arch-drift.yml", 100, SOURCE)]


def workflow(name):
    return parse_workflow((ROOT / ".github/workflows" / name).read_text())


def test_scheduled_sanitizers_never_build_save_or_upload_an_sdk():
    config = workflow("native-sanitizers.yml")
    assert config["on"]["schedule"]
    assert (
        config["concurrency"]["group"]
        == "native-sanitizers-${{ github.event_name }}-${{ github.ref }}"
    )
    assert config["concurrency"]["cancel-in-progress"] is False
    for kind, name in sanitizers.JOBS.items():
        steps = config["jobs"][name]["steps"]
        guarded = [
            step
            for step in steps
            if "build_sanitizer_sdk.py" in step.get("run", "")
            or "ci_sanitizer_artifacts.py pack" in step.get("run", "")
            or "actions/cache/save@" in step.get("uses", "")
            or step.get("name", "").startswith("Share the installed")
        ]
        assert len(guarded) == 4
        assert all("github.event_name != 'schedule'" in step["if"] for step in guarded)
        recovery = next(step for step in steps if step.get("id") == "sdk-qualification")
        assert (
            "github.event_name == 'workflow_dispatch'" in recovery["env"]["ALLOW_BUILD"]
        )
        assert not sanitizers.trusted(
            REPOSITORY,
            {
                "path": sanitizers.WORKFLOW,
                "head_repository": {"full_name": REPOSITORY},
                "head_branch": "main",
                "event": "schedule",
            },
            0,
            kind=kind,
        )
    assert (
        "github.event_name != 'schedule'"
        in config["jobs"]["native-thread-sanitizer"]["continue-on-error"]
    )


def test_arch_daily_probe_inlines_toolchain_and_runs_existing_full_gates():
    config = workflow("arch-drift.yml")
    assert config["on"]["schedule"]
    assert config["on"]["pull_request"]["paths"] == [".github/workflows/arch-drift.yml"]
    job = config["jobs"]["arch"]
    assert (
        job["container"]
        == workflow("linux-platform-stages.yml")["jobs"]["native-linux"]["container"]
    )
    setup = parse_workflow(
        (ROOT / ".github/actions/setup-linux-stage/action.yml").read_text()
    )
    install = next(
        step["run"]
        for step in setup["runs"]["steps"]
        if step["name"] == "Install Linux application toolchain"
    )
    rolling = job["steps"][0]["run"]
    assert set(install.split()[4:]) <= set(rolling.split())
    commands = "\n".join(step.get("run", "") for step in job["steps"])
    assert "tools/platform_python_tests.py --platform linux" in commands
    assert (
        "xvfb-run -a dbus-run-session -- bash tools/build.sh --platform linux -G Ninja"
        in commands
    )
    assert (
        "build_sanitizer_sdk.py" not in commands and "build_linux_sdk" not in commands
    )
    assert not any("cache/save@" in step.get("uses", "") for step in job["steps"])
    assert not any(
        "uses" in step and step["uses"].startswith("./.github/actions/")
        for step in job["steps"]
    )
    for filename in ("arch-drift.yml", "native-sanitizers.yml"):
        issue = workflow(filename)["jobs"]["drift-issue"]
        assert (
            "always()" in issue["if"]
            and "github.ref == 'refs/heads/main'" in issue["if"]
        )
        assert issue["permissions"]["issues"] == "write"
        assert issue["concurrency"]["cancel-in-progress"] is False
