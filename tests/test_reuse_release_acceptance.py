"""Publication rechecks original latest attempts and immutable upstream ZIP bytes."""

import copy
import hashlib
import io
import json
import subprocess
from types import SimpleNamespace
import zipfile

import pytest

from tools import reuse_release_acceptance as reuse
from tools import ci_release_candidates as candidates
from tools import ci_release_evidence as evidence

SHA = "a" * 40
REPO = "owner/repo"


def fixture(monkeypatch):
    state = SimpleNamespace(
        assets=[], runs={}, jobs={}, items={}, blobs={}, downloads=[], attempt_starts={}
    )
    installers = []
    for index, suffix in enumerate((".deb", ".rpm", ".pkg.tar.zst", ".dmg")):
        name, digest = "installer" + suffix, str(index) * 64
        state.assets.extend(
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
    state.report = {
        "suite_version": reuse.SUITE_VERSION,
        "tag": "v0.1.2",
        "source_commit": SHA,
        "status": "automated_passed_manual_pending",
        "installers": installers,
        "gpu_inference": {"status": "manual_pending", "evidence": []},
    }

    def add(run_id, report, attempt=2):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as bundle:
            bundle.writestr("release-acceptance.json", json.dumps(report))
        data = raw.getvalue()
        state.blobs[run_id] = data
        state.runs[run_id] = {
            "id": run_id,
            "path": ".github/workflows/release.yml",
            "head_sha": SHA,
            "head_branch": "main",
            "event": "workflow_dispatch",
            "status": "completed",
            "repository": {"full_name": REPO},
            "head_repository": {"full_name": REPO},
            "conclusion": "failure",  # Publication may be awaiting manual evidence.
        }
        state.jobs[run_id] = [
            {
                "id": run_id + 100,
                "name": "acceptance / acceptance",
                "status": "completed",
                "conclusion": "success",
                "run_attempt": attempt,
                "started_at": "2026-10-18T01:00:00Z",
                "completed_at": "2026-10-18T01:01:00Z",
            }
        ]
        state.items[run_id] = [
            {
                "id": run_id,
                "name": "release-acceptance-summary-" + str(attempt),
                "expired": False,
                "created_at": "2026-10-18T01:00:30Z",
                "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                "workflow_run": {"id": run_id},
                "size_in_bytes": len(data),
            }
        ]
        return {
            "run": run_id,
            "attempt": attempt,
            "job": run_id + 100,
            "artifact": run_id,
            "digest": state.items[run_id][0]["digest"],
        }

    state.add = add
    state.locator = add(42, state.report)

    def api(repo, route):
        assert repo == REPO
        if route == "commits/v0.1.2":
            return {"sha": SHA}
        run_id = int(route.split("/")[2])
        if "/attempts/" in route:
            attempt = int(route.rsplit("/", 1)[1])
            return {
                **state.runs[run_id],
                "run_attempt": attempt,
                "run_started_at": state.attempt_starts.get(
                    (run_id, attempt), "2026-10-18T00:59:00Z"
                ),
            }
        if "/artifacts?" in route:
            return {"artifacts": state.items[run_id]}
        if "/jobs?" in route:
            return {"jobs": state.jobs[run_id]}
        return state.runs[run_id]

    for module in (reuse, evidence, candidates):
        monkeypatch.setattr(module, "api", api)
    monkeypatch.setenv("GITHUB_RUN_ID", "99")
    monkeypatch.setattr(
        reuse,
        "release_for_tag",
        lambda *args: {"assets": state.assets, "target_commitish": SHA},
    )

    def download(command, *, stdout, check, timeout, **kwargs):
        identity = int(command[-1].split("/")[-2])
        state.downloads.append(identity)
        stdout.write(state.blobs[identity])

    monkeypatch.setattr(subprocess, "run", download)
    return state


def test_publish_only_reuses_automated_checks_without_fabricating_gpu(monkeypatch):
    state = fixture(monkeypatch)
    result = reuse.restore(REPO, "v0.1.2", 42)
    assert result["status"] == "automated_passed_manual_pending"
    assert result["gpu_inference"]["status"] == "manual_pending"
    assert result["reused_validation_from"] == state.locator


@pytest.mark.parametrize(
    "invalid",
    ["workflow", "job", "upload", "digest", "asset", "source", "suite", "status"],
)
def test_untrusted_or_changed_acceptance_never_authorizes_publication(
    monkeypatch, invalid
):
    state = fixture(monkeypatch)
    if invalid == "workflow":
        state.runs[42]["path"] = ".github/workflows/untrusted.yml"
    if invalid == "job":
        state.jobs[42][0]["conclusion"] = "failure"
    if invalid == "upload":
        state.items[42][0]["created_at"] = "2026-10-18T02:00:00Z"
    if invalid == "digest":
        state.items[42][0]["digest"] = "sha256:" + "f" * 64
    if invalid == "asset":
        state.assets[0]["digest"] = "sha256:" + "f" * 64
    if invalid == "source":
        monkeypatch.setattr(
            reuse,
            "release_for_tag",
            lambda *args: {"assets": state.assets, "target_commitish": "b" * 40},
        )
    if invalid in ("suite", "status"):
        report = copy.deepcopy(state.report)
        report["suite_version" if invalid == "suite" else "status"] = "obsolete"
        state.add(42, report)
    with pytest.raises(ValueError):
        reuse.restore(REPO, "v0.1.2", 42)


@pytest.mark.parametrize(
    "conclusion,status",
    [
        ("failure", "completed"),
        ("cancelled", "completed"),
        (None, "in_progress"),
        ("skipped", "completed"),
        ("success", "completed"),
    ],
)
def test_old_success_cannot_hide_a_later_attempt(monkeypatch, conclusion, status):
    state = fixture(monkeypatch)
    state.jobs[42].append(
        {
            **state.jobs[42][0],
            "id": 200,
            "run_attempt": 3,
            "conclusion": conclusion,
            "status": status,
        }
    )
    with pytest.raises(ValueError):
        reuse.restore(REPO, "v0.1.2", 42)
    assert state.downloads == []


def test_reused_summary_resolves_original_immutable_proof_and_flattens_chain(
    monkeypatch,
):
    state = fixture(monkeypatch)
    forwarded = {**state.report, "reused_validation_from": state.locator}
    next_locator = state.add(43, forwarded)
    state.add(44, {**forwarded, "reused_validation_from": next_locator})
    result = reuse.restore(REPO, "v0.1.2", 44)
    assert result["reused_validation_from"] == state.locator
    assert state.downloads == [44, 43, 42]
    assert state.items[42][0]["name"] == "release-acceptance-summary-2"


@pytest.mark.parametrize(
    "attack",
    [
        "failed-original",
        "wrong-digest",
        "changed-installers",
        "changed-source",
        "malformed",
        "cycle",
    ],
)
def test_forwarder_cannot_authorize_a_bad_original(monkeypatch, attack):
    state = fixture(monkeypatch)
    forwarded = copy.deepcopy({**state.report, "reused_validation_from": state.locator})
    if attack == "failed-original":
        state.jobs[42].append(
            {**state.jobs[42][0], "run_attempt": 3, "conclusion": "failure"}
        )
    if attack == "wrong-digest":
        forwarded["reused_validation_from"]["digest"] = "sha256:" + "f" * 64
    if attack == "changed-installers":
        forwarded["installers"][0]["sha256"] = "f" * 64
    if attack == "changed-source":
        forwarded["source_commit"] = "b" * 40
    if attack == "malformed":
        forwarded["reused_validation_from"] = {"run": 42}
    if attack == "cycle":
        forwarded["reused_validation_from"] = {**state.locator, "run": 43}
    state.add(43, forwarded)
    with pytest.raises(ValueError):
        reuse.restore(REPO, "v0.1.2", 43)


def test_same_run_reuse_cannot_replace_its_original_summary(monkeypatch):
    fixture(monkeypatch)
    monkeypatch.setenv("GITHUB_RUN_ID", "42")
    with pytest.raises(ValueError, match="distinct original run"):
        reuse.restore(REPO, "v0.1.2", 42)


def test_restored_manual_gpu_evidence_remains_bound_to_original_installer_bytes(
    monkeypatch,
):
    state = fixture(monkeypatch)
    records = [
        {
            "platform": item["platform"],
            "installer_sha256": item["sha256"],
            "gpu": "fixture hardware",
            "backend": "GPU",
            "tester": "release tester",
            "tested_at_utc": "2026-10-19T10:00:00Z",
            "evidence": "fixture owned report",
        }
        for item in (state.report["installers"][0], state.report["installers"][-1])
    ]
    result = reuse.restore(REPO, "v0.1.2", 42, json.dumps(records))
    assert result["status"] == "passed"
    assert result["gpu_inference"]["evidence"] == records
    assert result["reused_validation_from"] == state.locator
    records[0]["installer_sha256"] = "f" * 64
    with pytest.raises(ValueError, match="accepted installer"):
        reuse.restore(REPO, "v0.1.2", 42, json.dumps(records))


def test_reuse_cannot_apply_other_release_or_duplicate_installer_summary(monkeypatch):
    state = fixture(monkeypatch)
    with pytest.raises(ValueError, match="another release"):
        reuse.restore(REPO, "v0.1.3", 42)
    state.report["installers"].append(state.report["installers"][0])
    state.add(42, state.report)
    with pytest.raises(ValueError, match="Installer bytes changed"):
        reuse.restore(REPO, "v0.1.2", 42)


def test_reuse_cli_writes_only_verified_restored_report(tmp_path, monkeypatch):
    import sys
    from unittest.mock import Mock

    restored = {"tag": "v0.1.2", "reused_validation_from": {"run": 42}}
    restore = Mock(return_value=restored)
    monkeypatch.setattr(reuse, "restore", restore)
    monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
    monkeypatch.setenv("GPU_EVIDENCE", "explicit fixture evidence")
    output = tmp_path / "restored.json"
    monkeypatch.setattr(
        sys,
        "argv",
        ["reuse", "--tag", "v0.1.2", "--run", "42", "--output", str(output)],
    )
    reuse.main()
    restore.assert_called_once_with(REPO, "v0.1.2", 42, "explicit fixture evidence")
    assert json.loads(output.read_text()) == restored


def test_copied_acceptance_summary_keeps_actual_original_job_and_upload_attempt(
    monkeypatch,
):
    state = fixture(monkeypatch)
    original = state.jobs[42][0]
    original.update(
        run_id=42,
        head_sha=SHA,
        steps=[{"name": "Upload original summary", "conclusion": "success"}],
    )
    state.jobs[42].append({**copy.deepcopy(original), "id": 1042, "run_attempt": 3})
    state.attempt_starts[42, 3] = "2026-10-18T01:02:00Z"
    result = reuse.restore(REPO, "v0.1.2", 42)
    assert result["reused_validation_from"] == state.locator
    assert result["reused_validation_from"]["attempt"] == 2
    assert result["reused_validation_from"]["job"] == original["id"]
    assert result["installers"] == state.report["installers"]
    assert state.downloads == [42]
