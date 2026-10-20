#!/usr/bin/env python3
"""Freeze complete paginated GitHub CI metadata; never dispatch or rerun work."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode


def api(path):
    return json.loads(
        subprocess.check_output(
            ["gh", "api", "--paginate", "--slurp", path], text=True, timeout=300
        )
    )


def pages(request, path, key=None):
    result = []
    for page in request(path):
        values = page[key] if key else page
        if not isinstance(values, list):
            raise ValueError("Unexpected paginated GitHub response")
        result.extend(values)
    return result


def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Snapshot timestamps require an explicit timezone")
    return parsed.astimezone(timezone.utc)


def validate_observations(value):
    """Allow documented annotations without overriding frozen API outcomes."""
    allowed_runs = {
        "configuration",
        "scope",
        "cache_state",
        "selection",
        "qualification",
        "cache_observations",
        "checked_out_source",
        "bundle_source",
        "workflow_source",
    }
    if set(value) - {"runs", "jobs"}:
        raise ValueError("Invalid CI observation sections")
    for section, permitted in (
        ("runs", allowed_runs),
        ("jobs", {"failure_evidence", "platform", "cache_state"}),
    ):
        for identity, fields in value.get(section, {}).items():
            if (
                not str(identity).isdigit()
                or not isinstance(fields, dict)
                or set(fields) - permitted
            ):
                raise ValueError("Invalid CI diagnostic annotation")
            if section == "runs" and fields.get("cache_observations"):
                for observation in fields["cache_observations"]:
                    if (
                        observation.get("status")
                        not in {"hit", "miss", "restore-failure"}
                        or not observation.get("stage")
                        or not observation.get("source")
                        or (
                            observation["status"] == "hit"
                            and not observation.get("input_identity")
                        )
                    ):
                        raise ValueError(
                            "Cache observations require actual stage/input evidence"
                        )


def verify(directory):
    """Verify frozen input bytes and refuse partial collection as evidence."""
    path = directory / "manifest.json"
    if not path.exists():
        return None  # Legacy reporting inputs remain readable, explicitly unstamped.
    manifest = json.loads(path.read_text())
    if (
        type(manifest.get("schema")) is not int
        or manifest.get("schema") != 1
        or manifest.get("complete") is not True
    ):
        raise ValueError("CI snapshot collection is incomplete or incompatible")
    required = {"runs.jsonl", "prs.json", "trees.txt"}
    if not required <= set(manifest.get("checksums", {})):
        raise ValueError("CI snapshot is missing frozen inputs")
    if (
        directory / "observations.json"
    ).exists() and "observations.json" not in manifest["checksums"]:
        raise ValueError("CI annotations are not frozen")
    for log in (directory / "logs").rglob("*.txt"):
        if log.relative_to(directory).as_posix() not in manifest["checksums"]:
            raise ValueError("Consumed CI source logs are not frozen")
    for name, digest in manifest["checksums"].items():
        member = Path(name)
        if member.is_absolute() or ".." in member.parts or member.as_posix() != name:
            raise ValueError("Invalid CI snapshot member")
        file = directory / member
        if (
            not file.is_file()
            or file.is_symlink()
            or not file.resolve().is_relative_to(directory.resolve())
            or checksum(file) != digest
        ):
            raise ValueError("CI snapshot checksum mismatch: " + name)
    runs = [
        json.loads(line)
        for line in (directory / "runs.jsonl").read_text().splitlines()
        if line
    ]
    for run in runs:
        name = f"jobs/{run['id']}.jsonl"
        if name not in manifest["checksums"]:
            raise ValueError("CI snapshot lacks complete job attempts")
        if manifest.get("attempts", {}).get(str(run["id"])) != list(
            range(1, run.get("run_attempt", 1) + 1)
        ):
            raise ValueError("CI snapshot lacks complete job attempts")
    return manifest


def collect(repository, since, directory, request=api, observations=None, until=None):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Explicit repository required")
    beginning = timestamp(since)
    end = timestamp(until) if until else None
    if end is not None and end <= beginning:
        raise ValueError("Snapshot end must follow its beginning")
    since = beginning.isoformat().replace("+00:00", "Z")
    until = end.isoformat().replace("+00:00", "Z") if end else None
    validate_observations(observations or {})
    directory.mkdir(parents=True, exist_ok=False)
    (directory / "jobs").mkdir()
    manifest = {
        "schema": 1,
        "repository": repository,
        "since": since,
        "until": until,
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "complete": False,
        "pagination": "all pages",
        "attempts": {},
        "log_references": [],
        "exclusions": [],
    }
    destination = directory / "manifest.json"
    destination.write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        if observations is not None:
            (directory / "observations.json").write_text(
                json.dumps(observations, indent=2) + "\n"
            )
        query = urlencode(
            {
                "per_page": 100,
                "created": since + ".." + until if until else ">=" + since,
            }
        )
        runs = pages(
            request, f"repos/{repository}/actions/runs?{query}", "workflow_runs"
        )
        if len(runs) >= 1000:
            raise ValueError(
                "GitHub's filtered run limit may truncate this window; collect narrower windows instead"
            )
        (directory / "runs.jsonl").write_text(
            "".join(json.dumps(run) + "\n" for run in runs)
        )
        for run in runs:
            jobs = []
            attempts = list(range(1, run.get("run_attempt", 1) + 1))
            for attempt in attempts:
                entries = pages(
                    request,
                    f"repos/{repository}/actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100",
                    "jobs",
                )
                if any(job.get("run_attempt") != attempt for job in entries):
                    raise ValueError("GitHub returned jobs from another attempt")
                jobs.extend(entries)
                manifest["log_references"].append(
                    {
                        "run": run["id"],
                        "attempt": attempt,
                        "url": f"https://github.com/{repository}/actions/runs/{run['id']}/attempts/{attempt}",
                        "failed_jobs": [
                            job["id"]
                            for job in entries
                            if job.get("conclusion")
                            in {"failure", "timed_out", "startup_failure"}
                        ],
                    }
                )
            (directory / "jobs" / f"{run['id']}.jsonl").write_text(
                "".join(json.dumps(job) + "\n" for job in jobs)
            )
            manifest["attempts"][str(run["id"])] = attempts
        pulls = pages(request, f"repos/{repository}/pulls?state=all&per_page=100")
        prs = [
            {
                "number": pull["number"],
                "state": "MERGED" if pull.get("merged_at") else pull["state"].upper(),
                "headRefName": pull["head"]["ref"],
                "headRefOid": pull["head"]["sha"],
                "createdAt": pull["created_at"],
                "closedAt": pull.get("closed_at"),
                "mergeCommit": {"oid": pull["merge_commit_sha"]}
                if pull.get("merged_at")
                else None,
                "mergedAt": pull.get("merged_at"),
                "measurement_window": bool(
                    pull.get("merged_at")
                    and timestamp(pull["merged_at"]) >= beginning
                    and (end is None or timestamp(pull["merged_at"]) <= end)
                ),
            }
            for pull in pulls
        ]
        (directory / "prs.json").write_text(json.dumps(prs, indent=2) + "\n")
        revisions = {run["head_sha"] for run in runs}
        branches = {
            run.get("head_branch") for run in runs if run["event"] == "pull_request"
        }
        revisions.update(
            pull["headRefOid"]
            for pull in prs
            if pull["measurement_window"] or pull["headRefName"] in branches
        )
        revisions.update(
            pull["mergeCommit"]["oid"]
            for pull in prs
            if pull["mergeCommit"] and pull["measurement_window"]
        )
        trees = []
        for revision in sorted(revisions):
            value = request(f"repos/{repository}/commits/{revision}")[0]
            trees.append(
                " ".join(
                    [
                        revision,
                        value["commit"]["tree"]["sha"],
                        *[parent["sha"] for parent in value["parents"]],
                    ]
                )
            )
        (directory / "trees.txt").write_text("\n".join(trees) + "\n")
        manifest["checksums"] = {
            path.relative_to(directory).as_posix(): checksum(path)
            for path in sorted(directory.rglob("*"))
            if path.is_file() and path != destination
        }
        manifest["complete"] = True
        manifest["completed_at"] = datetime.now(timezone.utc).isoformat()
    except Exception as error:
        manifest["error"] = str(error)
        raise
    finally:
        destination.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    verify(directory)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--since", required=True)
    parser.add_argument(
        "--until",
        help="Inclusive collection window boundary; deduplicate run IDs when combining windows",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--observations",
        type=Path,
        help="Reviewed diagnostic/cache annotations with source links",
    )
    args = parser.parse_args()
    collect(
        args.repository,
        args.since,
        args.output,
        observations=json.loads(args.observations.read_text())
        if args.observations
        else None,
        until=args.until,
    )


if __name__ == "__main__":
    main()
