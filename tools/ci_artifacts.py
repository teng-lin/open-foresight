#!/usr/bin/env python3
"""Content-addressed CI dependencies and exact-commit application promotion."""

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
from functools import lru_cache, partial
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.sdk_workflow_recipe import validate as validate_recipe_workflow  # noqa: E402
from tools import sdk_producer_trust as producer_trust  # noqa: E402
from tools import sdk_approval_bridge as approval_bridge  # noqa: E402
from tools import sdk_final_approval as final_approval  # noqa: E402
from tools.ci_producer_trust import PRODUCERS  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    "macos-sdk": ["tools/build_macos_sdk.py"],
    "macos-runtime": [
        "tools/build_macos_runtimes.py",
        "services/speech/CMakeLists.txt",
        "services/speech/worker.cpp",
        "services/inference/persistent_worker.h",
        "services/inference/output_budget.h",
        "services/inference/worker_frame.h",
    ],
    "macos-vendor": [
        "tools/build_macos_vendor.py",
        "tools/build_litert_extensions.py",
        "tools/litert_extensions.py",
        "tools/test_litert_status_abi.py",
        "third_party/litert_lm/stop-token-sequences.patch",
        "third_party/litert_lm/macos-trivial-abi.patch",
    ],
    "linux-core": [
        "packaging/sdk-core.Dockerfile",
        "packaging/minimal-grpc.cmake",
    ],
    "linux-litert": [
        "packaging/sdk-litert.Dockerfile",
        "tools/build_litert_extensions.py",
        "tools/litert_extensions.py",
        "tools/test_litert_status_abi.py",
        "third_party/litert_lm/stop-token-sequences.patch",
        "third_party/litert_lm/linux-trivial-abi.patch",
    ],
    "linux-whisper": [
        "packaging/sdk-whisper.Dockerfile",
        "tools/build_whisper_vulkan.py",
    ],
    "linux-sdk": [
        "packaging/sdk.Dockerfile",
        "requirements-dev.lock",
        "requirements-litert.lock",
        "services/speech/CMakeLists.txt",
        "services/speech/worker.cpp",
        "services/inference/persistent_worker.h",
        "services/inference/output_budget.h",
        "services/inference/worker_frame.h",
    ],
}
# Build recipes and provenance are separate: promotion/receipt implementation and
# unrelated pin metadata cannot change compiler outputs. The workflow regions
# contain only the component's runner, build environment and build/setup steps.
WORKFLOW = PRODUCERS["dependency-sdk"].workflows[0]
PIN_KEYS = {"linux-litert": ("litert_lm",), "macos-vendor": ("litert_lm",)}
for _component, _inputs in FILES.items():
    _inputs.append(WORKFLOW)
    if _component.startswith("linux-"):
        _inputs.append("tools/sdk_build_recipe.py")
    if _component in PIN_KEYS:
        _inputs.append("tools/pins.json")


def recipe_regions(path, component):
    """Read explicitly delimited build behavior using only the bootstrap stdlib."""
    regions: list[list[str]] = []
    active = None
    lines = path.read_text().splitlines(keepends=True)
    coverage: list[set[str]] = []
    for line in lines:
        marker = re.fullmatch(r"\s*# sdk-recipe: ([a-z,-]+) (begin|end)\s*", line)
        coverage.append(set(active.split(",")) if active else set())
        if marker:
            owner, direction = marker.groups()
            if direction == "begin":
                if active is not None:
                    raise ValueError("Nested SDK recipe region")
                active = owner
                if component in owner.split(","):
                    regions.append([])
            else:
                if active != owner:
                    raise ValueError("Unmatched SDK recipe region")
                active = None
        elif active is not None and component in active.split(","):
            regions[-1].append(line)
    if active is not None or not regions:
        raise ValueError("Missing or unfinished SDK recipe regions: " + component)
    validate_recipe_workflow(lines, coverage)
    return ["".join(region) for region in regions]


def component_input(component, name, root):
    value: object
    if name == WORKFLOW:
        value = [
            "".join(
                line
                for line in region.splitlines(keepends=True)
                if not re.match(r"      id:", line)
            )
            for region in recipe_regions(root / name, component)
        ]
    elif name == "tools/pins.json":
        pins = json.loads((root / name).read_text())
        value = {key: pins[key] for key in PIN_KEYS[component]}
    else:
        return input_digest(root / name)
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


PARENTS = {
    "macos-runtime": ["macos-vendor"],
    "linux-litert": ["linux-core"],
    "linux-whisper": ["linux-core"],
    "linux-sdk": ["linux-core", "linux-litert", "linux-whisper"],
}
JOBS = {
    component: jobs[0] for component, jobs in PRODUCERS["dependency-sdk"].jobs.items()
}


def fingerprint(component, root=ROOT):
    """Bind a component to its recipe, source pins, flags and parent identities."""
    record = {
        "schema": 2,
        "component": component,
        "files": {
            name: component_input(component, name, root) for name in FILES[component]
        },
        "source_trees": {"services/speech": source_tree(root / "services/speech")}
        if component in ("linux-sdk", "macos-runtime")
        else {},
        "parents": {
            name: fingerprint(name, root) for name in PARENTS.get(component, [])
        },
    }
    return hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()


def source_tree(path):
    """Bind the entire bounded source directory consumed by COPY/CMake."""
    result = {}
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            raise ValueError("SDK source tree must not contain symlinks")
        if item.is_file():
            result[item.relative_to(path).as_posix()] = {
                "sha256": digest(item),
                "executable": bool(item.stat().st_mode & 0o111),
            }
    return result


def input_digest(path):
    """Ignore pip comment-only lines; retain requirement order, flags and hashes.

    Only whole comment lines are ignored. Inline comments and continuation syntax
    remain byte-exact to avoid accidentally changing pip's parsing semantics.
    """
    path = Path(path)
    if path.name.startswith("requirements-") and path.suffix == ".lock":
        lines = []
        continued = False
        for line in path.read_bytes().splitlines(keepends=True):
            if not continued and line.lstrip().startswith(b"#"):
                continue
            lines.append(line)
            continued = line.rstrip().endswith(b"\\")
        meaningful = b"".join(lines)
        return hashlib.sha256(meaningful).hexdigest()
    return digest(path)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def name(component, identity):
    if component not in (*FILES, "macos-app", "linux-app") or not re.fullmatch(
        r"[a-f0-9]{40}|[a-f0-9]{64}", identity
    ):
        raise ValueError("Invalid artifact identity")
    return f"ci-{component}-{identity}"


def pack(component, identity, prefix, output):
    """Archive verified outputs with executable modes, symlinks and a digest."""
    source_commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=30
    ).strip()
    if component.endswith("-app"):
        if source_commit != identity:
            raise ValueError(
                "Application identity must match the actual built checkout"
            )
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "payload.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1) as stream:
        stream.add(prefix, arcname="payload")
    reused = None
    for metadata in ("source-qualification.json", "approved-source.json"):
        previous = prefix / metadata
        if previous.is_symlink():
            raise ValueError("SDK qualification metadata must be regular")
        if previous.is_file():
            reused = json.loads(previous.read_text())
            break
    (output / "identity.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "component": component,
                "identity": identity,
                "sha256": digest(archive),
                "source_commit": source_commit,
                "source_run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                **(
                    {
                        "distribution": application_distribution(
                            prefix, component, identity
                        )
                    }
                    if component.endswith("-app")
                    else {}
                ),
                **({"reused_from": reused} if reused is not None else {}),
            },
            indent=2,
        )
        + "\n"
    )


def unpack(component, identity, source, destination):
    """Reject mismatched or escaping archives before installing a fresh prefix."""
    record = json.loads((source / "identity.json").read_text())
    archive = source / "payload.tar.gz"
    if component.endswith("-app") and record.get("source_commit") != identity:
        raise ValueError("Application receipt does not match the requested source")
    if (record.get("schema"), record.get("component"), record.get("identity")) != (
        1,
        component,
        identity,
    ):
        raise ValueError("Artifact identity mismatch")
    if digest(archive) != record["sha256"]:
        raise ValueError("Artifact archive checksum mismatch")
    if destination.exists() or destination.is_symlink():
        raise ValueError("Artifact destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        with tarfile.open(archive) as stream:
            if any(
                not (m.name == "payload" or m.name.startswith("payload/"))
                for m in stream.getmembers()
            ):
                raise ValueError("Unexpected artifact archive root")
            stream.extractall(temporary, filter="data")
        (Path(temporary) / "payload").rename(destination)


def application_distribution(prefix, component, source):
    pattern = "*.build.json" if component == "linux-app" else "*.manifest.json"
    records = list(prefix.glob(pattern))
    if len(records) != 1:
        raise ValueError(
            "Application candidate requires unambiguous distribution metadata"
        )
    metadata = json.loads(records[0].read_text())
    version, number = metadata.get("version"), metadata.get("build_number")
    if (
        metadata.get("revision") != source
        or not isinstance(version, str)
        or not re.fullmatch(r"\d+\.\d+\.\d+", version)
        or type(number) is not int
        or number < 1
    ):
        raise ValueError("Invalid application distribution identity")
    return {"version": version, "build_number": number}


def github_read(operation):
    """Retry transient read failures without turning them into cache misses."""
    for attempt in range(3):
        try:
            return operation()
        except (
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            json.JSONDecodeError,
        ) as error:
            transient = isinstance(
                error, (subprocess.TimeoutExpired, json.JSONDecodeError)
            )
            if isinstance(error, subprocess.CalledProcessError):
                diagnostic = error.stderr or b""
                if isinstance(diagnostic, bytes):
                    diagnostic = diagnostic.decode("utf-8", errors="replace")
                if diagnostic:
                    print(diagnostic, file=sys.stderr, end="")
                transient = bool(
                    re.search(
                        r"HTTP 5\d\d\b|unexpected end of JSON input|"
                        r"connection reset|TLS handshake timeout|i/o timeout|"
                        r"unexpected EOF",
                        diagnostic,
                        re.IGNORECASE,
                    )
                )
            if not transient or attempt == 2:
                raise
            delay = 2 ** (attempt + 1)
            print(
                f"Transient GitHub read failure ({type(error).__name__}); "
                f"retrying in {delay}s ({attempt + 2}/3)",
                file=sys.stderr,
            )
            time.sleep(delay)


def api(repository, route):
    env = dict(os.environ)
    env.pop("GH_DEBUG", None)
    return github_read(
        lambda: json.loads(
            subprocess.check_output(
                ["gh", "api", f"repos/{repository}/{route}"],
                env=env,
                stderr=subprocess.PIPE,
                timeout=300,
            )
        )
    )


def trusted_run(
    run,
    component,
    own_head="",
    repository="teng-lin/open-foresight",
    own_pr=0,
    *,
    consumer="artifact-pull",
):
    """Dependencies come from main, merged sources, or this repository's own PR."""
    producer = PRODUCERS[
        consumer
        if component.endswith("-app") or consumer != "artifact-pull"
        else "dependency-sdk"
    ]
    if (
        not producer.matches_run(run)
        or (run.get("head_repository") or {}).get("full_name") != repository
    ):
        return False
    if component.endswith("-app"):
        return run.get("head_branch") == "main"
    if run.get("head_branch") == "main" and run.get("event") != "pull_request":
        return True
    if (
        run.get("event") == "workflow_dispatch"
        and own_head
        and run.get("head_sha") == own_head
    ):
        return True
    return (
        run.get("event") == "pull_request"
        and bool(own_pr)
        and any(pr["number"] == own_pr for pr in run.get("pull_requests", []))
    )


def merged_source(repository, run):
    """Promote only reviewed main commits or the final head of a merged PR."""
    if not re.fullmatch(r"[a-f0-9]{40}", run.get("head_sha", "")):
        return False
    merged_commits = []
    if run.get("event") == "pull_request" or run.get("head_branch") != "main":
        pulls = run.get("pull_requests") or api(
            repository, f"commits/{run['head_sha']}/pulls"
        )
        final_head = False
        for reference in pulls:
            pull = api(repository, f"pulls/{reference['number']}")
            if (
                pull.get("merged_at")
                and pull.get("head", {}).get("sha") == run["head_sha"]
                and pull.get("base", {}).get("repo", {}).get("full_name") == repository
            ):
                final_head = True
                merge = pull.get("merge_commit_sha")
                if isinstance(merge, str) and re.fullmatch(r"[a-f0-9]{40}", merge):
                    merged_commits.append(merge)
        if not final_head:
            return False
    comparison = api(repository, f"compare/{run['head_sha']}...main")
    if comparison["status"] in ("ahead", "identical"):
        return True
    # Rebase merges rewrite the reviewed final commit. Require the authoritative
    # merge commit to be on main and its entire tree to equal the producer tree.
    for merge in merged_commits:
        if api(repository, f"compare/{merge}...main")["status"] not in (
            "ahead",
            "identical",
        ):
            continue
        trees = []
        for commit in (run["head_sha"], merge):
            record = api(repository, f"git/commits/{commit}")
            tree = record.get("tree", {}).get("sha")
            if record.get("sha") != commit or not isinstance(tree, str):
                break
            if not re.fullmatch(r"[a-f0-9]{40}", tree):
                break
            trees.append(tree)
        if len(trees) == 2 and trees[0] == trees[1]:
            return True
    return False


def dependency_jobs(repository, run_id):
    """Retain completed producers when a later workflow attempt reruns failures."""
    jobs = []
    page = 1
    while True:
        batch = api(
            repository,
            f"actions/runs/{run_id}/jobs?filter=all&per_page=100&page={page}",
        )["jobs"]
        jobs.extend(batch)
        if len(batch) < 100:
            return jobs
        page += 1


def receipt_name(component, identity):
    return "receipt-" + name(component, identity)


_APPROVED_FINAL_SDK_SOURCES: set[tuple] = set()


def approved_final_sdk_source(repository, run, component):
    references = tuple(
        reference.get("number")
        for reference in run.get("pull_requests", [])
        if type(reference.get("number")) is int
    )
    key = (
        repository,
        component,
        run.get("id"),
        run.get("head_sha"),
        references,
        run.get("event"),
        run.get("path"),
        (run.get("head_repository") or {}).get("full_name"),
    )
    if key in _APPROVED_FINAL_SDK_SOURCES:
        return True
    approved = final_approval.approved_final_source(
        repository,
        run,
        component,
        api=api,
        merged_source=merged_source,
        fingerprint_at=source_fingerprint_at,
        read_source=lambda repo, commit, **kwargs: (
            producer_trust.read_producer_controls(
                repo, commit, api=partial(immutable_source_api, api), **kwargs
            )
        ),
        controls=(*producer_trust.PRODUCER_CONTROLS, WORKFLOW),
    )
    # Only cache positive immutable-source approvals: an unmerged PR may merge
    # while a long-running consumer is waiting for compatible original bytes.
    if approved:
        _APPROVED_FINAL_SDK_SOURCES.add(key)
    return approved


def eligible_run(
    repository, run, component, own_head="", own_pr=0, *, consumer="artifact-pull"
):
    if trusted_run(run, component, own_head, repository, own_pr, consumer=consumer):
        return True
    return (
        not component.endswith("-app")
        and PRODUCERS["sdk-promoted-source"].matches_run(run)
        and (run.get("head_repository") or {}).get("full_name") == repository
        and (
            merged_source(repository, run)
            or approved_final_sdk_source(repository, run, component)
        )
    )


def download_zip(repository, artifact, destination):
    def download():
        # Each retry truncates partial bytes from the preceding failed transfer.
        with destination.open("wb") as stream:
            subprocess.run(
                [
                    "gh",
                    "api",
                    f"repos/{repository}/actions/artifacts/{artifact['id']}/zip",
                ],
                stdout=stream,
                stderr=subprocess.PIPE,
                check=True,
                timeout=300,
            )

    github_read(download)
    expected = artifact.get("digest", "")
    if (
        not isinstance(expected, str)
        or not re.fullmatch(r"sha256:[a-f0-9]{64}", expected)
        or expected != "sha256:" + digest(destination)
    ):
        raise ValueError("Artifact ZIP digest mismatch")


def optional_api(repository, route):
    try:
        return api(repository, route)
    except subprocess.CalledProcessError as error:
        try:
            missing = json.loads(error.output or b"{}")
        except (ValueError, TypeError):
            raise error from None
        if str(missing.get("status")) == "404":
            return None
        raise


def valid_receipt(receipt, component, identity):
    return (
        isinstance(receipt, dict)
        and type(receipt.get("schema")) is int
        and receipt["schema"] == 1
        and receipt.get("component") == component
        and receipt.get("identity") == identity
        and isinstance(receipt.get("sha256"), str)
        and bool(re.fullmatch(r"[a-f0-9]{64}", receipt["sha256"]))
        and isinstance(receipt.get("source_commit"), str)
        and bool(re.fullmatch(r"[a-f0-9]{40}", receipt["source_commit"]))
        and type(receipt.get("source_run_attempt")) is int
        and receipt["source_run_attempt"] > 0
    )


def in_producer_attempt(artifact, job):
    try:
        created = datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00"))
        started = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
        completed = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
        return started <= created <= completed
    except (KeyError, TypeError, ValueError):
        return False


def application_jobs(repository, run, component, artifact, *, consumer="artifact-pull"):
    """Qualify a completed platform producer independently of sibling jobs."""
    if not trusted_run(run, component, repository=repository, consumer=consumer):
        return []
    return [
        job
        for job in dependency_jobs(repository, run["id"])
        if PRODUCERS[consumer].matches_job(job, component)
        and job.get("conclusion") == "success"
        and in_producer_attempt(artifact, job)
    ]


def publish_receipt(repository, component, identity, source, artifact_id, output):
    """Bind a small receipt to this job's original immutable payload upload."""
    receipt = json.loads((source / "identity.json").read_text())
    if not valid_receipt(receipt, component, identity):
        raise ValueError("Invalid source artifact receipt")
    artifact = api(repository, f"actions/artifacts/{artifact_id}")
    if (
        artifact.get("expired")
        or artifact.get("name") != name(component, identity)
        or str(artifact["workflow_run"]["id"]) != os.environ.get("GITHUB_RUN_ID")
        or receipt["source_run_attempt"]
        != int(os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
        or not re.fullmatch(r"sha256:[a-f0-9]{64}", artifact.get("digest", ""))
    ):
        raise ValueError("Payload upload does not match the current producer")
    output.mkdir(parents=True, exist_ok=True)
    (output / "receipt.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "component": component,
                "identity": identity,
                "artifact_id": artifact_id,
                "artifact_digest": artifact["digest"],
                "source_receipt": receipt,
            },
            indent=2,
        )
        + "\n"
    )


@lru_cache(maxsize=1024)
def immutable_source_api(fetch, repository, route):
    # This is exclusively for content-addressed Git objects, never mutable runs,
    # approvals, jobs, artifact expiry or current main ancestry.
    return fetch(repository, route)


def source_fingerprint_at(repository, commit, component):
    return producer_trust.source_fingerprint(
        repository,
        commit,
        component,
        api=partial(immutable_source_api, api),
        fingerprint=fingerprint,
        files=FILES,
        parents=PARENTS,
    )


def qualified_producer_control(repository, run, component=None):
    if merged_source(repository, run):
        return True
    if component is not None and approved_final_sdk_source(repository, run, component):
        return True
    return producer_trust.producer_controls_match(
        repository,
        run["head_sha"],
        api=partial(immutable_source_api, api),
        root=ROOT,
    )


def approved_original(repository, component, identity):
    if component.endswith("-app"):
        return None
    return approval_bridge.find_original(
        repository,
        component,
        identity,
        api=api,
        optional_api=optional_api,
        read_source=lambda repository, commit, **kwargs: producer_trust.read_source(
            repository, commit, api=partial(immutable_source_api, api), **kwargs
        ),
        merged_source=merged_source,
        dependency_jobs=dependency_jobs,
        download_zip=download_zip,
        verify_producer_source=producer_trust.verify_producer_source,
    )


def candidate_verified(
    repository, run, component, identity, receipt, job, payload, errors
):
    """Try all eligible candidates, retaining qualification failures until exhausted."""
    try:
        return producer_trust.verify_producer_source(
            repository,
            run,
            component,
            identity,
            receipt,
            job,
            payload,
            fingerprint_at=source_fingerprint_at,
            qualified_control=lambda repo, producer: qualified_producer_control(
                repo, producer, component
            ),
        )
    except json.JSONDecodeError:
        # Invalid API JSON is a protocol failure, not an incompatible candidate.
        raise
    except ValueError as error:
        errors.append(error)
        return False


def probe(repository, component, identity, own_head="", own_pr=0):
    """Find an original qualified payload without downloading its large bytes.

    Receipts never forward other receipts. Both uploads must belong to the same
    successful producer attempt. Consumers still verify the original full payload.
    """
    original = approved_original(repository, component, identity)
    if original:
        entry, payload = original
        print(
            f"Reusing approved original {payload['id']} from run {entry['producer_run']}",
            flush=True,
        )
        return True
    sidecar_name = receipt_name(component, identity)
    candidates = api(repository, f"actions/artifacts?name={sidecar_name}&per_page=100")[
        "artifacts"
    ]
    qualification_errors: list[ValueError] = []
    for sidecar in candidates:
        if (
            sidecar.get("expired")
            or sidecar.get("name") != sidecar_name
            or sidecar.get("size_in_bytes", 65537) > 65536
        ):
            continue
        run = api(repository, f"actions/runs/{sidecar['workflow_run']['id']}")
        try:
            eligible = eligible_run(repository, run, component, own_head, own_pr)
        except json.JSONDecodeError:
            raise
        except ValueError as error:
            qualification_errors.append(error)
            continue
        if not eligible:
            continue
        jobs = dependency_jobs(repository, run["id"])
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "receipt.zip"
            try:
                download_zip(repository, sidecar, archive)
                with zipfile.ZipFile(archive) as stream:
                    if (
                        stream.namelist() != ["receipt.json"]
                        or stream.getinfo("receipt.json").file_size > 16384
                    ):
                        continue
                    reference = json.loads(stream.read("receipt.json"))
            except (ValueError, zipfile.BadZipFile):
                continue
        if not isinstance(reference, dict):
            continue
        receipt = reference.get("source_receipt", {})
        if (
            type(reference.get("schema")) is not int
            or reference["schema"] != 1
            or reference.get("component") != component
            or reference.get("identity") != identity
            or not valid_receipt(receipt, component, identity)
            or type(reference.get("artifact_id")) is not int
            or reference["artifact_id"] < 1
            or not isinstance(reference.get("artifact_digest"), str)
            or not re.fullmatch(r"sha256:[a-f0-9]{64}", reference["artifact_digest"])
        ):
            continue
        payload = optional_api(
            repository, f"actions/artifacts/{reference['artifact_id']}"
        )
        if (
            not payload
            or payload.get("expired")
            or payload.get("name") != name(component, identity)
        ):
            continue
        if (
            payload.get("digest") != reference["artifact_digest"]
            or payload.get("workflow_run", {}).get("id") != run["id"]
        ):
            continue
        try:
            expires = datetime.fromisoformat(
                payload["expires_at"].replace("Z", "+00:00")
            )
            if expires < datetime.now(timezone.utc) + timedelta(hours=24):
                continue
        except (KeyError, TypeError, ValueError):
            continue
        if not any(
            job["name"] == JOBS[component]
            and job.get("conclusion") == "success"
            and job.get("run_attempt", 1) == receipt["source_run_attempt"]
            and in_producer_attempt(payload, job)
            and in_producer_attempt(sidecar, job)
            and candidate_verified(
                repository,
                run,
                component,
                identity,
                receipt,
                job,
                payload,
                qualification_errors,
            )
            for job in jobs
        ):
            continue
        print(
            f"Reusing qualified original {payload['id']} from run {run['id']} without transferring its payload",
            flush=True,
        )
        return True
    if qualification_errors:
        raise qualification_errors[-1]
    return False


def waiting_for_dependency(repository, component, identity, own_head, own_pr):
    """Wait for this head or compatible reviewed main, never another PR."""
    if component not in FILES or not own_head:
        return []
    result = []
    for status, scope in (
        (status, scope)
        for status in ("queued", "in_progress", "waiting", "pending", "requested")
        for scope in (f"head_sha={own_head}", "branch=main")
    ):
        page = 1
        while True:
            runs = api(
                repository,
                f"actions/workflows/ci-dependencies.yml/runs?{scope}&status={status}&per_page=100&page={page}",
            )["workflow_runs"]
            for run in runs:
                if (
                    not (
                        run.get("head_sha") == own_head
                        if scope.startswith("head_sha=")
                        else run.get("head_branch") == "main"
                        and run.get("event") != "pull_request"
                    )
                    or run.get("status") != status
                    or not trusted_run(run, component, own_head, repository, own_pr)
                ):
                    continue
                jobs = [
                    job
                    for job in dependency_jobs(repository, run["id"])
                    if job.get("name") == JOBS[component]
                    and job.get("run_attempt", 1) == run.get("run_attempt", 1)
                ]
                if jobs and all(job.get("conclusion") is not None for job in jobs):
                    continue
                if (
                    source_fingerprint_at(repository, run["head_sha"], component)
                    == identity
                ):
                    result.append(run["id"])
            if len(runs) < 100:
                break
            page += 1
    return sorted(set(result))


def unavailable_message(component, identity):
    producer = "ci-dependencies.yml" if component in FILES else "macos.yml"
    return (
        f"Verified {component} identity {identity} unavailable from {producer}. "
        "No same-head or compatible main producer is running, or the 1800-second wait expired. "
        "Run the producer on the reviewed source and retry the failed consumer."
    )


def report_unavailable(component, identity):
    message = unavailable_message(component, identity)
    print("::error::" + message)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write("## Missing verified dependency\n\n" + message + "\n")
    return message


def pull(
    repository,
    component,
    identity,
    prefix,
    wait=0,
    own_head="",
    own_pr=0,
    source_run=0,
    *,
    consumer="artifact-pull",
):
    original = approved_original(repository, component, identity)
    if original:
        entry, artifact = original
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "original.zip"
            download_zip(repository, artifact, archive)
            source = Path(temporary) / "download"
            source.mkdir()
            with zipfile.ZipFile(archive) as stream:
                if len(stream.namelist()) != 2 or set(stream.namelist()) != {
                    "identity.json",
                    "payload.tar.gz",
                }:
                    raise ValueError("Unexpected original SDK archive members")
                stream.extractall(source)  # noqa: S202 - Exact member names validated above.
            receipt = json.loads((source / "identity.json").read_text())
            if receipt != entry["source_receipt"]:
                raise ValueError("Original SDK receipt differs from approved receipt")
            unpack(component, entry["legacy_identity"], source, prefix)
            if (prefix / "approved-source.json").exists() or (
                prefix / "approved-source.json"
            ).is_symlink():
                raise ValueError(
                    "Original SDK contains unexpected imported qualification"
                )
            # Preserve original provenance alongside the downloaded image bytes.
            if (prefix / "image.json").is_file():
                (prefix / "approved-source.json").write_text(
                    json.dumps(
                        approval_bridge.qualification(entry, prefix, digest), indent=2
                    )
                    + "\n"
                )
        return True
    artifact_name = name(component, identity)
    deadline = time.monotonic() + max(0, min(wait, 1800))
    qualification_errors: list[ValueError] = []
    while True:
        artifacts = api(
            repository, f"actions/artifacts?name={artifact_name}&per_page=100"
        )["artifacts"]
        for artifact in artifacts:
            if artifact["expired"] or artifact["name"] != artifact_name:
                continue
            if source_run and artifact["workflow_run"]["id"] != source_run:
                continue
            run = api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
            try:
                eligible = eligible_run(
                    repository, run, component, own_head, own_pr, consumer=consumer
                )
            except json.JSONDecodeError:
                raise
            except ValueError as error:
                qualification_errors.append(error)
                continue
            if not eligible:
                continue
            if component.endswith("-app"):
                if run["head_sha"] != identity and not (
                    run.get("event") == "workflow_dispatch"
                ):
                    continue
                jobs = application_jobs(
                    repository, run, component, artifact, consumer=consumer
                )
                if not jobs:
                    continue
            else:
                jobs = dependency_jobs(repository, run["id"])
                if not any(
                    j["name"] == JOBS[component] and j.get("conclusion") == "success"
                    for j in jobs
                ):
                    continue
            with tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / "artifact.zip"
                download_zip(repository, artifact, archive)
                source = Path(temporary) / "download"
                source.mkdir()
                with zipfile.ZipFile(archive) as stream:
                    if len(stream.namelist()) != 2 or set(stream.namelist()) != {
                        "identity.json",
                        "payload.tar.gz",
                    }:
                        raise ValueError("Unexpected artifact download members")
                    stream.extractall(source)  # noqa: S202 - Archive members are validated immediately above; links are retained.
                receipt = json.loads((source / "identity.json").read_text())
                if component.endswith("-app"):
                    if (
                        not valid_receipt(receipt, component, identity)
                        or not PRODUCERS[consumer].matches_receipt(receipt)
                        or not any(
                            job.get("run_attempt", 1) == receipt["source_run_attempt"]
                            for job in jobs
                        )
                    ):
                        raise ValueError(
                            "Application receipt differs from successful producer attempt"
                        )
                else:
                    attempt = receipt.get(
                        "source_run_attempt", run.get("run_attempt", 1)
                    )
                    if type(attempt) is not int or attempt < 1:
                        raise ValueError("Invalid artifact producer attempt")
                    if not any(
                        j["name"] == JOBS[component]
                        and j.get("conclusion") == "success"
                        and j.get("run_attempt", 1) == attempt
                        and candidate_verified(
                            repository,
                            run,
                            component,
                            identity,
                            receipt,
                            j,
                            artifact,
                            qualification_errors,
                        )
                        for j in jobs
                    ):
                        continue
                unpack(component, identity, source, prefix)
                if (prefix / "approved-source.json").exists() or (
                    prefix / "approved-source.json"
                ).is_symlink():
                    raise ValueError(
                        "Ordinary SDK artifact contains imported approval; use the verified original bridge"
                    )
                if (prefix / "source-qualification.json").is_symlink():
                    raise ValueError("SDK qualification metadata must be regular")
                (prefix / "source-qualification.json").write_text(
                    json.dumps(
                        {
                            "source_receipt": receipt,
                            "producer_run": run["id"],
                            "artifact_id": artifact["id"],
                            "artifact_digest": artifact["digest"],
                        },
                        indent=2,
                    )
                    + "\n"
                )
            print(
                f"Using {artifact_name} from verified workflow run {run['id']}",
                flush=True,
            )
            return True
        if time.monotonic() >= deadline or not waiting_for_dependency(
            repository, component, identity, own_head, own_pr
        ):
            if qualification_errors:
                raise qualification_errors[-1]
            return False
        print(f"Waiting for verified dependency/candidate {artifact_name}", flush=True)
        time.sleep(min(20, max(0, deadline - time.monotonic())))


def application_descriptor(
    repository, component, source, run_id, *, consumer="artifact-pull"
):
    """Prefer a small verified receipt; legacy candidates retain full verification."""
    run = api(repository, f"actions/runs/{run_id}")
    metadata_name = receipt_name(component, source)
    items = api(repository, f"actions/artifacts?name={metadata_name}&per_page=100")[
        "artifacts"
    ]
    for item in items:
        if (
            item["expired"]
            or item["name"] != metadata_name
            or item["workflow_run"]["id"] != run_id
        ):
            continue
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "receipt.zip"
            download_zip(repository, item, archive)
            with zipfile.ZipFile(archive) as bundle:
                if (
                    bundle.namelist() != ["receipt.json"]
                    or bundle.getinfo("receipt.json").file_size > 65536
                ):
                    raise ValueError("Invalid application metadata archive")
                record = json.loads(bundle.read("receipt.json"))
        payload = api(repository, f"actions/artifacts/{record['artifact_id']}")
        receipt = record.get("source_receipt")
        if (
            not valid_receipt(receipt, component, source)
            or not PRODUCERS[consumer].matches_receipt(receipt)
            or receipt["source_commit"] != source
            or record.get("component") != component
            or record.get("identity") != source
            or record.get("artifact_digest") != payload.get("digest")
            or payload.get("expired")
            or payload.get("name") != name(component, source)
            or payload.get("workflow_run", {}).get("id") != run_id
        ):
            raise ValueError("Application metadata does not bind the original payload")
        jobs = application_jobs(repository, run, component, payload, consumer=consumer)
        if not any(
            job.get("run_attempt", 1) == receipt["source_run_attempt"]
            and in_producer_attempt(item, job)
            for job in jobs
        ):
            raise ValueError("Application metadata producer job/attempt mismatch")
        distribution = receipt.get("distribution", {})
        if (
            not isinstance(distribution.get("version"), str)
            or not re.fullmatch(r"\d+\.\d+\.\d+", distribution["version"])
            or type(distribution.get("build_number")) is not int
            or distribution["build_number"] < 1
        ):
            raise ValueError("Application metadata lacks a valid distribution identity")
        return distribution
    with tempfile.TemporaryDirectory() as temporary:
        prefix = Path(temporary) / "candidate"
        options = {"consumer": consumer} if consumer != "artifact-pull" else {}
        if not pull(
            repository, component, source, prefix, source_run=run_id, **options
        ):
            raise ValueError("Verified surviving candidate became unavailable")
        return application_distribution(prefix, component, source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=("keys", "pack", "pull", "probe", "publish-receipt")
    )
    parser.add_argument("--component", choices=(*FILES, "macos-app", "linux-app"))
    parser.add_argument("--identity")
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--artifact-id", type=int)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--wait", type=int, default=0)
    parser.add_argument("--optional", action="store_true")
    parser.add_argument("--own-head", default="")
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument(
        "--run-id",
        type=int,
        default=0,
        help="Require this exact candidate producer run",
    )
    args = parser.parse_args()
    if args.command == "keys":
        keys = {key: fingerprint(key) for key in FILES}
        for key, value in keys.items():
            print(f"{key}={value}")
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a") as stream:
                stream.write("".join(f"{key}={value}\n" for key, value in keys.items()))
        return
    if args.command == "probe":
        if args.component not in FILES:
            parser.error("A dependency --component is required")
        hit = probe(
            args.repository,
            args.component,
            args.identity or fingerprint(args.component),
            args.own_head,
            args.own_pr,
        )
        if destination := os.environ.get("GITHUB_OUTPUT"):
            with open(destination, "a") as stream:
                stream.write(f"hit={str(hit).lower()}\n")
        return
    if args.command == "publish-receipt":
        if (
            not args.component
            or not args.prefix
            or not args.output
            or not args.artifact_id
        ):
            parser.error(
                "--component, --prefix, --output and --artifact-id are required"
            )
        publish_receipt(
            args.repository,
            args.component,
            args.identity or fingerprint(args.component),
            args.prefix,
            args.artifact_id,
            args.output,
        )
        return
    if not args.component or not args.prefix:
        parser.error("--component and --prefix are required")
    identity = args.identity or fingerprint(args.component)
    name(args.component, identity)
    if args.command == "pack":
        if not args.output:
            parser.error("--output is required")
        pack(args.component, identity, args.prefix, args.output)
    elif not pull(
        args.repository,
        args.component,
        identity,
        args.prefix,
        args.wait,
        args.own_head,
        args.own_pr,
        source_run=args.run_id,
    ):
        if args.optional:
            raise SystemExit(4)
        raise SystemExit(report_unavailable(args.component, identity))


if __name__ == "__main__":
    main()
