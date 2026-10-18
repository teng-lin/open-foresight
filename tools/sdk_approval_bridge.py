"""Explicit, reviewed migration of qualified SDK bytes without recompilation.

Original receipts remain original. Each entry names one immutable producer and
an approved final PR source with byte-identical *full legacy* build inputs. A
changed current semantic identity cannot use the entry. No producer code runs.
"""

import ast
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

MANIFEST = Path(__file__).with_name("sdk_approved_legacy.json")
SHA = re.compile(r"[a-f0-9]{40}")
IDENTITY = re.compile(r"[a-f0-9]{64}")


def legacy_definition(source):
    values = {}
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in (
                "FILES",
                "PRODUCER_INPUTS",
                "PARENTS",
            ):
                values[target.id] = ast.literal_eval(node.value)
    if set(values) != {"FILES", "PRODUCER_INPUTS", "PARENTS"}:
        raise ValueError("Unsupported legacy SDK identity definition")
    return values


def legacy_paths(component, definition):
    result = set()

    def visit(name):
        result.update(definition["FILES"][name])
        result.update(definition["PRODUCER_INPUTS"])
        for parent in definition["PARENTS"].get(name, []):
            visit(parent)

    visit(component)
    return result


def legacy_proof(component, read):
    """Recompute the historical algorithm from immutable blobs, never eval it."""
    definition = legacy_definition(read("tools/ci_artifacts.py"))
    proof = {}

    def identity(name):
        paths = [*definition["FILES"][name], *definition["PRODUCER_INPUTS"]]
        files = {}
        for path in paths:
            pure = PurePosixPath(path)
            if pure.is_absolute() or ".." in pure.parts:
                raise ValueError("Invalid legacy input path")
            data = read(path)
            proof[path] = hashlib.sha256(data).hexdigest()
            if pure.name.startswith("requirements-") and pure.suffix == ".lock":
                meaningful = []
                continued = False
                for line in data.splitlines(keepends=True):
                    if not continued and line.lstrip().startswith(b"#"):
                        continue
                    meaningful.append(line)
                    continued = line.rstrip().endswith(b"\\")
                data = b"".join(meaningful)
            files[path] = hashlib.sha256(data).hexdigest()
        record = {
            "schema": 1,
            "component": name,
            "files": files,
            "parents": {
                parent: identity(parent)
                for parent in definition["PARENTS"].get(name, [])
            },
        }
        return hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()

    return identity(component), proof


def entries(repository, component, semantic_identity):
    if not MANIFEST.exists():
        return []
    manifest = json.loads(MANIFEST.read_text())
    if manifest.get("schema") != 1:
        raise ValueError("Unsupported SDK migration manifest")
    return [
        entry
        for entry in manifest["entries"]
        if entry["repository"] == repository
        and entry["component"] == component
        and entry["semantic_identity"] == semantic_identity
    ]


def approved(
    entry, repository, component, semantic_identity, *, api, read_source, merged_source
):
    """Require exact final approval plus machine-checked legacy source equality."""
    if (
        entry.get("repository") != repository
        or entry.get("component") != component
        or entry.get("semantic_identity") != semantic_identity
        or not IDENTITY.fullmatch(semantic_identity)
        or not SHA.fullmatch(entry.get("approved_source", ""))
        or not SHA.fullmatch(entry.get("producer_source", ""))
        or not IDENTITY.fullmatch(entry.get("legacy_identity", ""))
    ):
        return False
    pull = api(repository, f"pulls/{entry['approved_pr']}")
    if (
        not pull.get("merged_at")
        or pull.get("head", {}).get("sha") != entry["approved_source"]
        or pull.get("base", {}).get("repo", {}).get("full_name") != repository
    ):
        return False
    # Historical producer runs can belong to a stacked PR that was later
    # rebased. Its entire compiler/control closure is the approved source proof;
    # current PR commit membership is deliberately not used for that branch.
    if entry.get("producer_pr") == entry["approved_pr"]:
        if api(
            repository,
            f"compare/{entry['producer_source']}...{entry['approved_source']}",
        ).get("status") not in ("ahead", "identical"):
            return False
        member = False
        for page in range(1, 31):
            commits = api(
                repository,
                f"pulls/{entry['approved_pr']}/commits?per_page=100&page={page}",
            )
            if any(commit.get("sha") == entry["producer_source"] for commit in commits):
                member = True
                break
            if len(commits) < 100:
                break
        if not member:
            return False
    # Validate final head through authoritative merge commit and main ancestry;
    # do not tell merged_source that the intermediate producer was a final head.
    if not merged_source(
        repository,
        {
            "head_sha": entry["approved_source"],
            "head_branch": "approved-sdk-source",
            "event": "pull_request",
            "pull_requests": [{"number": entry["approved_pr"]}],
        },
    ):
        return False
    original = read_source(
        repository, entry["producer_source"], paths=("tools/ci_artifacts.py",)
    )
    paths = legacy_paths(
        component, legacy_definition(original["tools/ci_artifacts.py"][1])
    )
    directories = (
        ("services/speech",) if component in ("linux-sdk", "macos-runtime") else ()
    )
    producer = read_source(
        repository, entry["producer_source"], paths=paths, directories=directories
    )
    final = read_source(
        repository, entry["approved_source"], paths=paths, directories=directories
    )
    legacy_identity, proof = legacy_proof(component, lambda path: producer[path][1])
    approved_identity, final_proof = legacy_proof(
        component, lambda path: final[path][1]
    )
    if (
        legacy_identity != entry["legacy_identity"]
        or approved_identity != legacy_identity
        or proof != entry["legacy_inputs"]
        or final_proof != proof
    ):
        return False
    # Bind executable bits and every source in the directory consumed by COPY /
    # CMake, including future headers not present in historical FILES arrays.
    for path in proof:
        if producer[path][0] != final[path][0]:
            return False
    source_dirs = (
        ("services/speech/",) if component in ("linux-sdk", "macos-runtime") else ()
    )
    for directory in source_dirs:
        if {p: value for p, value in producer.items() if p.startswith(directory)} != {
            p: value for p, value in final.items() if p.startswith(directory)
        }:
            return False
    return True


def matches_original(entry, run, component, identity, receipt, artifact):
    """Only the exact pinned historical upload can use this approval bridge."""
    return (
        component == entry["component"]
        and identity == entry["legacy_identity"]
        and run.get("id") == entry["producer_run"]
        and run.get("head_sha") == entry["producer_source"]
        and run.get("path") == ".github/workflows/ci-dependencies.yml"
        and run.get("head_repository", {}).get("full_name") == entry["repository"]
        and run.get("event") == entry.get("producer_event", "pull_request")
        and run.get("head_branch")
        == entry.get("producer_branch", run.get("head_branch"))
        and (
            not run.get("pull_requests")
            or any(
                pr.get("number") == entry.get("producer_pr", entry["approved_pr"])
                for pr in run["pull_requests"]
            )
        )
        and artifact.get("id") == entry["artifact_id"]
        and artifact.get("digest") == entry["artifact_digest"]
        and receipt == entry["source_receipt"]
    )


def descriptor_approval(prefix, component, old_identity, current_identity, digest):
    """A local bridge records qualification separately from the old image.json."""
    path = prefix / "approved-source.json"
    if not path.is_file() or path.is_symlink():
        return False
    record = json.loads(path.read_text())
    return any(
        record == qualification(entry, prefix, digest)
        for entry in entries(record.get("repository", ""), component, current_identity)
        if entry["legacy_identity"] == old_identity
    )


def find_original(
    repository,
    component,
    semantic_identity,
    *,
    api,
    optional_api,
    read_source,
    merged_source,
    dependency_jobs,
    download_zip,
    verify_producer_source,
):
    """Find only manifest-pinned originals, retaining both uploaded receipts."""
    import tempfile
    import zipfile

    for entry in entries(repository, component, semantic_identity):
        run = optional_api(repository, f"actions/runs/{entry['producer_run']}")
        if run is None:
            continue
        payload = optional_api(repository, f"actions/artifacts/{entry['artifact_id']}")
        if payload is None:
            continue
        sidecar = optional_api(repository, f"actions/artifacts/{entry['sidecar_id']}")
        if sidecar is None:
            continue
        legacy = entry["legacy_identity"]
        if (
            payload.get("expired")
            or sidecar.get("expired")
            or payload.get("name") != f"ci-{component}-{legacy}"
            or sidecar.get("name") != f"receipt-ci-{component}-{legacy}"
            or sidecar.get("digest") != entry["sidecar_digest"]
            or sidecar.get("workflow_run", {}).get("id") != entry["producer_run"]
            or payload.get("workflow_run", {}).get("id") != entry["producer_run"]
            or sidecar.get("size_in_bytes", 65537) > 65536
        ):
            continue
        if not matches_original(
            entry, run, component, legacy, entry["source_receipt"], payload
        ):
            continue
        if not approved(
            entry,
            repository,
            component,
            semantic_identity,
            api=api,
            read_source=read_source,
            merged_source=merged_source,
        ):
            continue
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "original-receipt.zip"
            download_zip(repository, sidecar, archive)
            with zipfile.ZipFile(archive) as stream:
                if (
                    stream.namelist() != ["receipt.json"]
                    or stream.getinfo("receipt.json").file_size > 16384
                ):
                    continue
                reference = json.loads(stream.read("receipt.json"))
        if reference != {
            "schema": 1,
            "component": component,
            "identity": legacy,
            "artifact_id": entry["artifact_id"],
            "artifact_digest": entry["artifact_digest"],
            "source_receipt": entry["source_receipt"],
        }:
            continue
        for job in dependency_jobs(repository, run["id"]):

            def explicit_approval(
                candidate_run,
                candidate_component,
                candidate_identity,
                receipt,
                artifact,
                *,
                entry=entry,
            ):
                return matches_original(
                    entry,
                    candidate_run,
                    candidate_component,
                    candidate_identity,
                    receipt,
                    artifact,
                )

            # The common verifier still requires the successful exact job and
            # artifact creation window even though this source approval is explicit.
            if not verify_producer_source(
                repository,
                run,
                component,
                legacy,
                entry["source_receipt"],
                job,
                payload,
                fingerprint_at=lambda *_: None,
                approved_legacy=explicit_approval,
            ):
                continue
            from datetime import datetime, timezone

            try:
                created = datetime.fromisoformat(
                    sidecar["created_at"].replace("Z", "+00:00")
                )
                started = datetime.fromisoformat(
                    job["started_at"].replace("Z", "+00:00")
                )
                completed = datetime.fromisoformat(
                    job["completed_at"].replace("Z", "+00:00")
                )
                expires = datetime.fromisoformat(
                    payload["expires_at"].replace("Z", "+00:00")
                )
                if (
                    not started <= created <= completed
                    or (expires - datetime.now(timezone.utc)).total_seconds() < 86400
                ):
                    continue
            except (KeyError, TypeError, ValueError):
                continue
            return entry, payload
    return None


def qualification(entry, prefix, digest):
    return {
        "schema": 1,
        "repository": entry["repository"],
        "component": entry["component"],
        "semantic_identity": entry["semantic_identity"],
        "legacy_identity": entry["legacy_identity"],
        "approved_source": entry["approved_source"],
        "producer_run": entry["producer_run"],
        "artifact_id": entry["artifact_id"],
        "original_source_receipt": entry["source_receipt"],
        "descriptor_sha256": digest(prefix / "image.json"),
    }
