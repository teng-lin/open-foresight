#!/usr/bin/env python3
"""Audit a green same-source preview without stamping or compiling another app."""

import argparse
import json
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile
import sys
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import integration_application as application  # noqa: E402
from tools import ci_linux_acceptance as acceptance  # noqa: E402
from tools.ci_nightly import pages, jobs  # noqa: E402
from tools.ci_producer_trust import PRODUCERS  # noqa: E402


# Each latest API job is checked independently; an old green aggregate cannot
# authorize bytes while a retried child is pending or red.
NIGHTLY_REQUIRED = (
    "plan",
    "nightly-checks",
    "publish",
    "macos",
    "linux (deb)",
    "linux (rpm)",
    "linux (arch)",
    "build / linux-build",
    "build / linux-test",
    "build / macos",
    "build / linux-document-imports",
    "build / platform-checks",
    "build / acceptance-checks",
    "build / acceptance-cpu",
    "build / acceptance-audio",
    "build / acceptance-deb",
    "build / packaging / linux-deb",
    "build / packaging / linux-rpm",
    "build / packaging / linux-arch",
    "build / packaging / dmg",
)


def green_closure(rows, run, source):
    def complete(job, allowed):
        return (
            type(job.get("id")) is int
            and job["id"] > 0
            and job.get("run_id") == run["id"]
            and job.get("head_sha") == source
            and type(job.get("run_attempt")) is int
            and type(run.get("run_attempt")) is int
            and 1 <= job["run_attempt"] <= run["run_attempt"]
            and job.get("status") == "completed"
            and job.get("conclusion") in allowed
        )

    for name in NIGHTLY_REQUIRED:
        matching = [job for job in rows if job.get("name") == name]
        if len(matching) != 1 or not complete(matching[0], ("success",)):
            return False
    return all(
        complete(job, ("success", "skipped"))
        for job in rows
        if job.get("name", "").startswith("build / ")
    )


def checkout(source):
    if (
        not re.fullmatch(r"[a-f0-9]{40}", source)
        or subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, timeout=30
        ).strip()
        != source
    ):
        raise ValueError("External audit source must match the actual main checkout")


def reviewed_preview(repository, run, source=None):
    return (
        PRODUCERS["weekly-preview-audit"].matches_run(run)
        and type(run.get("id")) is int
        and run["id"] > 0
        and type(run.get("run_attempt")) is int
        and run["run_attempt"] > 0
        and re.fullmatch(r"[a-f0-9]{40}", run.get("head_sha", "")) is not None
        and (source is None or run["head_sha"] == source)
        and run.get("head_branch") == "main"
        and (run.get("repository") or {}).get("full_name") == repository
        and (run.get("head_repository") or {}).get("full_name") == repository
    )


def qualified(repository, source, run):
    if not reviewed_preview(repository, run, source) or run.get("status") not in (
        "completed",
        "in_progress",
    ):
        return None
    latest = jobs(repository, run["id"], request=artifacts.api)
    if not green_closure(latest, run, source):
        return None
    producers = [
        job for job in latest if PRODUCERS["weekly-preview-audit"].matches_job(job)
    ]
    if (
        len(producers) != 1
        or producers[0].get("status") != "completed"
        or producers[0].get("conclusion") != "success"
    ):
        return None
    return producers[0]


AUDIT_STEPS = (
    "Audit external CPU models using the original preview",
    "Audit virtual audio, meeting UI and software Vulkan independently",
    "Audit Ubuntu and Debian 13 lifecycle against those same bytes",
    "Record completed weekly external audit",
)


def completion(repository, run, item):
    if not reviewed_preview(repository, run):
        raise ValueError("Unqualified weekly audit completion run")
    match = re.fullmatch(
        rf"weekly-external-audit-completion-{run['id']}-([1-9][0-9]*)",
        item.get("name", ""),
    )
    if not match or item.get("expired") is not False:
        return None
    attempt = int(match[1])
    if (
        attempt > run["run_attempt"]
        or type(item.get("id")) is not int
        or item["id"] < 1
        or type(item.get("workflow_run", {}).get("id")) is not int
        or item.get("workflow_run", {}).get("id") != run["id"]
        or item.get("workflow_run", {}).get("head_sha") != run["head_sha"]
        or type(item.get("size_in_bytes")) is not int
        or not 0 < item["size_in_bytes"] <= 1024 * 1024
        or not re.fullmatch(r"sha256:[a-f0-9]{64}", item.get("digest", ""))
    ):
        raise ValueError("Weekly audit completion artifact identity mismatch")
    # A receipt uploaded before cancellation/post-job failure is not a weekly
    # completion. Resolve its exact original API job before reading any bytes;
    # malformed/ambiguous identity and upload windows remain hard failures.
    candidates = [
        job
        for job in artifacts.dependency_jobs(repository, run["id"])
        if PRODUCERS["weekly-audit-completion"].matches_job(job)
        and job.get("run_attempt") == attempt
    ]
    if len(candidates) != 1:
        raise ValueError("Ambiguous or missing original weekly audit producer")
    original = candidates[0]
    if (
        type(original.get("id")) is not int
        or original["id"] < 1
        or type(original.get("run_attempt")) is not int
        or type(original.get("run_id")) is not int
        or original["run_id"] != run["id"]
        or original.get("head_sha") != run["head_sha"]
    ):
        raise ValueError("Original weekly audit producer identity mismatch")
    if (
        original.get("status") in {"queued", "in_progress", "waiting"}
        and original.get("conclusion") is None
    ):
        try:
            uploaded = datetime.fromisoformat(item["created_at"].replace("Z", "+00:00"))
            started = datetime.fromisoformat(
                original["started_at"].replace("Z", "+00:00")
            )
            if uploaded.tzinfo is None or started.tzinfo is None or uploaded < started:
                raise ValueError("Invalid original producer start window")
            if original.get("completed_at") and not artifacts.in_producer_attempt(
                item, original
            ):
                raise ValueError("Invalid original producer completion window")
        except (KeyError, TypeError, AttributeError) as error:
            raise ValueError("Incomplete original producer upload metadata") from error
        return None
    if original.get("status") != "completed" or not artifacts.in_producer_attempt(
        item, original
    ):
        raise ValueError("Weekly completion upload is outside its original producer")
    if original.get("conclusion") in {
        "failure",
        "cancelled",
        "timed_out",
        "skipped",
        "neutral",
        "action_required",
        "stale",
        "startup_failure",
    }:
        return None
    job = application.original_producer(
        repository,
        run["head_sha"],
        run["id"],
        attempt,
        item,
        consumer="weekly-audit-completion",
        wait=0,
    )
    if type(job.get("run_attempt")) is not int:
        raise ValueError("Invalid original weekly audit producer attempt")
    for name in AUDIT_STEPS:
        steps = [step for step in job.get("steps", []) if step.get("name") == name]
        if len(steps) > 1:
            raise ValueError("Ambiguous actual weekly audit step")
        if (
            not steps
            or steps[0].get("status") != "completed"
            or steps[0].get("conclusion") != "success"
        ):
            return None
    if artifacts.api(repository, f"compare/{run['head_sha']}...main").get(
        "status"
    ) not in {"ahead", "identical"}:
        raise ValueError("Weekly audit completion source is not reviewed main")
    with tempfile.TemporaryDirectory(prefix="weekly-audit-completion-") as temporary:
        archive = Path(temporary) / "completion.zip"
        artifacts.download_zip(repository, item, archive)
        with zipfile.ZipFile(archive) as stream:
            members = stream.infolist()
            if (
                len(members) != 1
                or members[0].filename != "completion.json"
                or members[0].is_dir()
                or members[0].file_size > 65536
                or (members[0].external_attr >> 16) & 0o170000 not in (0, 0o100000)
            ):
                raise ValueError("Unexpected weekly audit completion ZIP members")
            receipt = json.loads(stream.read(members[0]))
    expected = {
        "schema": 1,
        "kind": "weekly-external-audit",
        "repository": repository,
        "workflow": run["path"],
        "event": run["event"],
        "source_commit": run["head_sha"],
        "source_run": run["id"],
        "source_run_attempt": attempt,
        "job": "weekly-external-audit",
        "gates": {"cpu": "success", "audio": "success", "deb": "success"},
    }
    if (
        not isinstance(receipt, dict)
        or any(receipt.get(key) != value for key, value in expected.items())
        or any(
            type(receipt.get(key)) is not int
            for key in ("schema", "source_run", "source_run_attempt")
        )
    ):
        raise ValueError("Weekly audit completion receipt differs from its producer")
    try:
        recorded = datetime.fromisoformat(
            receipt["completed_at"].replace("Z", "+00:00")
        )
        started = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
        uploaded = datetime.fromisoformat(item["created_at"].replace("Z", "+00:00"))
        if recorded.tzinfo is None or not started <= recorded <= uploaded:
            raise ValueError(
                "Weekly audit completion timestamp is outside its original upload"
            )
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError("Invalid weekly audit completion timestamp") from error
    return recorded


def audited_this_week(repository, now):
    """Cadence bookkeeping only; never authorizes application bytes or test reuse."""
    now = now.astimezone(timezone.utc)
    beginning = (now - timedelta(days=now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    created = quote(">=" + (beginning - timedelta(days=7)).date().isoformat())
    runs = pages(
        repository,
        f"actions/workflows/preview-packages.yml/runs?branch=main&created={created}",
        "workflow_runs",
        request=artifacts.api,
    )
    for run in runs:
        if not reviewed_preview(repository, run):
            continue
        items = pages(
            repository,
            f"actions/runs/{run['id']}/artifacts",
            "artifacts",
            request=artifacts.api,
        )
        named = [
            item
            for item in items
            if item.get("name", "").startswith(
                f"weekly-external-audit-completion-{run['id']}-"
            )
            and item.get("expired") is False
        ]
        if len({item["name"] for item in named}) != len(named):
            raise ValueError("Ambiguous weekly audit completion upload")
        for item in named:
            completed = completion(repository, run, item)
            if completed is not None and beginning <= completed <= now:
                return True
    return False


def record(source, output):
    checkout(source)
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    if (
        os.environ.get("GITHUB_REF") != "refs/heads/main"
        or os.environ.get("GITHUB_WORKFLOW_REF")
        != f"{repository}/.github/workflows/preview-packages.yml@refs/heads/main"
        or event not in {"schedule", "workflow_dispatch"}
        or os.environ.get("GITHUB_JOB") != "weekly-external-audit"
        or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
        or any(
            os.environ.get(f"AUDIT_{gate}") != "success"
            for gate in ("CPU", "AUDIO", "DEB")
        )
        or any(
            not re.fullmatch(r"[1-9][0-9]*", os.environ.get(name, ""))
            for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")
        )
    ):
        raise ValueError(
            "Completion requires this main preview's three performed audit gates"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            {
                "schema": 1,
                "kind": "weekly-external-audit",
                "repository": repository,
                "workflow": ".github/workflows/preview-packages.yml",
                "event": event,
                "source_commit": source,
                "source_run": int(os.environ["GITHUB_RUN_ID"]),
                "source_run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
                "job": "weekly-external-audit",
                "gates": {"cpu": "success", "audio": "success", "deb": "success"},
                "completed_at": datetime.now(timezone.utc)
                .replace(microsecond=0)
                .isoformat(),
            },
            indent=2,
        )
        + "\n"
    )


class ProducerDeferralLimit(ValueError):
    """A scheduling-only age failure; never catches artifact trust errors."""


def active_preview(repository, source, run, *, now=None):
    if not reviewed_preview(repository, run, source):
        return False
    status = run.get("status")
    queued = status in {"queued", "pending", "waiting", "requested"}
    if not queued:
        if status != "in_progress":
            return False
        # A no-build trigger or a completed failed producer is not active.
        # This signal only defers scheduling; it never authorizes bytes.
        active = any(
            job.get("name", "").startswith("build / ")
            and job.get("status") in {"queued", "in_progress", "waiting"}
            and job.get("conclusion") is None
            and job.get("head_sha") == source
            and job.get("run_id") == run["id"]
            and type(job.get("run_attempt")) is int
            and 1 <= job["run_attempt"] <= run["run_attempt"]
            for job in jobs(repository, run["id"], request=artifacts.api)
        )
        if not active:
            return False
    # Queued reruns retain their old run ID: use the API status-update time.
    # Running attempts use their start, so unrelated updates cannot extend them.
    timestamp = run.get("updated_at") if queued else run.get("run_started_at")
    try:
        started = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        age = ((now or datetime.now(timezone.utc)) - started).total_seconds()
        if started.tzinfo is None or not 0 <= age <= 1800:
            raise ValueError("Unbounded producer age")
    except (ValueError, TypeError, AttributeError) as error:
        raise ProducerDeferralLimit(
            "Preview producer exceeds or lacks the 30-minute audit deferral window; "
            "preserve it and retry only this consume-only audit after completion."
        ) from error
    return True


def emit(values):
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for key, value in values.items():
                stream.write(f"{key}={value}\n")
    return values


def plan(repository, source, event, full=False, *, now=None):
    now = now or datetime.now(timezone.utc)
    if not full and event != "schedule":
        return emit({"selected": "false", "source": source})
    # A metadata/transport failure must still select the audit failure gate.
    emit({"selected": "true", "source": source})
    checkout(source)
    if artifacts.api(repository, "commits/main").get("sha") != source:
        print("Main advanced: preserve the newer source and skip this superseded audit")
        return emit({"selected": "false", "source": source})
    if not full and audited_this_week(repository, now):
        return emit({"selected": "false", "source": source})
    runs = pages(
        repository,
        f"actions/workflows/preview-packages.yml/runs?branch=main&head_sha={source}",
        "workflow_runs",
        request=artifacts.api,
    )
    unqualified = []
    for run in sorted(runs, key=lambda item: item["id"], reverse=True):
        producer = qualified(repository, source, run)
        if producer is None:
            unqualified.append(run)
            continue
        attempt = producer.get("run_attempt")
        items = pages(
            repository,
            f"actions/runs/{run['id']}/artifacts",
            "artifacts",
            request=artifacts.api,
        )
        matches = [
            item
            for item in items
            if item.get("name") == f"preview-linux-app-{run['id']}-{attempt}"
            and item.get("expired") is False
        ]
        if not matches:
            continue
        if len(matches) != 1:
            raise ValueError("Ambiguous original preview bundle upload")
        artifact = matches[0]
        if (
            type(artifact.get("id")) is not int
            or artifact["id"] < 1
            or artifact.get("workflow_run", {}).get("id") != run["id"]
            or artifact.get("workflow_run", {}).get("head_sha") != source
            or not re.fullmatch(r"sha256:[a-f0-9]{64}", artifact.get("digest", ""))
            or not artifacts.in_producer_attempt(artifact, producer)
        ):
            raise ValueError(
                "Preview bundle differs from its successful original upload"
            )
        return emit(
            {
                "selected": "true",
                "source": source,
                "producer_run": str(run["id"]),
                "attempt": str(attempt),
                "artifact_id": str(artifact["id"]),
                "artifact_digest": artifact["digest"].removeprefix("sha256:"),
            }
        )
    # Exhaust retained green candidates before considering any wait. A newer
    # stale queue cannot disqualify an already verified same-source bundle.
    pending = False
    limit_error = None
    for run in unqualified:
        try:
            pending = active_preview(repository, source, run, now=now) or pending
        except ProducerDeferralLimit as error:
            limit_error = error
    if pending:
        print(
            "Verified preview producer is active; defer this consume-only audit to the next nightly"
        )
        return emit({"selected": "false", "source": source})
    if limit_error is not None:
        raise limit_error
    raise ValueError(
        "No retained green preview for this exact main source. Preserve any active producer; retry only this consume-only audit after its verified bundle is available."
    )


def restore(repository, source, run_id, attempt, artifact_id, checksum, destination):
    checkout(source)
    if artifacts.api(repository, "commits/main").get("sha") != source:
        raise ValueError(
            "Main advanced before the consume-only audit; retry on current main"
        )
    run = artifacts.api(repository, f"actions/runs/{run_id}")
    job = qualified(repository, source, run)
    if job is None or job.get("run_attempt") != attempt:
        raise ValueError(
            "The selected preview no longer has green latest suite evidence"
        )
    return application.retrieve(
        repository,
        repository,
        source,
        run_id,
        artifact_id,
        attempt,
        checksum,
        destination,
        purpose="weekly-audit",
        label=None,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "restore", "record"))
    parser.add_argument("--source", required=True)
    parser.add_argument("--full", action="store_true")
    parser.add_argument(
        "--output", type=Path, default=Path("test-results/weekly-audit/completion.json")
    )
    parser.add_argument("--producer-run", type=int)
    parser.add_argument("--attempt", type=int)
    parser.add_argument("--artifact-id", type=int)
    parser.add_argument("--artifact-digest")
    parser.add_argument("--directory", type=Path, default=Path("artifacts"))
    args = parser.parse_args()
    if args.command == "record":
        record(args.source, args.output)
    elif args.command == "plan":
        plan(
            os.environ["GITHUB_REPOSITORY"],
            args.source,
            os.environ["GITHUB_EVENT_NAME"],
            args.full,
        )
    else:
        if any(
            value is None
            for value in (
                args.producer_run,
                args.attempt,
                args.artifact_id,
                args.artifact_digest,
            )
        ):
            parser.error(
                "restore requires the original run, attempt, artifact ID and digest"
            )
        qualification = restore(
            os.environ["GITHUB_REPOSITORY"],
            args.source,
            args.producer_run,
            args.attempt,
            args.artifact_id,
            args.artifact_digest,
            args.directory,
        )
        acceptance.prepare(
            args.directory,
            Path("build/portable/dist"),
            args.source,
            qualification["source_receipt"]["label"],
        )


if __name__ == "__main__":
    main()
