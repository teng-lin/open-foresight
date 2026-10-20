"""Cutover needs actual original-attempt evidence; elapsed time alone proves nothing."""

import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import sys
import zipfile

import pytest

from tools import ci_rollout as rollout

SOURCE = "a" * 40
REPOSITORY = "teng-lin/open-foresight"


@pytest.fixture
def root(tmp_path):
    for name in ("tools/ci_changes.py", "tools/ci_selection.py", ".github/workflows/macos.yml"):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("retained input\n")
    return tmp_path


class Evidence:
    def __init__(self, root):
        self.root = root
        self.runs = {}
        self.jobs = {}
        self.artifacts = {}
        self.payloads = {}
        self.history = []
        self.proof = {"status": "identical"}
        self.index = {"schema": 1, "repository": REPOSITORY, "source": SOURCE, "closure": rollout.closure(root), "capabilities": sorted(rollout.CAPABILITIES), "evidence": []}

    def add(self, kind, day=0):
        run_id = len(self.runs) + 1
        created = (datetime(2026, 10, 1, tzinfo=timezone.utc) + timedelta(days=day)).isoformat().replace("+00:00", "Z")
        workflow, gate = rollout.KINDS[kind]
        run = {"id": run_id, "head_sha": SOURCE, "path": workflow, "head_branch": "main", "head_repository": {"full_name": REPOSITORY}, "status": "completed", "conclusion": "success", "event": "schedule", "created_at": created}
        self.runs[run_id] = run
        names = [gate]
        if kind == "nightly":
            names += ["linux-build", "linux-test", "macos", "acceptance-cpu", "acceptance-audio", "acceptance-deb", "platform-checks", "acceptance-checks", "dmg", "publish", "linux (deb)", "linux (rpm)", "linux (arch)"]
            self.history.append(run)
        self.jobs[run_id] = [{"id": run_id * 100 + i, "name": name, "conclusion": "success", "run_attempt": 1, "started_at": "2026-10-01T00:00:00Z", "completed_at": "2026-10-01T00:10:00Z"} for i, name in enumerate(names)]
        self.artifacts[run_id] = {"id": run_id, "name": "ci-rollout-qualification", "expired": False, "workflow_run": {"id": run_id}, "created_at": "2026-10-01T00:05:00Z"}
        self.payloads[run_id] = rollout.descriptor(SOURCE, root=self.root, run_id=run_id, attempt=1, producer_job=gate)
        entry = {"kind": kind, "run_id": run_id, "attempt": 1, "artifact_id": run_id, "producer_job_id": run_id * 100}
        self.index["evidence"].append(entry)
        return entry

    def api(self, repository, route):
        assert repository == REPOSITORY
        if route.startswith("compare/"):
            return self.proof
        if route.startswith("actions/artifacts/"):
            return self.artifacts[int(route.split("/")[2])]
        if route.startswith("actions/workflows/"):
            return {"workflow_runs": self.history}
        run_id = int(route.split("/")[2])
        if "/jobs?" in route:
            return {"jobs": self.jobs[run_id]}
        return self.runs[run_id]

    def download(self, repository, artifact, path):
        assert repository == REPOSITORY
        with zipfile.ZipFile(path, "w") as stream:
            stream.writestr("qualification.json", json.dumps(self.payloads[artifact["id"]]))

    def verify(self, *capabilities):
        # Compute actual ZIP checksums, so mutation tests keep the transport
        # valid and independently exercise provenance/receipt assertions.
        for entry in self.index["evidence"]:
            path = self.root / "transport.zip"
            self.download(REPOSITORY, self.artifacts[entry["artifact_id"]], path)
            entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            path.unlink()
        return rollout.authorize(self.index, root=self.root, source=SOURCE, capabilities=capabilities, api=self.api, download=self.download)


def test_default_committed_index_never_authorizes_any_cutover(root):
    index = json.loads((Path(__file__).parents[1] / "docs/platforms/ci-rollout-index.json").read_text())
    for capability in rollout.CAPABILITIES:
        with pytest.raises(ValueError, match="inactive"):
            rollout.authorize(index, root=root, source=SOURCE, capabilities=[capability])


def test_closure_works_without_git_and_binds_modes_inputs_and_new_files(root):
    original = rollout.closure(root)
    legacy = root / "tools/run_ci_stage.py"
    legacy.write_text("retired input")
    (root / "tools/__pycache__").mkdir()
    (root / "tools/__pycache__/generated").write_text("generated")
    assert rollout.compare(original, rollout.closure(root)) == original["sha256"]
    (root / "requirements-dev.lock").write_text("new input")
    with pytest.raises(ValueError, match="requirements-dev.lock"):
        rollout.compare(original, rollout.closure(root))
    original = rollout.closure(root)
    (root / "tools/ci_selection.py").chmod(0o755)
    with pytest.raises(ValueError, match="ci_selection.py"):
        rollout.compare(original, rollout.closure(root))


def test_incomplete_export_and_linked_retained_source_are_rejected(tmp_path, root):
    with pytest.raises(ValueError, match="Incomplete"):
        rollout.closure(tmp_path / "missing")
    (root / "tools/linked").symlink_to("ci_selection.py")
    with pytest.raises(ValueError, match="symlink"):
        rollout.closure(root)


def test_path_selection_and_main_receipts_have_separate_qualification_from_phase_skips(root):
    evidence = Evidence(root)
    evidence.add("selector-replay")
    assert evidence.verify("path_selection")["capabilities"] == ["path_selection"]
    with pytest.raises(ValueError, match="observer, publisher"):
        evidence.verify("main_receipts")
    evidence.add("observer")
    evidence.add("publisher")
    assert evidence.verify("main_receipts")["source"] == SOURCE
    with pytest.raises(ValueError, match="actual hosted"):
        evidence.verify("acceptance_narrowing")


@pytest.mark.parametrize("fault", ["foreign", "workflow", "ref", "event", "source", "reachability", "attempt", "gate", "window", "artifact", "expired", "marker", "producer", "closure", "id", "kind"])
def test_invalid_original_producer_never_authorizes_a_cutover(root, fault):
    evidence = Evidence(root)
    entry = evidence.add("selector-replay")
    run, job, artifact, receipt = evidence.runs[1], evidence.jobs[1][0], evidence.artifacts[1], evidence.payloads[1]
    if fault == "foreign":
        run["head_repository"]["full_name"] = "attacker/fork"
    elif fault == "workflow":
        run["path"] = ".github/workflows/other.yml"
    elif fault == "ref":
        run["head_branch"] = "feature"
    elif fault == "event":
        run["event"] = "pull_request"
    elif fault == "source":
        run["head_sha"] = "invalid"
    elif fault == "reachability":
        evidence.proof["status"] = "diverged"
    elif fault == "attempt":
        entry["attempt"] = 0
    elif fault == "gate":
        job["conclusion"] = "failure"
    elif fault == "window":
        artifact["created_at"] = "2026-10-01T01:05:00Z"
    elif fault == "artifact":
        artifact["workflow_run"]["id"] = 99
    elif fault == "expired":
        artifact["expired"] = True
    elif fault == "marker":
        receipt.pop("superseded")
    elif fault == "producer":
        receipt["producer"]["job"] = "other"
    elif fault == "closure":
        receipt["closure"]["sha256"] = "b" * 64
    elif fault == "id":
        entry["producer_job_id"] = 0
    else:
        entry["kind"] = "synthetic"
    with pytest.raises(ValueError):
        evidence.verify("path_selection")


def retirement_evidence(root, nights=2):
    evidence = Evidence(root)
    for kind in ("arch", "archive-sdk", "fork-sdk", "recipe-change"):
        evidence.add(kind)
    for day in range(nights):
        evidence.add("nightly", day)
    return evidence


def test_retirement_requires_real_consecutive_nightlies_and_recipe_exercises(root):
    evidence = retirement_evidence(root, 1)
    with pytest.raises(ValueError, match="two distinct"):
        evidence.verify("arch_retirement")
    evidence.add("nightly", 1)
    assert evidence.verify("arch_retirement")["capabilities"] == ["arch_retirement"]
    red = copy.deepcopy(evidence.history[0])
    red.update(id=999, conclusion="failure")
    evidence.history.append(red)
    with pytest.raises(ValueError, match="consecutive"):
        evidence.verify("arch_retirement")


def test_four_week_requirement_applies_only_to_phase_narrowing(root):
    evidence = retirement_evidence(root)
    with pytest.raises(ValueError, match="acceptance-replay"):
        evidence.verify("acceptance_narrowing")
    evidence.add("acceptance-replay")
    with pytest.raises(ValueError, match="four green weeks"):
        evidence.verify("acceptance_narrowing")
    for day in range(2, 29):
        evidence.add("nightly", day)
    assert evidence.verify("acceptance_narrowing")["capabilities"] == ["acceptance_narrowing"]


def test_incomplete_history_skipped_replacement_jobs_and_dispatch_nightlies_fail(root):
    evidence = retirement_evidence(root)
    evidence.history.pop()
    with pytest.raises(ValueError, match="history is incomplete"):
        evidence.verify("arch_retirement")
    evidence = retirement_evidence(root)
    evidence.jobs[5] = evidence.jobs[5][:1]
    with pytest.raises(ValueError, match="replacement suite"):
        evidence.verify("arch_retirement")
    evidence = retirement_evidence(root)
    evidence.runs[5]["event"] = "workflow_dispatch"
    with pytest.raises(ValueError, match="actual scheduled"):
        evidence.verify("arch_retirement")


def test_source_capabilities_and_descriptor_cli_are_explicit(root, monkeypatch):
    for capabilities in ([], ["force"]):
        with pytest.raises(ValueError, match="capability"):
            rollout.authorize({}, root=root, source=SOURCE, capabilities=capabilities)
    with pytest.raises(ValueError, match="immutable"):
        rollout.authorize({}, root=root, source="main", capabilities=["path_selection"])
    evidence = Evidence(root)
    evidence.index["source"] = "b" * 40
    with pytest.raises(ValueError, match="source does not match"):
        evidence.verify("path_selection")
    with pytest.raises(ValueError, match="immutable commit"):
        rollout.descriptor("main", root=root, run_id=1, attempt=1, producer_job="changes")
    with pytest.raises(ValueError, match="original producer"):
        rollout.descriptor(SOURCE, root=root, run_id=0, attempt=1, producer_job="changes")
    output = root / "out/qualification.json"
    monkeypatch.setattr(sys, "argv", ["rollout", "--root", str(root), "--source", SOURCE, "--run-id", "1", "--attempt", "2", "--producer-job", "changes", "--output", str(output)])
    rollout.main()
    assert json.loads(output.read_text())["producer"] == {"run_id": 1, "attempt": 2, "job": "changes"}


def test_transport_checksum_and_archive_membership_are_verified(root):
    evidence = Evidence(root)
    evidence.add("selector-replay")
    evidence.verify("path_selection")
    def corrupt(repository, artifact, path):
        path.write_bytes(b"corrupt ZIP")
    with pytest.raises(ValueError, match="checksum"):
        rollout.authorize(evidence.index, root=root, source=SOURCE, capabilities=["path_selection"], api=evidence.api, download=corrupt)
    def unexpected(repository, artifact, path):
        with zipfile.ZipFile(path, "w") as stream:
            stream.writestr("unexpected", "untrusted")
    evidence.download = unexpected
    with pytest.raises(ValueError, match="archive"):
        evidence.verify("path_selection")


def test_positive_ids_do_not_substitute_for_original_uploading_job(root):
    evidence = Evidence(root)
    entry = evidence.add("selector-replay")
    entry["producer_job_id"] = 999
    with pytest.raises(ValueError, match="upload window"):
        evidence.verify("path_selection")


def test_duplicate_evidence_cannot_multiply_green_observations(root):
    evidence = retirement_evidence(root)
    evidence.index["evidence"].append(copy.deepcopy(evidence.index["evidence"][-1]))
    with pytest.raises(ValueError, match="Duplicate qualification"):
        evidence.verify("arch_retirement")
