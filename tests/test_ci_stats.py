"""Frozen reporting fixtures avoid network, git metadata and local history."""

import json
from pathlib import Path
import subprocess
import sys

import pytest

from tools import ci_stats as stats

ROOT = Path(__file__).resolve().parents[1]
A, B, C = "a" * 40, "b" * 40, "c" * 40


def job(name="python", status="success", identity=1, attempt=1):
    return {
        "id": identity,
        "run_attempt": attempt,
        "runner_id": identity,
        "name": name,
        "status": "completed",
        "conclusion": status,
        "started_at": "2026-10-19T00:00:00Z",
        "completed_at": "2026-10-19T00:02:00Z",
        "minutes": 2.0,
    }


def run(identity=1, event="pull_request", sha=A, jobs=None):
    return {
        "id": identity,
        "event": event,
        "head_sha": sha,
        "source": sha,
        "head_branch": "feature" if event == "pull_request" else "main",
        "path": ".github/workflows/quality.yml",
        "created_at": "2026-10-19T00:00:00Z",
        "pull_requests": [1],
        "jobs": jobs if jobs is not None else [job()],
        "minutes": 2.0,
    }


def pull(number=1, state="MERGED", head=A, merge=B):
    return {
        "number": number,
        "state": state,
        "headRefOid": head,
        "mergeCommit": {"oid": merge},
        "mergedAt": "2026-10-19T00:05:00Z",
    }


def report(runs, prs=None, trees=None):
    return stats.report(
        runs,
        prs if prs is not None else [pull()],
        trees if trees is not None else {A: "same", B: "same"},
        "2026-10-19T00:00:00Z",
    )


def test_full_required_set_and_final_sha_are_necessary_for_green():
    jobs = [job(name, identity=i) for i, name in enumerate(sorted(stats.REQUIRED), 1)]
    good = run(jobs=jobs)
    result = report([good, run(2, "push", B)])
    assert result["push_to_green"] == {"n": 1, "p50": 2, "p90": 2, "mean": 2}
    assert result["final_push_to_green"]["n"] == 1
    assert result["identical_tree_share"] == 1
    assert result["identical_tree_merge_minutes"]["p50"] == 2
    assert result["mean_per_merge"] == 2
    assert result["merges"][0]["observed"]
    for name in stats.REQUIRED:
        missing = [case for case in jobs if case["name"] != name]
        assert report([run(jobs=missing)])["push_to_green"]["n"] == 0
    assert report([good], [pull(state="CLOSED")])["pushes"] == []
    assert report([good], [pull(head=C)])["final_push_to_green"]["n"] == 0
    jobs[-1]["conclusion"] = "skipped"
    assert report([good])["push_to_green"]["n"] == 0
    jobs[-1]["completed_at"] = None
    assert report([good])["push_to_green"]["n"] == 0


def test_push_cost_and_merge_identity_are_separate_from_unknown_evidence():
    result = report([run(), run(2, "push", B)], trees={A: "old", B: "new"})
    assert result["divergent_count"] == 1
    assert result["divergent_sweep_minutes"]["mean"] == 2
    assert result["runner_minutes_per_push"]["p50"] == 2
    result = report([run()], trees={})
    assert result["unknown_tree_count"] == result["unobserved_merge_count"] == 1
    assert result["identical_tree_share"] is None
    assert result["mean_per_merge"] is None
    assert (
        report([], [pull(state="OPEN", merge=B) | {"mergedAt": None}])["merges"] == []
    )
    assert report([], [pull() | {"mergeCommit": None}])["merges"] == []


def test_required_latest_rerun_failure_overrides_previous_success():
    jobs = [job(name, identity=i) for i, name in enumerate(sorted(stats.REQUIRED), 1)]
    jobs.append(job("python", "failure", 100, 2))
    result = report([run(jobs=jobs)])
    assert result["pushes"][0]["missing_or_red"] == ["python"]


def test_removed_shapes_are_separate_and_unattributed_recovery_is_explicit():
    old = run(jobs=[job("obsolete")]) | {"created_at": "2026-10-18T00:00:00Z"}
    unknown = run(2, "workflow_run", B) | {"source": None}
    result = report([old, unknown])
    assert (
        result["job_shapes"][".github/workflows/quality.yml / obsolete"]["removed"] == 2
    )
    assert result["unattributed_workflow_run_ids"] == [2]
    assert result["unobserved_merge_count"] == 1
    result = report([run() | {"pull_requests": [{"number": 1}]}])
    assert len(result["pushes"]) == 1


def test_snapshot_loader_deduplicates_attempt_copies_and_reads_actual_candidate(
    tmp_path,
):
    (tmp_path / "jobs").mkdir()
    (tmp_path / "logs").mkdir()
    runs = [run(), run(2, "workflow_run", C), run(3, "workflow_run", C)]
    (tmp_path / "runs.jsonl").write_text("\n".join(json.dumps(item) for item in runs))
    jobs = [
        job(),
        job(identity=2, attempt=2) | {"runner_id": 1},
        job(identity=3) | {"status": "in_progress"},
        job(identity=4) | {"runner_id": None},
    ]
    (tmp_path / "jobs/1.jsonl").write_text("\n".join(json.dumps(item) for item in jobs))
    (tmp_path / "logs/2.txt").write_text(
        'timestamp {"source": "' + B + '", "version": "1"}'
    )
    (tmp_path / "prs.json").write_text(json.dumps([pull()]))
    (tmp_path / "trees.txt").write_text(f"{A} same 1\n{B} same 2\n\n")
    loaded, prs, trees = stats.load(tmp_path)
    assert loaded[0]["minutes"] == 2
    assert len(loaded[0]["jobs"]) == 3
    assert loaded[1]["source"] == B
    assert loaded[2]["source"] is None
    assert report(loaded, prs, trees)["unattributed_workflow_run_ids"] == [3]


@pytest.mark.parametrize(
    "log,expected",
    [("none", None), (f"source={A}", A), (f"source={A}\nSOURCE={B}", None)],
)
def test_candidate_source(log, expected):
    assert stats.candidate_source(log) == expected


def test_percentiles_and_empty_samples():
    assert stats.percentile([], 0.5) is None
    assert stats.percentile([1, 3], 0.5) == 2
    assert stats.percentile([1, 3], 1) == 3
    assert stats.summary([])["mean"] is None


def test_line_inventory_counts_code_without_git_or_docstrings(tmp_path):
    (tmp_path / "tools").mkdir()
    (tmp_path / "tests").mkdir()
    (tmp_path / ".github/workflows").mkdir(parents=True)
    (tmp_path / "tools/ci_fixture.py").write_text(
        '"""Doc.\nMore docs."""\n# note\nvalue = 1\n\ndef f():\n    """Docs."""\n    return value\n'
    )
    (tmp_path / "tools/ci_fixture.sh").write_text("#!/bin/bash\n# note\n\necho yes\n")
    (tmp_path / "tools/not_ci.py").write_text('raise Exception("excluded")')
    (tmp_path / "tools/platform_python_tests.py").write_text("x = 1\n")
    (tmp_path / "tests/test_ci_fixture.py").write_text("assert True\n")
    (tmp_path / ".github/workflows/test.yml").write_text(
        "# comment\njobs:\n  test: {}\n"
    )
    result = stats.line_inventory(tmp_path)
    assert result["total"] == 8
    assert "tools/not_ci.py" not in result["files"]
    command = [sys.executable, str(ROOT / "tools/ci_stats.py")]
    cli = subprocess.run(
        command + ["--lines", "--root", str(tmp_path)],
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )
    assert json.loads(cli.stdout) == result
    missing = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert missing.returncode == 2
    assert "snapshot directory" in missing.stderr


def test_script_main_report(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(sys, "argv", ["ci_stats", str(tmp_path)])
    monkeypatch.setattr(stats, "load", lambda path: ([], [], {}))
    stats.main()
    assert json.loads(capsys.readouterr().out)["pushes"] == []


def test_statistics_are_maintenance_only():
    from tools.ci_changes import select_gates

    assert not any(select_gates(["tools/ci_stats.py"]).values())


def test_merged_run_empty_pr_association_uses_only_unique_branch():
    sample = run() | {"pull_requests": []}
    first = pull() | {"headRefName": "feature"}
    assert report([sample], [first])["pushes"][0]["pr"] == 1
    second = pull(number=2) | {"headRefName": "feature"}
    assert report([sample], [first, second])["pushes"] == []
