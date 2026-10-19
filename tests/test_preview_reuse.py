"""Retained preview bytes keep source/build identity across retries and validation."""

import hashlib
import io
import json
import os
from pathlib import Path
from unittest.mock import patch
import zipfile

import pytest

from tools import preview_reuse as reuse, preview_packages as preview

SHA = "a" * 40
LABEL = "nightly.20261018.12"
REPO = "owner/repo"


def transport(monkeypatch, members, names, jobs):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        for name, data in members.items():
            archive.writestr(name, data)
    raw = stream.getvalue()
    items = [
        {
            "id": index + 1,
            "name": name,
            "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
            "expired": False,
            "created_at": "2026-10-18T01:00:30Z",
            "workflow_run": {"id": 42},
        }
        for index, name in enumerate(names)
    ]
    run = {
        "id": 42,
        "path": reuse.WORKFLOW,
        "head_sha": SHA,
        "head_branch": "main",
        "event": "schedule",
        "head_repository": {"full_name": REPO},
        "conclusion": "success",
    }
    records = [
        {
            "name": name,
            "conclusion": "success",
            "run_attempt": 2,
            "started_at": "2026-10-18T01:00:00Z",
            "completed_at": "2026-10-18T01:01:00Z",
        }
        for name in jobs
    ]

    def api(repo, route, **kwargs):
        assert repo == REPO
        if route == "commits/main":
            return {"sha": SHA}
        if route == "actions/runs/42":
            return run
        if route.endswith("/artifacts?per_page=100"):
            return {"artifacts": items}
        if "/jobs?" in route:
            return {"jobs": records}
        if "preview-packages.yml/runs?" in route:
            return {"workflow_runs": [run]}
        raise AssertionError(route)

    monkeypatch.setattr(reuse.ci_artifacts, "api", api)

    def download(command, *, stdout, check, timeout):
        stdout.write(raw)

    monkeypatch.setattr(reuse.ci_artifacts.subprocess, "run", download)
    return run, items, records, api


def installer_members():
    result = {}
    for kind, suffix in {
        "deb": ".deb",
        "rpm": ".rpm",
        "arch": ".pkg.tar.zst",
        "dmg": ".dmg",
    }.items():
        name = kind + "/installer" + suffix
        payload = kind.encode()
        digest = hashlib.sha256(payload).hexdigest()
        metadata = {
            "revision": SHA,
            "format": kind,
            "version": "0.1.2" if kind == "dmg" else "0.1.2~" + LABEL,
            "build_number": 12,
            "sha256": digest,
            "arch": "arm64" if kind == "dmg" else "x86_64",
        }
        result.update(
            {
                name: payload,
                name + ".sha256": f"{digest}  {Path(name).name}\n",
                name + ".build.json": json.dumps(metadata),
            }
        )
    return result


@pytest.mark.parametrize("ref", ["refs/pull/987/merge", "refs/heads/main", ""])
def test_full_validation_restores_original_bytes_and_provenance(
    tmp_path, monkeypatch, ref
):
    monkeypatch.setenv("GITHUB_REF", ref)
    run, items, jobs, api = transport(
        monkeypatch,
        installer_members(),
        [
            "preview-installer-linux-deb",
            "preview-installer-linux-rpm",
            "preview-installer-linux-arch",
            "preview-installer-macos",
        ],
        ["linux (deb, ubuntu)", "linux (rpm, fedora)", "linux (arch, arch)", "macos"],
    )
    result = reuse.restore(REPO, 42, SHA, "deb", tmp_path / "assets")
    assert result["producer_run"] == 42 and result["producer_attempt"] == 2
    assert result["build_number"] == 12 and result["version"] == "0.1.2~" + LABEL
    assert (tmp_path / "assets/installer.deb").read_bytes() == b"deb"
    with (
        patch.dict(
            os.environ, {"GITHUB_RUN_ID": "43", "GITHUB_REF": "refs/heads/main"}
        ),
        patch.object(preview, "request", side_effect=api),
        patch.object(preview.subprocess, "check_output", return_value=SHA),
        patch.object(preview, "allocate") as allocate,
    ):
        planned = preview.plan(REPO, False, "full")
    assert planned["build"] == "false" and planned["reuse_run"] == "42"
    allocate.assert_not_called()


def test_partial_preview_recovers_same_identity_instead_of_allocating_build(
    monkeypatch,
):
    run, items, jobs, api = transport(
        monkeypatch,
        installer_members(),
        ["preview-installer-linux-deb"],
        ["linux (deb, ubuntu)"],
    )
    run["conclusion"] = "failure"
    with (
        patch.dict(
            os.environ, {"GITHUB_RUN_ID": "43", "GITHUB_REF": "refs/heads/main"}
        ),
        patch.object(preview, "request", side_effect=api),
        patch.object(preview.subprocess, "check_output", return_value=SHA),
        patch.object(
            preview,
            "recovery_identity",
            return_value={
                "build": "false",
                "recovery_run": "42",
                "label": LABEL,
                "build_number": "12",
            },
        ) as recover,
        patch.object(preview, "allocate") as allocate,
    ):
        assert preview.plan(REPO, False, "standard")["recovery_run"] == "42"
    recover.assert_called_once_with(REPO, 42, SHA)
    allocate.assert_not_called()


@pytest.mark.parametrize("invalid", ["source", "workflow", "job", "digest", "expired"])
def test_invalid_preview_artifacts_cannot_be_promoted(tmp_path, monkeypatch, invalid):
    run, items, jobs, api = transport(
        monkeypatch,
        installer_members(),
        ["preview-installer-linux-deb"],
        ["linux (deb, ubuntu)"],
    )
    if invalid == "source":
        run["head_sha"] = "b" * 40
    if invalid == "workflow":
        run["path"] = ".github/workflows/untrusted.yml"
    if invalid == "job":
        jobs[0]["conclusion"] = "failure"
    if invalid == "digest":
        items[0]["digest"] = "sha256:" + "0" * 64
    if invalid == "expired":
        items[0]["expired"] = True
    if invalid in ("job", "expired"):
        assert reuse.restore(REPO, 42, SHA, "deb", tmp_path / "assets") is None
    else:
        with pytest.raises(ValueError):
            reuse.restore(REPO, 42, SHA, "deb", tmp_path / "assets")


def test_forced_rebuild_requires_a_reason_before_allocating_or_requesting():
    with (
        patch.object(preview, "request") as request,
        patch.object(preview, "allocate") as allocate,
    ):
        with pytest.raises(ValueError, match="rebuild reason"):
            preview.plan(REPO, True, "standard")
    request.assert_not_called()
    allocate.assert_not_called()


@pytest.mark.parametrize("mismatch", [False, True])
def test_packaging_recovery_reads_matching_original_application_identities(
    monkeypatch, mismatch
):
    members = {
        "application.tar.gz.build.json": json.dumps(
            {"revision": SHA, "version": "0.1.2~" + LABEL, "build_number": 12}
        ),
        "Open Foresight.manifest.json": json.dumps(
            {
                "revision": SHA,
                "version": "0.1.2",
                "build_number": 13 if mismatch else 12,
            }
        ),
        "application.tar.gz": b"compiled application fixture",
        "Open-Foresight-macos-arm64.zip": b"compiled macOS application fixture",
    }
    run, items, jobs, api = transport(
        monkeypatch,
        members,
        ["preview-linux-portable", "preview-macos-application"],
        ["build / linux-bundle", "build / macos"],
    )
    run["conclusion"] = "failure"
    if mismatch:
        with pytest.raises(ValueError, match="identities disagree"):
            reuse.recovery_identity(REPO, 42, SHA)
    else:
        result = reuse.recovery_identity(REPO, 42, SHA)
        assert (
            result["build"] == "false"
            and result["build_number"] == "12"
            and result["label"] == LABEL
        )
        assert result["source"] == SHA and result["recovery_run"] == "42"
