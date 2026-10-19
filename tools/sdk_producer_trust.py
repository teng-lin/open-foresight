"""Verify SDK producer inputs without importing or executing producer code.

The caller supplies this checkout's reviewed fingerprint implementation. GitHub
objects provide data only; historical Python/workflows are never executed.
Legacy identity migrations require a separately reviewed, exact-artifact proof.
"""

import base64
from datetime import datetime
import hashlib
from pathlib import Path, PurePosixPath
import re
import tempfile

from tools.ci_producer_trust import PRODUCERS

COMMIT = re.compile(r"[a-f0-9]{40}")
WORKFLOW = PRODUCERS["dependency-sdk"].workflows[0]
JOBS = {
    component: jobs[0] for component, jobs in PRODUCERS["dependency-sdk"].jobs.items()
}
PRODUCER_CONTROLS = (
    "tools/ci_artifacts.py",
    "tools/linux_sdk_artifacts.py",
    "tools/ci_verify_dependency.py",
    "tools/sdk_producer_trust.py",
    "tools/ci_producer_trust.py",
    "tools/sdk_approval_bridge.py",
    "tools/sdk_final_approval.py",
    "tools/sdk_approved_legacy.json",
    "tools/sdk_workflow_recipe.py",
    "tools/sdk_transport_contract.json",
    "tools/sdk_build_transport.py",
)


def producer_controls_match(repository, commit, *, api, root, paths=PRODUCER_CONTROLS):
    """Qualify executable transport separately from SDK build compatibility.

    This check never changes a semantic SDK identity. A reviewed main producer
    or exact approved migration may instead be qualified by the caller. A
    mismatch needs requalification of existing bytes, not a cold compilation.
    """
    source = read_source(repository, commit, api=api, paths=paths)
    for name, (mode, data) in source.items():
        path = Path(root) / name
        if path.is_symlink() or not path.is_file():
            return False
        current_mode = "100755" if path.stat().st_mode & 0o111 else "100644"
        if (mode, data) != (current_mode, path.read_bytes()):
            return False
    return True


def source_fingerprint(
    repository, commit, component, *, api, fingerprint, files, parents
):
    """Apply the consumer's recipe to an immutable producer source closure.

    Read regular blobs and modes only. A symlink/gitlink in a consumed input,
    truncated tree, missing object or invalid object checksum fails closed.
    """
    if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
        raise ValueError("Invalid SDK producer commit")
    inputs = set()
    components = set()

    def collect(name):
        if name in components:
            return
        components.add(name)
        inputs.update(files[name])
        for parent in parents.get(name, []):
            collect(parent)

    collect(component)
    directories = (
        {"services/speech"} if components & {"linux-sdk", "macos-runtime"} else set()
    )
    source = read_source(
        repository, commit, api=api, paths=inputs, directories=directories
    )
    with tempfile.TemporaryDirectory(prefix="sdk-source-proof-") as temporary:
        root = Path(temporary)
        for name, (mode, data) in source.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o755 if mode == "100755" else 0o644)
        return fingerprint(component, root)


def read_source(repository, commit, *, api, paths=None, directories=()):
    """Read immutable regular Git blobs as {path: (Git mode, bytes)}.

    Explicit paths must all exist; directories include every new descendant.
    With paths=None this reads the whole tree (including no producer execution).
    """
    if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
        raise ValueError("Invalid SDK producer commit")
    record = api(repository, f"git/commits/{commit}")
    tree_sha = record.get("tree", {}).get("sha")
    if (
        record.get("sha") != commit
        or not isinstance(tree_sha, str)
        or not COMMIT.fullmatch(tree_sha)
    ):
        raise ValueError("Invalid SDK producer commit object")
    tree = api(repository, f"git/trees/{tree_sha}?recursive=1")
    if tree.get("sha") != tree_sha or tree.get("truncated") is not False:
        raise ValueError("Incomplete SDK producer source tree")
    result = {}
    for entry in tree["tree"]:
        name = entry["path"]
        if (
            paths is not None
            and name not in paths
            and not any(name.startswith(directory + "/") for directory in directories)
        ):
            continue
        if entry.get("type") == "tree":
            continue
        path = PurePosixPath(name)
        if (
            path.is_absolute()
            or ".." in path.parts
            or str(path) != name
            or name in result
        ):
            raise ValueError("Invalid SDK source path")
        if entry.get("type") != "blob" or entry.get("mode") not in ("100644", "100755"):
            raise ValueError("SDK source inputs must be regular files")
        blob_sha = entry.get("sha", "")
        if not isinstance(blob_sha, str) or not COMMIT.fullmatch(blob_sha):
            raise ValueError("Invalid SDK source blob identity")
        blob = api(repository, f"git/blobs/{blob_sha}")
        if blob.get("sha") != blob_sha or blob.get("encoding") != "base64":
            raise ValueError("Invalid SDK source blob")
        data = base64.b64decode("".join(blob["content"].split()), validate=True)
        actual = hashlib.sha1(
            b"blob " + str(len(data)).encode() + b"\0" + data,
            usedforsecurity=False,
        ).hexdigest()
        if actual != blob_sha or blob.get("size") != len(data):
            raise ValueError("SDK source blob checksum mismatch")
        result[name] = (entry["mode"], data)
    if paths is not None and not set(paths) <= result.keys():
        raise ValueError("SDK producer is missing required recipe inputs")
    return result


def successful_attempt(component, receipt, job, artifact):
    """An upload must occur inside the successful, exact component attempt."""
    attempt = receipt.get("source_run_attempt")
    if (
        type(attempt) is not int
        or attempt < 1
        or job.get("name") != JOBS.get(component)
        or job.get("conclusion") != "success"
        or job.get("run_attempt", 1) != attempt
    ):
        return False
    try:
        created, started, completed = (
            datetime.fromisoformat(value.replace("Z", "+00:00"))
            for value in (
                artifact["created_at"],
                job["started_at"],
                job["completed_at"],
            )
        )
        return started <= created <= completed
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


def verify_producer_source(
    repository,
    run,
    component,
    identity,
    receipt,
    job,
    artifact,
    *,
    fingerprint_at,
    approved_legacy=None,
    qualified_control=None,
):
    """Bind an eligible producer's payload to its successful source recipe.

    Caller also enforces main/own-PR eligibility and ZIP/archive checksums.
    An exact approved legacy proof can bridge old synthetic-event SHA receipts;
    it cannot bypass the successful-job/attempt/upload-time requirements.
    """
    head = run.get("head_sha", "")
    if (
        run.get("path") != WORKFLOW
        or (run.get("head_repository") or {}).get("full_name") != repository
        or not isinstance(head, str)
        or not COMMIT.fullmatch(head)
        or receipt.get("component") != component
        or artifact.get("workflow_run", {}).get("id") != run.get("id")
        or not successful_attempt(component, receipt, job, artifact)
    ):
        return False
    if approved_legacy and approved_legacy(run, component, identity, receipt, artifact):
        return True
    if receipt.get("source_commit") != head or receipt.get("identity") != identity:
        return False
    if qualified_control is None or not qualified_control(repository, run):
        raise ValueError(
            "SDK producer executable controls are not qualified. Preserve its "
            "artifact and obtain reviewed control compatibility or source approval; "
            "this does not authorize a cold SDK build."
        )
    return fingerprint_at(repository, head, component) == identity


def compatible_producers(
    repository, runs, component, identity, *, eligible, jobs, fingerprint_at
):
    """Preserve compatible running producers across application-only pushes."""
    result = []
    for run in runs:
        if run.get("status") == "completed" or not eligible(run):
            continue
        component_jobs = [
            job
            for job in jobs(repository, run["id"])
            if job.get("name") == JOBS[component]
        ]
        # A failed historical attempt does not disqualify a currently running
        # rerun. Look only at the run's current attempt.
        attempt = run.get("run_attempt", 1)
        current = [
            job for job in component_jobs if job.get("run_attempt", 1) == attempt
        ]
        if current and all(
            job.get("conclusion") in ("failure", "cancelled", "timed_out", "skipped")
            for job in current
        ):
            continue
        if fingerprint_at(repository, run["head_sha"], component) == identity:
            result.append(run["id"])
    return result
