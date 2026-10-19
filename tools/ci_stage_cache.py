#!/usr/bin/env python3
"""Reuse successful PR stages only after independently verifying their producer.

Input roles are deliberately conservative: all tracked/new nonignored paths are
common inputs unless explicitly assigned below. Tools, workflows/actions, pins,
requirements, packaging, CMake, native/services/proto, and native/helper/inference/
integration tests therefore invalidate every stage. Native excludes only the
known Dart application and service-test trees; core additionally consumes all
core/test-support inputs, desktop consumes core and desktop, service consumes
all application and service tests. Parent identities and complete caller-supplied
compiler/runtime/system-package/SDK identity are mandatory cache inputs.

No producer Python, shell script, or workflow is executed by this verifier. Git
objects are read with this checkout's recipe, including this module itself.
"""

import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

artifacts = importlib.import_module(
    "tools.ci_artifacts" if __package__ else "ci_artifacts"
)

timing = importlib.import_module("tools.ci_timing" if __package__ else "ci_timing")

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ("linux", "macos")
STAGES = ("native", "core", "desktop", "service")
WORKFLOW = ".github/workflows/macos.yml"
HEX = r"[a-f0-9]{64}"
COMMIT = r"[a-f0-9]{40}"
# These are known editorial inputs. Unknown/new paths always enter the common
# input set rather than silently missing a newly introduced build dependency.
EDITORIAL = {"README.md", "CHANGELOG.md", "LICENSE", "AGENTS.md"}
IDENTITY_RECIPE = 2
MAX_NATIVE_WORK_DOWNLOADS = 3
MAX_STAGE_RECEIPT_BYTES = 16 * 1024 * 1024


def lookup_api(repository, route):
    with timing.phase("stage API request"):
        return artifacts.api(repository, route)


def lookup_download(repository, artifact, destination):
    with timing.phase("stage artifact transfer and ZIP checksum"):
        return artifacts.download_zip(repository, artifact, destination)


def lookup_jobs(repository, run_id):
    with timing.phase("stage producer jobs request"):
        return artifacts.dependency_jobs(repository, run_id)


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, timeout=120)


def selected_v1(path, stage):
    """Frozen original selector for independently verifying legacy artifacts."""
    if path in EDITORIAL or path.startswith("docs/"):
        return False
    if path == "apps/desktop/pubspec.yaml":
        return True  # Native build and helper identity consume application version.
    if path == "packages/foresight_core/lib/src/model_pins.dart":
        return True  # Shared native/runtime fixtures consume these model pins.
    if path.startswith("apps/desktop/"):
        # Core's registry guard validates desktop command literals as well.
        return stage in ("desktop", "service") or (
            stage == "core" and path.startswith("apps/desktop/lib/")
        )
    if path.startswith("packages/foresight_core/"):
        return stage != "native"
    if path.startswith("tests/service/"):
        return stage in ("core", "service")
    return True


def selected(path, stage, recipe=IDENTITY_RECIPE):
    if recipe == 2 and path.startswith("packages/foresight_test_support/"):
        return stage != "native"
    return selected_v1(path, stage)


def version_input(root, stage, name, mode, kind, identity, recipe, data=None):
    """Bind only the exact version line consumed by native CMake, when valid."""
    if (
        recipe >= 2
        and stage == "native"
        and name == "apps/desktop/pubspec.yaml"
        and kind == "blob"
        and mode != "120000"
    ):
        data = git(root, "cat-file", "blob", identity) if data is None else data
        # This mirrors OpenForesightVersion.cmake's anchored file(STRINGS)
        # expression. Malformed/duplicate declarations retain the full blob;
        # they must never inherit a previously successful version qualification.
        lines = re.findall(rb"(?m)^version: [0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$", data)
        if len(lines) == 1:
            return [mode, "native-version", lines[0].decode("ascii")]
    return [mode, kind, identity]


def source_inputs(root, stage, ref=None, recipe=IDENTITY_RECIPE):
    """Mode and Git blob identities, including modified/new working files."""
    if ref is not None:
        if not re.fullmatch(COMMIT, ref):
            raise ValueError("Source ref must be a full commit SHA")
        rows = git(root, "ls-tree", "-r", "-z", ref).split(b"\0")
        result = {}
        for row in filter(None, rows):
            metadata, path = row.split(b"\t", 1)
            mode, kind, identity = metadata.decode().split()
            name = os.fsdecode(path)
            if selected(name, stage, recipe):
                result[name] = version_input(
                    root, stage, name, mode, kind, identity, recipe
                )
        return result
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    result = {}
    object_format = git(root, "rev-parse", "--show-object-format").decode().strip()
    for raw in filter(None, paths.split(b"\0")):
        name = os.fsdecode(raw)
        if not selected(name, stage, recipe):
            continue
        path = root / name
        if not path.exists() and not path.is_symlink():
            continue  # Deletion is represented by removing the inventory entry.
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            data, mode = os.fsencode(os.readlink(path)), "120000"
        elif path.is_dir():
            # Gitlinks bind their checked-out commit, never recurse into them.
            identity = git(path, "rev-parse", "HEAD").decode().strip()
            result[name] = ["160000", "commit", identity]
            continue
        else:
            data = path.read_bytes()
            mode = "100755" if info.st_mode & 0o111 else "100644"
        blob = b"blob " + str(len(data)).encode() + b"\0" + data
        result[name] = version_input(
            root,
            stage,
            name,
            mode,
            "blob",
            hashlib.new(object_format, blob).hexdigest(),
            recipe,
            data,
        )
    return result


def fingerprint(
    platform,
    stage,
    root=ROOT,
    ref=None,
    environment=None,
    parents=None,
    recipe=IDENTITY_RECIPE,
):
    if platform not in PLATFORMS or stage not in STAGES:
        raise ValueError("Invalid platform or stage")
    if type(recipe) is not int or recipe not in (1, IDENTITY_RECIPE):
        raise ValueError("Unsupported stage identity recipe")
    if not isinstance(environment, dict) or not environment:
        raise ValueError("Explicit compiler/runtime/system/SDK environment is required")
    parents = {} if parents is None else parents
    if not isinstance(parents, dict) or any(
        not isinstance(key, str)
        or not isinstance(value, str)
        or not re.fullmatch(HEX, value)
        for key, value in parents.items()
    ):
        raise ValueError("Parent identities must be a mapping of SHA256 identities")
    if stage != "native" and "native" not in parents:
        raise ValueError("Dart stages require a native parent identity")
    record = {
        "schema": 1,
        "platform": platform,
        "stage": stage,
        "environment": environment,
        "parents": parents,
        "inputs": source_inputs(Path(root), stage, ref, recipe),
    }
    return hashlib.sha256(
        json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def name(platform, stage, identity):
    if (
        platform not in PLATFORMS
        or stage not in STAGES
        or not isinstance(identity, str)
        or not re.fullmatch(HEX, identity)
    ):
        raise ValueError("Invalid stage artifact identity")
    return f"ci-stage-{platform}-{stage}-{identity}"


def reusable(event, own_pr, branch="", release=False):
    return (
        event == "pull_request"
        and type(own_pr) is int
        and own_pr > 0
        and branch != "main"
        and not release
    )


def reusable_native_work(event, own_pr, branch="", release=False):
    """Fresh main validation may retain objects from existing trusted producers."""
    return reusable(event, own_pr, branch, release) or (
        event in ("push", "workflow_dispatch", "schedule")
        and branch == "main"
        and type(own_pr) is int
        and own_pr == 0
    )


def trusted_run(run, repository, own_pr):
    if (
        run.get("path") != WORKFLOW
        or (run.get("head_repository") or {}).get("full_name") != repository
    ):
        return False
    if run.get("event") == "push" and run.get("head_branch") == "main":
        return True
    return run.get("event") == "pull_request" and any(
        pr.get("number") == own_pr for pr in run.get("pull_requests", [])
    )


@timing.phase("native producer qualification")
def trusted_native_work_run(run, repository, own_pr, root=ROOT):
    """Qualify compiler objects from a source-equivalent approved merged PR.

    This does not grant result reuse. Current configure/build/tests still run;
    the payload's original source, recipe, attempt and checksums remain checked.
    """
    if trusted_run(run, repository, own_pr):
        return True
    producer = run.get("head_sha")
    for final in artifacts.final_approval.approved_final_heads(
        repository,
        run,
        workflow=WORKFLOW,
        api=artifacts.api,
        merged_source=artifacts.merged_source,
    ):
        ensure_commit(root, producer)
        ensure_commit(root, final)
        # Use the current approved conservative selector. Receipt verification
        # separately recomputes the original producer's frozen identity recipe.
        if source_inputs(root, "native", producer) == source_inputs(
            root, "native", final
        ):
            return True
    return False


def ensure_commit(root, commit):
    if not re.fullmatch(COMMIT, commit):
        raise ValueError("Invalid producer source commit")
    try:
        git(root, "cat-file", "-e", commit + "^{commit}")
    except subprocess.CalledProcessError:
        subprocess.run(
            ["git", "fetch", "--no-tags", "origin", commit],
            cwd=root,
            check=True,
            timeout=300,
        )
        git(root, "cat-file", "-e", commit + "^{commit}")


@timing.phase("stage receipt validation")
def validate_receipt(
    receipt, platform, stage, identity, run, environment, parents, root
):
    if not isinstance(receipt, dict) or type(receipt.get("schema")) is not int:
        raise ValueError("Invalid receipt schema")
    if (
        receipt.get("schema"),
        receipt.get("platform"),
        receipt.get("stage"),
        receipt.get("identity"),
    ) != (1, platform, stage, identity):
        raise ValueError("Stage receipt identity mismatch")
    if receipt.get("payload_kind", stage) != stage:
        raise ValueError("Runtime-only outputs are not a native compilation cache")
    if receipt.get("environment") != environment or receipt.get("parents") != parents:
        raise ValueError("Stage environment or parent mismatch")
    if not isinstance(receipt.get("sha256"), str) or not re.fullmatch(
        HEX, receipt["sha256"]
    ):
        raise ValueError("Invalid payload checksum")
    if (
        type(receipt.get("source_run_attempt")) is not int
        or receipt["source_run_attempt"] < 1
    ):
        raise ValueError("Invalid producer attempt")
    if receipt.get("reusable", True) is not True:
        raise ValueError("Derived distribution outputs are not reusable stage proofs")
    commit = receipt.get("source_commit")
    if not isinstance(commit, str) or commit != run.get("head_sha"):
        raise ValueError("Receipt source differs from actual workflow producer")
    ensure_commit(root, commit)
    if (
        fingerprint(
            platform,
            stage,
            root,
            commit,
            environment,
            parents,
            recipe=receipt.get("identity_recipe", 1),
        )
        != identity
    ):
        raise ValueError("Producer source fingerprint differs from current recipe")


@timing.phase("stage archive verification and extraction")
def read_zip(path, destination=None):
    """Read exactly the expected two flat regular files, with bounded receipt."""
    with zipfile.ZipFile(path) as stream:
        if sorted(stream.namelist()) != ["identity.json", "payload.tar.gz"]:
            raise ValueError("Unexpected stage artifact members")
        receipt_info = stream.getinfo("identity.json")
        if receipt_info.file_size > MAX_STAGE_RECEIPT_BYTES:
            raise ValueError("Stage receipt too large")
        for entry in stream.infolist():
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG) or entry.is_dir():
                raise ValueError("Stage artifact members must be regular files")
        try:
            receipt = json.loads(stream.read(receipt_info))
        except json.JSONDecodeError as error:
            raise ValueError("Invalid cached stage receipt JSON") from error
        # Do not trust a receipt's checksum without reading the actual payload.
        with stream.open("payload.tar.gz") as payload:
            digest = hashlib.sha256()
            while block := payload.read(1024 * 1024):
                digest.update(block)
            checksum = digest.hexdigest()
        if not isinstance(receipt, dict) or receipt.get("sha256") != checksum:
            raise ValueError("Stage payload checksum mismatch")
        if destination:
            destination.mkdir(parents=True, exist_ok=False)
            for member in ("identity.json", "payload.tar.gz"):
                with (
                    stream.open(member) as source,
                    (destination / member).open("wb") as target,
                ):
                    shutil.copyfileobj(source, target)
        return receipt


@timing.phase("stage result lookup")
def find(
    repository,
    platform,
    stage,
    identity,
    environment,
    parents,
    root=ROOT,
    own_pr=0,
    event="",
    branch="",
    release=False,
    output=None,
):
    """Return verified download/receipt metadata; an ineligible consumer misses."""
    result = {
        "hit": False,
        "identity": identity,
        "artifact_name": name(platform, stage, identity),
    }
    if not reusable(event, own_pr, branch, release):
        return result
    candidates = lookup_api(
        repository, f"actions/artifacts?name={result['artifact_name']}&per_page=100"
    )["artifacts"]
    for artifact in candidates:
        if artifact.get("expired") or artifact.get("name") != result["artifact_name"]:
            continue
        run = lookup_api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
        if not trusted_run(run, repository, own_pr):
            continue
        jobs = lookup_jobs(repository, run["id"])
        # Reject bad job provenance before transferring a potentially large ZIP.
        candidates_jobs = [
            job
            for job in jobs
            if job.get("name", "").split(" / ")[-1] == f"{stage}-{platform}"
            and job.get("conclusion") == "success"
            and artifacts.in_producer_attempt(artifact, job)
        ]
        if not candidates_jobs:
            continue
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "stage.zip"
            try:
                lookup_download(repository, artifact, archive)
                receipt = read_zip(archive)
                validate_receipt(
                    receipt, platform, stage, identity, run, environment, parents, root
                )
                if not any(
                    job.get("run_attempt", 1) == receipt["source_run_attempt"]
                    for job in candidates_jobs
                ):
                    raise ValueError(
                        "Stage payload not from successful producer attempt"
                    )
                if output:
                    read_zip(archive, Path(output))
            except (
                ValueError,
                KeyError,
                zipfile.BadZipFile,
                subprocess.CalledProcessError,
            ):
                continue
        return {
            **result,
            "hit": True,
            "artifact_id": artifact["id"],
            "run_id": run["id"],
            "receipt": receipt,
            **({"download_dir": str(output)} if output else {}),
        }
    return result


def compilation_environment(environment):
    """Bind actual native compiler inputs, separately from validation metadata.

    The former all-role collector recorded Dart/Flutter in native jobs although
    native configure/build/CTest never invokes them. Their versions and locator
    are irrelevant to compiler work. A verified SDK's complete extracted bytes
    bind compatibility more precisely than its bookkeeping identity, which can
    change solely because the SDK fingerprint algorithm migrated.

    The host kernel string does not select compiler inputs inside the pinned
    toolchain; platform/architecture, packages and Apple SDK/Xcode stay bound.
    Pins are tracked source/configuration inputs, not a reason to discard object
    files: changed pins refresh CMake values and rebuild affected targets.

    All actual compiler, SDK bytes/prefix, workspace, system packages, flags,
    locale, and unknown settings remain bound. This is a warm build input, never
    a successful validation result. Original receipts retain every field.
    """
    result = {
        key: value
        for key, value in environment.items()
        if key not in ("utc_validation_date", "dart", "flutter", "system", "pins")
    }
    sdk = result.get("sdk")
    if (
        isinstance(sdk, dict)
        and isinstance(sdk.get("content_sha256"), str)
        and re.fullmatch(HEX, sdk["content_sha256"])
        and isinstance(sdk.get("prefix"), str)
        and Path(sdk["prefix"]).is_absolute()
    ):
        result["sdk"] = {key: value for key, value in sdk.items() if key != "identity"}
    flags = result.get("validation_environment_sha256")
    if isinstance(flags, dict):
        result["validation_environment_sha256"] = {
            key: value
            for key, value in flags.items()
            if key != "FORESIGHT_FLUTTER_EXECUTABLE"
        }
    return result


def changed_configuration(root, producer):
    """Changed CMake defaults must not inherit stale producer cache values."""

    def configuration(inputs):
        return {
            name: value
            for name, value in inputs.items()
            if Path(name).name == "CMakeLists.txt"
            or name.endswith(".cmake")
            or name
            in ("tools/build.sh", "tools/check_build_cache.py", "tools/pins.json")
        }

    before = configuration(source_inputs(root, "native", producer))
    after = configuration(source_inputs(root, "native"))
    return sorted(
        name
        for name in before.keys() | after.keys()
        if before.get(name) != after.get(name)
    )


def native_work_candidates(repository, platform):
    """Find retained full native artifacts, including those with older keys."""
    pattern = rf"ci-stage-{platform}-native-({HEX})"
    page = 1
    while True:
        batch = lookup_api(repository, f"actions/artifacts?per_page=100&page={page}")[
            "artifacts"
        ]
        for artifact in batch:
            match = re.fullmatch(pattern, artifact.get("name", ""))
            if match and not artifact.get("expired"):
                yield artifact, match[1]
        if len(batch) < 100:
            return
        page += 1


@timing.phase("native metadata lookup")
def native_work_metadata(repository, artifact, identity, run, platform, jobs, root):
    """Read a small successful producer receipt before transferring its objects.

    Metadata and full payload must share the exact run/job attempt and source.
    The payload's embedded receipt is compared again after its ZIP and tar
    checksums have been verified. Missing metadata enables bounded legacy reuse;
    malformed metadata is not silently treated as a legacy artifact.
    """
    metadata_name = "receipt-" + artifact["name"]
    page = 1
    found = False
    while True:
        batch = lookup_api(
            repository,
            f"actions/artifacts?name={metadata_name}&per_page=100&page={page}",
        )["artifacts"]
        for metadata in batch:
            if (
                metadata.get("name") != metadata_name
                or metadata.get("expired")
                or metadata.get("workflow_run", {}).get("id") != run["id"]
            ):
                continue
            found = True
            if metadata.get(
                "size_in_bytes", MAX_STAGE_RECEIPT_BYTES * 2 + 1
            ) > MAX_STAGE_RECEIPT_BYTES * 2 or not any(
                artifacts.in_producer_attempt(metadata, job) for job in jobs
            ):
                continue
            with tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / "receipt.zip"
                lookup_download(repository, metadata, archive)
                with zipfile.ZipFile(archive) as stream:
                    if stream.namelist() != ["identity.json"]:
                        raise ValueError("Unexpected native metadata members")
                    info = stream.getinfo("identity.json")
                    if info.file_size > MAX_STAGE_RECEIPT_BYTES or stat.S_IFMT(
                        info.external_attr >> 16
                    ) not in (0, stat.S_IFREG):
                        raise ValueError("Invalid native metadata file")
                    try:
                        receipt = json.loads(stream.read(info))
                    except json.JSONDecodeError as error:
                        raise ValueError(
                            "Invalid cached native metadata JSON"
                        ) from error
            environment = (
                receipt.get("environment") if isinstance(receipt, dict) else None
            )
            validate_receipt(
                receipt, platform, "native", identity, run, environment, {}, root
            )
            if not any(
                job.get("run_attempt", 1) == receipt["source_run_attempt"]
                and artifacts.in_producer_attempt(metadata, job)
                for job in jobs
            ):
                raise ValueError(
                    "Native metadata differs from successful payload attempt"
                )
            return receipt
        if len(batch) < 100:
            if found:
                raise ValueError("No valid native metadata from the payload's producer")
            return None
        page += 1


@timing.phase("native compilation lookup")
def find_native_work(
    repository,
    platform,
    environment,
    root=ROOT,
    own_pr=0,
    event="",
    branch="",
    release=False,
    output=None,
):
    """Restore compatible compilation work without reusing its test result.

    A different source tree is intentional: CMake/Ninja must incrementally build
    current inputs and CTest must run afterwards. The original successful
    producer and its full original receipt are independently verified first.
    """
    if not reusable_native_work(event, own_pr, branch, release):
        return {"hit": False}
    current_environment = compilation_environment(environment)
    current_links = {
        key: value
        for key, value in source_inputs(root, "native").items()
        if value[0] == "120000"
    }
    runs = {}
    qualified_runs = {}
    jobs_by_run = {}
    mismatches: set[str] = set()
    rejected = 0
    legacy_downloads = 0
    for artifact, identity in native_work_candidates(repository, platform):
        run_id = artifact["workflow_run"]["id"]
        if run_id not in runs:
            runs[run_id] = lookup_api(repository, f"actions/runs/{run_id}")
        run = runs[run_id]
        if run_id not in qualified_runs:
            qualified_runs[run_id] = trusted_native_work_run(
                run, repository, own_pr, root
            )
        if not qualified_runs[run_id]:
            continue
        if run_id not in jobs_by_run:
            jobs_by_run[run_id] = lookup_jobs(repository, run_id)
        jobs = [
            job
            for job in jobs_by_run[run_id]
            if job.get("name", "").split(" / ")[-1] == f"native-{platform}"
            and job.get("conclusion") == "success"
            and artifacts.in_producer_attempt(artifact, job)
        ]
        if not jobs:
            continue
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "native.zip"
            try:
                metadata = native_work_metadata(
                    repository, artifact, identity, run, platform, jobs, root
                )
                if metadata is None:
                    if legacy_downloads >= MAX_NATIVE_WORK_DOWNLOADS:
                        fields = (
                            ", ".join(sorted(mismatches))
                            or "invalid original receipts/payloads"
                        )
                        raise RuntimeError(
                            f"Native compilation-work search inspected {legacy_downloads} legacy full artifacts; "
                            f"another trusted successful candidate has no small receipt "
                            f"(artifact {artifact['id']}, run {run_id}). Earlier candidates differed in {fields}. "
                            "The search is incomplete: preserve the artifacts and inspect the "
                            "remaining legacy candidates or publish a verified small receipt. "
                            "Do not start a cold build solely because this transfer budget was reached."
                        )
                    legacy_downloads += 1
                    lookup_download(repository, artifact, archive)
                    receipt = read_zip(archive)
                else:
                    receipt = metadata
                previous_environment = receipt.get("environment")
                if (
                    not isinstance(previous_environment, dict)
                    or compilation_environment(previous_environment)
                    != current_environment
                ):
                    if isinstance(previous_environment, dict):
                        previous_compile = compilation_environment(previous_environment)
                        mismatches.update(
                            key
                            for key in previous_compile.keys()
                            | current_environment.keys()
                            if previous_compile.get(key) != current_environment.get(key)
                        )
                    rejected += 1
                    continue
                validate_receipt(
                    receipt,
                    platform,
                    "native",
                    identity,
                    run,
                    previous_environment,
                    {},
                    root,
                )
                if not any(
                    job.get("run_attempt", 1) == receipt["source_run_attempt"]
                    for job in jobs
                ):
                    raise ValueError("Native compilation not from successful attempt")
                previous_links = {
                    key: value
                    for key, value in source_inputs(
                        root,
                        "native",
                        receipt["source_commit"],
                        recipe=receipt.get("identity_recipe", 1),
                    ).items()
                    if value[0] == "120000"
                }
                # A changed symlink can point to an old-mtime header outside
                # Git's regular-file inventory. Do not warm that ambiguity.
                if previous_links != current_links:
                    rejected += 1
                    continue
                if metadata is not None:
                    lookup_download(repository, artifact, archive)
                    if read_zip(archive) != metadata:
                        raise ValueError(
                            "Native payload receipt differs from verified metadata"
                        )
                if output:
                    read_zip(archive, Path(output))
            except json.JSONDecodeError:
                # A malformed API response is not evidence that compiler work
                # is unavailable. Cached JSON parse failures are wrapped above.
                raise
            except (
                ValueError,
                KeyError,
                zipfile.BadZipFile,
            ):
                rejected += 1
                continue
        return {
            "hit": True,
            "identity": identity,
            "artifact_id": artifact["id"],
            "run_id": run_id,
            "receipt": receipt,
            "configuration_changed": changed_configuration(
                root, receipt["source_commit"]
            ),
            **({"download_dir": str(output)} if output else {}),
        }
    return {
        "hit": False,
        "reason": "No retained verified successful native producer has compatible work",
        "incompatible_environment_fields": sorted(mismatches),
        "rejected_payloads": rejected,
    }


def publish(
    platform,
    stage,
    root,
    environment,
    parents,
    archive,
    output,
    content=None,
    reusable_result=True,
    payload_kind=None,
):
    payload_kind = stage if payload_kind is None else payload_kind
    if payload_kind != stage and (stage, payload_kind) != ("native", "native-runtime"):
        raise ValueError("Unexpected stage payload kind")
    artifact_suffix = "-runtime" if payload_kind == "native-runtime" else ""
    identity = fingerprint(
        platform, stage, root, environment=environment, parents=parents
    )
    commit = git(root, "rev-parse", "HEAD").decode().strip()
    # Only a clean committed input tree has a verifiable producer counterpart.
    if (
        reusable_result
        and fingerprint(platform, stage, root, commit, environment, parents) != identity
    ):
        raise ValueError("Cannot publish outputs with uncommitted stage inputs")
    receipt = {
        "schema": 1,
        "identity_recipe": IDENTITY_RECIPE,
        "platform": platform,
        "stage": stage,
        "identity": identity,
        "source_commit": commit,
        "source_run_attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
        "reusable": reusable_result,
        "payload_kind": payload_kind,
        "environment": environment,
        "parents": parents,
        "sha256": artifacts.digest(archive),
    }
    if content is not None:
        receipt["content"] = content
    output.mkdir(parents=True, exist_ok=True)
    (output / "identity.json").write_text(
        json.dumps(receipt, sort_keys=True, indent=2) + "\n"
    )
    return {
        "identity": identity,
        "artifact_name": name(platform, stage, identity) + artifact_suffix,
        "receipt": receipt,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("key", "probe", "restore", "publish"))
    parser.add_argument("--platform", choices=PLATFORMS, required=True)
    parser.add_argument("--stage", choices=STAGES, required=True)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--ref")
    parser.add_argument("--environment-json", type=json.loads, required=True)
    parser.add_argument("--parents-json", type=json.loads, default={})
    parser.add_argument("--content-json", type=json.loads)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument(
        "--branch",
        default=os.environ.get(
            "GITHUB_HEAD_REF", os.environ.get("GITHUB_REF_NAME", "")
        ),
    )
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    identity = fingerprint(
        args.platform,
        args.stage,
        args.root,
        args.ref,
        args.environment_json,
        args.parents_json,
    )
    result = {
        "identity": identity,
        "artifact_name": name(args.platform, args.stage, identity),
    }
    if args.command in ("probe", "restore"):
        if args.command == "restore" and not args.output:
            parser.error("restore requires --output")
        result = find(
            args.repository,
            args.platform,
            args.stage,
            identity,
            args.environment_json,
            args.parents_json,
            args.root,
            args.own_pr,
            args.event,
            args.branch,
            args.release,
            args.output if args.command == "restore" else None,
        )
    elif args.command == "publish":
        if not args.archive or not args.output:
            parser.error("publish requires --archive and --output")
        result = publish(
            args.platform,
            args.stage,
            args.root,
            args.environment_json,
            args.parents_json,
            args.archive,
            args.output,
            args.content_json,
        )
    print(json.dumps(result, sort_keys=True))
    if destination := os.environ.get("GITHUB_OUTPUT"):
        with open(destination, "a") as stream:
            for key in (
                "identity",
                "artifact_name",
                "hit",
                "artifact_id",
                "run_id",
                "download_dir",
            ):
                if key in result:
                    value = (
                        str(result[key]).lower()
                        if isinstance(result[key], bool)
                        else result[key]
                    )
                    stream.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
