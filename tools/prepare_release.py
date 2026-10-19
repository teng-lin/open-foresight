#!/usr/bin/env python3
"""Verify exact-main candidates and an administrator-created tag before drafting."""

import argparse
import base64
import json
import os
import re
from pathlib import Path
import sys
import subprocess
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.app_version import PUBSPEC, SOURCE, read_version, stale
from tools.ci_artifacts import (
    api,
    name,
    trusted_run,
    application_jobs,
    application_descriptor,
)
from tools.github_release import release_for_tag


def candidate_runs(repository, commit, run_id=None):
    result = {}
    for component in ("linux-app", "macos-app"):
        artifact_name = name(component, commit)
        artifacts = api(
            repository, f"actions/artifacts?name={artifact_name}&per_page=100"
        )["artifacts"]
        for artifact in artifacts:
            if artifact["expired"] or artifact["name"] != artifact_name:
                continue
            producer = artifact["workflow_run"]["id"]
            if run_id is not None and producer != run_id:
                continue
            run = api(repository, f"actions/runs/{producer}")
            if (
                (
                    run["head_sha"] == commit
                    or run.get("event") == "workflow_dispatch"
                )
                and trusted_run(run, component, repository=repository)
                and application_jobs(repository, run, component, artifact)
            ):
                result[component] = producer
                break
    return result


def candidates_ready(repository, commit, run_id=None):
    return len(candidate_runs(repository, commit, run_id)) == 2


def require_candidates(repository, commit, wait, fresh=False, candidate_run=0):
    # This consumer never starts a producer. A missing output is an actionable
    # artifact problem, not authorization to rebuild both platforms.
    if candidate_run < 0:
        raise ValueError("Candidate run must be a positive run ID")
    deadline = time.monotonic() + wait
    while True:
        runs = candidate_runs(repository, commit, candidate_run or None)
        if len(runs) == 2:
            identities = [
                application_descriptor(repository, component, commit, run)
                for component, run in runs.items()
            ]
            if identities[0] != identities[1]:
                raise ValueError(
                    "Platform candidates have different distribution identities; recover only the missing matching output"
                )
            print(
                f"Reuse verified exact-source platform candidates: {runs}", flush=True
            )
            return runs
        active = (
            [api(repository, f"actions/runs/{candidate_run}")]
            if candidate_run
            else api(
                repository, "actions/workflows/macos.yml/runs?branch=main&per_page=100"
            )["workflow_runs"]
        )
        pending = any(
            run.get("status")
            in ("queued", "in_progress", "waiting", "requested", "pending")
            and (
                candidate_run
                or run.get("head_sha") == commit
                or run.get("id") in runs.values()
            )
            and run.get("head_branch") == "main"
            and run.get("path") == ".github/workflows/macos.yml"
            and run.get("head_repository", {}).get("full_name") == repository
            for run in active
        )
        if not pending or time.monotonic() >= deadline:
            missing = sorted({"linux-app", "macos-app"} - runs.keys())
            raise ValueError(
                f"Verified candidates unavailable for {commit}: {missing}. "
                "Preserve completed outputs; inspect existing producers, then "
                "dispatch macos.yml with source and platforms only for missing outputs. "
                "Packaging never recompiles applications or SDKs."
            )
        print(
            f"Waiting for existing exact-source producers; available: {runs}",
            flush=True,
        )
        time.sleep(min(20, max(0, deadline - time.monotonic())))


def package_release(body):
    """Reserve the next draft generation independently of workflow run order."""
    markers = re.findall(r"<!-- foresight-package-release: ([0-9]+) -->", body)
    return str(max([0, *map(int, markers)]) + 1)


def release_source(repository, tag, control_commit):
    """Resolve an administrator-created tag reachable from reviewed main."""
    refs = api(repository, f"git/matching-refs/tags/{tag}")
    if not any(ref["ref"] == f"refs/tags/{tag}" for ref in refs):
        raise ValueError(
            f"Release tag {tag} is missing. An administrator must create it at the "
            f"reviewed intended product commit (current main: {control_commit}) and "
            "push it before dispatching release.yml; protected v* tags cannot be created by the workflow token."
        )
    commit = api(repository, f"commits/{tag}")["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Release tag must resolve to a full source commit")
    comparison = api(repository, f"compare/{commit}...{control_commit}")
    if comparison["status"] not in ("ahead", "identical"):
        raise ValueError("Release tag must be reachable from reviewed main")
    pubspec = api(repository, f"contents/{PUBSPEC}?ref={commit}")
    if pubspec.get("encoding") != "base64":
        raise ValueError("Cannot verify the tagged application version")
    text = base64.b64decode("".join(pubspec["content"].split()), validate=True).decode(
        "utf-8"
    )
    version = SOURCE.search(text)
    if not version or tag != "v" + version[1]:
        raise ValueError("Release tag must match its immutable application version")
    return commit


def create_draft(repository, tag, commit):
    # Querying refs explicitly distinguishes absence from API/auth failures.
    refs = api(repository, f"git/matching-refs/tags/{tag}")
    existing = [ref for ref in refs if ref["ref"] == f"refs/tags/{tag}"]
    if existing:
        if api(repository, f"commits/{tag}")["sha"] != commit:
            raise ValueError("Existing release tag points to a different commit")
    else:
        raise ValueError(
            f"Release tag {tag} is missing. An administrator must create it at {commit} "
            "and push it before dispatching release.yml; protected v* tags cannot be created by the workflow token."
        )
    release = release_for_tag(repository, tag, optional=True, request=api)
    if release is None:
        subprocess.run(
            [
                "gh",
                "release",
                "create",
                tag,
                "--repo",
                repository,
                "--verify-tag",
                "--draft",
                "--title",
                "Open Foresight " + tag,
                "--generate-notes",
            ],
            check=True,
            timeout=300,
        )
        # Newly created drafts can lag in the authenticated list API. Keep the
        # existing tag and candidates intact while discovery catches up.
        for attempt in range(6):
            release = release_for_tag(repository, tag, optional=True, request=api)
            if release is not None:
                break
            if attempt < 5:
                time.sleep(2)
        if release is None:
            raise ValueError(
                "Created draft is not yet visible; resume with --candidate-run "
                "after draft discovery recovers instead of rebuilding candidates"
            )
    if not release["draft"]:
        raise ValueError("Public releases are immutable; cut a new version")
    body = release.get("body") or ""
    generation = str(max(1, int(package_release(body)) - 1))
    body = re.sub(r"\n?<!-- foresight-package-release: [0-9]+ -->", "", body)
    body += f"\n<!-- foresight-package-release: {generation} -->"
    # Resume the same draft generation and retain successful installer bytes.
    updated = subprocess.run(
        [
            "gh",
            "api",
            "--method",
            "PATCH",
            f"repos/{repository}/releases/{release['id']}",
            "-f",
            f"tag_name={tag}",
            "-f",
            f"target_commitish={commit}",
            "-F",
            "draft=true",
            "-f",
            "body=" + body,
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=300,
    )
    metadata = json.loads(updated.stdout)
    if (
        metadata.get("id") != release["id"]
        or metadata.get("tag_name") != tag
        or metadata.get("target_commitish") != commit
        or metadata.get("draft") is not True
    ):
        raise ValueError(
            "Draft metadata update changed the immutable release binding; assets were not deleted"
        )
    return generation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--repo", default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight")
    )
    parser.add_argument("--wait", type=int, default=10800)
    parser.add_argument(
        "--candidate-run",
        type=int,
        default=0,
        help="Resume packaging from both verified candidates in this successful main run",
    )
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag) or stale():
        raise ValueError(
            "Release requires a stable tag and synchronized application version"
        )
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Release preparation requires reviewed main")
    control_commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, timeout=300
    ).strip()
    commit = release_source(args.repo, args.tag, control_commit)
    if commit == control_commit and args.tag != "v" + read_version()[0]:
        raise ValueError(
            "A new release tag must match the synchronized application version"
        )
    candidate_run = require_candidates(
        args.repo, commit, args.wait, candidate_run=args.candidate_run
    )
    release = create_draft(args.repo, args.tag, commit)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(
            f"tag={args.tag}\npackage_release={release}\ncommit={commit}\ncontrol_commit={control_commit}\ncandidate_run={args.candidate_run}\nlinux_candidate_run={candidate_run['linux-app']}\nmacos_candidate_run={candidate_run['macos-app']}\n"
        )
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write(
                f"Product tag: `{args.tag}`\n\nProduct commit: `{commit}`\n\nControl commit: `{control_commit}`\n"
            )


if __name__ == "__main__":
    main()
