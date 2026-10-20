"""Frozen synthetic REST metadata exercises complete collection without live Git history."""

import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

import pytest

from tools import ci_stats as stats, ci_stats_snapshot as snapshot
from tests.test_ci_stats import A, B, job, pull, run


def request(path):
    if "/actions/runs?" in path:
        return [{"workflow_runs": [run() | {"run_attempt": 2}]}, {"workflow_runs": []}]
    if "/attempts/" in path:
        attempt = int(path.split("/attempts/")[1].split("/")[0])
        return [{"jobs": [job(identity=attempt, attempt=attempt)]}, {"jobs": []}]
    if "/pulls?" in path:
        return [
            [
                {
                    "number": 1,
                    "state": "closed",
                    "head": {"ref": "feature", "sha": A},
                    "created_at": "2026-10-18T00:00:00Z",
                    "closed_at": "2026-10-19T00:05:00Z",
                    "merged_at": "2026-10-19T00:05:00Z",
                    "merge_commit_sha": B,
                }
            ]
        ]
    return [{"commit": {"tree": {"sha": "same"}}, "parents": []}]


def collect(tmp_path, **kwargs):
    destination = tmp_path / "snapshot"
    snapshot.collect(
        "owner/repository", "2026-10-19T00:00:00Z", destination, request, **kwargs
    )
    return destination


def test_collect_freezes_every_page_and_attempt_with_checksums_and_sources(tmp_path):
    root = collect(tmp_path)
    manifest = snapshot.verify(root)
    assert manifest["complete"] is True
    assert manifest["attempts"] == {"1": [1, 2]}
    assert len(manifest["log_references"]) == 2
    assert set(manifest["checksums"]) == {
        "runs.jsonl",
        "jobs/1.jsonl",
        "prs.json",
        "trees.txt",
    }
    runs, prs, trees = stats.load(root)
    assert len(runs[0]["jobs"]) == 2
    assert prs[0]["headRefOid"] == A and trees == {A: "same", B: "same"}
    with pytest.raises(FileExistsError):
        snapshot.collect("owner/repository", "2026-10-19T00:00:00Z", root, request)


def test_measurement_window_uses_actual_timestamps_and_excludes_historical_merges(
    tmp_path,
):
    root = tmp_path / "window"
    snapshot.collect(
        "owner/repository",
        "2026-10-18T20:05:00.500-04:00",
        root,
        request,
        until="2026-10-19T01:00:00Z",
    )
    manifest = snapshot.verify(root)
    assert manifest["since"] == "2026-10-19T00:05:00.500000Z"
    runs, prs, trees = stats.load(root)
    assert prs[0]["measurement_window"] is False
    assert B not in trees
    data = stats.report(runs, prs, trees, "2026-10-19T00:00:00Z")
    assert data["merges"] == []
    with pytest.raises(ValueError, match="explicit timezone"):
        snapshot.timestamp("2026-10-19T00:00:00")


def test_github_collection_query_uses_whole_seconds_without_changing_cohort_boundary(tmp_path):
    calls = []

    def recorded(path):
        calls.append(path)
        return request(path)

    destination = tmp_path / "whole-second-query"
    snapshot.collect(
        "owner/repository", "2026-10-19T00:05:00.500Z", destination, recorded,
        until="2026-10-19T01:00:00.750Z",
    )
    from urllib.parse import parse_qs, urlparse

    query = parse_qs(urlparse(next(path for path in calls if "/actions/runs?" in path)).query)
    assert query["created"] == ["2026-10-19T00:05:00Z..2026-10-19T01:00:00Z"]
    assert not json.loads((destination / "prs.json").read_text())[0]["measurement_window"]


@pytest.mark.parametrize("event", ["pull_request", "push"])
def test_qualification_annotation_cannot_remove_ordinary_runs_from_denominators(tmp_path, event):
    observations = {"runs": {"1": {"qualification": True}}}

    def actual_request(path):
        values = request(path)
        if "/actions/runs?" in path:
            values[0]["workflow_runs"][0]["event"] = event
        return values

    with pytest.raises(ValueError, match="Ordinary PR and push"):
        snapshot.collect(
            "owner/repository", "2026-10-19T00:00:00Z", tmp_path / "snapshot",
            actual_request, observations=observations,
        )
    # Legacy unstamped metadata is held to the same rule at load time.
    root = tmp_path / "legacy"
    (root / "jobs").mkdir(parents=True)
    (root / "runs.jsonl").write_text(json.dumps(run(event=event)) + "\n")
    (root / "observations.json").write_text(json.dumps(observations))
    with pytest.raises(ValueError, match="Ordinary PR and push"):
        stats.load(root)
    with pytest.raises(ValueError, match="Ordinary PR and push"):
        stats.operational_report([run(event=event) | {"qualification": True}])


def test_qualification_annotation_requires_boolean():
    for marker in (1, "true", None):
        with pytest.raises(ValueError, match="boolean"):
            snapshot.validate_observations({"runs": {"1": {"qualification": marker}}})
        with pytest.raises(ValueError, match="boolean"):
            snapshot.validate_qualification(run() | {"qualification": marker})


@pytest.mark.parametrize(
    "invalid",
    [
        "tamper",
        "missing",
        "path",
        "attempts",
        "incomplete",
        "schema",
        "inputs",
        "annotations",
        "logs",
    ],
)
def test_snapshot_rejects_corrupt_incomplete_or_unfrozen_input(tmp_path, invalid):
    root = collect(tmp_path)
    path = root / "manifest.json"
    manifest = json.loads(path.read_text())
    if invalid == "tamper":
        (root / "runs.jsonl").write_text("tampered")
    elif invalid == "missing":
        del manifest["checksums"]["jobs/1.jsonl"]
    elif invalid == "path":
        manifest["checksums"]["../outside"] = "bad"
    elif invalid == "attempts":
        manifest["attempts"]["1"] = [2]
    elif invalid == "incomplete":
        manifest["complete"] = False
    elif invalid == "schema":
        manifest["schema"] = 999
    elif invalid == "annotations":
        (root / "observations.json").write_text("{}")
    elif invalid == "logs":
        (root / "logs").mkdir()
        (root / "logs/1.txt").write_text("source=" + B)
    else:
        del manifest["checksums"]["trees.txt"]
    path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        stats.load(root)


def test_collection_failure_preserves_partial_manifest_and_actual_error(tmp_path):
    def broken(path):
        raise RuntimeError("GitHub pagination failed on page 2")

    root = tmp_path / "failed"
    with pytest.raises(RuntimeError, match="page 2"):
        snapshot.collect("owner/repo", "2026-10-19T00:00:00Z", root, broken)
    manifest = json.loads((root / "manifest.json").read_text())
    assert manifest["complete"] is False and "page 2" in manifest["error"]
    with pytest.raises(ValueError, match="Explicit repository"):
        snapshot.collect("not-a-repository", "bad", tmp_path / "invalid")
    with pytest.raises(ValueError, match="Unexpected paginated"):
        snapshot.pages(lambda _: [{"jobs": {}}], "jobs", "jobs")

    def wrong_attempt(path):
        values = request(path)
        if "/attempts/2/" in path:
            values[0]["jobs"][0]["run_attempt"] = 1
        return values

    with pytest.raises(ValueError, match="another attempt"):
        snapshot.collect(
            "owner/repo", "2026-10-19T00:00:00Z", tmp_path / "wrong", wrong_attempt
        )

    def truncated(path):
        return [{"workflow_runs": [run()] * 1000}]

    with pytest.raises(ValueError, match="filtered run limit"):
        snapshot.collect(
            "owner/repo", "2026-10-19T00:00:00Z", tmp_path / "truncated", truncated
        )
    with pytest.raises(ValueError, match="end must follow"):
        snapshot.collect(
            "owner/repo",
            "2026-10-19T00:00:00Z",
            tmp_path / "reversed",
            request,
            until="2026-10-18T00:00:00Z",
        )


def test_annotations_cannot_override_results_and_cache_hit_requires_input_evidence(
    tmp_path,
):
    for value in [
        {"other": {}},
        {"runs": {"1": {"conclusion": "success"}}},
        {"jobs": {"not-id": {}}},
        {
            "runs": {
                "1": {
                    "cache_observations": [
                        {"status": "hit", "stage": "ci", "source": "log"}
                    ]
                }
            }
        },
    ]:
        with pytest.raises(ValueError):
            snapshot.validate_observations(value)
    root = collect(
        tmp_path,
        observations={
            "runs": {
                "1": {
                    "scope": "application",
                    "cache_observations": [
                        {
                            "status": "hit",
                            "stage": "ci",
                            "source": "retained-log",
                            "input_identity": "sha256:input",
                        }
                    ],
                }
            }
        },
    )
    assert "observations.json" in snapshot.verify(root)["checksums"]
    runs, _, _ = stats.load(root)
    assert runs[0]["cache_observations"][0]["stage"] == "ci"
    assert runs[0]["scope"] == "application"


def test_readonly_api_and_collector_cli_use_explicit_inputs(monkeypatch, tmp_path):
    monkeypatch.setattr(
        snapshot.subprocess, "check_output", lambda argv, **kwargs: json.dumps([[]])
    )
    assert snapshot.api("repos/owner/repo/pulls") == [[]]
    observed = []
    annotation = tmp_path / "observations.json"
    annotation.write_text("{}")
    monkeypatch.setattr(
        snapshot, "collect", lambda *args, **kwargs: observed.append((args, kwargs))
    )
    monkeypatch.setattr(
        snapshot.argparse.ArgumentParser,
        "parse_args",
        lambda _: SimpleNamespace(
            repository="owner/repo",
            since="2026-10-19T00:00:00Z",
            output=tmp_path / "new",
            observations=annotation,
            until=None,
        ),
    )
    snapshot.main()
    assert observed[0][0][0] == "owner/repo" and observed[0][1] == {
        "observations": {},
        "until": None,
    }


@pytest.mark.parametrize(
    "conclusion,state",
    [
        ("success", "success"),
        ("failure", "failure"),
        ("timed_out", "failure"),
        ("startup_failure", "failure"),
        ("cancelled", "cancelled"),
        ("skipped", "skipped"),
        (None, "unknown"),
    ],
)
def test_failure_denominators_preserve_explicit_non_success_outcomes(conclusion, state):
    assert stats.outcome([job(status=conclusion)]) == state
    assert stats.outcome([]) == "unknown"
    assert stats.outcome([job() | {"status": "queued"}]) == "incomplete"
    assert stats.first_attempt_state(run() | {"status": "in_progress"}) == "incomplete"
    assert (
        stats.first_attempt_state(run(jobs=[]) | {"conclusion": "startup_failure"})
        == "failure"
    )


def test_first_attempt_failures_queue_and_classification_never_follow_later_green():
    failed = job(status="timed_out") | {
        "failure_evidence": {
            "class": "package-network",
            "command": "apt-get update",
            "diagnostic": "HTTP 503",
            "source": "retained failed-step log",
        },
        "created_at": "2026-10-18T23:59:00Z",
    }
    later = job(identity=2, attempt=2)
    sample = run(jobs=[failed, later]) | {
        "run_attempt": 2,
        "run_started_at": "2026-10-19T00:01:00Z",
    }
    data = stats.operational_report([sample, run(2, jobs=[job(status="cancelled")])])
    assert data["first_attempt_workflows"] == {
        "failed": 1,
        "eligible": 1,
        "rate": 1.0,
        "outcomes": {"cancelled": 1, "failure": 1},
    }
    assert data["first_attempt_pr_commits"]["failed"] == 1
    assert data["job_queue_minutes"]["p50"] == 1
    assert data["workflow_start_latency_minutes"]["p50"] == 1
    assert data["failures"][0]["class"] == "package-network"
    assert data["failures"][0]["attempt"] == 1
    assert data["first_attempt_job_conclusions"]["timed_out"] == 1
    assert data["manual_qualification_runs"] == []
    assert (
        stats.failure_class({"failure_evidence": {"class": "test-assertion"}})
        == "unknown"
    )


@pytest.mark.parametrize(
    "path,event,category",
    [
        ("linux-cache-publish.yml", "workflow_dispatch", "cache-publisher"),
        ("ci-dependencies.yml", "push", "sdk-producer"),
        ("release.yml", "workflow_dispatch", "release"),
        ("arch-drift.yml", "schedule", "nightly-or-drift"),
        ("macos.yml", "workflow_dispatch", "dispatch-or-other"),
        ("macos.yml", "push", "main"),
    ],
)
def test_independent_work_has_its_own_cost_category(path, event, category):
    assert stats.run_category(run(event=event) | {"path": path}) == category


def test_first_green_survives_later_red_but_latest_readiness_does_not():
    jobs = [
        job(name, identity=index)
        for index, name in enumerate(sorted(stats.REQUIRED), 1)
    ]
    jobs.append(
        job("python", "failure", 99, 2) | {"completed_at": "2026-10-19T00:05:00Z"}
    )
    data = stats.report(
        [run(jobs=jobs)], [pull()], {A: "same", B: "same"}, "2026-10-19T00:00:00Z"
    )
    assert data["push_to_first_green"]["p50"] == 2
    assert data["push_to_green"]["n"] == 0
    assert data["pushes"][0]["first_green_minutes"] == 2
    assert data["pushes"][0]["first_green_attempt"] == 1


def test_rerun_green_latency_is_separate_from_first_attempt_green():
    jobs = [
        job(name, identity=index)
        for index, name in enumerate(sorted(stats.REQUIRED), 1)
    ]
    first = next(item for item in jobs if item["name"] == "python")
    first["conclusion"] = "failure"
    jobs.append(
        job("python", "success", 99, 2) | {"completed_at": "2026-10-19T00:12:00Z"}
    )
    data = stats.report([run(jobs=jobs)], [pull()], {}, "2026-10-19T00:00:00Z")
    assert data["push_to_first_green"]["p50"] == 12
    assert data["push_to_first_attempt_green"]["n"] == 0
    assert data["pushes"][0]["first_green_attempt"] == 2


def test_same_head_retrigger_cannot_be_called_first_attempt_green():
    original = run(jobs=[job("python", "failure")])
    jobs = [
        job(name, identity=index + 10)
        | {"started_at": "2026-10-19T00:10:00Z", "completed_at": "2026-10-19T00:12:00Z"}
        for index, name in enumerate(sorted(stats.REQUIRED), 1)
    ]
    replacement = run(2, jobs=jobs) | {"created_at": "2026-10-19T00:10:00Z"}
    data = stats.report([original, replacement], [pull()], {}, "2026-10-19T00:00:00Z")
    assert data["push_to_first_green"]["p50"] == 12
    assert data["push_to_first_attempt_green"]["n"] == 0
    assert data["pushes"][0]["first_green_attempt"] == 1
    assert data["pushes"][0]["first_attempt_green"] is False
    assert data["pushes"][0]["first_green_runs"]["python"]["run"] == 2


def test_green_qualification_repeats_cannot_improve_ordinary_error_rate():
    ordinary = run(jobs=[job(status="failure")])
    repeats = [run(index, event="workflow_dispatch") | {"qualification": True} for index in range(2, 8)]
    data = stats.operational_report([ordinary, *repeats])
    assert data["first_attempt_workflows"]["rate"] == 1.0
    assert data["first_attempt_workflows"]["eligible"] == 1
    assert data["first_attempt_jobs"]["eligible"] == 1
    assert data["first_attempt_pr_commits"]["failed"] == 1
    assert data["qualification_first_attempts"]["outcomes"] == {"success": 6}
    assert data["runner_minutes_by_category"]["pr"] == 2
    assert data["runner_minutes_by_category"]["dispatch-or-other"] == 12
    assert data["manual_qualification_runs"] == list(range(2, 8))


def test_workflow_cancellation_is_not_success_even_when_completed_jobs_are_green():
    value = run() | {"status": "completed", "conclusion": "cancelled", "run_attempt": 1}
    assert stats.first_attempt_state(value) == "cancelled"
    assert stats.operational_report([value])["first_attempt_workflows"]["eligible"] == 0
    # A cancelled later rerun does not rewrite the completed first attempt.
    value["run_attempt"] = 2
    assert stats.first_attempt_state(value) == "success"


def test_branch_creation_window_excludes_unrelated_reuse():
    first = pull() | {
        "headRefName": "feature",
        "createdAt": "2026-10-18T00:00:00Z",
        "closedAt": "2026-10-19T00:05:00Z",
    }
    second = pull(number=2) | {
        "headRefName": "feature",
        "createdAt": "2026-10-20T00:00:00Z",
    }
    data = stats.report(
        [run() | {"pull_requests": []}], [first, second], {}, "2026-10-19T00:00:00Z"
    )
    assert [push["pr"] for push in data["pushes"]] == [1]


def test_report_output_records_verified_manifest_and_never_mutates_frozen_inputs(
    tmp_path,
):
    root = collect(tmp_path)
    command = [
        sys.executable,
        str(Path(stats.__file__)),
        str(root),
        "--report-output",
        str(root),
    ]
    subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
    report = json.loads((root / "report.json").read_text())
    assert report["schema"] == 2 and report["snapshot"]["verified"] is True
    assert "Eligible" in (root / "report.md").read_text()
    assert snapshot.verify(root)["complete"] is True
