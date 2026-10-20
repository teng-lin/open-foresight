#!/usr/bin/env python3
"""Verify fully tested release candidates; the receipt is an API-checked index."""

import argparse
import base64
from datetime import datetime, timezone
import json
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.app_version import PUBSPEC, SOURCE  # noqa: E402
from tools.ci_producer_trust import PRODUCERS  # noqa: E402
from tools.github_job_attempts import canonical_jobs  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "tools/release_candidate_policy.json"
COMMIT = re.compile(r"[a-f0-9]{40}")
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")
COMPONENTS = ("linux-app", "macos-app")
# These are required jobs, not optional dependency/cache or comparison jobs.
GATES = (
    "linux-build",
    "macos",
    "linux-test",
    "acceptance-cpu",
    "acceptance-audio",
    "acceptance-deb",
    "linux-document-imports",
    "workflow-lint",
    "acceptance-checks",
    "platform-checks",
    "packaging / linux-deb",
    "packaging / linux-rpm",
    "packaging / linux-arch",
    "packaging / dmg",
    "sanitizers / native-sanitizers",
    "sanitizers / thread-policy",
    "sanitizers / native-thread-sanitizer",
)
CONSUMERS = ("linux-test", "acceptance-cpu", "acceptance-audio", "acceptance-deb")
api = artifacts.api


def utc_now():
    return datetime.now(timezone.utc)


def positive(value):
    return type(value) is int and value > 0


def checksum(value):
    if isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value):
        value = "sha256:" + value
    if not isinstance(value, str) or not DIGEST.fullmatch(value):
        raise ValueError("Missing verified artifact SHA256")
    return value


def ancestor(repository, older, newer):
    return api(repository, f"compare/{older}...{newer}")["status"] in (
        "ahead",
        "identical",
    )


def source_policy(repository, source, control, *, floor=None, now=None, policy=None):
    floor = os.environ.get("RELEASE_SOURCE_FLOOR", "") if floor is None else floor
    policy = json.loads(POLICY.read_text()) if policy is None else policy
    if (
        policy.get("schema") != 1
        or type(policy.get("schema")) is not int
        or not all(
            isinstance(value, str) and COMMIT.fullmatch(value)
            for value in (source, control, floor)
        )
        or policy.get("expected_source_floor", "") not in ("", floor)
    ):
        raise ValueError(
            "Configure the reviewed WS5b-1 merge SHA as RELEASE_SOURCE_FLOOR; it must match the recorded policy"
        )
    if not ancestor(repository, floor, control) or not ancestor(
        repository, source, control
    ):
        raise ValueError(
            "Release source and floor must be reachable from reviewed main"
        )
    if ancestor(repository, floor, source):
        return "release"
    try:
        expiry = datetime.fromisoformat(
            policy["legacy_expires_at"].replace("Z", "+00:00")
        )
        current = now or utc_now()
        if expiry.tzinfo is None or current >= expiry:
            raise ValueError(
                "Legacy below-floor release transition has expired; use a source at or above RELEASE_SOURCE_FLOOR"
            )
    except (KeyError, TypeError) as error:
        raise ValueError(
            "Legacy transition needs an explicit schema-1 expiry"
        ) from error
    return "legacy"


def pages(repository, route, key, *, page_size=100):
    result = []
    page = 1
    while True:
        batch = api(
            repository,
            f"{route}{'&' if '?' in route else '?'}per_page={page_size}&page={page}",
        )[key]
        result.extend(batch)
        if len(batch) < page_size:
            return result
        page += 1


def original_jobs(repository, run):
    # Large all-attempt job pages can time out; retain every complete row while
    # bounding each response, including historical original producer attempts.
    jobs = pages(
        repository, f"actions/runs/{run['id']}/jobs?filter=all", "jobs", page_size=30
    )
    return canonical_jobs(
        jobs,
        run,
        lambda attempt: api(repository, f"actions/runs/{run['id']}/attempts/{attempt}"),
    )


def latest(jobs, name):
    matches = [job for job in jobs if job.get("name") == name]
    if not matches or any(not positive(job.get("run_attempt")) for job in matches):
        raise ValueError(f"Missing original job/attempt: {name}")
    attempt = max(job["run_attempt"] for job in matches)
    selected = [job for job in matches if job["run_attempt"] == attempt]
    if (
        len(selected) != 1
        or selected[0].get("conclusion") != "success"
        or selected[0].get("status") != "completed"
        or not positive(selected[0].get("id"))
    ):
        raise ValueError(f"Latest required job must succeed: {name}")
    return selected[0]


def read_json(repository, artifact, member):
    if artifact.get("expired") or artifact.get("size_in_bytes", 65537) > 65536:
        raise ValueError("Candidate evidence must be a live small original artifact")
    checksum(artifact.get("digest"))
    with tempfile.TemporaryDirectory(prefix="release-candidate-index-") as directory:
        archive = Path(directory) / "evidence.zip"
        artifacts.download_zip(repository, artifact, archive)
        with zipfile.ZipFile(archive) as bundle:
            if (
                bundle.namelist() != [member]
                or bundle.getinfo(member).file_size > 65536
            ):
                raise ValueError("Unexpected candidate evidence archive members")
            record = json.loads(bundle.read(member))
    if not isinstance(record, dict):
        raise ValueError("Candidate evidence must be an object")
    return record


class CandidateArtifactsUnavailable(ValueError):
    """Original artifacts are absent or expired; no bytes may be reused."""


def original(items, name, run, job):
    live = [
        item for item in items if item.get("name") == name and not item.get("expired")
    ]
    if not live:
        raise CandidateArtifactsUnavailable(
            f"Missing or expired original upload for {name}"
        )
    selected = [
        item
        for item in items
        if item.get("name") == name
        and not item.get("expired")
        and item.get("workflow_run", {}).get("id") == run["id"]
        and artifacts.in_producer_attempt(item, job)
    ]
    if len(selected) != 1:
        raise ValueError(f"Missing unambiguous original upload for {name}")
    checksum(selected[0].get("digest"))
    return selected[0]


def release_controller(repository, run):
    """Discovery names are public; only the API producer scope can be trusted."""
    return (
        PRODUCERS["release-candidate"].matches_run(run)
        and (run.get("head_repository") or {}).get("full_name") == repository
        and run.get("head_branch") == "main"
    )


def run_identity(repository, run, *, current_run=0):
    if (
        not release_controller(repository, run)
        or not positive(run.get("id"))
        or not positive(run.get("run_attempt"))
        or not isinstance(run.get("head_sha"), str)
        or not COMMIT.fullmatch(run["head_sha"])
        or (run["id"] != current_run and run.get("status") != "completed")
    ):
        raise ValueError(
            "Candidate must come from a completed reviewed-main release controller"
        )


def component_record(
    repository, source, component, run, jobs, items, *, consumer="release-candidate"
):
    job = latest(jobs, PRODUCERS[consumer].jobs[component][0])
    payload = original(items, artifacts.name(component, source), run, job)
    sidecars = [
        item
        for item in items
        if item.get("name") == artifacts.receipt_name(component, source)
        and not item.get("expired")
    ]
    if sidecars or consumer != "legacy-release-candidate":
        sidecar = original(items, artifacts.receipt_name(component, source), run, job)
        record = read_json(repository, sidecar, "receipt.json")
        receipt = record.get("source_receipt", {})
        if (
            type(record.get("schema")) is not int
            or record.get("schema") != 1
            or record.get("component") != component
            or record.get("identity") != source
            or record.get("artifact_id") != payload["id"]
            or record.get("artifact_digest") != payload["digest"]
        ):
            raise ValueError("Candidate sidecar does not bind its original payload")
    else:
        # The below-floor transition retains byte verification for old payloads
        # that predate sidecars. Never execute or relabel their source code.
        with tempfile.TemporaryDirectory(
            prefix="legacy-release-candidate-"
        ) as directory:
            archive = Path(directory) / "original.zip"
            artifacts.download_zip(repository, payload, archive)
            with zipfile.ZipFile(archive) as bundle:
                if (
                    set(bundle.namelist()) != {"identity.json", "payload.tar.gz"}
                    or len(bundle.namelist()) != 2
                ):
                    raise ValueError("Unexpected legacy candidate archive members")
                receipt = json.loads(bundle.read("identity.json"))
                digest = hashlib.sha256()
                with bundle.open("payload.tar.gz") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                if receipt.get("sha256") != digest.hexdigest():
                    raise ValueError("Legacy candidate payload checksum mismatch")
    legacy = consumer == "legacy-release-candidate"
    if (
        not artifacts.valid_receipt(receipt, component, source)
        or not PRODUCERS[consumer].matches_receipt(receipt)
        or receipt.get("label") not in ((None, "") if legacy else ("",))
        or (legacy and receipt.get("tier") is not None)
        or receipt.get("source_commit") != source
        or receipt["source_run_attempt"] != job["run_attempt"]
    ):
        raise ValueError(
            f"Untested, preview or mismatched {component} original receipt"
        )
    distribution = receipt.get("distribution", {})
    if (
        not isinstance(distribution, dict)
        or not isinstance(distribution.get("version"), str)
        or not re.fullmatch(r"\d+\.\d+\.\d+", distribution["version"])
        or not positive(distribution.get("build_number"))
    ):
        raise ValueError("Candidate has no stamped distribution identity")
    return {
        "artifact_id": payload["id"],
        "artifact_digest": payload["digest"],
        "payload_sha256": receipt["sha256"],
        "job_id": job["id"],
        "run_attempt": job["run_attempt"],
        "distribution": distribution,
    }


def gate_records(jobs):
    return {
        name: {
            "job_id": (job := latest(jobs, "candidates / " + name))["id"],
            "run_attempt": job["run_attempt"],
        }
        for name in GATES
    }


def require_original_uploads(source, run, jobs, items):
    # Check all live metadata before permitting an expiry rebuild. An earlier
    # missing upload cannot hide a later ambiguous/wrong-attempt live upload.
    expected: list[tuple[str, dict]] = []
    for component in COMPONENTS:
        job = latest(jobs, PRODUCERS["release-candidate"].jobs[component][0])
        expected.extend(
            (name, job)
            for name in (
                artifacts.name(component, source),
                artifacts.receipt_name(component, source),
            )
        )
    expected.extend(
        (f"ci-release-input-{name}-{source}", latest(jobs, "candidates / " + name))
        for name in CONSUMERS
    )
    unavailable = []
    for name, job in expected:
        try:
            original(items, name, run, job)
        except CandidateArtifactsUnavailable as error:
            unavailable.append(str(error))
    if unavailable:
        raise CandidateArtifactsUnavailable("; ".join(unavailable))


def collect(
    repository, source, run, *, floor, receipt_attempt, outputs=None, current_run=0
):
    run_identity(repository, run, current_run=current_run)
    if source_policy(repository, source, run["head_sha"], floor=floor) != "release":
        raise ValueError("A tested release receipt cannot promote a below-floor source")
    jobs = original_jobs(repository, run)
    items = pages(repository, f"actions/runs/{run['id']}/artifacts", "artifacts")
    gates = gate_records(jobs)
    require_original_uploads(source, run, jobs, items)
    components = {
        name: component_record(repository, source, name, run, jobs, items)
        for name in COMPONENTS
    }
    if (
        components["linux-app"]["distribution"]
        != components["macos-app"]["distribution"]
    ):
        raise ValueError("Platform candidates have different stamped identities")
    distribution = components["linux-app"]["distribution"]
    version, minimum = source_version(repository, source)
    if distribution["version"] != version or distribution["build_number"] < minimum:
        raise ValueError("Candidate distribution differs from immutable source version")
    if outputs is not None and (
        outputs.get("source") != source
        or outputs.get("version") != distribution["version"]
        or str(outputs.get("build_number")) != str(distribution["build_number"])
    ):
        raise ValueError(
            "Candidate outputs differ from immutable source/build identity"
        )
    for component, platform in (("linux-app", "linux"), ("macos-app", "macos")):
        if outputs is not None and (
            str(components[component]["artifact_id"])
            != str(outputs.get(f"{platform}_bundle_id"))
            or components[component]["artifact_digest"]
            != checksum(outputs.get(f"{platform}_bundle_digest"))
            or str(components[component]["run_attempt"])
            != str(outputs.get(f"{platform}_bundle_attempt"))
        ):
            raise ValueError("Candidate outputs differ from original verified uploads")
    consumed = {}
    for name in CONSUMERS:
        job = latest(jobs, "candidates / " + name)
        item = original(items, f"ci-release-input-{name}-{source}", run, job)
        record = read_json(repository, item, "consumption.json")
        linux = components["linux-app"]
        expected = {
            "schema": 1,
            "source": source,
            "component": "linux-app",
            "artifact_id": linux["artifact_id"],
            "artifact_digest": linux["artifact_digest"],
            "payload_sha256": linux["payload_sha256"],
            "source_run_attempt": linux["run_attempt"],
            "consumer_run_id": run["id"],
            "consumer_run_attempt": job["run_attempt"],
        }
        if json.dumps(record, sort_keys=True) != json.dumps(expected, sort_keys=True):
            raise ValueError(
                f"{name} did not consume the stamped Linux candidate bytes"
            )
        consumed[name] = {
            "artifact_id": item["id"],
            "artifact_digest": item["digest"],
            **gates[name],
        }
    return {
        "schema": 1,
        "tested": True,
        "tier": "release",
        "label": "",
        "source": source,
        "source_floor": floor,
        "run_id": run["id"],
        "run_attempt": receipt_attempt,
        "components": components,
        "gates": gates,
        "consumption": consumed,
    }


def verify(repository, source, run_id, *, floor=None, current_run=0):
    floor = os.environ.get("RELEASE_SOURCE_FLOOR", "") if floor is None else floor
    if (
        not positive(run_id)
        or not isinstance(source, str)
        or not COMMIT.fullmatch(source)
    ):
        raise ValueError("Candidate source/run must be immutable positive identifiers")
    run = api(repository, f"actions/runs/{run_id}")
    run_identity(repository, run, current_run=current_run)
    jobs = original_jobs(repository, run)
    receipt_job = latest(jobs, PRODUCERS["release-candidate-receipt"].jobs[""][0])
    items = pages(repository, f"actions/runs/{run_id}/artifacts", "artifacts")
    item = original(items, f"ci-release-candidate-{source}", run, receipt_job)
    record = read_json(repository, item, "release-candidate.json")
    header = {
        "schema": 1,
        "tested": True,
        "tier": "release",
        "label": "",
        "source": source,
        "source_floor": floor,
        "run_id": run["id"],
        "run_attempt": receipt_job["run_attempt"],
        "gates": gate_records(jobs),
    }
    if json.dumps(
        {key: record.get(key) for key in header}, sort_keys=True
    ) != json.dumps(header, sort_keys=True):
        raise ValueError(
            "Candidate index differs from required source, tier, original receipt job or latest gates"
        )
    expected = collect(
        repository,
        source,
        run,
        floor=floor,
        receipt_attempt=receipt_job["run_attempt"],
        current_run=current_run,
    )
    if (
        type(record.get("schema")) is not int
        or record.get("tested") is not True
        or json.dumps(record, sort_keys=True) != json.dumps(expected, sort_keys=True)
    ):
        raise ValueError(
            "Candidate index differs from current original producers, checksums or latest required gates; rerun candidate-receipt after affected gates succeed"
        )
    return record


def find(repository, source, run_id=0, *, floor=None, current_run=0):
    if (
        type(run_id) is not int
        or run_id < 0
        or not isinstance(source, str)
        or not COMMIT.fullmatch(source)
    ):
        raise ValueError("Invalid candidate discovery identifiers")
    result = []
    for item in pages(
        repository, f"actions/artifacts?name=ci-release-candidate-{source}", "artifacts"
    ):
        producer = item.get("workflow_run", {}).get("id")
        if item.get("expired") or item.get("name") != f"ci-release-candidate-{source}":
            continue
        if not positive(producer):
            result.append("Existing candidate index has no valid original producer run")
            continue
        if run_id and producer != run_id:
            continue
        run = api(repository, f"actions/runs/{producer}")
        if not release_controller(repository, run):
            # PRs can upload the same public name. Ignore those bytes entirely;
            # malformed evidence from actual release controllers still fails
            # closed in verify(), including unfinished or failed original jobs.
            continue
        try:
            return verify(
                repository, source, producer, floor=floor, current_run=current_run
            )
        except json.JSONDecodeError:
            raise
        except CandidateArtifactsUnavailable as error:
            if run_id:
                result.append(f"Original candidate run {producer}: {error}")
            else:
                print(
                    f"Original candidate run {producer} not reusable: {error}; a fresh fully gated build is permitted",
                    file=sys.stderr,
                )
            # Expiry or a content-addressed miss may require one fresh build.
            # All new outputs must still pass the complete release gates.
        except ValueError as error:
            result.append(f"Original candidate run {producer}: {error}")
    if run_id:
        raise ValueError(
            "Requested fully tested release candidate is unavailable: "
            + "; ".join(result)
        )
    if result:
        raise ValueError(
            "Existing tested candidate evidence failed verification; preserve its "
            "compiled outputs and repair the original evidence or rerun only the "
            "failed gate/receipt instead of rebuilding candidates: " + "; ".join(result)
        )
    return None


def source_version(repository, source):
    record = api(repository, f"contents/{PUBSPEC}?ref={source}")
    if record.get("encoding") != "base64":
        raise ValueError("Cannot verify immutable source version")
    match = SOURCE.search(
        base64.b64decode("".join(record["content"].split()), validate=True).decode()
    )
    if not match:
        raise ValueError("Candidate source must declare a stable version")
    return match[1], int(match[2])


def preflight(
    repository,
    control,
    *,
    ref,
    tag="",
    source="",
    candidate_run=0,
    candidates_only=False,
    publish_only=False,
    floor=None,
):
    if (
        ref != "refs/heads/main"
        or (candidates_only and publish_only)
        or candidate_run < 0
    ):
        raise ValueError("Release preflight requires main and one valid mode")
    if (tag and not re.fullmatch(r"v\d+\.\d+\.\d+", tag)) or (
        not candidates_only and not tag
    ):
        raise ValueError(
            "A normal release requires an administrator-created stable tag"
        )
    if tag:
        from tools.prepare_release import release_source

        resolved = release_source(repository, tag, control)
        if source and source != resolved:
            raise ValueError(
                "Explicit product source differs from immutable release tag"
            )
        source = resolved
    source = source or control
    mode = source_policy(repository, source, control, floor=floor)
    version, minimum = source_version(repository, source)
    if mode == "legacy":
        if candidates_only:
            raise ValueError(
                "Below-floor sources use the expiring legacy release path; candidates_only requires the new source capabilities"
            )
        from tools.prepare_release import legacy_candidate_runs

        runs = legacy_candidate_runs(
            repository,
            source,
            candidate_run or None,
            consumer="legacy-release-candidate",
        )
        if set(runs) != set(COMPONENTS):
            raise ValueError(
                "Below-floor release needs both existing verified legacy platform candidates; do not rebuild unsupported source"
            )
        verified_evidence(repository, source, runs, floor=floor)
        found = None
    else:
        found = find(repository, source, candidate_run, floor=floor)
        runs = {name: found["run_id"] for name in COMPONENTS} if found else {}
        if publish_only and not found:
            raise ValueError(
                "publish_only requires existing verified tested candidates and schedules no producers"
            )
    return {
        "source": source,
        "mode": mode,
        "reuse": str(bool(runs)).lower(),
        "candidate_run": str(found["run_id"] if found else candidate_run),
        "linux_candidate_run": str(runs.get("linux-app", 0)),
        "macos_candidate_run": str(runs.get("macos-app", 0)),
        "version": version,
        "source_floor": floor or os.environ.get("RELEASE_SOURCE_FLOOR", ""),
    }


def legacy_component(repository, source, run_id, component):
    require_legacy(repository, source)
    run = api(repository, f"actions/runs/{run_id}")
    if (
        not artifacts.trusted_run(
            run, component, repository=repository, consumer="legacy-release-candidate"
        )
        or run.get("head_sha") != source
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
    ):
        raise ValueError(
            "Legacy evidence requires original green reviewed-main push producers"
        )
    jobs = original_jobs(repository, run)
    items = pages(repository, f"actions/runs/{run_id}/artifacts", "artifacts")
    record = component_record(
        repository,
        source,
        component,
        run,
        jobs,
        items,
        consumer="legacy-release-candidate",
    )
    version, minimum = source_version(repository, source)
    if (
        record["distribution"]["version"] != version
        or record["distribution"]["build_number"] < minimum
    ):
        raise ValueError(
            "Legacy candidate distribution differs from immutable source version"
        )
    return record


def verified_evidence(repository, source, platform_runs, *, floor=None, current_run=0):
    """Shared T5 adapter; the expiring legacy exception remains explicit."""
    floor = os.environ.get("RELEASE_SOURCE_FLOOR", "") if floor is None else floor
    control = api(repository, "commits/main")["sha"]
    mode = source_policy(repository, source, control, floor=floor)
    if set(platform_runs) != set(COMPONENTS) or any(
        not positive(run) for run in platform_runs.values()
    ):
        raise ValueError("Evidence requires both original platform producer runs")
    if mode == "release":
        if len(set(platform_runs.values())) != 1:
            raise ValueError(
                "Release platforms must share one fully tested candidate index"
            )
        record = verify(
            repository,
            source,
            platform_runs["linux-app"],
            floor=floor,
            current_run=current_run,
        )
        return {
            "schema": 1,
            "mode": mode,
            "source": source,
            "source_floor": floor,
            "candidate_runs": platform_runs,
            "components": record["components"],
            "index": record,
        }
    components = {
        component: legacy_component(repository, source, run_id, component)
        for component, run_id in platform_runs.items()
    }
    if (
        components["linux-app"]["distribution"]
        != components["macos-app"]["distribution"]
    ):
        raise ValueError("Legacy platform distribution identities differ")
    return {
        "schema": 1,
        "mode": mode,
        "source": source,
        "source_floor": floor,
        "candidate_runs": platform_runs,
        "components": components,
        "legacy_expires_at": json.loads(POLICY.read_text())["legacy_expires_at"],
    }


def require_legacy(repository, source):
    control = api(repository, "commits/main")["sha"]
    if source_policy(repository, source, control) != "legacy":
        raise ValueError(
            "Legacy candidate acceptance is restricted to an unexpired below-floor source"
        )


def authorize(repository, source, run_id, component):
    """Only packaging consumers may select the expiring below-floor exception."""
    control = api(repository, "commits/main")["sha"]
    mode = source_policy(repository, source, control)
    if mode == "legacy":
        legacy_component(repository, source, run_id, component)
        return "legacy-release-candidate"
    verify(
        repository,
        source,
        run_id,
        current_run=int(os.environ.get("GITHUB_RUN_ID", "0")),
    )
    return "release-candidate"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "receipt", "evidence"))
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--source", default="")
    parser.add_argument("--tag", default="")
    parser.add_argument("--candidate-run", type=int, default=0)
    parser.add_argument("--candidates-only", action="store_true")
    parser.add_argument("--publish-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "preflight":
        values = preflight(
            args.repository,
            os.environ["GITHUB_SHA"],
            ref=os.environ.get("GITHUB_REF", ""),
            tag=args.tag,
            source=args.source,
            candidate_run=args.candidate_run,
            candidates_only=args.candidates_only,
            publish_only=args.publish_only,
        )
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write("".join(f"{key}={value}\n" for key, value in values.items()))
    elif args.command == "evidence":
        if args.output is None:
            parser.error("evidence requires --output")
        values = preflight(
            args.repository,
            os.environ["GITHUB_SHA"],
            ref=os.environ.get("GITHUB_REF", ""),
            tag=args.tag,
            source=args.source,
            candidate_run=args.candidate_run,
            candidates_only=args.candidates_only,
        )
        if values["reuse"] != "true":
            raise ValueError(
                "Evidence forwarding requires an existing verified original"
            )
        record = {
            "schema": 1,
            "mode": values["mode"],
            "source": values["source"],
            "original_runs": {
                component: int(values[f"{platform}_candidate_run"])
                for component, platform in (
                    ("linux-app", "linux"),
                    ("macos-app", "macos"),
                )
            },
        }
        if values["mode"] == "release":
            record["original_candidate"] = verify(
                args.repository, values["source"], int(values["candidate_run"])
            )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(record, indent=2) + "\n")
    else:
        if args.output is None:
            parser.error("receipt requires --output")
        run_id = int(os.environ["GITHUB_RUN_ID"])
        record = collect(
            args.repository,
            args.source,
            api(args.repository, f"actions/runs/{run_id}"),
            floor=os.environ.get("RELEASE_SOURCE_FLOOR", ""),
            receipt_attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]),
            outputs=json.loads(os.environ["CANDIDATE_OUTPUTS"]),
            current_run=run_id,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
