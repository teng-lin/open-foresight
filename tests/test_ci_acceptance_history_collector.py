"""Bounded original-attempt history collection without Git or inherited refs."""

from copy import deepcopy
import hashlib
import json
import subprocess
import sys
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import pytest

from tools import ci_acceptance_history as history

REPOSITORY = "example/repo"
HEAD, BASE, MERGE, MERGE_BASE = (letter * 40 for letter in "abcd")
UNTIL = "2026-10-12T01:00:00Z"
PIN = "e" * 64


def run(
    identity=1,
    *,
    path="integration-acceptance.yml",
    event="pull_request",
    attempt=1,
    status="completed",
    conclusion="failure",
):
    return {
        "id": identity,
        "path": ".github/workflows/" + path,
        "event": event,
        "head_sha": HEAD,
        "head_branch": "topic" if event == "pull_request" else "main",
        "run_attempt": attempt,
        "status": status,
        "conclusion": conclusion,
        "created_at": "2026-10-12T00:01:00Z",
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
    }


def job(
    identity=101,
    *,
    run_id=1,
    name="ubuntu-application",
    attempt=1,
    conclusion="failure",
):
    return {
        "id": identity,
        "run_id": run_id,
        "head_sha": HEAD,
        "run_attempt": attempt,
        "name": name,
        "status": "completed",
        "conclusion": conclusion,
        "started_at": "2026-10-12T00:02:00Z",
        "completed_at": "2026-10-12T00:03:00Z",
        "steps": [{"name": "Actual model assertion", "conclusion": "failure"}]
        if conclusion == "failure"
        else [],
    }


def log(source=HEAD, base=BASE):
    return f"2026-10-12T00:01:00Z [command]/usr/bin/git log -1 --format=%H\n2026-10-12T00:01:01Z {source}\n2026-10-12T00:01:02Z   BASE: {base}\n2026-10-12T00:01:02Z   EVENT: pull_request\n"


def baseline(*, runs=None, failures=None):
    return {
        "schema": 1,
        "repository": REPOSITORY,
        "since": history.SINCE,
        "until": "2026-10-12T00:30:00Z",
        "complete": True,
        "runs": runs or [],
        "failures": failures or [],
    }


class API:
    def __init__(self, runs=None, jobs=None):
        self.runs = runs if runs is not None else [run()]
        self.jobs = (
            jobs
            if jobs is not None
            else {1: [job(100, name="changes", conclusion="success"), job()]}
        )
        self.calls = []
        self.files = [
            {
                "filename": "native/current.cpp",
                "previous_filename": "native/previous.cpp",
                "status": "renamed",
            }
        ]
        self.merge_base = MERGE_BASE
        self.parents = [{"sha": "f" * 40}, {"sha": HEAD}]
        self.logs = {}

    def api(self, repository, route):
        assert repository == REPOSITORY
        self.calls.append(route)
        query = parse_qs(urlsplit(route).query)
        page, size = (
            int(query.get("page", [1])[0]),
            int(query.get("per_page", [100])[0]),
        )
        if route.startswith("actions/runs?"):
            return {
                "total_count": len(self.runs),
                "workflow_runs": self.runs[(page - 1) * size : page * size],
            }
        if "/jobs?" in route:
            rows = self.jobs[int(route.split("/")[2])]
            if "/attempts/" in route:
                rows = [
                    row
                    for row in rows
                    if row["run_attempt"] == int(route.split("/")[4])
                ]
            return {
                "jobs": rows[(page - 1) * size : page * size],
                "total_count": len(rows),
            }
        if "/attempts/" in route:
            rid, attempt = int(route.split("/")[2]), int(route.split("/")[4])
            current = next(row for row in self.runs if row["id"] == rid)
            return {
                "id": rid,
                "head_sha": HEAD,
                "run_attempt": attempt,
                "run_started_at": "2026-10-12T00:01:30Z",
                "status": current["status"],
                "conclusion": current["conclusion"],
            }
        if route.startswith("compare/"):
            return {
                "base_commit": {"sha": route.split("compare/")[1].split("...")[0]},
                "status": "ahead",
                "merge_base_commit": {"sha": self.merge_base},
                "files": self.files,
            }
        if route.startswith("git/commits/"):
            return {"parents": self.parents}
        raise AssertionError(route)

    def log(self, repository, identity):
        assert repository == REPOSITORY
        return self.logs.get(identity, log())


def collect(fixture, frozen=None, **kwargs):
    return history.collect(
        frozen or baseline(),
        repository=REPOSITORY,
        until=kwargs.pop("until", UNTIL),
        baseline_sha256=PIN,
        api=fixture.api,
        log=fixture.log,
        **kwargs,
    )


@pytest.mark.parametrize(
    "inherited", ["refs/pull/99999/merge", "refs/heads/main", None]
)
def test_actual_failed_revision_paths_and_original_attempt_are_independent_of_host_git(
    tmp_path, monkeypatch, inherited
):
    if inherited:
        monkeypatch.setenv("GITHUB_REF", inherited)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)
    fixture = API()
    result = collect(fixture, evidence=tmp_path / "evidence")
    assert result["complete"] is True and result["baseline_sha256"] == PIN
    row = result["failures"][0]
    assert row["id"] == "1:1:101"
    assert row["source"] == HEAD
    assert row["paths"] == ["native/current.cpp", "native/previous.cpp"]
    assert row["range"] == {
        "base": BASE,
        "head": HEAD,
        "merge_base": MERGE_BASE,
        "proof_job": 100,
        "proof_attempt": 1,
        "proof_run": 1,
        "kind": "original-changes-environment",
    }
    assert row["required_phases"] == list(history.PHASES)
    assert all(
        (tmp_path / "evidence" / item["file"]).is_file()
        for item in result["diagnostics"]["evidence"]
    )
    assert any("filter=all&per_page=30" in call for call in fixture.calls)


def test_new_green_rerun_preserves_the_original_frozen_failure_byte_semantically():
    original = {
        "id": "1:1:101",
        "reviewed_assertion": "checksum mismatch is a genuine guard",
    }
    frozen = baseline(runs=[run()], failures=[original])
    fixture = API(
        [run(attempt=2, conclusion="success")],
        {1: [job(), job(102, attempt=2, conclusion="success")]},
    )
    fixture.log = lambda *args: pytest.fail(
        "Do not reclassify already frozen original failures"
    )
    result = collect(fixture, frozen)
    assert result["failures"] == [original]
    assert result["baseline_count"] == 1
    assert result["diagnostics"]["changed_runs"] == [1]


def test_unchanged_completed_runs_do_not_refetch_jobs_but_incomplete_runs_do():
    fixture = API([run(conclusion="success")])
    collect(fixture, baseline(runs=deepcopy(fixture.runs)))
    assert not any("/jobs?" in call for call in fixture.calls)
    fixture = API([run(status="in_progress", conclusion=None)])
    collect(fixture, baseline(runs=deepcopy(fixture.runs)))
    assert any("/jobs?" in call for call in fixture.calls)


def test_original_event_base_wins_over_a_later_parallel_merge_parent():
    failed = run()
    sibling = run(2, path="macos.yml", conclusion="success")
    fixture = API(
        [failed, sibling],
        {1: [job()], 2: [job(200, run_id=2, name="changes", conclusion="success")]},
    )
    fixture.logs[200] = log(MERGE, BASE)
    result = collect(fixture)
    row = result["failures"][0]
    assert row["source"] == HEAD
    assert row["range"]["base"] == BASE
    assert row["range"]["proof_run"] == 2
    assert row["range"]["kind"] == "same-event-platform-changes-environment"
    assert f"compare/{BASE}...{HEAD}" in fixture.calls


@pytest.mark.parametrize(
    "change",
    [
        {"created_at": "2026-10-12T00:02:00Z"},
        {"head_branch": "other"},
        {"head_sha": "f" * 40},
        {"event": "push"},
    ],
)
def test_another_event_cannot_supply_missing_original_pr_base(change):
    sibling = run(2, path="macos.yml", conclusion="success") | change
    fixture = API(
        [run(), sibling],
        {1: [job()], 2: [job(200, run_id=2, name="changes", conclusion="success")]},
    )
    fixture.jobs[2][0]["head_sha"] = sibling["head_sha"]
    result = collect(fixture)
    assert result["failures"][0]["unresolved"] is True
    assert result["failures"][0]["paths"] == []


@pytest.mark.parametrize(
    "case",
    [
        "missing-log-range",
        "large-compare",
        "bad-merge-base",
        "wrong-compare-head",
        "empty-diff",
    ],
)
def test_unprovable_pr_range_is_explicitly_unresolved_without_invented_paths(case):
    fixture = API()
    if case == "missing-log-range":
        fixture.logs[100] = "No original base retained"
    if case == "large-compare":
        fixture.files *= 300
    if case == "bad-merge-base":
        fixture.merge_base = "invalid"
    if case == "empty-diff":
        fixture.files = []
    if case == "wrong-compare-head":
        fixture.merge_base = HEAD
    result = collect(fixture)
    assert result["failures"][0]["unresolved"] is True
    assert not result["failures"][0]["paths"]


def test_actual_merge_checkout_is_verified_through_commit_parents():
    fixture = API()
    fixture.logs[101] = log(MERGE)
    result = collect(fixture)
    assert result["failures"][0]["source"] == MERGE
    assert "git/commits/" + MERGE in fixture.calls


def test_non_pr_failures_use_unavoidable_full_event_policy_and_startup_is_not_silently_lost():
    fixture = API([run(event="schedule")], {1: [job()]})
    row = collect(fixture)["failures"][0]
    assert row["range"] == {"kind": "full-event-backstop"}
    assert row["paths"] == [] and row["required_phases"] == list(history.PHASES)
    fixture = API(
        [run(conclusion="startup_failure")],
        {1: []},
    )
    startup = collect(fixture)["failures"][0]
    assert startup["id"] == "1:1:0"
    assert startup["required_phases"] == []
    assert startup["classification"] == "workflow-startup-no-jobs"
    assert startup["range"] == {"kind": "workflow-startup-no-jobs"}
    assert startup["startup_proof"]["job_count"] == 0
    fixture = API(
        [run(status="completed", conclusion="cancelled")],
        {
            1: [
                job(conclusion="cancelled")
                | {"steps": [{"name": "Actual assertion", "conclusion": "failure"}]}
            ]
        },
    )
    assert collect(fixture)["failures"][0]["failed_steps"] == ["Actual assertion"]


def test_filtered_windows_split_before_github_cap_and_deduplicate_exact_boundaries():
    fixture = API()
    original = fixture.api

    def api(repository, route):
        query = parse_qs(urlsplit(route).query)
        if route.startswith("actions/runs?"):
            lower, upper = query["created"][0].split("..")
            if history.stamp(upper) - history.stamp(lower) > history.timedelta(
                minutes=30
            ):
                fixture.calls.append(route)
                return {"total_count": 1001, "workflow_runs": []}
        return original(repository, route)

    fixture.api = api
    result = collect(fixture)
    assert len(result["runs"]) == 1
    assert (
        len([call for call in fixture.calls if call.startswith("actions/runs?")]) == 3
    )


def test_pagination_and_request_budgets_are_actionable(monkeypatch):
    fixture = API(
        [run(index) for index in range(1, 102)], {index: [] for index in range(1, 102)}
    )
    result = collect(fixture)
    assert len(result["runs"]) == 101
    assert any("page=2" in call for call in fixture.calls)
    monkeypatch.setattr(history, "MAX_REQUESTS", 1)
    with pytest.raises(ValueError, match="request budget"):
        collect(API())


@pytest.mark.parametrize(
    "field,value",
    [
        ("schema", 2),
        ("repository", "foreign/repo"),
        ("since", "2026-10-13T00:00:00Z"),
        ("complete", False),
    ],
)
def test_baseline_identity_and_completeness_are_mandatory(field, value):
    with pytest.raises(ValueError, match="reviewed baseline"):
        collect(API(), baseline() | {field: value})


def test_bad_checksum_bounds_disappeared_runs_and_mutated_original_identity_fail():
    with pytest.raises(ValueError, match="checksum"):
        history.collect(
            baseline(), repository=REPOSITORY, until=UNTIL, baseline_sha256="bad"
        )
    with pytest.raises(ValueError, match="repository"):
        history.collect(
            baseline(), repository="invalid", until=UNTIL, baseline_sha256=PIN
        )
    with pytest.raises(ValueError, match="90-day"):
        history.collect(
            baseline(),
            repository=REPOSITORY,
            until="2027-01-20T00:00:00Z",
            baseline_sha256=PIN,
        )
    with pytest.raises(ValueError, match="90-day"):
        collect(API(), until="2026-10-12T00:00:00Z")
    with pytest.raises(ValueError, match="disappeared"):
        collect(API([]), baseline(runs=[run()]))
    with pytest.raises(ValueError, match="identity changed"):
        collect(API(), baseline(runs=[run() | {"head_sha": "f" * 40}]))
    with pytest.raises(ValueError, match="duplicate run"):
        collect(API(), baseline(runs=[run(), run()]))
    with pytest.raises(ValueError, match="duplicate original failure"):
        collect(API(), baseline(failures=[{"id": "same"}, {"id": "same"}]))


def test_log_or_api_failure_never_claims_complete_history(monkeypatch):
    fixture = API()
    fixture.log = lambda *args: (_ for _ in ()).throw(
        RuntimeError("Original log download failed")
    )
    with pytest.raises(RuntimeError, match="download failed"):
        collect(fixture)
    monkeypatch.setattr(history, "MAX_LOG_BYTES", 1)
    with pytest.raises(ValueError, match="bounded evidence"):
        collect(API())
    fixture = API()
    fixture.jobs[1][0]["run_id"] = 2
    with pytest.raises(ValueError, match="identity mismatch"):
        collect(fixture)


def test_readonly_job_log_preserves_failure_output_and_has_timeout(monkeypatch):
    seen = []

    def execute(command, **kwargs):
        seen.append((command, kwargs))
        return subprocess.CompletedProcess(
            command, 1, stdout="original output", stderr="original diagnostic"
        )

    monkeypatch.setattr(history.subprocess, "run", execute)
    with pytest.raises(RuntimeError, match="(?s)original output.*original diagnostic"):
        history.job_log(REPOSITORY, 1)
    assert seen[0][1]["timeout"] == 120
    assert seen[0][0][:3] == ["gh", "api", "--allow-escape-sequences"]


def test_cli_verifies_raw_baseline_checksum_and_preserves_explicit_binding(
    tmp_path, monkeypatch
):
    raw = json.dumps(baseline(), indent=4).encode()
    source, output = tmp_path / "baseline.json", tmp_path / "merged.json"
    source.write_bytes(raw)
    checksum = hashlib.sha256(raw).hexdigest()
    calls = []
    verified = {"authenticated": True}
    observations = []

    def load(*args):
        observations.append(args)
        return verified

    monkeypatch.setitem(
        sys.modules, "tools.ci_acceptance_observations", SimpleNamespace(load=load)
    )

    def collected(value, **kwargs):
        calls.append(kwargs)
        return {"baseline_sha256": kwargs["baseline_sha256"], "complete": True}

    monkeypatch.setattr(history, "collect", collected)
    args = [
        "history",
        "--baseline",
        str(source),
        "--baseline-sha256",
        checksum,
        "--output",
        str(output),
        "--evidence",
        str(tmp_path / "evidence"),
    ]
    monkeypatch.setattr(sys, "argv", args)
    history.main()
    assert json.loads(output.read_text())["baseline_sha256"] == checksum
    source.write_bytes(raw + b"\n")
    with pytest.raises(ValueError, match="checksum mismatch"):
        history.main()
    assert len(calls) == 1
    assert calls[0]["verified_observation"] is verified
    assert observations == [(REPOSITORY, checksum, baseline(), None)]


def test_timestamp_requires_timezone():
    with pytest.raises(ValueError, match="timezone"):
        history.stamp("2026-10-12T00:00:00")


def test_all_attempt_job_pagination_keeps_each_original_failure_and_log_is_fetched_once():
    failed = job()
    proof = job(100, name="changes", conclusion="success")
    filler = [
        job(index, name="unrelated", conclusion="skipped") for index in range(200, 231)
    ]
    fixture = API(jobs={1: [proof, *filler, failed]})
    calls = []
    original = fixture.log
    fixture.log = lambda repo, identity: (
        calls.append(identity),
        original(repo, identity),
    )[1]
    result = collect(fixture)
    assert len(result["failures"]) == 1
    assert any("/jobs?" in route and "page=2" in route for route in fixture.calls)
    assert calls.count(100) == 1 and calls.count(101) == 1


def test_malformed_discovery_and_job_pages_and_exhausted_run_budget_are_not_complete(
    monkeypatch,
):
    reader = history.Reader(
        REPOSITORY, lambda *args: {"jobs": {}}, lambda *args: "", None
    )
    with pytest.raises(ValueError, match="Incomplete"):
        reader.pages("route", "jobs")
    reader.api = lambda *args: {"workflow_runs": {}}
    with pytest.raises(ValueError, match="Incomplete"):
        reader.runs(history.stamp(history.SINCE), history.stamp(UNTIL))
    reader.api = lambda *args: {"workflow_runs": [], "total_count": 1000}
    start = history.stamp(history.SINCE)
    with pytest.raises(ValueError, match="1000-run cap"):
        reader.runs(start, start + history.timedelta(seconds=1))
    monkeypatch.setattr(history, "MAX_RUNS", 1)
    with pytest.raises(ValueError, match="run budget"):
        collect(API([run(1), run(2)]))
    reader = history.Reader(
        REPOSITORY, lambda *args: {"jobs": [job()]}, lambda *args: "", None
    )
    with pytest.raises(ValueError, match="page budget"):
        reader.pages("route", "jobs", 1)


def test_wrong_checkout_parents_repository_and_job_sources_fail_without_false_paths():
    fixture = API()
    fixture.logs[101] = log(MERGE)
    fixture.parents = [{"sha": BASE}, {"sha": "f" * 40}]
    assert collect(fixture)["failures"][0]["unresolved"]
    fixture = API()
    fixture.logs[100] = log(MERGE)
    fixture.parents = [{"sha": BASE}, {"sha": "f" * 40}]
    assert collect(fixture)["failures"][0]["unresolved"]
    fixture = API()
    fixture.runs[0]["repository"] = {"full_name": "foreign/repo"}
    with pytest.raises(ValueError, match="repository/source"):
        collect(fixture)
    fixture = API()
    fixture.jobs[1][0]["head_sha"] = "f" * 40
    with pytest.raises(ValueError, match="source differs"):
        collect(fixture)


def test_ineligible_workflow_and_already_frozen_startup_observation_are_retained_without_reclassification():
    fixture = API([run(path="quality.yml")])
    assert not collect(fixture)["failures"]
    current = run(conclusion="startup_failure")
    original = {"id": "1:1:0", "reviewed_original": True}
    fixture = API([current], {1: []})
    old = deepcopy(current) | {"status": "in_progress"}
    result = collect(fixture, baseline(runs=[old], failures=[original]))
    assert result["failures"] == [original]


def test_real_log_adapter_returns_original_bytes_when_successful(monkeypatch):
    monkeypatch.setattr(
        history.subprocess,
        "run",
        lambda *args, **kwargs: subprocess.CompletedProcess(
            args, 0, stdout="raw original log", stderr=""
        ),
    )
    assert history.job_log(REPOSITORY, 10) == "raw original log"


def test_carried_successful_job_copy_resolves_to_original_attempt():
    first = job(conclusion="success")
    first["steps"] = [{"name": "Allowed original failure", "conclusion": "failure"}]
    copy = deepcopy(first) | {"id": 202, "run_attempt": 2}
    fixture = API(
        [run(attempt=2, conclusion="success", event="push")], {1: [first, copy]}
    )
    original_api = fixture.api

    def api(repository, route):
        if route.endswith("/attempts/2"):
            return {
                "id": 1,
                "head_sha": HEAD,
                "run_attempt": 2,
                "run_started_at": "2026-10-12T00:05:00Z",
            }
        return original_api(repository, route)

    fixture.api = api
    result = collect(fixture)
    assert [row["id"] for row in result["failures"]] == ["1:1:101"]


def test_old_run_rerun_after_cutoff_retains_both_original_and_new_failures():
    original = {"id": "1:1:101", "reviewed_assertion": "original checksum"}
    frozen = baseline(runs=[run()], failures=[original])
    fresh = job(202, attempt=2) | {
        "started_at": "2026-10-12T00:45:00Z",
        "completed_at": "2026-10-12T00:46:00Z",
    }
    proof = job(200, name="changes", attempt=2, conclusion="success") | {
        "started_at": "2026-10-12T00:44:00Z",
        "completed_at": "2026-10-12T00:44:30Z",
    }
    fixture = API([run(attempt=2)], {1: [job(), proof, fresh]})
    rows = collect(fixture, frozen)["failures"]
    assert rows[0] == original
    assert rows[1]["id"] == "1:2:202"
    assert rows[1]["range"]["proof_attempt"] == 2


@pytest.mark.parametrize("owner", ["same-run", "sibling"])
def test_later_rerun_changes_cannot_prove_an_earlier_failure_range(owner):
    proof = job(200, name="changes", attempt=2, conclusion="success") | {
        "started_at": "2026-10-12T00:45:00Z",
        "completed_at": "2026-10-12T00:46:00Z",
    }
    if owner == "same-run":
        fixture = API([run(attempt=2)], {1: [job(), proof]})
    else:
        proof["run_id"] = 2
        fixture = API(
            [run(), run(2, path="macos.yml", attempt=2)],
            {1: [job()], 2: [proof]},
        )
    row = collect(fixture)["failures"][0]
    assert row["unresolved"] is True
    assert not row["paths"]


def test_short_or_duplicate_discovery_pages_cannot_stamp_complete_history():
    reader = history.Reader(
        REPOSITORY,
        lambda *args: {"total_count": 2, "workflow_runs": [run()]},
        lambda *args: "",
        None,
    )
    with pytest.raises(ValueError, match="discovery count"):
        reader.runs(history.stamp(history.SINCE), history.stamp(UNTIL))
    reader.api = lambda *args: {"total_count": 2, "workflow_runs": [run(), run()]}
    with pytest.raises(ValueError, match="discovery count"):
        reader.runs(history.stamp(history.SINCE), history.stamp(UNTIL))


def test_log_requests_and_aggregate_retained_bytes_share_collection_budgets(
    monkeypatch,
):
    reader = history.Reader(REPOSITORY, lambda *args: {}, lambda *args: "abc", None)
    monkeypatch.setattr(history, "MAX_REQUESTS", 2)
    reader.get("metadata")
    assert reader.text(job()) == "abc"
    assert reader.text(job()) == "abc"  # Cached bytes cost no extra request.
    with pytest.raises(ValueError, match="request budget"):
        reader.text(job(102))
    monkeypatch.setattr(history, "MAX_REQUESTS", 10)
    monkeypatch.setattr(history, "MAX_TOTAL_LOG_BYTES", 5)
    with pytest.raises(ValueError, match="aggregate log budget"):
        reader.text(job(102))


@pytest.mark.parametrize("path", sorted(history.WORKFLOWS))
def test_workflow_specific_failure_scope_preserves_prerequisites_and_audits(path):
    current = run() | {"path": path}
    assert history.failure_job(current, job(name="Prepare dependencies")) is (
        path != ".github/workflows/macos.yml"
    )
    assert history.failure_job(current, job(name="macos-acceptance"))
    assert history.failure_job(current, job(name="DMG audit"))


def test_verified_observation_reuses_only_unchanged_runs_and_preserves_dynamic_failures():
    frozen = baseline()
    fixture = API()
    observed = collect(fixture, frozen)
    observed["until"] = "2026-10-12T00:40:00Z"
    fixture.calls.clear()
    fixture.log = lambda *args: pytest.fail(
        "Unchanged authenticated bytes are reusable"
    )
    result = collect(fixture, frozen, verified_observation=observed)
    assert result["failures"] == observed["failures"]
    assert result["baseline_count"] == 0
    assert not any("/jobs?" in route for route in fixture.calls)
    fixture.runs[0]["updated_at"] = "2026-10-12T00:45:00Z"
    observed["runs"][0] = deepcopy(observed["runs"][0]) | {
        "updated_at": "2026-10-12T00:35:00Z"
    }
    collect(fixture, frozen, verified_observation=observed)
    assert any("/jobs?" in route for route in fixture.calls)


@pytest.mark.parametrize(
    "mutation",
    [
        "pin",
        "count",
        "failure",
        "duplicate-failure",
        "since",
        "complete",
        "future",
        "before-baseline",
        "missing-run",
        "source",
        "duplicate-run",
    ],
)
def test_verified_observation_must_preserve_original_frozen_inventory(mutation):
    fixture = API()
    original = {"id": "1:1:101", "original_assertion": "provenance mismatch"}
    frozen = baseline(runs=[run()], failures=[original])
    observed = collect(fixture, frozen)
    observed["until"] = "2026-10-12T00:40:00Z"
    if mutation == "pin":
        observed["baseline_sha256"] = "f" * 64
    if mutation == "count":
        observed["baseline_count"] = 0
    if mutation == "failure":
        observed["failures"][0]["original_assertion"] = "silently exempt infrastructure"
    if mutation == "duplicate-failure":
        observed["failures"] *= 2
    if mutation == "since":
        observed["since"] = UNTIL
    if mutation == "complete":
        observed["complete"] = False
    if mutation == "future":
        observed["until"] = "2026-10-12T01:01:00Z"
    if mutation == "before-baseline":
        observed["until"] = history.SINCE
    if mutation == "missing-run":
        observed["runs"] = []
    if mutation == "source":
        observed["runs"][0]["head_sha"] = "f" * 40
    if mutation == "duplicate-run":
        observed["runs"] *= 2
    with pytest.raises(ValueError, match="observation|duplicate run"):
        collect(fixture, frozen, verified_observation=observed)


def test_incomplete_job_page_count_is_never_a_complete_observation():
    reader = history.Reader(
        REPOSITORY, lambda *args: {"jobs": [], "total_count": 1}, lambda *args: "", None
    )
    with pytest.raises(ValueError, match="page count"):
        reader.jobs(run())


def test_startup_without_jobs_preserves_older_executed_failures_as_separate_rows():
    original = {"id": "1:1:101", "original_assertion": "real product failure"}
    fixture = API([run(attempt=2, conclusion="startup_failure")], {1: [job()]})
    rows = collect(fixture, baseline(runs=[run()], failures=[original]))["failures"]
    assert rows[0] == original
    assert rows[1]["id"] == "1:2:0"
    assert rows[1]["startup_proof"] == {
        "run": 1,
        "attempt": 2,
        "conclusion": "startup_failure",
        "status": "completed",
        "job_count": 0,
        "workflow": ".github/workflows/integration-acceptance.yml",
    }
    assert rows[1]["required_phases"] == []
    assert rows[1]["paths"] == []


def test_startup_with_executed_jobs_does_not_invent_a_zero_job_row():
    fixture = API([run(conclusion="startup_failure", event="push")], {1: [job()]})
    rows = collect(fixture)["failures"]
    assert [row["job"] for row in rows] == [101]


def test_startup_proof_requires_matching_original_attempt_metadata():
    fixture = API([run(conclusion="startup_failure")], {1: []})
    original = fixture.api

    def api(repository, route):
        value = original(repository, route)
        if route.endswith("/attempts/1"):
            value["head_sha"] = "f" * 40
        return value

    fixture.api = api
    with pytest.raises(ValueError, match="Original startup attempt"):
        collect(fixture)


def test_incomplete_authenticated_run_metadata_cannot_skip_job_inspection():
    fixture = API()
    observed = deepcopy(collect(fixture))
    observed["until"] = "2026-10-12T00:40:00Z"
    observed["runs"][0].pop("run_attempt")
    fixture.calls.clear()
    collect(fixture, verified_observation=observed)
    assert any("/jobs?" in route for route in fixture.calls)


def test_persisted_run_headers_retain_identity_and_freshness_with_raw_api_evidence(
    tmp_path,
):
    fixture = API()
    fixture.runs[0].update(
        updated_at="2026-10-12T00:03:00Z",
        run_started_at="2026-10-12T00:01:30Z",
        actor={"account_payload": "raw-evidence-marker"},
    )
    result = collect(fixture, evidence=tmp_path)
    header = result["runs"][0]
    assert header == {
        "id": 1,
        "path": ".github/workflows/integration-acceptance.yml",
        "event": "pull_request",
        "head_sha": HEAD,
        "head_branch": "topic",
        "created_at": "2026-10-12T00:01:00Z",
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "failure",
        "updated_at": "2026-10-12T00:03:00Z",
        "run_started_at": "2026-10-12T00:01:30Z",
    }
    assert result["failures"][0]["range"]["base"] == BASE
    discovery = next(
        item
        for item in result["diagnostics"]["evidence"]
        if item["identity"].startswith("actions/runs?")
    )
    raw = (tmp_path / discovery["file"]).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == discovery["sha256"]
    assert b"raw-evidence-marker" in raw
    assert fixture.runs[0]["repository"]["full_name"] == REPOSITORY


def test_compact_observations_still_detect_live_metadata_changes():
    fixture = API()
    fixture.runs[0]["updated_at"] = "2026-10-12T00:03:00Z"
    observed = collect(fixture)
    observed["until"] = "2026-10-12T00:40:00Z"
    fixture.calls.clear()
    collect(fixture, verified_observation=observed)
    assert not any("/jobs?" in route for route in fixture.calls)
    fixture.runs[0]["updated_at"] = "2026-10-12T00:45:00Z"
    collect(fixture, verified_observation=observed)
    assert any("/jobs?" in route for route in fixture.calls)
    fixture.runs[0]["head_branch"] = "different-original-event"
    with pytest.raises(ValueError, match="identity changed"):
        collect(fixture, verified_observation=observed)


@pytest.mark.parametrize("days", [1, 7, 28])
def test_daily_compact_observation_size_stays_within_consumer_contract(days):
    fixture = API()
    # Real collected raw metadata averaged ~14.7KB/run. Account and action URLs
    # are diagnostic data; they must not multiply the persisted daily inventory.
    fixture.runs[0]["actor"] = {"api_payload": "x" * 14700}
    observation = collect(fixture)
    header = observation["runs"][0]
    observation["runs"] = [dict(header, id=identity) for identity in range(days * 500)]
    encoded = json.dumps(observation, sort_keys=True).encode()
    assert len(encoded) < 64 * 1024 * 1024  # Authenticated loader MAX_BYTES.
    assert (
        len(encoded) < len(json.dumps(fixture.runs[0])) * len(observation["runs"]) / 10
    )
