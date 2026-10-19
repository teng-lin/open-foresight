"""Exercise verified candidate promotion and partial-run recovery with real bytes."""

import hashlib
import json
import subprocess
from unittest.mock import patch
import zipfile

import pytest

from tools import ci_artifacts as artifacts
from tools import prepare_release as release
from tools import candidate_identity

SOURCE = "a" * 40
REPO = "owner/repo"


def candidate(tmp_path, monkeypatch):
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "2")
    prefix = tmp_path / "prefix"
    prefix.mkdir()
    (prefix / "application").write_bytes(b"verified compiled fixture")
    (prefix / "application.tar.gz.build.json").write_text(
        json.dumps({"version": "0.1.2", "build_number": 10, "revision": SOURCE})
    )
    monkeypatch.setattr(
        artifacts.subprocess, "check_output", lambda *args, **kwargs: SOURCE
    )
    upload = tmp_path / "upload"
    artifacts.pack("linux-app", SOURCE, prefix, upload)
    archive = tmp_path / "artifact.zip"
    with zipfile.ZipFile(archive, "w") as stream:
        for name in ("identity.json", "payload.tar.gz"):
            stream.write(upload / name, name)
    artifact = {
        "id": 5,
        "name": artifacts.name("linux-app", SOURCE),
        "workflow_run": {"id": 42},
        "expired": False,
        "digest": "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest(),
        "created_at": "2026-10-18T01:00:30Z",
    }
    run = {
        "id": 42,
        "head_sha": SOURCE,
        "path": ".github/workflows/macos.yml",
        "event": "push",
        "head_branch": "main",
        "head_repository": {"full_name": REPO},
        "conclusion": "failure",
    }
    job = {
        "name": "linux-bundle",
        "conclusion": "success",
        "run_attempt": 2,
        "started_at": "2026-10-18T01:00:00Z",
        "completed_at": "2026-10-18T01:01:00Z",
    }

    def api(repo, route):
        assert repo == REPO
        if route.startswith("actions/artifacts?"):
            return {"artifacts": [artifact]}
        if "/jobs?" in route:
            return {"jobs": [job]}
        assert route == "actions/runs/42", route
        return run

    monkeypatch.setattr(artifacts, "api", api)

    def download(command, *, stdout, check, timeout, stderr):
        assert command[:2] == ["gh", "api"] and command[-1].endswith("/5/zip")
        stdout.write(archive.read_bytes())
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(artifacts.subprocess, "run", download)
    return artifact, run, job


@pytest.mark.parametrize("ref", ["refs/pull/987/merge", "refs/heads/main", ""])
def test_successful_platform_in_failed_run_retains_original_receipt(
    tmp_path, monkeypatch, ref
):
    monkeypatch.setenv("GITHUB_REF", ref)
    artifact, run, job = candidate(tmp_path, monkeypatch)
    destination = tmp_path / "restored"
    assert artifacts.pull(REPO, "linux-app", SOURCE, destination, source_run=42)
    assert (destination / "application").read_bytes() == b"verified compiled fixture"
    assert artifacts.application_distribution(destination, "linux-app", SOURCE) == {
        "version": "0.1.2",
        "build_number": 10,
    }


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
    tmp_path, monkeypatch, change
):
    artifact, run, job = candidate(tmp_path, monkeypatch)
    if change == "failed_job":
        job["conclusion"] = "failure"
    if change == "wrong_attempt":
        job["run_attempt"] = 1
    if change == "wrong_upload":
        artifact["created_at"] = "2026-10-18T02:00:00Z"
    if change == "untrusted_workflow":
        run["path"] = ".github/workflows/untrusted.yml"
    if change == "corrupt_zip":
        artifact["digest"] = "sha256:" + "0" * 64
    if change in ("wrong_attempt", "corrupt_zip"):
        with pytest.raises(ValueError):
            artifacts.pull(
                REPO, "linux-app", SOURCE, tmp_path / "restored", source_run=42
            )
    else:
        assert not artifacts.pull(
            REPO, "linux-app", SOURCE, tmp_path / "restored", source_run=42
        )


def test_release_waits_for_existing_missing_platform_without_dispatch():
    runs = {"linux-app": 42, "macos-app": 43}
    pending = {
        "head_sha": SOURCE,
        "status": "in_progress",
        "head_branch": "main",
        "path": ".github/workflows/macos.yml",
        "head_repository": {"full_name": REPO},
    }
    with (
        patch.object(release, "candidate_runs", side_effect=[{"linux-app": 42}, runs]),
        patch.object(
            release,
            "application_descriptor",
            return_value={"version": "0.1.2", "build_number": 10},
        ),
        patch.object(release, "api", return_value={"workflow_runs": [pending]}),
        patch.object(release.time, "sleep") as sleep,
        patch.object(release.subprocess, "run") as dispatch,
    ):
        assert release.require_candidates(REPO, SOURCE, 30) == runs
    sleep.assert_called_once()
    dispatch.assert_not_called()


def test_release_does_not_mix_different_platform_build_numbers():
    with (
        patch.object(
            release, "candidate_runs", return_value={"linux-app": 42, "macos-app": 43}
        ),
        patch.object(
            release,
            "application_descriptor",
            side_effect=[
                {"version": "0.1.2", "build_number": 10},
                {"version": "0.1.2", "build_number": 11},
            ],
        ),
    ):
        with pytest.raises(ValueError, match="different distribution"):
            release.require_candidates(REPO, SOURCE, 0)


def test_partial_platform_build_retains_surviving_number():
    with (
        patch.object(candidate_identity, "source_version", return_value=("0.1.2", 3)),
        patch.object(
            candidate_identity, "candidate_runs", return_value={"macos-app": 42}
        ),
        patch.object(
            candidate_identity,
            "application_descriptor",
            return_value={"version": "0.1.2", "build_number": 10},
        ),
        patch.object(candidate_identity, "allocate") as allocate,
    ):
        assert candidate_identity.number(REPO, SOURCE, "linux") == 10
        with pytest.raises(ValueError, match="already has"):
            candidate_identity.number(REPO, SOURCE, "all")
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


def test_historical_source_candidate_is_discovered_without_rebuilding(
    tmp_path, monkeypatch
):
    artifact, run, job = candidate(tmp_path, monkeypatch)
    run.update(head_sha="b" * 40, event="workflow_dispatch")
    monkeypatch.setattr(release, "api", artifacts.api)
    assert release.candidate_runs(REPO, SOURCE) == {"linux-app": 42}
    assert artifacts.pull(REPO, "linux-app", SOURCE, tmp_path / "restored")
    assert artifacts.application_distribution(
        tmp_path / "restored", "linux-app", SOURCE
    ) == {
        "version": "0.1.2",
        "build_number": 10,
    }
