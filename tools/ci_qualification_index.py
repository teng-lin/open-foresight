#!/usr/bin/env python3
"""Publish and consume main-only, independently reverified rollout evidence."""

import argparse
from functools import lru_cache
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_producer_trust import evidence_job_name  # noqa: E402
from tools import ci_artifacts as artifacts, ci_rollout as rollout  # noqa: E402

WORKFLOW = ".github/workflows/ci-qualification-index.yml"
NAME = "ci-qualification-index"
JOB = "publish-index"
ROOT = Path(__file__).resolve().parents[1]
TRANSPORT_FAILURES = (subprocess.SubprocessError, RuntimeError, OSError)
CONSUMER_FAILURES = (ValueError, KeyError, TypeError, ImportError, zipfile.BadZipFile, *TRANSPORT_FAILURES)


@lru_cache(maxsize=None)
def cached_api(repository, route):
    return artifacts.api(repository, route)


_DOWNLOADS: dict[tuple, bytes] = {}


def cached_download(repository, artifact, target):
    key = (repository, artifact["id"], artifact.get("digest"))
    if key not in _DOWNLOADS:
        artifacts.download_zip(repository, artifact, target)
        _DOWNLOADS[key] = target.read_bytes()
    else:
        target.write_bytes(_DOWNLOADS[key])


def rows(repository, route, key, api):
    page = 1
    while True:
        batch = api(repository, f"{route}&per_page=100&page={page}")[key]
        yield from batch
        if len(batch) < 100:
            return
        page += 1


def payload(repository, artifact, member, download):
    with tempfile.TemporaryDirectory(prefix="ci-proof-index-") as temporary:
        archive = Path(temporary) / "artifact.zip"
        download(repository, artifact, archive)
        checksum = artifacts.digest(archive)
        with zipfile.ZipFile(archive) as stream:
            if stream.namelist() != [member] or stream.getinfo(member).file_size > 16 * 1024 * 1024 or stat.S_IFMT(stream.getinfo(member).external_attr >> 16) not in (0, stat.S_IFREG):
                raise ValueError("Invalid proof-index archive")
            return json.loads(stream.read(member)), checksum


def original(repository, artifact, run, producer, api):
    if artifact.get("expired") or artifact.get("workflow_run", {}).get("id") != run["id"]:
        raise ValueError("Proof artifact expired or from another run")
    attempt = producer.get("attempt")
    if type(attempt) is not int or attempt < 1 or producer.get("run_id") != run["id"]:
        raise ValueError("Proof lacks original producer attempt")
    jobs = list(rows(repository, f"actions/runs/{run['id']}/attempts/{attempt}/jobs?", "jobs", api))
    matches = [job for job in jobs if evidence_job_name(job) == evidence_job_name({"name": producer.get("job")}) and job.get("conclusion") == "success" and job.get("run_attempt") == attempt and artifacts.in_producer_attempt(artifact, job)]
    if len(matches) != 1:
        raise ValueError("Proof has no successful original uploading job")
    return matches[0]


def main_source(repository, run, api):
    if (run.get("head_branch"), (run.get("head_repository") or {}).get("full_name"), run.get("status"), run.get("conclusion")) != ("main", repository, "completed", "success"):
        raise ValueError("Proof producer is not successful reviewed main")
    if run.get("repository", {}).get("full_name") != repository:
        raise ValueError("Proof producer repository mismatch")
    source = run.get("head_sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source) or api(repository, f"compare/{source}...main").get("status") not in ("ahead", "identical"):
        raise ValueError("Proof producer is not reachable from main")
    return source


def collect(repository, source, *, root=ROOT, api=cached_api, download=cached_download):
    """Discover original evidence, then independently qualify each capability.

    Bad/stale individual descriptors are observations, never activation. API and
    transport failures propagate, preserving actionable infrastructure failures.
    """
    index = {"schema": 1, "repository": repository, "source": source, "closure": rollout.closure(root), "control_closure": rollout.control_closure(root), "capabilities": [], "evidence": [], "qualification_sets": {}}
    previous_capabilities = set()
    try:
        previous = load(repository, api=api, download=download)
        rollout.compare(previous["control_closure"], index["control_closure"])
    except (ValueError, KeyError, TypeError):
        pass
    else:
        previous_capabilities = set(previous.get("capabilities", []))
        if "arch_retirement" in previous_capabilities:
            index.update(source=previous["source"], closure=previous["closure"])
    for artifact in rows(repository, "actions/artifacts?name=ci-rollout-qualification", "artifacts", api):
        if artifact.get("name") != "ci-rollout-qualification" or artifact.get("expired"):
            continue
        run = api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
        if run.get("status") != "completed" or run.get("conclusion") != "success":
            continue
        value, checksum = payload(repository, artifact, "qualification.json", download)
        kind = next((kind for kind, (workflow, _) in rollout.KINDS.items() if workflow == run.get("path") and (workflow != ".github/workflows/ci-qualification.yml" or kind == value.get("exercise", {}).get("kind") or (kind == "selector-replay" and "selector_replay" in value) or (kind == "acceptance-replay" and "acceptance_replay" in value))), None)
        if kind is None:
            continue
        try:
            main_source(repository, run, api)
            job = original(repository, artifact, run, value.get("producer", {}), api)
            entry = {"kind": kind, "run_id": run["id"], "artifact_id": artifact["id"], "attempt": value["producer"]["attempt"], "producer_job_id": job["id"], "sha256": checksum, "closure_sha256": value["closure"]["sha256"]}
            rollout._qualified(entry, repository=repository, expected=index["control_closure"], api=api, download=download, controls=True)
        except (ValueError, KeyError, TypeError):
            continue
        index["evidence"].append(entry)
    retained_nights = [entry for entry in index["evidence"] if entry["kind"] == "nightly"]
    history = list(rows(repository, "actions/workflows/preview-packages.yml/runs?event=schedule&branch=main", "workflow_runs", api))
    eligible_nights = {entry["run_id"] for entry in retained_nights}
    barriers = [row["created_at"] for row in history if row.get("status") != "completed" or row.get("conclusion") != "success" or row["id"] not in eligible_nights]
    if barriers:
        boundary = max(barriers)
        allowed = {row["id"] for row in history if row["created_at"] > boundary}
        index["evidence"] = [entry for entry in index["evidence"] if entry["kind"] != "nightly" or entry["run_id"] in allowed]
    for capability in sorted(rollout.CAPABILITIES):
        trial = dict(index, capabilities=[capability])
        if capability in previous_capabilities and capability in {"arch_retirement", "acceptance_narrowing"}:
            prior_set = set(previous.get("qualification_sets", {}).get(capability, [entry["artifact_id"] for entry in previous["evidence"]]))
            prior_ids = {(entry["run_id"], entry["artifact_id"]) for entry in previous["evidence"] if entry["kind"] == "nightly" and entry["artifact_id"] in prior_set}
            trial["evidence"] = [entry for entry in index["evidence"] if entry["kind"] != "nightly"] + [entry for entry in retained_nights if (entry["run_id"], entry["artifact_id"]) in prior_ids]
        try:
            rollout.authorize(trial, root=root, source=index["source"], capabilities=[capability], repository=repository, api=api, download=download, ongoing=capability in previous_capabilities)
        except (ValueError, KeyError, TypeError):
            continue
        index["capabilities"].append(capability)
        index["qualification_sets"][capability] = sorted(entry["artifact_id"] for entry in trial["evidence"])
        if capability in previous_capabilities and capability in {"arch_retirement", "acceptance_narrowing"}:
            existing = {(entry["run_id"], entry["artifact_id"]) for entry in index["evidence"]}
            index["evidence"].extend(entry for entry in trial["evidence"] if (entry["run_id"], entry["artifact_id"]) not in existing)
    return index


def load(repository, *, api=artifacts.api, download=artifacts.download_zip):
    """Select newest valid published index; never trust a name or latest attempt."""
    candidates = sorted(rows(repository, f"actions/artifacts?name={NAME}", "artifacts", api), key=lambda artifact: artifact["id"], reverse=True)
    for artifact in candidates:
        if artifact.get("name") != NAME or artifact.get("expired"):
            continue
        run = api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
        if run.get("path") != WORKFLOW or run.get("event") not in ("schedule", "workflow_dispatch", "workflow_run") or run.get("status") != "completed" or run.get("conclusion") != "success":
            continue
        try:
            source = main_source(repository, run, api)
            value, _ = payload(repository, artifact, "index.json", download)
            original(repository, artifact, run, value.get("producer", {}), api)
            if value.get("repository") != repository or value.get("producer", {}).get("source") != source or value.get("producer", {}).get("job") != JOB:
                raise ValueError("Index receipt differs from its authenticated producer")
            return value
        except (ValueError, KeyError, TypeError):
            continue
    raise ValueError("No successful reviewed-main qualification index is available")


def capability(name, source, *, root=ROOT, repository=None, api=cached_api, download=cached_download):
    repository = repository or os.environ["GITHUB_REPOSITORY"]
    index = load(repository, api=api, download=download)
    return rollout.authorize(index, root=root, source=source, capabilities=[name], repository=repository, api=api, download=download, ongoing=True)


def resolve(source, *, root=ROOT, repository=None, api=cached_api, download=cached_download):
    """Read a single index for all routing decisions in this changes job.

    Transport failures expand production checks. The publisher uses collect()
    directly and keeps its API/transport failures visible.
    """
    def inactive(error):
        reason = f"{type(error).__name__}: {error}"
        return {name: {"active": False, "reason": reason} for name in sorted(rollout.CAPABILITIES)}
    repository = repository or os.environ.get("GITHUB_REPOSITORY")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository or ""):
        return inactive(ValueError("Explicit repository required for qualification discovery"))
    try:
        index = load(repository, api=api, download=download)
    except CONSUMER_FAILURES as error:
        return inactive(error)
    result = {}
    for name in sorted(rollout.CAPABILITIES):
        try:
            rollout.authorize(index, root=root, source=source, capabilities=[name], repository=repository, api=api, download=download, ongoing=True)
        except TRANSPORT_FAILURES as error:
            return inactive(error)
        except (ValueError, KeyError, TypeError, ImportError, zipfile.BadZipFile) as error:
            result[name] = {"active": False, "reason": f"{type(error).__name__}: {error}"}
        else:
            result[name] = {"active": True}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = os.environ["GITHUB_SHA"]
    repository = os.environ["GITHUB_REPOSITORY"]
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get("GITHUB_EVENT_NAME") not in ("schedule", "workflow_dispatch", "workflow_run") or os.environ.get("GITHUB_WORKFLOW_REF") != f"{repository}/{WORKFLOW}@refs/heads/main":
        raise ValueError("Only the dedicated main publisher can publish an index")
    if artifacts.api(repository, "commits/main")["sha"] != source:
        raise ValueError("Main advanced; reconcile the current source instead")
    value = collect(repository, source)
    value["producer"] = {"run_id": int(os.environ["GITHUB_RUN_ID"]), "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]), "job": JOB, "source": source}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
