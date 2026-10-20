"""Authenticated proof indices cannot waive original producer or closure proof."""

import copy
import hashlib
import json
import sys
import zipfile

import pytest

from tools import ci_qualification_index as index, ci_changes
from tools import ci_rollout as rollout
from tests.test_ci_rollout import Evidence, REPOSITORY, SOURCE


@pytest.fixture
def proof(tmp_path):
    for name in (
        "tools/ci_changes.py",
        "tools/ci_selection.py",
        ".github/workflows/macos.yml",
    ):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("retained input\n")
    return IndexEvidence(tmp_path)


class IndexEvidence(Evidence):
    def __init__(self, root):
        super().__init__(root)
        self.indexes = []

    def publish(self):
        value = copy.deepcopy(self.index)
        value["producer"] = {
            "run_id": 999,
            "attempt": 1,
            "job": index.JOB,
            "source": SOURCE,
        }
        self.runs[999] = {
            "id": 999,
            "path": index.WORKFLOW,
            "event": "schedule",
            "head_sha": SOURCE,
            "head_branch": "main",
            "repository": {"full_name": REPOSITORY},
            "head_repository": {"full_name": REPOSITORY},
            "status": "completed",
            "conclusion": "success",
        }
        self.jobs[999] = [
            {
                "id": 9990,
                "name": index.JOB,
                "run_attempt": 1,
                "conclusion": "success",
                "started_at": "2026-10-01T00:00:00Z",
                "completed_at": "2026-10-01T00:10:00Z",
            }
        ]
        self.artifacts[999] = {
            "id": 999,
            "name": index.NAME,
            "expired": False,
            "workflow_run": {"id": 999},
            "created_at": "2026-10-01T00:05:00Z",
        }
        self.payloads[999] = value
        self.indexes = [self.artifacts[999]]
        return value

    def api(self, repository, route):
        if route.startswith("actions/artifacts?"):
            rows = (
                self.indexes
                if f"name={index.NAME}&" in route
                else [
                    row
                    for row in self.artifacts.values()
                    if row["name"] == "ci-rollout-qualification"
                ]
            )
            return {"artifacts": rows}
        return super().api(repository, route)

    def download(self, repository, artifact, path):
        with zipfile.ZipFile(path, "w") as stream:
            stream.writestr(
                "index.json"
                if artifact["name"] == index.NAME
                else "qualification.json",
                json.dumps(self.payloads[artifact["id"]]),
            )


def test_index_original_producer_and_real_selection_capability(proof):
    proof.add("selector-replay")
    proof.verify("path_selection")
    value = proof.publish()
    assert index.load(REPOSITORY, api=proof.api, download=proof.download) == value
    result = index.capability(
        "path_selection",
        SOURCE,
        root=proof.root,
        repository=REPOSITORY,
        api=proof.api,
        download=proof.download,
    )
    assert result["capabilities"] == ["path_selection"]
    with pytest.raises(ValueError, match="Missing actual"):
        index.capability(
            "main_receipts",
            SOURCE,
            root=proof.root,
            repository=REPOSITORY,
            api=proof.api,
            download=proof.download,
        )


@pytest.mark.parametrize(
    "fault",
    [
        "workflow",
        "event",
        "pending",
        "repository",
        "foreign",
        "ancestor",
        "expired",
        "window",
        "attempt",
        "job",
        "receipt",
        "source",
    ],
)
def test_invalid_index_never_enables_cutover(proof, fault):
    proof.publish()
    run, job, artifact, value = (
        proof.runs[999],
        proof.jobs[999][0],
        proof.artifacts[999],
        proof.payloads[999],
    )
    if fault == "workflow":
        run["path"] = ".github/workflows/other.yml"
    if fault == "event":
        run["event"] = "pull_request"
    if fault == "pending":
        run["status"] = "in_progress"
    if fault == "repository":
        run["repository"]["full_name"] = "foreign/repository"
    if fault == "foreign":
        run["head_repository"]["full_name"] = "foreign/repository"
    if fault == "ancestor":
        proof.proof = {"status": "diverged"}
    if fault == "expired":
        artifact["expired"] = True
    if fault == "window":
        artifact["created_at"] = "2026-10-01T00:30:00Z"
    if fault == "attempt":
        job["run_attempt"] = 2
    if fault == "job":
        job["name"] = "other"
    if fault == "receipt":
        value["repository"] = "foreign/repository"
    if fault == "source":
        value["producer"]["source"] = "b" * 40
    with pytest.raises(ValueError, match="No successful"):
        index.load(REPOSITORY, api=proof.api, download=proof.download)


def test_discovery_publishes_only_independently_valid_capabilities(proof):
    proof.add("selector-replay")
    proof.add("publisher")
    result = index.collect(
        REPOSITORY, SOURCE, root=proof.root, api=proof.api, download=proof.download
    )
    assert result["capabilities"] == ["path_selection"]
    assert len(result["evidence"]) == 2
    proof.payloads[1]["producer"]["job"] = "wrong-uploader"
    result = index.collect(
        REPOSITORY, SOURCE, root=proof.root, api=proof.api, download=proof.download
    )
    assert result["capabilities"] == []


def test_discovery_ignores_pending_unknown_and_expired_and_propagates_api_errors(proof):
    proof.add("selector-replay")
    proof.runs[1]["status"] = "in_progress"
    assert not index.collect(
        REPOSITORY, SOURCE, root=proof.root, api=proof.api, download=proof.download
    )["evidence"]
    proof.runs[1].update(status="completed", path="other")
    assert not index.collect(
        REPOSITORY, SOURCE, root=proof.root, api=proof.api, download=proof.download
    )["evidence"]
    proof.artifacts[1]["expired"] = True
    assert not index.collect(
        REPOSITORY, SOURCE, root=proof.root, api=proof.api, download=proof.download
    )["evidence"]

    def broken(*args):
        raise RuntimeError("API unavailable")

    with pytest.raises(RuntimeError, match="API unavailable"):
        index.load(REPOSITORY, api=broken)


def test_payload_rejects_extra_entries_and_keeps_zip_digest(proof, tmp_path):
    artifact = {"id": 10}

    def download(repository, artifact, path):
        with zipfile.ZipFile(path, "w") as stream:
            stream.writestr("index.json", "{}")
            stream.writestr("unexpected", "bytes")

    with pytest.raises(ValueError, match="archive"):
        index.payload(REPOSITORY, artifact, "index.json", download)
    proof.publish()
    value, checksum = index.payload(
        REPOSITORY, proof.artifacts[999], "index.json", proof.download
    )
    target = tmp_path / "transport.zip"
    proof.download(REPOSITORY, proof.artifacts[999], target)
    assert checksum == hashlib.sha256(target.read_bytes()).hexdigest()
    assert value["producer"]["job"] == index.JOB


def test_pagination_and_cached_transport(monkeypatch, tmp_path):
    def api(repository, route):
        return {"items": list(range(100)) if route.endswith("page=1") else [100]}

    assert list(index.rows(REPOSITORY, "route?key=value", "items", api)) == list(
        range(101)
    )
    calls = []

    def download(repository, artifact, target):
        calls.append(artifact["id"])
        target.write_bytes(b"verified bytes")

    monkeypatch.setattr(index.artifacts, "download_zip", download)
    index._DOWNLOADS.clear()
    first, second = tmp_path / "first", tmp_path / "second"
    index.cached_download(REPOSITORY, {"id": 1}, first)
    index.cached_download(REPOSITORY, {"id": 1}, second)
    assert calls == [1] and first.read_bytes() == second.read_bytes()
    monkeypatch.setattr(index.artifacts, "api", lambda *args: {"verified": True})
    index.cached_api.cache_clear()
    assert index.cached_api(REPOSITORY, "route") == {"verified": True}


def test_main_publisher_is_guarded_and_records_original_job(
    proof, monkeypatch, tmp_path
):
    output = tmp_path / "output/index.json"
    monkeypatch.setattr(sys, "argv", ["ci-index", "--output", str(output)])
    for name, value in {
        "GITHUB_SHA": SOURCE,
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_EVENT_NAME": "schedule",
        "GITHUB_WORKFLOW_REF": f"{REPOSITORY}/{index.WORKFLOW}@refs/heads/main",
        "GITHUB_RUN_ID": "999",
        "GITHUB_RUN_ATTEMPT": "1",
    }.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(index.artifacts, "api", lambda *args: {"sha": SOURCE})
    monkeypatch.setattr(index, "collect", lambda *args: {"capabilities": []})
    index.main()
    assert json.loads(output.read_text())["producer"] == {
        "run_id": 999,
        "attempt": 1,
        "job": index.JOB,
        "source": SOURCE,
    }
    monkeypatch.setenv("GITHUB_REF", "refs/pull/123/merge")
    with pytest.raises(ValueError, match="dedicated"):
        index.main()
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setattr(index.artifacts, "api", lambda *args: {"sha": "b" * 40})
    with pytest.raises(ValueError, match="advanced"):
        index.main()


def test_production_routing_and_shadow_errors_fail_closed(monkeypatch):
    report = ci_changes.selection_report(["docs/example.md"])
    report["candidate"] = {"error": "broken candidate"}

    def inactive(*args, **kwargs):
        raise ValueError("No qualification")

    assert ci_changes.activate_report(
        report, source=SOURCE, repository=REPOSITORY, capability=inactive
    )["selection"] == ci_changes.select_gates(["docs/example.md"])
    with pytest.raises(ValueError, match="selector failed"):
        ci_changes.activate_report(
            report,
            source=SOURCE,
            repository=REPOSITORY,
            capability=lambda *args, **kwargs: True,
        )
    report = ci_changes.selection_report(["native/runtime.cpp"])
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "push")
    result = ci_changes.activate_report(
        report,
        source=SOURCE,
        repository=REPOSITORY,
        capability=lambda *args, **kwargs: True,
    )
    assert result["arch_retired"] and result["main_coordination"]
    assert not any(result["selection"].values())
    report = ci_changes.selection_report(["native/runtime.cpp"], force=True)
    assert any(
        ci_changes.activate_report(
            report,
            source=SOURCE,
            repository=REPOSITORY,
            capability=lambda *args, **kwargs: True,
        )["selection"].values()
    )


def test_original_rejects_other_run_and_missing_attempt(proof):
    proof.publish()
    with pytest.raises(ValueError, match="another run"):
        index.original(REPOSITORY, {"expired": True}, proof.runs[999], {}, proof.api)
    with pytest.raises(ValueError, match="original producer"):
        index.original(REPOSITORY, proof.artifacts[999], proof.runs[999], {}, proof.api)


def test_successful_index_is_renewed_without_changing_qualified_retirement_baseline(proof):
    proof.add("selector-replay")
    proof.verify("path_selection")
    proof.publish()
    proof.payloads[999]["capabilities"] = ["arch_retirement"]
    result = index.collect(REPOSITORY, "b" * 40, root=proof.root, api=proof.api, download=proof.download)
    assert result["source"] == SOURCE
    proof.payloads[999]["capabilities"] = []
    assert index.collect(REPOSITORY, "b" * 40, root=proof.root, api=proof.api, download=proof.download)["source"] == "b" * 40


def test_candidate_read_errors_are_observations_until_production_authorization(monkeypatch):
    from tools import ci_selection
    def broken(*args, **kwargs):
        raise OSError("unavailable candidate-only inventory")
    monkeypatch.setattr(ci_selection, "select", broken)
    report = ci_changes.selection_report(["docs/guide.md"])
    assert report["candidate"] == {"error": "unavailable candidate-only inventory"}
    assert report["selection"] == ci_changes.select_gates(["docs/guide.md"])


def test_arch_retirement_continues_across_application_only_changes(proof):
    from tests.test_ci_rollout import retirement_evidence
    evidence = retirement_evidence(proof.root)
    evidence.verify("arch_retirement")
    (proof.root / "native").mkdir()
    (proof.root / "native/runtime.cpp").write_text("product change")
    result = rollout.authorize(evidence.index, root=proof.root, source="b" * 40, capabilities=["arch_retirement"], repository=REPOSITORY, api=evidence.api, download=evidence.download, ongoing=True)
    assert result["qualified_source"] == SOURCE
    (proof.root / "tools/ci_changes.py").write_text("changed routing contract")
    with pytest.raises(ValueError, match="Retained candidate closure"):
        rollout.authorize(evidence.index, root=proof.root, source="b" * 40, capabilities=["arch_retirement"], repository=REPOSITORY, api=evidence.api, download=evidence.download, ongoing=True)


def test_publisher_keeps_actual_retirement_proof_after_product_change(proof):
    for kind in ("arch", "archive-sdk", "fork-sdk", "recipe-change"):
        proof.add(kind)
    proof.add("nightly", 0)
    proof.add("nightly", 1)
    proof.verify("arch_retirement")
    proof.index["capabilities"] = ["arch_retirement"]
    proof.publish()
    (proof.root / "native").mkdir()
    (proof.root / "native/app.cpp").write_text("new product bytes")
    renewed = index.collect(REPOSITORY, "b" * 40, root=proof.root, api=proof.api, download=proof.download)
    assert renewed["source"] == SOURCE
    assert "arch_retirement" in renewed["capabilities"]
    (proof.root / "tools/ci_selection.py").write_text("new CI control bytes")
    changed = index.collect(REPOSITORY, "b" * 40, root=proof.root, api=proof.api, download=proof.download)
    assert changed["source"] == "b" * 40
    assert "arch_retirement" not in changed["capabilities"]
