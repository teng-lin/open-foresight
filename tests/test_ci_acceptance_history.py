"""Original failure observations independently constrain phase narrowing."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile

import pytest

from tools import ci_acceptance_plan as acceptance

ROOT = Path(__file__).resolve().parents[1]


def inventory():
    baseline, checksum = acceptance.failure_baseline()
    return {
        **baseline,
        "baseline_sha256": checksum,
        "baseline_count": len(baseline["failures"]),
    }


def report(value=None):
    value = value or inventory()
    return acceptance.replay(
        value, inventory_sha256=hashlib.sha256(json.dumps(value).encode()).hexdigest()
    )


def summary():
    value = report()
    return {**value, "sha256": "a" * 64}


def test_frozen_original_api_pages_jobs_attempts_ranges_and_logs_are_complete():
    baseline, _ = acceptance.failure_baseline()
    archive = ROOT / "tests/fixtures" / baseline["evidence_archive"]["path"]
    assert (
        hashlib.sha256(archive.read_bytes()).hexdigest()
        == baseline["evidence_archive"]["sha256"]
    )
    with tarfile.open(archive) as stream:
        members = {
            member.name: stream.extractfile(member).read()
            for member in stream.getmembers()
        }
    manifest = json.loads(members.pop("manifest.json"))
    assert set(members) == set(manifest["files"])
    assert all(
        hashlib.sha256(raw).hexdigest() == manifest["files"][name]
        for name, raw in members.items()
    )
    runs = json.loads(members["all-runs.json"])
    assert len(runs) == len({run["id"] for run in runs}) == 2189
    discovered = {}
    for day in manifest["discovery"]["daily_windows"]:
        pages = json.loads(members[f"days/{day}.json"])
        rows = [run for page in pages for run in page["workflow_runs"]]
        assert len(rows) == pages[0]["total_count"] < 1000
        discovered.update({run["id"]: run for run in rows})
    for hour in manifest["discovery"]["six_hour_starts"]:
        pages = json.loads(members[f"days/2026-10-18-{hour}.json"])
        rows = [run for page in pages for run in page["workflow_runs"]]
        assert len(rows) == pages[0]["total_count"] < 1000
        discovered.update({run["id"]: run for run in rows})
    assert discovered == {run["id"]: run for run in runs}
    expected = set()
    jobs_by_id = {}
    job_owners = {}
    job_count = 0
    for run in baseline["runs"]:
        pages = json.loads(members[f"jobs/{run['id']}.json"])
        jobs = [job for page in pages for job in page["jobs"]]
        assert len(jobs) == pages[0]["total_count"]
        job_count += len(jobs)
        for job in jobs:
            jobs_by_id[job["id"]] = job
            job_owners[job["id"]] = discovered[run["id"]]
            if run["path"].endswith("/macos.yml") and not any(
                word in job["name"].lower() for word in ("acceptance", "audit")
            ):
                continue
            if job.get("conclusion") in (
                "failure",
                "timed_out",
                "startup_failure",
            ) or any(
                step.get("conclusion") in ("failure", "timed_out", "startup_failure")
                for step in job.get("steps", [])
            ):
                expected.add(f"{run['id']}:{job['run_attempt']}:{job['id']}")
        if run["conclusion"] == "startup_failure" and not any(
            job["run_attempt"] == run["run_attempt"] for job in jobs
        ):
            expected.add(f"{run['id']}:{run['run_attempt']}:0")
    assert job_count == 6559
    assert expected == {row["id"] for row in baseline["failures"]}
    for failure in baseline["failures"]:
        for item in failure["evidence"]:
            assert hashlib.sha256(members[item["path"]]).hexdigest() == item["sha256"]
        if failure["job"]:
            job = jobs_by_id[failure["job"]]
            assert job["run_attempt"] == failure["attempt"]
            assert failure["failed_steps"] == [
                step
                for step in job.get("steps", [])
                if step.get("conclusion") in ("failure", "timed_out", "startup_failure")
            ]
        if failure["job"] == 0:
            assert acceptance.startup_guard(failure)
            original_run = json.loads(members["startup/run.json"])
            original_jobs = json.loads(members["startup/jobs.json"])
            assert (original_run["id"], original_run["run_attempt"], original_run["conclusion"]) == (failure["run"], failure["attempt"], "startup_failure")
            assert original_jobs["total_count"] == 0 and original_jobs["jobs"] == []
            continue
        assert failure["range"].get("proof_attempt", failure["attempt"]) == failure["attempt"]
        if failure["event"] != "pull_request":
            assert failure["range"]["kind"] == "full-event-backstop"
            continue
        scope = failure["range"]
        compare = json.loads(members[f"compares/{scope['base']}-{scope['head']}.json"])
        assert scope["head"] == failure["source"]
        assert compare["base_commit"]["sha"] == scope["base"]
        assert compare["merge_base_commit"]["sha"] == scope["merge_base"]
        assert len(compare["files"]) == scope["file_count"] < 300
        assert failure["paths"] == sorted(
            {
                name
                for item in compare["files"]
                for name in (item["filename"], item.get("previous_filename"))
                if name
            }
        )
        log = members[f"logs/{scope['proof_job']}.txt"].decode(errors="replace")
        if scope["kind"] == "original-merge-checkout":
            assert f"Merge {failure['head']} into {scope['base']}" in log
            commit = json.loads(members[f"merge-commits/{failure['source']}.json"])
            assert [parent["sha"] for parent in commit["parents"]] == [
                scope["base"],
                failure["head"],
            ]
        else:
            assert f"BASE: {scope['base']}" in log
            if scope["kind"] != "same-event-platform-changes":
                assert "EVENT: pull_request" in log
            else:
                proof_job = jobs_by_id[scope["proof_job"]]
                sibling = job_owners[scope["proof_job"]]
                original = discovered[failure["run"]]
                assert all(sibling[key] == original[key] for key in ("event", "head_sha", "head_branch", "created_at"))
                assert proof_job["run_attempt"] == scope["proof_attempt"] == 1
        assert scope["proof_attempt"] > 0
    result = report()
    assert result["count"] == 204
    assert result["miss_count"] == result["unresolved_count"] == 0


def test_failed_phase_omission_is_detected_independently_of_planner(monkeypatch):
    original = acceptance.plan

    def omit(*args, **kwargs):
        value = original(*args, **kwargs)
        value["proposed"]["cpu-models"] = False
        return value

    monkeypatch.setattr(acceptance, "plan", omit)
    result = report()
    assert result["miss_count"] > 0
    assert any("cpu-models" in row["misses"] for row in result["failures"])


@pytest.mark.parametrize(
    "change", ["removed", "relabeled", "duplicate", "pin", "cutoff", "incomplete"]
)
def test_replay_rejects_incomplete_or_rewritten_original_observations(change):
    value = copy.deepcopy(inventory())
    if change == "removed":
        value["failures"].pop()
    elif change == "relabeled":
        value["failures"][0]["required_phases"] = ["virtual-audio"]
    elif change == "duplicate":
        value["failures"].append(value["failures"][0])
    elif change == "pin":
        value["baseline_sha256"] = "f" * 64
    elif change == "cutoff":
        value["until"] = "2026-10-20T00:00:00Z"
    else:
        value["complete"] = False
    with pytest.raises(ValueError):
        report(value)


def test_delta_unknown_range_blocks_qualification_without_inventing_paths():
    value = copy.deepcopy(inventory())
    row = copy.deepcopy(value["failures"][0])
    row.update(id="new-original-run", unresolved=True, paths=[])
    value["failures"].append(row)
    assert report(value)["unresolved_count"] == 1


@pytest.mark.parametrize(
    "key,value",
    [
        ("miss_count", 1),
        ("unresolved_count", 1),
        ("baseline_sha256", "b" * 64),
        ("count", 50),
        ("inventory_sha256", "invalid"),
        ("sha256", "invalid"),
    ],
)
def test_qualification_summary_requires_zero_misses_and_pinned_original_inventory(
    key, value
):
    candidate = summary()
    candidate[key] = value
    with pytest.raises(ValueError, match="original failure"):
        acceptance.verify_replay_summary(candidate)


@pytest.mark.parametrize(
    "cutoff", ["2026-10-20T00:00:00Z", "2026-10-21T00:05:00Z", "2026-10-21T01:00:00Z"]
)
def test_actual_run_cutoff_must_cover_start_and_precede_upload(cutoff):
    candidate = summary()
    candidate["coverage"]["until"] = cutoff
    with pytest.raises(ValueError, match="cutoff"):
        acceptance.verify_replay_summary(
            candidate,
            run_started="2026-10-21T00:10:00Z",
            uploaded="2026-10-21T00:20:00Z",
        )


def test_cli_keeps_failed_replay_diagnostics_and_checks_inventory_bytes(tmp_path):
    value = inventory()
    extra = copy.deepcopy(value["failures"][0])
    extra.update(id="unresolved-new-failure", unresolved=True)
    value["failures"].append(extra)
    source = tmp_path / "inventory.json"
    source.write_text(json.dumps(value))
    target = tmp_path / "report.json"
    command = [
        sys.executable,
        "-m",
        "tools.ci_acceptance_plan",
        "--replay",
        str(source),
        "--sha256",
        hashlib.sha256(source.read_bytes()).hexdigest(),
        "--output",
        str(target),
    ]
    result = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, timeout=30
    )
    assert result.returncode != 0 and "unresolved evidence" in result.stderr
    assert json.loads(target.read_text())["unresolved_count"] == 1
    command[-3] = "0" * 64
    result = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, timeout=30
    )
    assert result.returncode != 0 and "checksum mismatch" in result.stderr


def test_valid_summary_binds_qualification_cutoff():
    value = summary()
    assert (
        acceptance.verify_replay_summary(
            value, run_started="2026-10-21T00:00:00Z", uploaded="2026-10-21T00:10:00Z"
        )
        is value
    )
    value["coverage"]["complete"] = False
    with pytest.raises(ValueError, match="complete historical"):
        acceptance.verify_replay_summary(value)


def test_checksum_verified_frozen_baseline_has_no_local_git_dependency(tmp_path):
    baseline = ROOT / acceptance.FAILURE_BASELINE
    copied = tmp_path / acceptance.FAILURE_BASELINE
    copied.parent.mkdir(parents=True)
    copied.write_bytes(baseline.read_bytes())
    copied.with_suffix(".sha256").write_bytes(
        baseline.with_suffix(".sha256").read_bytes()
    )
    assert acceptance.failure_baseline(tmp_path)[0]["failures"]
    copied.write_text(copied.read_text() + " ")
    with pytest.raises(ValueError, match="checksum"):
        acceptance.failure_baseline(tmp_path)


def test_qualification_workflow_retains_replay_and_inventory_diagnostics():
    from tests.test_pull_request_workflows import parse_workflow

    workflow = parse_workflow(
        (ROOT / ".github/workflows/ci-qualification.yml").read_text()
    )
    job = workflow["jobs"]["qualify"]
    steps = job["steps"]
    collect = next(
        step
        for step in steps
        if "-m tools.ci_acceptance_history " in step.get("run", "")
    )
    assert "steps.refresh.outputs.needed == 'true'" in collect["if"]
    assert "(inputs.exercise || 'acceptance-replay') == 'acceptance-replay'" in collect["if"]
    assert "--baseline-sha256" in collect["run"] and "--evidence" in collect["run"]
    replay = next(
        step
        for step in steps
        if "-m tools.ci_acceptance_plan --replay" in step.get("run", "")
    )
    assert "acceptance-failures.json" in replay["run"]
    diagnostics = next(
        step for step in steps if "diagnostics" in step.get("with", {}).get("name", "")
    )
    assert diagnostics["if"] == "always() && steps.refresh.outputs.needed == 'true'"
    assert "acceptance-replay.json" in diagnostics["with"]["path"]
    assert "acceptance-evidence/" in diagnostics["with"]["path"]


@pytest.mark.parametrize("key,value", [("required_phases", []), ("required_phases", ["invented"]), ("paths", None), ("run", 0), ("source", "bad"), ("event", "untrusted")])
def test_malformed_later_failure_is_unresolved(key, value):
    candidate = copy.deepcopy(inventory())
    row = copy.deepcopy(next(item for item in candidate["failures"] if item["job"]))
    row.update(id="later-malformed-row")
    row[key] = value
    candidate["failures"].append(row)
    assert report(candidate)["unresolved_count"] == 1


@pytest.mark.parametrize("key,value", [("job", 1), ("failed_steps", [{"name": "actual phase"}]), ("startup_proof", {}), ("required_phases", ["cpu-models"])])
def test_startup_guard_exception_cannot_hide_an_executed_phase(key, value):
    candidate = copy.deepcopy(inventory())
    row = copy.deepcopy(next(item for item in candidate["failures"] if item["job"] == 0))
    row.update(id="invalid-startup-claim")
    row[key] = value
    candidate["failures"].append(row)
    result = report(candidate)
    assert result["unresolved_count"] == 1
    assert result["outer_guard_count"] == 1
    assert result["phase_failure_count"] == 204


def test_descriptor_cli_records_real_replay_and_content_digest(tmp_path, monkeypatch):
    from tools import ci_rollout

    replay_path = tmp_path / "replay.json"
    replay_path.write_text(json.dumps(report()))
    output = tmp_path / "qualification.json"
    monkeypatch.setattr(sys, "argv", ["ci_rollout", "--source", "a" * 40, "--run-id", "81", "--attempt", "2", "--producer-job", "qualification-acceptance-replay", "--acceptance-report", str(replay_path), "--output", str(output)])
    ci_rollout.main()
    actual = json.loads(output.read_text())["acceptance_replay"]
    assert actual["sha256"] == hashlib.sha256(replay_path.read_bytes()).hexdigest()
    assert actual["inventory_sha256"] == report()["inventory_sha256"]
    assert actual["miss_count"] == actual["unresolved_count"] == 0
    assert actual["phase_failure_count"] == 203 and actual["outer_guard_count"] == 1
    malformed = json.loads(replay_path.read_text())
    malformed["miss_count"] = 1
    replay_path.write_text(json.dumps(malformed))
    with pytest.raises(ValueError, match="zero-miss"):
        ci_rollout.main()


def test_old_fifty_pr_selector_replay_cannot_authorize_acceptance_narrowing():
    with pytest.raises(ValueError, match="original failure"):
        acceptance.verify_replay_summary({"count": 50, "known_escapes": [102, 110, 112, 119, 137, 144]})


def test_baseline_metadata_and_timestamp_completeness_are_mandatory(tmp_path):
    path = tmp_path / acceptance.FAILURE_BASELINE
    path.parent.mkdir(parents=True)
    value = inventory()
    value["schema"] = 99
    path.write_text(json.dumps(value))
    path.with_suffix(".sha256").write_text(hashlib.sha256(path.read_bytes()).hexdigest())
    with pytest.raises(ValueError, match="Incomplete frozen"):
        acceptance.failure_baseline(tmp_path)
    value = inventory()
    value["until"] = "2026-10-21T00:05:00"
    with pytest.raises(ValueError, match="cutoff"):
        report(value)


def test_daily_refresh_stops_after_verified_narrowing_but_dispatch_can_renew():
    from tests.test_pull_request_workflows import parse_workflow

    workflow = parse_workflow((ROOT / ".github/workflows/ci-qualification.yml").read_text())
    assert workflow["on"]["schedule"] == [{"cron": "43 10 * * *"}]
    job = workflow["jobs"]["qualify"]
    assert "github.ref == 'refs/heads/main'" in job["if"]
    assert "github.event_name == 'schedule'" in job["if"]
    refresh = next(step for step in job["steps"] if step.get("id") == "refresh")
    assert 'capability("acceptance_narrowing"' in refresh["run"]
    assert 'os.environ["GITHUB_EVENT_NAME"] == "schedule"' in refresh["run"]
    for step in job["steps"][job["steps"].index(refresh) + 1:]:
        assert "steps.refresh.outputs.needed == 'true'" in step["if"]


def test_original_failed_attempt_cannot_borrow_later_successful_changes_proof():
    candidate = copy.deepcopy(inventory())
    row = copy.deepcopy(next(item for item in candidate["failures"] if item["job"] and item["event"] == "pull_request"))
    row["id"] = "later-cross-attempt-inventory"
    row["range"]["proof_attempt"] = row["attempt"] + 1
    candidate["failures"].append(row)
    assert report(candidate)["unresolved_count"] == 1
