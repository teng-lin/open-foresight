"""History observations need original main provenance before saving API reads."""

import hashlib
import io
import json
import subprocess
import zipfile

import pytest

from tools import ci_acceptance_observations as observations, ci_rollout as rollout

REPOSITORY = "teng-lin/open-foresight"
SOURCE = "a" * 40
UNTIL = "2026-10-21T00:19:00Z"


def archive(member, value):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as stream:
        stream.writestr(zipfile.ZipInfo(member), json.dumps(value, sort_keys=True).encode(), compress_type=zipfile.ZIP_DEFLATED)
    return output.getvalue()


@pytest.fixture
def proof(tmp_path):
    for name in ("tools/ci_changes.py", "tools/ci_selection.py", ".github/workflows/macos.yml"):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("reviewed control\n")
    frozen = observations.ROOT / "tests/fixtures/ci-acceptance-failures-20261020.json"
    baseline = json.loads(frozen.read_bytes())
    baseline_sha256 = hashlib.sha256(frozen.read_bytes()).hexdigest()
    inventory = dict(baseline, baseline_sha256=baseline_sha256, baseline_count=len(baseline["failures"]), until=UNTIL)
    inventory_raw = json.dumps(inventory, sort_keys=True).encode()
    run = {"id": 11, "head_sha": SOURCE, "head_branch": "main", "event": "workflow_dispatch", "path": ".github/workflows/ci-qualification.yml", "repository": {"full_name": REPOSITORY}, "head_repository": {"full_name": REPOSITORY}, "status": "completed", "conclusion": "success", "created_at": "2026-10-21T00:10:00Z"}
    job = {"id": 110, "run_id": 11, "name": "qualification-acceptance-replay", "run_attempt": 1, "conclusion": "success", "started_at": "2026-10-21T00:10:00Z", "completed_at": "2026-10-21T00:20:00Z"}
    descriptor = rollout.descriptor(SOURCE, root=tmp_path, run_id=11, attempt=1, producer_job=job["name"])
    descriptor["acceptance_replay"] = {"schema": 2, "baseline_sha256": baseline_sha256, "baseline_count": len(baseline["failures"]), "inventory_sha256": hashlib.sha256(inventory_raw).hexdigest(), "count": len(baseline["failures"]), "miss_count": 0, "unresolved_count": 0, "coverage": {"since": baseline["since"], "until": UNTIL, "complete": True}, "sha256": "c" * 64, "known_escapes": [102, 110, 112, 119, 137, 144]}
    payloads = {1: archive("qualification.json", descriptor), 2: archive(observations.MEMBER, inventory)}
    artifacts = {identity: {"id": identity, "name": "ci-rollout-qualification" if identity == 1 else observations.NAME, "digest": "sha256:" + hashlib.sha256(raw).hexdigest(), "expired": False, "workflow_run": {"id": 11}, "created_at": "2026-10-21T00:18:00Z"} for identity, raw in payloads.items()}
    calls = []
    def api(repository, route):
        assert repository == REPOSITORY
        calls.append(route)
        if route.startswith("actions/artifacts?name="):
            return {"artifacts": [artifacts[1]]}
        if route == "actions/runs/11":
            return run
        if route.startswith("actions/runs/11/attempts/1/jobs?"):
            return {"jobs": [job]}
        if route.startswith("actions/runs/11/artifacts?"):
            return {"artifacts": [artifacts[2]]}
        if route.startswith("actions/artifacts/"):
            return artifacts[int(route.split("/")[2])]
        if route.startswith("compare/") and route.endswith("...main"):
            return {"status": "identical"}
        raise AssertionError(route)
    def download(repository, artifact, path):
        assert repository == REPOSITORY
        path.write_bytes(payloads[artifact["id"]])
    def load(until="2026-10-21T00:21:00Z"):
        return observations.load(REPOSITORY, baseline_sha256, baseline, until, root=tmp_path, api=api, download=download)
    return {"load": load, "api": api, "download": download, "baseline": baseline, "baseline_sha256": baseline_sha256, "inventory": inventory, "descriptor": descriptor, "run": run, "job": job, "artifacts": artifacts, "payloads": payloads, "calls": calls, "root": tmp_path}


def test_current_control_original_main_qualification_authenticates_inventory(proof):
    assert proof["load"]() == proof["inventory"]
    assert "actions/runs/11/attempts/1/jobs?per_page=100&page=1" in proof["calls"]
    assert f"compare/{SOURCE}...main" in proof["calls"]


@pytest.mark.parametrize("fault", ["fork", "workflow", "failed", "expired", "controls", "future", "history-expired", "window"])
def test_unqualified_or_obsolete_observations_never_save_job_discovery(proof, fault):
    if fault == "fork":
        proof["run"]["head_repository"] = {"full_name": "fork/repo"}
    elif fault == "workflow":
        proof["run"]["path"] = ".github/workflows/other.yml"
    elif fault == "failed":
        proof["run"]["conclusion"] = "failure"
    elif fault == "expired":
        proof["artifacts"][1]["expired"] = True
    elif fault == "controls":
        (proof["root"] / "tools/ci_changes.py").write_text("new control\n")
    elif fault == "future":
        assert proof["load"]("2026-10-21T00:18:00Z") is None
        return
    elif fault == "history-expired":
        proof["artifacts"][2]["expired"] = True
    else:
        proof["artifacts"][2]["created_at"] = "2026-10-21T00:21:00Z"
    assert proof["load"]() is None


@pytest.mark.parametrize("fault", ["checksum", "member", "inventory", "attempt", "job", "producer-source"])
def test_corrupt_bytes_or_wrong_original_producer_fail_qualification(proof, fault):
    if fault == "checksum":
        proof["payloads"][2] += b"changed"
    elif fault == "member":
        proof["payloads"][2] = archive("wrong.json", proof["inventory"])
        proof["artifacts"][2]["digest"] = "sha256:" + hashlib.sha256(proof["payloads"][2]).hexdigest()
    elif fault == "inventory":
        changed = dict(proof["inventory"], until="2026-10-21T00:18:01Z")
        proof["payloads"][2] = archive(observations.MEMBER, changed)
        proof["artifacts"][2]["digest"] = "sha256:" + hashlib.sha256(proof["payloads"][2]).hexdigest()
    elif fault == "attempt":
        proof["job"]["run_attempt"] = 2
    elif fault == "job":
        proof["job"]["conclusion"] = "failure"
    else:
        proof["run"]["head_sha"] = "b" * 40
    with pytest.raises(ValueError):
        proof["load"]()


def test_no_published_observation_bootstraps_from_reviewed_frozen_inventory(proof):
    assert observations.load(REPOSITORY, proof["baseline_sha256"], proof["baseline"], UNTIL, root=proof["root"], api=lambda *args: {"artifacts": []}) is None


def test_transport_errors_remain_visible_in_qualification(proof):
    def unavailable(*args):
        raise subprocess.CalledProcessError(1, ["gh", "api"], stderr="HTTP 403")
    with pytest.raises(subprocess.CalledProcessError):
        observations.load(REPOSITORY, proof["baseline_sha256"], proof["baseline"], UNTIL, root=proof["root"], api=unavailable)


def test_cutoff_requires_timezone(proof):
    with pytest.raises(ValueError, match="timezone"):
        proof["load"]("2026-10-21T00:18:00")
