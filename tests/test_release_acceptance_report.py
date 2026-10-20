"""Publication requires GPU evidence for the accepted installer bytes."""

import json
import shutil

import pytest

from tools.release_acceptance_report import (
    aggregate,
    require_publication,
    require_coordinator,
)


def receipts(root):
    for index, suffix in enumerate((".deb", ".rpm", ".pkg.tar.zst", ".dmg")):
        directory = root / str(index)
        (directory / "assets").mkdir(parents=True)
        (directory / "reports").mkdir()
        (directory / "assets/installer.json").write_text(
            json.dumps(
                {
                    "tag": "v1.2.3",
                    "status": "verified_download",
                    "source_commit": "a" * 40,
                    "release_tag_commit": "a" * 40,
                    "asset": "app" + suffix,
                    "sha256": str(index) * 64,
                }
            )
        )
        (directory / "reports/functional.json").write_text(
            json.dumps(
                {
                    "status": "automated_passed_manual_pending",
                    "gpu_inference": {"status": "manual_pending"},
                }
            )
        )
        (directory / "reports/upgrade.json").write_text(
            json.dumps(
                {
                    "status": "passed",
                    "previous_tag": "v1.2.2",
                    "previous_sha256": "f" * 64,
                    "current_sha256": str(index) * 64,
                    "persistence_verified": True,
                }
            )
        )


def evidence():
    return [
        {
            "platform": platform,
            "installer_sha256": digest * 64,
            "gpu": "test GPU",
            "backend": "GPU",
            "tester": "release operator",
            "tested_at_utc": "2026-10-18T20:00:00Z",
            "evidence": "recorded real hardware GPU decode and Whisper results",
        }
        for platform, digest in (("linux", "0"), ("macos", "3"))
    ]


def test_automated_success_still_blocks_publication_until_manual_gpu(tmp_path):
    receipts(tmp_path)
    pending = aggregate(tmp_path, "v1.2.3", "")
    with pytest.raises(ValueError, match="release-day GPU"):
        require_publication(pending, "v1.2.3")
    report = aggregate(tmp_path, "v1.2.3", json.dumps(evidence()))
    require_publication(report, "v1.2.3")
    with pytest.raises(ValueError):
        require_publication(report, "v9.9.9")


@pytest.mark.parametrize(
    "change", ["wrong_digest", "missing_platform", "empty_evidence", "invalid_time"]
)
def test_unbound_or_incomplete_manual_gpu_evidence_is_rejected(tmp_path, change):
    receipts(tmp_path)
    records = evidence()
    if change == "wrong_digest":
        records[0]["installer_sha256"] = "f" * 64
    elif change == "missing_platform":
        records.pop()
    elif change == "empty_evidence":
        records[0]["evidence"] = ""
    else:
        records[0]["tested_at_utc"] = "yesterday"
    with pytest.raises(ValueError):
        aggregate(tmp_path, "v1.2.3", json.dumps(records))


def test_missing_installer_functional_report_fails_aggregation(tmp_path):
    receipts(tmp_path)
    (tmp_path / "2/reports/functional.json").unlink()
    with pytest.raises(ValueError, match="functional"):
        aggregate(tmp_path, "v1.2.3", "")


@pytest.mark.parametrize("publish_only", [False, True])
def test_publication_mode_requires_acceptance_and_exact_build_states(publish_only):
    expected = "skipped" if publish_only else "success"
    results = {job: {"result": expected} for job in ("prepare", "linux", "macos")}
    results["acceptance"] = {"result": "success"}
    results["preflight"] = {"result": "success"}
    results["candidates"] = {"result": expected}
    results["candidate-receipt"] = {"result": expected}
    require_coordinator(results, "refs/heads/main", publish_only, reuse=publish_only)
    with pytest.raises(ValueError, match="reviewed main"):
        require_coordinator(
            results, "refs/heads/feature", publish_only, reuse=publish_only
        )
    for job in results:
        for state in ("failure", "cancelled", "timed_out"):
            failed = {**results, job: {"result": state}}
            with pytest.raises(ValueError, match="unpublished"):
                require_coordinator(
                    failed, "refs/heads/main", publish_only, reuse=publish_only
                )
    with pytest.raises(ValueError):
        require_coordinator(results, "refs/heads/main", not publish_only)


def test_real_five_artifact_matrix_retains_duplicate_deb_validation(tmp_path):
    receipts(tmp_path)
    shutil.copytree(tmp_path / "0", tmp_path / "debian")
    report = aggregate(tmp_path, "v1.2.3", json.dumps(evidence()))
    assert len(report["installers"]) == 4
    assert len(report["validation_artifacts"]) == 5
    require_publication(report, "v1.2.3")
    (tmp_path / "debian/reports/functional.json").unlink()
    with pytest.raises(ValueError, match="functional"):
        aggregate(tmp_path, "v1.2.3", "")


def test_conflicting_duplicate_installer_identity_is_rejected(tmp_path):
    receipts(tmp_path)
    shutil.copytree(tmp_path / "0", tmp_path / "debian")
    receipt = tmp_path / "debian/assets/installer.json"
    data = json.loads(receipt.read_text())
    data["sha256"] = "f" * 64
    receipt.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="conflicting"):
        aggregate(tmp_path, "v1.2.3", "")


@pytest.mark.parametrize(
    "problem",
    [
        "missing",
        "duplicate",
        "failed",
        "persistence",
        "current-bytes",
        "previous-bytes",
        "same-version",
        "preview-version",
    ],
)
def test_upgrade_evidence_is_required_for_every_installer_environment(
    tmp_path, problem
):
    receipts(tmp_path)
    path = tmp_path / "0/reports/upgrade.json"
    record = json.loads(path.read_text())
    if problem == "missing":
        path.unlink()
    elif problem == "duplicate":
        path.with_name("nested").mkdir()
        shutil.copy2(path, path.with_name("nested") / "upgrade.json")
    else:
        field, value = {
            "failed": ("status", "failed"),
            "persistence": ("persistence_verified", False),
            "current-bytes": ("current_sha256", "e" * 64),
            "previous-bytes": ("previous_sha256", "invalid"),
            "same-version": ("previous_tag", "v1.2.3"),
            "preview-version": ("previous_tag", "nightly.20261019.1"),
        }[problem]
        record[field] = value
        path.write_text(json.dumps(record))
    with pytest.raises(ValueError, match="upgrade evidence"):
        aggregate(tmp_path, "v1.2.3", "")
