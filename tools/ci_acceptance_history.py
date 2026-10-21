#!/usr/bin/env python3
"""Collect bounded read-only acceptance history for main-only qualification.

This collector cannot authorize normal PR skips. Missing metadata, transport
errors and incomplete API windows fail qualification; an unproven historical
source range is retained as unresolved for the replay to reject.
"""

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.github_job_attempts import canonical_jobs  # noqa: E402

SINCE = "2026-10-12T00:00:00Z"
PHASES = ("cpu-models", "software-gpu", "virtual-audio")
WORKFLOWS = {
    ".github/workflows/" + name
    for name in (
        "macos.yml",
        "integration-acceptance.yml",
        "release-acceptance.yml",
        "release.yml",
        "preview-packages.yml",
        "linux-packages.yml",
        "macos-release.yml",
    )
}
FAILURES = {"failure", "timed_out", "startup_failure"}
MAX_DAYS = 90
MAX_REQUESTS = 6000
MAX_RUNS = 30000
MAX_LOG_BYTES = 32 * 1024 * 1024
MAX_TOTAL_LOG_BYTES = 256 * 1024 * 1024
SHA = re.compile(r"[a-f0-9]{40}")
# Live records stay complete for repository and original-event proof checks.
# Persist only identity/freshness headers: account/URL payloads grow by ~15KB
# per run and would exhaust the authenticated inventory's 64MiB size contract.
RUN_FIELDS = (
    "id",
    "path",
    "event",
    "head_sha",
    "head_branch",
    "created_at",
    "run_attempt",
    "status",
    "conclusion",
    "updated_at",
    "run_started_at",
)


def stamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Acceptance history timestamps require a timezone")
    return parsed.astimezone(timezone.utc)


def formatted(value):
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def job_log(repository, identity):
    result = subprocess.run(
        [
            "gh",
            "api",
            "--allow-escape-sequences",
            f"repos/{repository}/actions/jobs/{identity}/logs",
        ],
        text=True,
        capture_output=True,
        timeout=120,
    )
    if result.returncode:
        raise RuntimeError(
            f"Original acceptance job {identity} log unavailable: {result.stdout}\n{result.stderr}"
        )
    return result.stdout


class Reader:
    def __init__(self, repository, api, log, evidence):
        self.repository, self.api, self.log = repository, api, log
        self.evidence = Path(evidence) if evidence else None
        self.requests = 0
        self.log_bytes = 0
        self.logs = {}
        self.job_cache = {}
        self.references = []

    def count_request(self):
        self.requests += 1
        if self.requests > MAX_REQUESTS:
            raise ValueError(
                "Acceptance history request budget exceeded; refresh the frozen baseline before qualification"
            )

    def get(self, route):
        self.count_request()
        result = self.api(self.repository, route)
        self.retain("api", route, json.dumps(result, sort_keys=True).encode())
        return result

    def retain(self, kind, identity, content):
        digest = hashlib.sha256(content).hexdigest()
        record = {"kind": kind, "identity": str(identity), "sha256": digest}
        if self.evidence:
            target = self.evidence / (digest + (".txt" if kind == "log" else ".json"))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            record["file"] = target.name
        self.references.append(record)
        return record

    def pages(self, route, key, size=100):
        result, page = [], 1
        while True:
            value = self.get(
                f"{route}{'&' if '?' in route else '?'}per_page={size}&page={page}"
            )
            batch = value[key]
            if not isinstance(batch, list):
                raise ValueError("Incomplete acceptance history API response")
            result.extend(batch)
            if len(batch) < size:
                if type(value.get("total_count")) is not int or value[
                    "total_count"
                ] != len(result):
                    raise ValueError("Incomplete acceptance history API page count")
                return result
            if len(result) >= MAX_RUNS:
                raise ValueError(
                    "Acceptance history page budget exceeded; refresh the frozen baseline"
                )
            page += 1

    def runs(self, beginning, end):
        lower = beginning.replace(microsecond=0)
        upper = (
            (end + timedelta(seconds=1)).replace(microsecond=0)
            if end.microsecond
            else end
        )
        route = "actions/runs?" + urlencode(
            {"created": formatted(lower) + ".." + formatted(upper)}
        )
        rows, page = [], 1
        while True:
            value = self.get(f"{route}&per_page=100&page={page}")
            batch = value["workflow_runs"]
            if not isinstance(batch, list):
                raise ValueError("Incomplete acceptance run discovery")
            rows.extend(batch)
            if value.get("total_count", 0) >= 1000 or len(rows) >= 1000:
                if end - beginning <= timedelta(seconds=1):
                    raise ValueError(
                        "Acceptance history exceeds GitHub's 1000-run cap within one second; qualification cannot establish completeness"
                    )
                middle = beginning + (end - beginning) / 2
                return {**self.runs(beginning, middle), **self.runs(middle, end)}
            if len(batch) < 100:
                if (
                    type(value.get("total_count")) is not int
                    or value["total_count"] != len(rows)
                    or len({row["id"] for row in rows}) != len(rows)
                ):
                    raise ValueError("Incomplete acceptance run discovery count")
                return {
                    run["id"]: run
                    for run in rows
                    if beginning <= stamp(run["created_at"]) <= end
                }
            page += 1

    def jobs(self, run):
        if run["id"] not in self.job_cache:
            jobs = self.pages(f"actions/runs/{run['id']}/jobs?filter=all", "jobs", 30)
            for job in jobs:
                if (
                    job.get("run_id") != run["id"]
                    or type(job.get("id")) is not int
                    or job["id"] < 1
                ):
                    raise ValueError("Acceptance job repository/run identity mismatch")
                if job.get("head_sha", run["head_sha"]) != run["head_sha"]:
                    raise ValueError("Acceptance job source differs from its run")
            self.job_cache[run["id"]] = canonical_jobs(
                jobs,
                run,
                lambda attempt: self.get(
                    f"actions/runs/{run['id']}/attempts/{attempt}"
                ),
            )
        return self.job_cache[run["id"]]

    def text(self, job):
        if job["id"] not in self.logs:
            self.count_request()
            value = self.log(self.repository, job["id"])
            if not isinstance(value, str) or len(value.encode()) > MAX_LOG_BYTES:
                raise ValueError(
                    "Original acceptance log exceeds the bounded evidence size; retain a reviewed baseline instead"
                )
            self.log_bytes += len(value.encode())
            if self.log_bytes > MAX_TOTAL_LOG_BYTES:
                raise ValueError(
                    "Acceptance history aggregate log budget exceeded; refresh the frozen baseline before qualification"
                )
            self.retain("log", job["id"], value.encode())
            self.logs[job["id"]] = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", value)
        return self.logs[job["id"]]


def checkout(text):
    match = re.search(
        r"\[command\][^\n]*git log -1 --format=%H\n[^\n]* ([a-f0-9]{40})\s*(?:\n|$)",
        text,
    )
    return match[1] if match else None


def actual_range(reader, run, job, runs):
    target = checkout(reader.text(job)) if job["id"] else run["head_sha"]
    candidates = [run] + [
        other
        for other in runs.values()
        if (
            other["id"] != run["id"]
            and other.get("path") == ".github/workflows/macos.yml"
            and all(
                other.get(key) == run.get(key)
                for key in ("event", "head_sha", "head_branch", "created_at")
            )
            and other.get("head_repository") == run.get("head_repository")
        )
    ]
    for owner in candidates:
        for proof in reader.jobs(owner):
            if (
                proof.get("name", "").split(" / ")[-1] != "changes"
                or proof.get("conclusion") != "success"
                or proof["run_attempt"] != job["run_attempt"]
                # Independent workflow rerun numbers do not identify the
                # same invocation. Borrow only original event invocations.
                or (owner["id"] != run["id"] and job["run_attempt"] != 1)
            ):
                continue
            text = reader.text(proof)
            bases = set(
                re.findall(r"^\S+\s+BASE: ([a-f0-9]{40})\s*$", text, re.MULTILINE)
            )
            original = checkout(text)
            if len(bases) != 1 or not original:
                continue
            if original != run["head_sha"]:
                parents = reader.get(f"git/commits/{original}").get("parents", [])
                if len(parents) != 2 or parents[1].get("sha") != run["head_sha"]:
                    continue
            source = target or original
            if source != run["head_sha"]:
                parents = reader.get(f"git/commits/{source}").get("parents", [])
                if len(parents) != 2 or parents[1].get("sha") != run["head_sha"]:
                    continue
            base = next(iter(bases))
            compared = reader.get(f"compare/{base}...{source}")
            files = compared.get("files")
            merge_base = compared.get("merge_base_commit", {}).get("sha")
            if (
                not isinstance(files, list)
                or len(files) >= 300
                or not SHA.fullmatch(merge_base or "")
            ):
                continue
            if (
                merge_base == source
                or compared.get("base_commit", {}).get("sha") != base
                or compared.get("status") not in ("ahead", "diverged")
            ):
                continue
            paths = sorted(
                {
                    path
                    for item in files
                    for path in (item.get("filename"), item.get("previous_filename"))
                    if path
                }
            )
            if not paths or any(
                not isinstance(path, str)
                or path.startswith("/")
                or ".." in Path(path).parts
                for path in paths
            ):
                continue
            return (
                source,
                paths,
                {
                    "base": base,
                    "head": source,
                    "merge_base": merge_base,
                    "proof_job": proof["id"],
                    "proof_attempt": proof["run_attempt"],
                    "proof_run": owner["id"],
                    "kind": "original-changes-environment"
                    if owner["id"] == run["id"]
                    else "same-event-platform-changes-environment",
                },
            )
    return target or run["head_sha"], [], {"kind": "unresolved-original-range"}


def failure_job(run, job):
    relevant = run["path"] in WORKFLOWS and (
        run["path"] != ".github/workflows/macos.yml"
        or any(word in job.get("name", "").lower() for word in ("acceptance", "audit"))
    )
    return relevant and (
        job.get("conclusion") in FAILURES
        or any(step.get("conclusion") in FAILURES for step in job.get("steps", []))
    )


def entry(reader, run, job, runs):
    steps = [
        step.get("name", "")
        for step in job.get("steps", [])
        if step.get("conclusion") in FAILURES
    ]
    value = {
        "id": f"{run['id']}:{job['run_attempt']}:{job['id']}",
        "run": run["id"],
        "attempt": job["run_attempt"],
        "job": job["id"],
        "event": run["event"],
        "head": run["head_sha"],
        "failed_steps": steps,
        "classification": "conservative-all-phases",
        "classification_reason": "Unknown or prerequisite failures retain all acceptance phases, including packaging and provenance assertions",
        "required_phases": list(PHASES),
    }
    if run["event"] != "pull_request":
        value.update(
            source=run["head_sha"], paths=[], range={"kind": "full-event-backstop"}
        )
        if job["id"]:
            reader.text(job)
    else:
        source, paths, proof = actual_range(reader, run, job, runs)
        value.update(source=source, paths=paths, range=proof)
        if proof["kind"] == "unresolved-original-range":
            value["unresolved"] = True
    value["evidence"] = {
        "job_url": f"https://github.com/{reader.repository}/actions/runs/{run['id']}/job/{job['id']}",
        "original_attempt": job["run_attempt"],
    }
    return value


def startup_entry(reader, run):
    route = f"actions/runs/{run['id']}/attempts/{run['run_attempt']}"
    attempt = reader.get(route)
    if (
        any(
            attempt.get(key) != run.get(key)
            for key in ("id", "head_sha", "run_attempt", "status", "conclusion")
        )
        or attempt.get("status") != "completed"
    ):
        raise ValueError(
            "Original startup attempt does not match its authoritative run"
        )
    if reader.pages(route + "/jobs", "jobs", 30):
        return None
    return {
        "id": f"{run['id']}:{run['run_attempt']}:0",
        "run": run["id"],
        "attempt": run["run_attempt"],
        "job": 0,
        "event": run["event"],
        "head": run["head_sha"],
        "source": run["head_sha"],
        "paths": [],
        "conclusion": "startup_failure",
        "failed_steps": [],
        "classification": "workflow-startup-no-jobs",
        "required_phases": [],
        "range": {"kind": "workflow-startup-no-jobs"},
        "startup_proof": {
            "run": run["id"],
            "attempt": run["run_attempt"],
            "conclusion": "startup_failure",
            "status": "completed",
            "job_count": 0,
            "workflow": run["path"],
        },
    }


def collect(
    baseline,
    *,
    repository,
    until=None,
    baseline_sha256=None,
    verified_observation=None,
    api=artifacts.api,
    log=job_log,
    evidence=None,
):
    """Merge fresh observations without trusting an arbitrary previous file.

    ``verified_observation`` must come from the original successful main-only
    qualification artifact verifier. The CLI obtains it through that verifier;
    it deliberately offers no unverified prior-inventory file argument.
    All run metadata is re-enumerated, including old runs rerun after cutoff.
    Requests include job-log downloads; exhausted budgets fail qualification
    with a baseline-refresh diagnostic instead of claiming complete coverage.
    """
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository or ""):
        raise ValueError("Explicit acceptance history repository required")
    if not re.fullmatch(r"[a-f0-9]{64}", baseline_sha256 or ""):
        raise ValueError(
            "Explicit checksum of the original frozen baseline bytes required"
        )
    if (
        type(baseline.get("schema")) is not int
        or baseline.get("schema") != 1
        or baseline.get("repository") != repository
        or baseline.get("since") != SINCE
        or baseline.get("complete") is not True
    ):
        raise ValueError("Acceptance history requires its complete reviewed baseline")
    beginning, cutoff = stamp(SINCE), stamp(baseline["until"])
    end = stamp(until) if until else datetime.now(timezone.utc)
    if end < cutoff or end - beginning > timedelta(days=MAX_DAYS):
        raise ValueError(
            "Acceptance history cutoff is before its baseline or beyond the 90-day evidence budget; refresh the baseline"
        )
    frozen_failures = {row["id"]: row for row in baseline["failures"]}
    if len(frozen_failures) != len(baseline["failures"]):
        raise ValueError("Frozen baseline has duplicate original failure identities")
    if len({run["id"] for run in baseline["runs"]}) != len(baseline["runs"]):
        raise ValueError("Frozen baseline has duplicate run identities")
    observed = baseline
    if verified_observation is not None:
        observed = verified_observation
        observed_failures = {row["id"]: row for row in observed["failures"]}
        observed_runs = {row["id"]: row for row in observed["runs"]}
        if (
            type(observed.get("schema")) is not int
            or observed.get("schema") != 1
            or observed.get("repository") != repository
            or observed.get("since") != SINCE
            or observed.get("complete") is not True
            or observed.get("baseline_sha256") != baseline_sha256
            or observed.get("baseline_count") != len(frozen_failures)
            or not cutoff <= stamp(observed["until"]) <= end
            or len(observed_failures) != len(observed["failures"])
            or any(
                observed_failures.get(key) != row
                for key, row in frozen_failures.items()
            )
            or {row["id"] for row in baseline["runs"]}
            - {row["id"] for row in observed["runs"]}
            or any(
                any(
                    row.get(key) != observed_runs.get(row["id"], {}).get(key)
                    for key in ("path", "event", "head_sha", "head_branch")
                )
                for row in baseline["runs"]
            )
        ):
            raise ValueError(
                "Verified acceptance observation does not preserve its frozen baseline"
            )
    reader = Reader(repository, api, log, evidence)
    runs = {}
    window = beginning
    while window < end:
        boundary = min(window + timedelta(days=1), end)
        runs.update(reader.runs(window, boundary))
        if len(runs) > MAX_RUNS:
            raise ValueError(
                "Acceptance history run budget exceeded; refresh the frozen baseline"
            )
        window = boundary
    previous = {run["id"]: run for run in observed["runs"]}
    if len(previous) != len(observed["runs"]):
        raise ValueError("Frozen baseline has duplicate run identities")
    if set(previous) - set(runs):
        raise ValueError(
            "Frozen baseline runs disappeared from live history; completeness cannot be established"
        )
    failures = {row["id"]: dict(row) for row in observed["failures"]}
    changed = []
    for run in runs.values():
        if run.get("path") not in WORKFLOWS:
            continue
        if run.get("repository", {}).get(
            "full_name"
        ) != repository or not SHA.fullmatch(run.get("head_sha", "")):
            raise ValueError("Acceptance run repository/source mismatch")
        old = previous.get(run["id"])
        if old and any(
            run.get(key) != old.get(key)
            for key in ("path", "event", "head_sha", "head_branch")
        ):
            raise ValueError(
                "Original acceptance run identity changed after its baseline"
            )
        if (
            old
            and run.get("status") == "completed"
            and all(
                run.get(key) == old.get(key)
                for key in ("run_attempt", "status", "conclusion")
            )
            and all(
                run.get(key) == old.get(key)
                for key in ("updated_at", "run_started_at")
                if key in old
            )
        ):
            continue
        changed.append(run["id"])
        jobs = reader.jobs(run)
        for job in jobs:
            if failure_job(run, job):
                identity = f"{run['id']}:{job['run_attempt']}:{job['id']}"
                if identity not in failures:
                    row = entry(reader, run, job, runs)
                    failures[row["id"]] = row
        if run.get("conclusion") == "startup_failure":
            identity = f"{run['id']}:{run['run_attempt']}:0"
            if identity not in failures:
                row = startup_entry(reader, run)
                if row is not None:
                    failures[row["id"]] = row
    return {
        "schema": 1,
        "repository": repository,
        "since": SINCE,
        "until": end.isoformat().replace("+00:00", "Z"),
        "complete": True,
        "baseline_sha256": baseline_sha256,
        "baseline_count": len(baseline["failures"]),
        "runs": [
            {key: run[key] for key in RUN_FIELDS if key in run}
            for run in sorted(runs.values(), key=lambda run: run["id"])
        ],
        "failures": list(sorted(failures.values(), key=lambda row: row["id"])),
        "diagnostics": {
            "requests": reader.requests,
            "log_bytes": reader.log_bytes,
            "changed_runs": sorted(changed),
            "observation_until": observed["until"],
            "evidence": reader.references,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--baseline-sha256", required=True)
    parser.add_argument("--until")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    raw = args.baseline.read_bytes()
    if hashlib.sha256(raw).hexdigest() != args.baseline_sha256:
        raise ValueError("Frozen acceptance baseline checksum mismatch")
    from tools.ci_acceptance_observations import load

    baseline = json.loads(raw)
    observation = load(
        baseline["repository"], args.baseline_sha256, baseline, args.until
    )
    result = collect(
        baseline,
        repository=baseline["repository"],
        until=args.until,
        baseline_sha256=args.baseline_sha256,
        verified_observation=observation,
        evidence=args.evidence,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
