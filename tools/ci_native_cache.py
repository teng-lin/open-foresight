#!/usr/bin/env python3
"""Retained compiler lookup/identity, independent of cached test results.

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

import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

evidence_job_name = importlib.import_module(
    "tools.ci_producer_trust" if __package__ else "ci_producer_trust"
).evidence_job_name

artifacts = importlib.import_module(
    "tools.ci_artifacts" if __package__ else "ci_artifacts"
)

timing = importlib.import_module("tools.ci_timing" if __package__ else "ci_timing")

ci_git = importlib.import_module("tools.ci_git" if __package__ else "ci_git")
git = ci_git.git
ensure_commit = ci_git.ensure_commit
read_zip = ci_git.read_zip

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
MAX_NATIVE_WORK_PRODUCER_ERRORS = 3
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
            if key
            not in (
                "FORESIGHT_FLUTTER_EXECUTABLE",
                "FORESIGHT_CORE_COVERAGE_BENCHMARK",
                # These control subsequent Dart gates or scheduling/reporting,
                # never native configure flags. Results still bind all of them.
                "FORESIGHT_COVERAGE",
                "FORESIGHT_CORE_COVERAGE_MIN",
                "FORESIGHT_DESKTOP_COVERAGE_MIN",
                "FORESIGHT_PARALLEL_GATES",
                "FORESIGHT_REQUIRE_DART_GATES",
                "FORESIGHT_BUILD_JOBS",
                "FORESIGHT_STAGE_ENVIRONMENT",
            )
        }
    validation_flags = result.get("validation_flags")
    if isinstance(validation_flags, dict):
        result["validation_flags"] = {
            key: value
            for key, value in validation_flags.items()
            if key
            not in (
                "FORESIGHT_COVERAGE",
                "FORESIGHT_CORE_COVERAGE_MIN",
                "FORESIGHT_DESKTOP_COVERAGE_MIN",
            )
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


def native_work_producers(repository, platform, own_pr, root):
    """Try independent producers after exhausted server errors, never cold build.

    A failed producer lookup is unresolved, not incompatible. Another producer
    may still be completely verified; if none supplies compatible work, rethrow
    the original failure when this iterator is exhausted.
    """
    runs = {}
    qualified_runs = {}
    jobs_by_run = {}
    failed_runs = {}
    for artifact, identity in native_work_candidates(repository, platform):
        run_id = artifact["workflow_run"]["id"]
        if run_id in failed_runs:
            continue
        try:
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
        except subprocess.CalledProcessError as error:
            diagnostic = error.stderr or b""
            if isinstance(diagnostic, bytes):
                diagnostic = diagnostic.decode("utf-8", errors="replace")
            if not re.search(r"\bHTTP 5\d\d\b", diagnostic):
                raise
            failed_runs[run_id] = error
            print(
                f"GitHub producer lookup failed for run {run_id}: {diagnostic.strip()}; "
                "checking other retained producers. An unresolved lookup cannot authorize a cold build.",
                file=sys.stderr,
            )
            if len(failed_runs) >= MAX_NATIVE_WORK_PRODUCER_ERRORS:
                raise
            continue
        jobs = [
            job
            for job in jobs_by_run[run_id]
            if evidence_job_name(job).split(" / ")[-1] == f"native-{platform}"
            and job.get("conclusion") == "success"
            and artifacts.in_producer_attempt(artifact, job)
        ]
        if jobs:
            yield artifact, identity, run, jobs
    if failed_runs:
        raise next(iter(failed_runs.values()))


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
    mismatches: set[str] = set()
    rejected = 0
    legacy_downloads = 0
    for artifact, identity, run, jobs in native_work_producers(
        repository, platform, own_pr, root
    ):
        run_id = run["id"]
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
