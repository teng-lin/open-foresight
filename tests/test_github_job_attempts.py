"""API copies do not change immutable receipt/attestation producer attempts."""

import copy
import hashlib
import json
from pathlib import Path

import pytest

from tools import ci_release_candidates as candidates
from tools.github_job_attempts import canonical_jobs

HEAD = "a" * 40
RUN = {"id": 42, "head_sha": HEAD}


@pytest.fixture
def history():
    original = {
        "id": 1,
        "run_id": 42,
        "head_sha": HEAD,
        "name": "macos / dmg",
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "started_at": "2026-10-19T00:00:01Z",
        "completed_at": "2026-10-19T00:01:00Z",
        "steps": [
            {
                "number": 1,
                "name": "Upload",
                "status": "completed",
                "conclusion": "success",
                "started_at": "2026-10-19T00:00:30Z",
                "completed_at": "2026-10-19T00:00:59Z",
            }
        ],
    }
    metadata = {
        n: {**RUN, "run_attempt": n, "run_started_at": f"2026-10-19T00:0{n - 1}:00Z"}
        for n in (1, 2, 3)
    }
    # Reruns begin after the untouched original finished.
    metadata[2]["run_started_at"] = "2026-10-19T00:02:00Z"
    metadata[3]["run_started_at"] = "2026-10-19T00:03:00Z"
    return original, metadata


def test_copied_rows_keep_exact_original_id_attempt_and_steps_without_mutation(history):
    original, metadata = history
    jobs = [
        original,
        {**copy.deepcopy(original), "id": 2, "run_attempt": 2},
        {**copy.deepcopy(original), "id": 3, "run_attempt": 3},
    ]
    before = copy.deepcopy(jobs)
    result = canonical_jobs(jobs, RUN, metadata.__getitem__)
    assert result == [original] and result[0] is original
    assert candidates.latest(result, "macos / dmg")["run_attempt"] == 1
    assert jobs == before


@pytest.mark.parametrize("conclusion", ["failure", "cancelled", "skipped", "success"])
def test_new_execution_remains_authoritative_over_carried_success(history, conclusion):
    original, metadata = history
    fresh = {
        **copy.deepcopy(original),
        "id": 3,
        "run_attempt": 3,
        "started_at": "2026-10-19T00:03:10Z",
        "completed_at": "2026-10-19T00:04:00Z",
        "conclusion": conclusion,
    }
    jobs = [original, {**copy.deepcopy(original), "id": 2, "run_attempt": 2}, fresh]
    result = canonical_jobs(jobs, RUN, metadata.__getitem__)
    assert result == [original, fresh]
    if conclusion == "success":
        assert candidates.latest(result, "macos / dmg") is fresh
    else:
        with pytest.raises(ValueError, match="Latest required job"):
            candidates.latest(result, "macos / dmg")


@pytest.mark.parametrize(
    "change",
    [
        "missing",
        "ambiguous",
        "steps",
        "source",
        "run",
        "window",
        "straddle",
        "missing-steps",
        "duplicate-id",
    ],
)
def test_copy_requires_unique_complete_original_and_authoritative_attempt(
    history, change
):
    original, metadata = history
    copied = {**copy.deepcopy(original), "id": 2, "run_attempt": 2}
    jobs = [original, copied]
    if change == "missing":
        jobs.remove(original)
    elif change == "ambiguous":
        jobs.append({**copy.deepcopy(original), "id": 3})
    elif change == "steps":
        copied["steps"][0]["name"] = "Different execution"
    elif change == "source":
        metadata[2]["head_sha"] = "b" * 40
    elif change == "run":
        metadata[2]["id"] = 43
    elif change == "window":
        metadata[1]["run_started_at"] = "2026-10-19T00:01:30Z"
    elif change == "straddle":
        copied["completed_at"] = "2026-10-19T00:02:30Z"
    elif change == "missing-steps":
        copied.pop("steps")
    else:
        copied["id"] = original["id"]
    with pytest.raises(ValueError):
        canonical_jobs(jobs, RUN, metadata.__getitem__)


def test_attempt_api_errors_propagate_and_never_authorize_an_original(history):
    original, _ = history

    def unavailable(number):
        raise RuntimeError("Attempt API unavailable")

    with pytest.raises(RuntimeError, match="Attempt API"):
        canonical_jobs(
            [original, {**original, "id": 2, "run_attempt": 2}], RUN, unavailable
        )


def test_single_original_does_not_require_rerun_metadata(history):
    original, _ = history
    assert canonical_jobs(
        [original], RUN, lambda number: pytest.fail("No later attempt")
    ) == [original]


def test_frozen_actual_release_and_targeted_rerun_api_shapes():
    path = Path(__file__).parent / "fixtures/github-job-copies.json"
    assert (
        hashlib.sha256(path.read_bytes()).hexdigest()
        == "4a85a9c9c26829369c20e2a72489b2bb8c347a958df35244e9d9c5f28d893edc"
    )
    for case in json.loads(path.read_text())["observations"]:
        attempts = {item["run_attempt"]: item for item in case["attempts"]}
        result = canonical_jobs(case["jobs"], case["run"], attempts.__getitem__)
        assert [job["id"] for job in result] == case["expected_original_job_ids"]
        assert [job["run_attempt"] for job in result] == [1, 1, 2]


@pytest.mark.parametrize(
    "field,value",
    [
        ("run_attempt", True),
        ("run_attempt", 3),
        ("run_started_at", None),
        ("run_started_at", "2026-10-19T00:02:00"),
    ],
)
def test_copy_cannot_use_missing_or_mismatched_attempt_metadata(history, field, value):
    original, metadata = history
    metadata[2][field] = value
    with pytest.raises(ValueError):
        canonical_jobs(
            [original, {**original, "id": 2, "run_attempt": 2}],
            RUN,
            metadata.__getitem__,
        )


def test_null_steps_are_not_complete_copy_proof(history):
    original, metadata = history
    original["steps"] = None
    with pytest.raises(ValueError):
        canonical_jobs(
            [original, {**original, "id": 2, "run_attempt": 2}],
            RUN,
            metadata.__getitem__,
        )


def test_actual_inverse_skipped_api_rows_stay_authoritative_and_do_not_block_other_jobs():
    data = json.loads(
        (Path(__file__).parent / "fixtures/github-job-copies.json").read_text()
    )
    case = data["observations"][0]
    jobs = case["jobs"] + data["inverse_skipped_rows"]
    attempts = {item["run_attempt"]: item for item in case["attempts"]}
    result = canonical_jobs(jobs, case["run"], attempts.__getitem__)
    for skipped in data["inverse_skipped_rows"]:
        assert skipped in result and skipped["started_at"] > skipped["completed_at"]
        with pytest.raises(ValueError, match="Latest required job"):
            candidates.latest(result, skipped["name"])
    assert (
        next(job for job in result if job["name"] == "macos-stages / native-macos")[
            "run_attempt"
        ]
        == 1
    )
