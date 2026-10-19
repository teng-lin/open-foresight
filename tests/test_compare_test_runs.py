"""Benchmark equivalence includes skips and suite identities, not just counts."""

import json

import pytest

from tools.compare_test_runs import compare, outcomes


def events(path, name="example", skip=False, success=True):
    records = [
        {"type": "suite", "suite": {"id": 1, "path": "test/example_test.dart"}},
        {"type": "testStart", "test": {"id": 2, "suiteID": 1, "name": name}},
        {
            "type": "testDone",
            "testID": 2,
            "result": "success",
            "hidden": False,
            "skipped": skip,
        },
        {"type": "done", "success": success},
    ]
    path.write_text("".join(json.dumps(event) + "\n" for event in records))
    return path


def test_matching_runs_report_passed_and_skipped(tmp_path, capsys):
    first = events(tmp_path / "plain.jsonl", skip=True)
    second = events(tmp_path / "coverage.jsonl", skip=True)
    compare(first, second)
    assert "0 passed, 1 skipped" in capsys.readouterr().out


@pytest.mark.parametrize("changes", [{"name": "different"}, {"skip": True}])
def test_equal_counts_cannot_hide_different_tests_or_skips(tmp_path, changes):
    first = events(tmp_path / "plain.jsonl")
    second = events(tmp_path / "coverage.jsonl", **changes)
    with pytest.raises(ValueError, match="changed test identities or skip outcomes"):
        compare(first, second)


@pytest.mark.parametrize("failure", ["failed", "truncated", "empty", "duplicate"])
def test_failed_incomplete_and_malformed_runs_are_rejected(tmp_path, failure):
    path = events(tmp_path / "events.jsonl", success=failure != "failed")
    lines = path.read_text().splitlines(keepends=True)
    if failure == "truncated":
        path.write_text("".join(lines[:-1]))
    elif failure == "empty":
        path.write_text(json.dumps({"type": "done", "success": True}) + "\n")
    elif failure == "duplicate":
        path.write_text("".join(lines[:3] + lines[2:]))
    with pytest.raises(ValueError):
        outcomes(path)
