"""Publication may reuse only a successful summary for unchanged source/bytes."""

import hashlib
import io
import json
import subprocess
import zipfile

import pytest

from tools import reuse_release_acceptance as reuse

SHA = "a" * 40
REPO = "owner/repo"


def fixture(monkeypatch):
    assets = []
    installers = []
    for index, suffix in enumerate((".deb", ".rpm", ".pkg.tar.zst", ".dmg")):
        name = "installer" + suffix
        digest = str(index) * 64
        assets.extend(
            [
                {"name": name, "digest": "sha256:" + digest},
                {"name": name + ".sha256"},
                {"name": name + ".build.json"},
            ]
        )
        installers.append(
            {
                "asset": name,
                "sha256": digest,
                "platform": "macos" if suffix == ".dmg" else "linux",
            }
        )
    report = {
        "tag": "v0.1.2",
        "source_commit": SHA,
        "status": "automated_passed_manual_pending",
        "installers": installers,
        "gpu_inference": {"status": "manual_pending", "evidence": []},
    }
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as bundle:
        bundle.writestr("release-acceptance.json", json.dumps(report))
    raw = stream.getvalue()
    artifact = {
        "id": 5,
        "name": "release-acceptance-summary",
        "expired": False,
        "created_at": "2026-10-18T01:00:30Z",
        "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
    }
    run = {
        "path": ".github/workflows/release.yml",
        "head_branch": "main",
        "event": "workflow_dispatch",
        "head_repository": {"full_name": REPO},
        "conclusion": "failure",
    }
    job = {
        "name": "acceptance / acceptance",
        "conclusion": "success",
        "run_attempt": 2,
        "started_at": "2026-10-18T01:00:00Z",
        "completed_at": "2026-10-18T01:01:00Z",
    }

    def api(repo, route):
        assert repo == REPO
        if route == "actions/runs/42":
            return run
        if route == "commits/v0.1.2":
            return {"sha": SHA}
        if "/artifacts?" in route:
            return {"artifacts": [artifact]}
        raise AssertionError(route)

    monkeypatch.setattr(reuse, "api", api)
    monkeypatch.setattr(reuse, "dependency_jobs", lambda *args: [job])
    monkeypatch.setattr(
        reuse,
        "release_for_tag",
        lambda *args: {"assets": assets, "target_commitish": SHA},
    )

    def download(command, *, stdout, check, timeout, stderr):
        stdout.write(raw)

    monkeypatch.setattr(subprocess, "run", download)
    # download_zip uses ci_artifacts.subprocess and verifies the actual ZIP hash.
    return run, job, artifact, assets


def test_publish_only_reuses_automated_checks_without_fabricating_gpu(monkeypatch):
    fixture(monkeypatch)
    result = reuse.restore(REPO, "v0.1.2", 42)
    assert result["status"] == "automated_passed_manual_pending"
    assert result["gpu_inference"]["status"] == "manual_pending"
    assert result["reused_validation_from"]["attempt"] == 2


@pytest.mark.parametrize(
    "invalid", ["workflow", "job", "upload", "digest", "asset", "source"]
)
def test_untrusted_or_changed_acceptance_never_authorizes_publication(
    monkeypatch, invalid
):
    run, job, artifact, assets = fixture(monkeypatch)
    if invalid == "workflow":
        run["path"] = ".github/workflows/untrusted.yml"
    if invalid == "job":
        job["conclusion"] = "failure"
    if invalid == "upload":
        artifact["created_at"] = "2026-10-18T02:00:00Z"
    if invalid == "digest":
        artifact["digest"] = "sha256:" + "f" * 64
    if invalid == "asset":
        assets[0]["digest"] = "sha256:" + "f" * 64
    if invalid == "source":
        monkeypatch.setattr(
            reuse,
            "release_for_tag",
            lambda *args: {"assets": assets, "target_commitish": "b" * 40},
        )
    with pytest.raises(ValueError):
        reuse.restore(REPO, "v0.1.2", 42)
