"""Retired per-merge outputs cannot bypass the tested release-tier index."""

import json
from pathlib import Path

import pytest
import yaml

from tests.test_ci_release_candidates import (
    producer as producer,
    REPOSITORY,
    SOURCE,
    FLOOR,
    CONTROL,
)
from tools import ci_artifacts as artifacts
from tools import ci_release_candidates as candidates
from tools.ci_producer_trust import PRODUCERS

ROOT = Path(__file__).resolve().parents[1]


def workflow(name):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())


@pytest.mark.parametrize("pinned", [False, True])
@pytest.mark.parametrize("ref", ["refs/pull/987/merge", "refs/heads/main", ""])
def test_public_application_pull_requires_real_tested_index_and_retains_original_bytes(
    producer, tmp_path, monkeypatch, pinned, ref
):
    monkeypatch.setenv("GITHUB_REF", ref)
    destination = tmp_path / "restored"
    assert artifacts.pull(
        REPOSITORY,
        "linux-app",
        SOURCE,
        destination,
        source_run=42 if pinned else 0,
    )
    assert (
        destination / "application"
    ).read_bytes() == b"compiled fixture, never rebuilt"
    qualification = json.loads((destination / "source-qualification.json").read_text())
    receipt = qualification["source_receipt"]
    assert qualification["producer_run"] == 42
    assert receipt["source_run_attempt"] == 1
    assert receipt["tier"] == "release"
    assert receipt["source_commit"] == SOURCE
    assert (
        producer.item(artifacts.name("linux-app", SOURCE))["id"] in producer.downloads
    )


@pytest.mark.parametrize(
    "failure", ["missing-index", "failed-gate", "preview", "main-push"]
)
def test_public_application_lookup_never_promotes_unindexed_or_wrong_tier_bytes(
    producer, tmp_path, failure
):
    if failure == "missing-index":
        producer.items.remove(producer.item(f"ci-release-candidate-{SOURCE}"))
        assert not artifacts.pull(
            REPOSITORY, "linux-app", SOURCE, tmp_path / "restored"
        )
    else:
        if failure == "failed-gate":
            next(
                job
                for job in producer.jobs
                if job["name"] == "candidates / acceptance-audio"
            )["conclusion"] = "failure"
        elif failure == "preview":
            producer.change(
                artifacts.receipt_name("linux-app", SOURCE),
                lambda record: record["source_receipt"].update(tier="preview"),
            )
        else:
            producer.run.update(path=".github/workflows/macos.yml", event="push")
        with pytest.raises(ValueError):
            artifacts.pull(
                REPOSITORY, "linux-app", SOURCE, tmp_path / "restored", source_run=42
            )
    assert not (tmp_path / "restored").exists()
    assert (
        producer.item(artifacts.name("linux-app", SOURCE))["id"]
        not in producer.downloads
    )


def test_below_floor_source_cannot_use_legacy_transition_after_switch(producer):
    with pytest.raises(ValueError, match="below RELEASE_SOURCE_FLOOR"):
        candidates.source_policy(REPOSITORY, FLOOR, CONTROL, floor=SOURCE)
    assert "legacy-release-candidate" not in PRODUCERS
    assert "main-acceptance" not in PRODUCERS
    # Independent dependency-seed historical qualification remains deliberately.
    assert PRODUCERS["dependency-seed"].jobs == {"": ("linux-bundle",)}


def test_ordinary_main_keeps_full_application_and_acceptance_without_candidate_uploads():
    jobs = workflow("macos.yml")["jobs"]
    assert "linux-bundle" not in jobs
    distribution = jobs["distribution-number"]
    assert "inputs.tier == 'release'" in distribution["if"]
    assert "github.event_name != 'pull_request'" in distribution["if"]
    assert "github.ref == 'refs/heads/main'" in distribution["if"]
    for name in ("macos", "linux-build"):
        assert "inputs.tier != 'release'" in jobs[name]["if"]
    assert not any(
        "main-linux-bundle-" in str(job) or "main-macos-app-" in str(job)
        for job in jobs.values()
    )
    uploads = [
        step for step in jobs["macos"]["steps"] if step.get("id") == "macos-candidate"
    ]
    assert len(uploads) == 1 and "inputs.tier == 'release'" in uploads[0]["if"]
    for name in ("acceptance-cpu", "acceptance-audio", "acceptance-deb"):
        assert jobs[name]["needs"] == ["changes", "linux-build"]
        assert jobs[name].get("continue-on-error", False) is False
    assert set(jobs["acceptance-checks"]["needs"]) == {
        "changes",
        "linux-build",
        "acceptance-cpu",
        "acceptance-audio",
        "acceptance-deb",
    }


def test_all_preview_linux_consumers_bind_the_exact_in_run_output():
    jobs = workflow("preview-packages.yml")["jobs"]
    for name, directory in (("linux", "artifacts"), ("publish", "packages/portable")):
        restore = next(
            step
            for step in jobs[name]["steps"]
            if "tools.integration_application" in step.get("run", "")
        )
        for key, output in (
            ("ARTIFACT_ID", "linux_bundle_id"),
            ("ARTIFACT_DIGEST", "linux_bundle_digest"),
            ("PRODUCER_ATTEMPT", "linux_bundle_attempt"),
        ):
            assert restore["env"][key] == "${{ needs.build.outputs." + output + " }}"
        assert restore["env"]["BUILD_LABEL"] == "${{ needs.plan.outputs.label }}"
        assert "--purpose package-contract" in restore["run"]
        assert "--directory " + directory in restore["run"]
    assert "preview-linux-portable" not in str(jobs)


def test_only_dependency_and_ci_docker_stages_remain():
    dockerfile = (ROOT / "packaging/build.Dockerfile").read_text()
    stages = [
        line.rsplit(" AS ", 1)[1]
        for line in dockerfile.splitlines()
        if line.startswith("FROM ")
    ]
    assert stages == [
        "appdeps_seed",
        "application-base",
        "application-dependencies",
        "ci",
    ]
    dispatch = workflow("macos.yml")["on"]["workflow_dispatch"]["inputs"]
    assert not {"platforms", "rebuild_reason", "request_id"} & dispatch.keys()
    # Reusable release coordination still identifies its explicit request.
    assert "request_id" in workflow("macos.yml")["on"]["workflow_call"]["inputs"]
