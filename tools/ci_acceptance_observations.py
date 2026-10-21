#!/usr/bin/env python3
"""Reuse authenticated history observations, never cached acceptance results.

Every refresh still enumerates the entire live run window to detect old reruns.
Only an unchanged run's already observed metadata/jobs may avoid another read.
"""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import stat
import tempfile
import zipfile

from tools import ci_artifacts as artifacts, ci_qualification_index as index, ci_rollout as rollout

ROOT = Path(__file__).resolve().parents[1]
NAME = "ci-acceptance-history"
MEMBER = "acceptance-failures.json"
MAX_BYTES = 64 * 1024 * 1024


def payload(repository, artifact, member, download):
    with tempfile.TemporaryDirectory(prefix="ci-history-observation-") as temporary:
        path = Path(temporary) / "observation.zip"
        download(repository, artifact, path)
        if artifact.get("digest") != "sha256:" + artifacts.digest(path):
            raise ValueError("Historical observation artifact checksum mismatch")
        with zipfile.ZipFile(path) as archive:
            info = archive.infolist()
            if (len(info) != 1 or info[0].filename != member or info[0].file_size > MAX_BYTES
                    or stat.S_IFMT(info[0].external_attr >> 16) not in (0, stat.S_IFREG)):
                raise ValueError("Invalid historical observation archive membership")
            raw = archive.read(member)
        return json.loads(raw), hashlib.sha256(raw).hexdigest(), artifacts.digest(path)


def load(repository, baseline_sha256, baseline, until, *, root=ROOT, api=None, download=None):
    """Return only a successful main producer's same-control, checked inventory."""
    api = api or artifacts.api
    download = download or artifacts.download_zip
    boundary = datetime.fromisoformat(until.replace("Z", "+00:00")) if until else datetime.now(timezone.utc)
    if boundary.tzinfo is None:
        raise ValueError("Observation cutoff needs an explicit timezone")
    controls = rollout.control_closure(root)
    candidates = sorted(index.rows(repository, "actions/artifacts?name=ci-rollout-qualification", "artifacts", api), key=lambda row: row["id"], reverse=True)
    for artifact in candidates:
        if artifact.get("name") != "ci-rollout-qualification" or artifact.get("expired") is not False:
            continue
        run = api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
        if (run.get("path") != ".github/workflows/ci-qualification.yml"
                or run.get("event") not in ("workflow_dispatch", "schedule")
                or run.get("status") != "completed" or run.get("conclusion") != "success"
                or run.get("head_branch") != "main"
                or run.get("repository", {}).get("full_name") != repository
                or (run.get("head_repository") or {}).get("full_name") != repository):
            continue
        descriptor, _, checksum = payload(repository, artifact, "qualification.json", download)
        summary = descriptor.get("acceptance_replay", {})
        if summary.get("baseline_sha256") != baseline_sha256 or descriptor.get("control_closure") != controls:
            continue
        ending = datetime.fromisoformat(summary["coverage"]["until"].replace("Z", "+00:00"))
        if ending.tzinfo is None or ending > boundary:
            continue
        producer = descriptor.get("producer", {})
        job = index.original(repository, artifact, run, producer, api)
        entry = {"kind": "acceptance-replay", "run_id": run["id"], "artifact_id": artifact["id"],
                 "attempt": producer["attempt"], "producer_job_id": job["id"], "sha256": checksum}
        rollout._qualified(entry, repository=repository, expected=controls, api=api, download=download, controls=True)
        histories = sorted(index.rows(repository, f"actions/runs/{run['id']}/artifacts?", "artifacts", api), key=lambda row: row["id"], reverse=True)
        for history in histories:
            if (history.get("name") != NAME or history.get("expired") is not False
                    or history.get("workflow_run", {}).get("id") != run["id"]
                    or not artifacts.in_producer_attempt(history, job)):
                continue
            value, digest, _ = payload(repository, history, MEMBER, download)
            if (digest != summary.get("inventory_sha256") or value.get("baseline_sha256") != baseline_sha256
                    or value.get("repository") != repository or value.get("schema") != 1
                    or value.get("complete") is not True or value.get("since") != baseline["since"]
                    or value.get("until") != summary["coverage"]["until"]
                    or value.get("baseline_count") != len(baseline["failures"])):
                raise ValueError("History observation differs from its authenticated qualification receipt")
            return value
    return None
