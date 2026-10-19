"""Preview retries reuse immutable identity and reject inconsistent metadata."""

import json
from unittest.mock import Mock

import pytest
from tools import preview_packages as preview
from test_preview_reuse import transport, installer_members, REPO, SHA, LABEL
from test_preview_packages import installers


@pytest.mark.parametrize("status", ["ahead", "diverged"])
def test_explicit_recovery_preserves_reviewed_source_without_allocating(
    tmp_path, monkeypatch, status
):
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setattr(preview.subprocess, "check_output", lambda *a, **kw: SHA)

    def request(repo, route):
        return (
            {"sha": SHA}
            if route == "commits/main"
            else {"head_sha": "b" * 40}
            if route == "actions/runs/42"
            else {"status": status}
        )

    monkeypatch.setattr(preview, "request", request)
    monkeypatch.setattr(
        preview, "recovery_identity", lambda *a: {"source": "b" * 40, "build": "false"}
    )
    allocate = Mock(side_effect=AssertionError("must not allocate new build"))
    monkeypatch.setattr(preview, "allocate", allocate)
    if status == "ahead":
        assert preview.plan(REPO, False, "full", candidate_run=42)["source"] == "b" * 40
    else:
        with pytest.raises(ValueError, match="reviewed main"):
            preview.plan(REPO, False, "full", candidate_run=42)
    allocate.assert_not_called()


def test_existing_preview_writes_reuse_summary_and_stale_version_aborts_new_build(
    tmp_path, monkeypatch
):
    _, _, _, api = transport(
        monkeypatch,
        installer_members(),
        [
            "preview-installer-linux-deb",
            "preview-installer-linux-rpm",
            "preview-installer-linux-arch",
            "preview-installer-macos",
        ],
        [],
    )
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setenv("GITHUB_RUN_ID", "43")
    summary = tmp_path / "summary"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    monkeypatch.setattr(preview, "request", api)
    monkeypatch.setattr(preview.subprocess, "check_output", lambda *a, **kw: SHA)
    assert preview.plan(REPO, False, "full")["build"] == "false"
    assert "original source, build number and checksums" in summary.read_text()
    monkeypatch.setattr(preview, "stale", lambda: ["version copies disagree"])
    allocate = Mock()
    monkeypatch.setattr(preview, "allocate", allocate)
    with pytest.raises(ValueError, match="version copies"):
        preview.plan(REPO, True, "standard", "Changed embedded application identity")
    allocate.assert_not_called()


@pytest.mark.parametrize(
    "version,number,label,source",
    [
        ("invalid", 12, "", SHA),
        ("1.2.3", 12, "nightly.20261018.13", SHA),
        ("1.2.3", 2, "", SHA),
        ("1.2.3", 12, "", "main"),
    ],
)
def test_invalid_stamp_does_not_write_distribution_identity(
    tmp_path, monkeypatch, version, number, label, source
):
    monkeypatch.setattr(preview, "read_version", lambda *a: ("1.2.3", 3))
    with pytest.raises(ValueError):
        preview.stamp(version, number, label, source, tmp_path)
    assert not (tmp_path / preview.IDENTITY).exists()


@pytest.mark.parametrize("failure", ["source", "format", "version", "build-number"])
def test_manifest_cannot_relabel_original_installer_bytes(tmp_path, failure):
    installers(tmp_path)
    target = next(tmp_path.rglob("*.deb.build.json"))
    record = json.loads(target.read_text())
    field, value = {
        "source": ("revision", "b" * 40),
        "format": ("format", "rpm"),
        "version": ("version", "9.9.9"),
        "build-number": ("build_number", 13),
    }[failure]
    record[field] = value
    target.write_text(json.dumps(record))
    with pytest.raises(ValueError):
        preview.manifest(tmp_path, "0.1.2", 12, LABEL, SHA, "full")


def test_preview_manifest_summary_binds_final_output_hashes(tmp_path, monkeypatch):
    installers(tmp_path)
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    report = preview.manifest(tmp_path, "0.1.2", 12, LABEL, SHA, "full")
    assert report["source_commit"] == SHA
    assert "build `12`" in summary.read_text()
