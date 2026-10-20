#!/usr/bin/env python3
"""Discover missing main cache keys without running SDK or language warmers.

API presence is scheduling evidence only. Consumers still verify restored SDK
and model bytes; this reconciler never reports a verified consumer cache hit.
"""

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import api  # noqa: E402

WORKFLOW = ".github/workflows/linux-cache-publish.yml"


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Registry publisher lacks an authoritative timestamp")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("Invalid registry publisher timestamp") from error
    if result.tzinfo is None:
        raise ValueError("Registry publisher timestamp needs a timezone")
    return result


def paginated(repository, route, key, fetch):
    page = 1
    while True:
        batch = fetch(repository, f"{route}&per_page=100&page={page}")[key]
        if not isinstance(batch, list):
            raise ValueError("Invalid registry publisher discovery response")
        yield from batch
        if len(batch) < 100:
            return
        page += 1


def registry_schedule(repository, source, *, fetch=api, now=None, current_run=None):
    """Schedule bounded maintenance from actual publisher jobs, never bytes."""
    records = []
    query = urlencode(
        {"event": "workflow_dispatch", "branch": "main", "head_sha": source}
    )
    route = f"actions/workflows/linux-cache-publish.yml/runs?{query}"
    for run in paginated(repository, route, "workflow_runs", fetch):
        if (
            type(run.get("id")) is not int
            or run["id"] < 1
            or run["id"] == current_run
            or run.get("path") != WORKFLOW
            or run.get("event") != "workflow_dispatch"
            or run.get("head_branch") != "main"
            or run.get("head_sha") != source
            or (run.get("repository") or {}).get("full_name") != repository
            or (run.get("head_repository") or {}).get("full_name") != repository
        ):
            continue
        jobs = paginated(
            repository, f"actions/runs/{run['id']}/jobs?filter=all", "jobs", fetch
        )
        for job in jobs:
            if (
                job.get("name") != "publish-linux-caches"
                or job.get("run_id") != run["id"]
                or type(job.get("run_attempt")) is not int
                or job["run_attempt"] < 1
                or type(job.get("id")) is not int
                or job["id"] < 1
                or job.get("conclusion") == "skipped"
            ):
                continue
            active = job.get("status") in (
                "queued",
                "waiting",
                "pending",
                "in_progress",
            )
            if not active and (
                job.get("status") != "completed" or not job.get("started_at")
            ):
                continue
            started = timestamp(job.get("started_at") or run.get("created_at"))
            finished = started if active else timestamp(job.get("completed_at"))
            if finished < started:
                raise ValueError("Registry publisher timestamps are inconsistent")
            records.append((started, job["id"], active, finished, job))
    if not records:
        return {
            "needed": True,
            "reason": "No executed publisher for the current main source",
        }
    _, _, active, finished, job = max(records, key=lambda item: item[:2])
    now = now or datetime.now(timezone.utc)
    if finished > now:
        raise ValueError("Registry publisher timestamps are inconsistent")
    if active:
        age = now - finished
        return {
            "needed": age > timedelta(minutes=30),
            "reason": "Publisher active beyond 30 minutes; reconcile without waiting"
            if age > timedelta(minutes=30)
            else "Current-source publisher is already active",
            "job": job["id"],
        }
    if job.get("conclusion") != "success":
        return {
            "needed": True,
            "reason": "Latest executed publisher did not succeed; reconcile current source",
            "job": job["id"],
        }
    stale = now - finished >= timedelta(hours=24)
    return {
        "needed": stale,
        "reason": "Successful registry maintenance is at least 24 hours old"
        if stale
        else "Current-source registry publisher succeeded within 24 hours",
        "job": job["id"],
    }


def cache_keys(core, ui, models):
    # Values come from GitHub's own hashFiles after checkout. Reimplementing
    # its file ordering or digest protocol here would create a second contract.
    if any(
        not re.fullmatch(r"[0-9a-f]{64}", value or "") for value in (core, ui, models)
    ):
        raise ValueError(
            "Cache reconciliation requires post-checkout exact input hashes"
        )
    return {
        "formatter": ["quality-flutter-linux-3.35.7"],
        "document": ["flutter-linux-document-host-3.35.7-v2"],
        "models_linux": [f"main-integration-models-Linux-{models}"],
        "models_macos": [f"main-integration-models-macOS-{models}"],
        "arch_core": ["flutter-linux-x64-3.35.7-dart-v2", f"pub-linux-dart-v2-{core}"],
        "arch_desktop": ["flutter-linux-x64-3.35.7-ui-v2", f"pub-linux-ui-v2-{ui}"],
    }


def main_cache_keys(repository, *, fetch=api):
    present = set()
    page = 1
    while True:
        query = urlencode({"ref": "refs/heads/main", "per_page": 100, "page": page})
        rows = fetch(repository, "actions/caches?" + query)["actions_caches"]
        if not isinstance(rows, list):
            raise ValueError("Invalid cache discovery response")
        for row in rows:
            if row.get("ref") == "refs/heads/main" and row.get("size_in_bytes", 0) > 0:
                key = row.get("key")
                if not isinstance(key, str) or not key:
                    raise ValueError("Cache discovery lacks an exact key")
                present.add(key)
        if len(rows) < 100:
            return present
        page += 1


def reconcile(environment=None, *, fetch=api, head=None, now=None):
    env = os.environ if environment is None else environment
    repository, source = env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_SHA", "")
    if (
        not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
        or not re.fullmatch(r"[a-f0-9]{40}", source)
        or env.get("GITHUB_REF") != "refs/heads/main"
        or env.get("GITHUB_EVENT_NAME") not in ("push", "workflow_dispatch", "schedule")
        or env.get("GITHUB_JOB") != "reconcile"
        or env.get("GITHUB_WORKFLOW_REF")
        != repository + "/.github/workflows/linux-cache-publish.yml@refs/heads/main"
    ):
        raise ValueError(
            "Cache reconciliation requires its dedicated reviewed-main job"
        )
    if head is None:
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, timeout=30
        ).strip()
    if head != source:
        raise ValueError("Reconciliation checkout differs from its reviewed source")
    expected = cache_keys(
        env.get("CORE_LOCK_HASH"), env.get("UI_LOCK_HASH"), env.get("MODEL_INPUT_HASH")
    )
    current = fetch(repository, "commits/main").get("sha") == source
    present = main_cache_keys(repository, fetch=fetch) if current else set()
    qualify = env.get("QUALIFY_CONSUMERS", "false")
    if qualify not in ("", "true", "false"):
        raise ValueError("Malformed consumer qualification request")
    current_run = env.get("GITHUB_RUN_ID")
    if current_run is not None and not re.fullmatch(r"[1-9][0-9]*", current_run):
        raise ValueError("Invalid current reconciliation run ID")
    registry = {
        "needed": False,
        "reason": "Main advanced; independent reconciliation owns current source",
    }
    if current:
        registry = (
            {"needed": True, "reason": "Explicit current-source consumer qualification"}
            if qualify == "true"
            else registry_schedule(
                repository,
                source,
                fetch=fetch,
                now=now,
                current_run=int(current_run) if current_run else None,
            )
        )
    # A main advance during pagination must not launch stale expensive jobs.
    current = current and fetch(repository, "commits/main").get("sha") == source
    missing = {
        role: [key for key in keys if key not in present] if current else []
        for role, keys in expected.items()
    }
    result: dict[str, object] = {role: bool(keys) for role, keys in missing.items()}
    result.update(
        {
            "schema": 1,
            "source": source,
            "current": current,
            "registry_needed": current and registry["needed"],
            "registry": registry,
            "missing": missing,
            "common": any(
                result[role] for role in ("formatter", "document", "models_linux")
            ),
            "arch_stages": [
                stage
                for stage, role in (("core", "arch_core"), ("desktop", "arch_desktop"))
                if result[role]
            ],
        }
    )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=Path("build/cache-reconciliation.json")
    )
    args = parser.parse_args()
    result = reconcile()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for key in (
                "current",
                "registry_needed",
                "common",
                "formatter",
                "document",
                "models_linux",
                "models_macos",
            ):
                stream.write(f"{key}={str(result[key]).lower()}\n")
            stream.write("arch_stages=" + json.dumps(result["arch_stages"]) + "\n")
            stream.write(f"arch_needed={str(bool(result['arch_stages'])).lower()}\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
