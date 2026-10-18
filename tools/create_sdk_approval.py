#!/usr/bin/env python3
"""Create a reviewable exact SDK migration entry; never build or publish bytes."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import sdk_approval_bridge as bridge  # noqa: E402


def git_source(root, commit):
    if not bridge.SHA.fullmatch(commit):
        raise ValueError("Source must be an exact commit SHA")
    listing = subprocess.check_output(
        ["git", "ls-tree", "-r", "-z", commit], cwd=root, timeout=30
    )
    result = {}
    for item in listing.split(b"\0"):
        if not item:
            continue
        metadata, raw_path = item.split(b"\t", 1)
        mode, kind, _ = metadata.decode().split()
        path = raw_path.decode()
        if kind != "blob" or mode not in ("100644", "100755"):
            continue
        result[path] = (mode, None)
    return result


def build_entry(
    root, repository, component, producer, approved, approved_pr, sidecar_id
):
    trees = {commit: git_source(root, commit) for commit in (producer, approved)}

    def read(commit, path):
        if path not in trees[commit]:
            raise ValueError("Missing regular legacy source: " + path)
        return subprocess.check_output(
            ["git", "show", f"{commit}:{path}"], cwd=root, timeout=30
        )

    legacy_identity, proof = bridge.legacy_proof(
        component, lambda path: read(producer, path)
    )
    approved_identity, approved_proof = bridge.legacy_proof(
        component, lambda path: read(approved, path)
    )
    if legacy_identity != approved_identity or proof != approved_proof:
        raise ValueError("Original and approved SDK inputs differ")
    for path in proof:
        if trees[producer][path][0] != trees[approved][path][0]:
            raise ValueError("Original and approved input modes differ")
    if component in ("linux-sdk", "macos-runtime"):
        for commit in (producer, approved):
            for path in trees[commit]:
                if path.startswith("services/speech/"):
                    read(commit, path)
        original_paths = {
            p for p in trees[producer] if p.startswith("services/speech/")
        }
        final_paths = {p for p in trees[approved] if p.startswith("services/speech/")}
        if original_paths != final_paths or any(
            read(producer, p) != read(approved, p) for p in original_paths
        ):
            raise ValueError("Original and approved source directories differ")
    sidecar = artifacts.api(repository, f"actions/artifacts/{sidecar_id}")
    if sidecar.get("expired") or sidecar.get("name") != artifacts.receipt_name(
        component, legacy_identity
    ):
        raise ValueError("Sidecar does not match the proven legacy recipe")
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / "receipt.zip"
        artifacts.download_zip(repository, sidecar, archive)
        with zipfile.ZipFile(archive) as stream:
            if (
                stream.namelist() != ["receipt.json"]
                or stream.getinfo("receipt.json").file_size > 16384
            ):
                raise ValueError("Invalid original receipt archive")
            reference = json.loads(stream.read("receipt.json"))
    if (
        reference.get("component") != component
        or reference.get("identity") != legacy_identity
        or not artifacts.valid_receipt(
            reference.get("source_receipt"), component, legacy_identity
        )
    ):
        raise ValueError("Invalid original SDK receipt")
    payload = artifacts.api(repository, f"actions/artifacts/{reference['artifact_id']}")
    run = artifacts.api(repository, f"actions/runs/{sidecar['workflow_run']['id']}")
    if (
        payload.get("expired")
        or payload.get("digest") != reference["artifact_digest"]
        or payload.get("name") != artifacts.name(component, legacy_identity)
        or payload.get("workflow_run", {}).get("id") != run.get("id")
        or run.get("head_sha") != producer
        or run.get("path") != ".github/workflows/ci-dependencies.yml"
        or run.get("head_repository", {}).get("full_name") != repository
    ):
        raise ValueError("Original producer provenance does not match")
    receipt = reference["source_receipt"]
    jobs = artifacts.dependency_jobs(repository, run["id"])
    if not any(
        job["name"] == artifacts.JOBS[component]
        and job.get("conclusion") == "success"
        and job.get("run_attempt", 1) == receipt["source_run_attempt"]
        and artifacts.in_producer_attempt(payload, job)
        and artifacts.in_producer_attempt(sidecar, job)
        for job in jobs
    ):
        raise ValueError("Original uploads lack a successful exact producer attempt")
    return {
        "repository": repository,
        "component": component,
        "semantic_identity": artifacts.fingerprint(component, root),
        "legacy_identity": legacy_identity,
        "legacy_inputs": proof,
        "approved_pr": approved_pr,
        "approved_source": approved,
        "producer_source": producer,
        "producer_pr": next(
            (pr["number"] for pr in run.get("pull_requests", [])), approved_pr
        ),
        "producer_event": run["event"],
        "producer_branch": run["head_branch"],
        "producer_run": run["id"],
        "artifact_id": payload["id"],
        "artifact_digest": payload["digest"],
        "sidecar_id": sidecar_id,
        "sidecar_digest": sidecar["digest"],
        "source_receipt": receipt,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=artifacts.FILES, required=True)
    parser.add_argument("--producer-source", required=True)
    parser.add_argument("--approved-source", required=True)
    parser.add_argument("--approved-pr", type=int, required=True)
    parser.add_argument("--sidecar-id", type=int, required=True)
    parser.add_argument("--repository", default="teng-lin/open-foresight")
    parser.add_argument("--output", type=Path, default=bridge.MANIFEST)
    args = parser.parse_args()
    entry = build_entry(
        artifacts.ROOT,
        args.repository,
        args.component,
        args.producer_source,
        args.approved_source,
        args.approved_pr,
        args.sidecar_id,
    )
    manifest: dict[str, Any] = (
        json.loads(args.output.read_text())
        if args.output.exists()
        else {"schema": 1, "entries": []}
    )
    manifest["entries"] = [
        e for e in manifest["entries"] if e["component"] != args.component
    ]
    manifest["entries"].append(entry)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
