"""Exercise verified candidate promotion and partial-run recovery with real bytes."""

import json
from unittest.mock import patch

import pytest

from tools import ci_artifacts as artifacts
from tools import prepare_release as release
from tools import candidate_identity
from test_ci_release_candidates import producer as producer, SOURCE, REPOSITORY as REPO


@pytest.mark.parametrize("ref", ["refs/pull/987/merge", "refs/heads/main", ""])
def test_successful_platform_in_failed_run_retains_original_receipt(
    producer, tmp_path, monkeypatch, ref
):
    monkeypatch.setenv("GITHUB_REF", ref)
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "7")
    producer.run["conclusion"] = "failure"
    destination = tmp_path / "restored"
    assert artifacts.pull(
        REPO,
        "linux-app",
        SOURCE,
        destination,
        source_run=42,
        consumer="release-preparation",
    )
    assert (
        destination / "application"
    ).read_bytes() == b"compiled fixture, never rebuilt"
    assert artifacts.application_distribution(destination, "linux-app", SOURCE) == {
        "version": "1.2.3",
        "build_number": 7,
    }
    qualification = json.loads((destination / "source-qualification.json").read_text())
    assert qualification["source_receipt"]["source_run_attempt"] == 1
    assert qualification["producer_run"] == 42


@pytest.mark.parametrize(
    "change",
    [
        "failed_job",
        "wrong_attempt",
        "wrong_upload",
        "untrusted_workflow",
        "corrupt_zip",
    ],
)
def test_application_promotion_rejects_failed_or_unbound_outputs(
    producer, tmp_path, change
):
    payload = producer.item(artifacts.name("linux-app", SOURCE))
    job = next(
        job for job in producer.jobs if job["name"] == "candidates / linux-build"
    )
    if change == "failed_job":
        job["conclusion"] = "failure"
    elif change == "wrong_attempt":
        job["run_attempt"] = 2
    elif change == "wrong_upload":
        payload["created_at"] = "2026-10-20T02:00:00Z"
    elif change == "untrusted_workflow":
        producer.run["path"] = ".github/workflows/untrusted.yml"
    else:
        producer.blobs[payload["id"]] += b"corrupt transport"
    expected = {
        "failed_job": "Latest required job must succeed",
        "wrong_attempt": "Candidate index differs from required source, tier, original receipt job or latest gates",
        "wrong_upload": "Missing unambiguous original upload",
        "untrusted_workflow": "completed reviewed-main release controller",
        "corrupt_zip": "ZIP digest",
    }[change]
    with pytest.raises(ValueError, match=expected):
        artifacts.pull(
            REPO,
            "linux-app",
            SOURCE,
            tmp_path / "restored",
            source_run=42,
            consumer="release-preparation",
        )
    assert not (tmp_path / "restored").exists()


def test_release_preparation_reads_completed_candidates_once_without_polling():
    runs = {"linux-app": 42, "macos-app": 42}
    with (
        patch.object(release, "candidate_runs", return_value=runs) as lookup,
        patch.object(release.time, "sleep") as sleep,
        patch.object(release.subprocess, "run") as dispatch,
    ):
        assert release.verified_candidates(REPO, SOURCE, 42) == runs
    lookup.assert_called_once_with(REPO, SOURCE, 42)
    sleep.assert_not_called()
    dispatch.assert_not_called()


def test_release_preparation_rejects_mixed_original_platform_runs():
    with patch.object(
        release, "candidate_runs", return_value={"linux-app": 42, "macos-app": 43}
    ):
        with pytest.raises(ValueError, match="unavailable"):
            release.verified_candidates(REPO, SOURCE, 42)


def test_existing_tested_candidate_never_allocates_a_replacement_number():
    with (
        patch.object(candidate_identity, "source_version", return_value=("0.1.2", 3)),
        patch.object(
            candidate_identity,
            "candidate_runs",
            return_value={"linux-app": 42, "macos-app": 42},
        ),
        patch.object(candidate_identity, "allocate") as allocate,
    ):
        with pytest.raises(ValueError, match="already has"):
            candidate_identity.number(REPO, SOURCE)
        allocate.assert_not_called()


def test_distribution_reads_product_version_instead_of_controller_checkout():
    with patch.object(
        candidate_identity.subprocess, "check_output", return_value="version: 0.1.2+3\n"
    ) as git:
        assert candidate_identity.source_version(SOURCE) == ("0.1.2", 3)
        assert git.call_args.args[0] == [
            "git",
            "show",
            f"{SOURCE}:apps/desktop/pubspec.yaml",
        ]
    with pytest.raises(ValueError, match="full commit"):
        candidate_identity.source_version("main")


def test_retired_generic_candidate_discovery_is_rejected_without_api_reads():
    with patch.object(release, "api") as request:
        with pytest.raises(ValueError, match="release-tier"):
            release.candidate_runs(REPO, SOURCE, consumer="artifact-pull")
    request.assert_not_called()
