#!/usr/bin/env python3
"""Verify exact-main candidates and an administrator-created tag before drafting."""

import argparse
import base64
import json
import os
import re
import subprocess
import time
import uuid

from app_version import PUBSPEC, SOURCE, read_version, stale
from ci_artifacts import api, name, trusted_run
from github_release import release_for_tag


def candidates_ready(repository, commit, run_id=None):
    for component in ("linux-app", "macos-app"):
        artifact_name = name(component, commit)
        artifacts = api(
            repository, f"actions/artifacts?name={artifact_name}&per_page=100"
        )["artifacts"]
        qualified = False
        for artifact in artifacts:
            if artifact["expired"] or artifact["name"] != artifact_name:
                continue
            if run_id is not None and artifact["workflow_run"]["id"] != run_id:
                continue
            run = api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
            if (
                run["head_sha"] == commit
                or (run_id is not None and run.get("event") == "workflow_dispatch")
            ) and trusted_run(run, component, repository=repository):
                qualified = True
                break
        if not qualified:
            return False
    return True


def require_candidates(repository, commit, wait, fresh=False, candidate_run=0):
    if candidate_run < 0:
        raise ValueError("Candidate run must be a positive run ID")
    if candidate_run:
        if not candidates_ready(repository, commit, run_id=candidate_run):
            raise ValueError(
                "Requested candidate run has no successful trusted Linux and macOS "
                "candidates for the tagged product commit"
            )
        print(
            f"Reuse verified exact-source candidates from run {candidate_run}",
            flush=True,
        )
        return candidate_run
    if not fresh and candidates_ready(repository, commit):
        return None
    current_main = api(repository, "commits/main")["sha"]
    if fresh and current_main != commit:
        comparison = api(repository, f"compare/{commit}...{current_main}")
        if comparison["status"] not in ("ahead", "identical"):
            raise ValueError("Distribution source must be reachable from reviewed main")
    if not fresh and current_main != commit:
        raise ValueError(
            "Exact-commit candidates are unavailable; refusing to substitute a newer main build"
        )
    route = "actions/workflows/macos.yml/runs?branch=main&event=workflow_dispatch&per_page=100"
    previous = (
        {run["id"] for run in api(repository, route)["workflow_runs"]}
        if fresh
        else set()
    )
    command = [
        "gh",
        "workflow",
        "run",
        "macos.yml",
        "--repo",
        repository,
        "--ref",
        "main",
    ]
    request_id = uuid.uuid4().hex if fresh else ""
    if fresh:
        command += ["-f", f"source={commit}", "-f", f"request_id={request_id}"]
    subprocess.run(
        command,
        check=True,
        timeout=300,
    )
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if fresh:
            for run in api(repository, route)["workflow_runs"]:
                if (
                    run["id"] in previous
                    or run.get("display_title") != f"Release candidate {request_id}"
                ):
                    continue
                if run.get("conclusion") in ("failure", "cancelled", "timed_out"):
                    raise RuntimeError(
                        "Fresh distribution build failed; release remains unpublished"
                    )
                if run.get("conclusion") == "success" and candidates_ready(
                    repository, commit, run["id"]
                ):
                    return run["id"]
        elif candidates_ready(repository, commit):
            return None
        if not fresh and api(repository, "commits/main")["sha"] != commit:
            raise ValueError(
                "Main advanced before the requested candidate was available; retry release preparation"
            )
        print(f"Waiting for exact-commit main candidates: {commit}", flush=True)
        time.sleep(min(20, max(0, deadline - time.monotonic())))
    raise TimeoutError(
        "Candidates unavailable; release remains unpublished. Inspect macos.yml and retry."
    )


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
    generation = package_release(body)
    body = re.sub(r"\n?<!-- foresight-package-release: [0-9]+ -->", "", body)
    body += f"\n<!-- foresight-package-release: {generation} -->"
    # Persist the reservation before deleting anything. Retrying an old workflow
    # still advances the draft generation, even after a partially failed rebuild.
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
    for asset in release["assets"]:
        subprocess.run(
            [
                "gh",
                "api",
                "--method",
                "DELETE",
                f"repos/{repository}/releases/assets/{asset['id']}",
            ],
            check=True,
            timeout=300,
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
        args.repo, commit, args.wait, fresh=True, candidate_run=args.candidate_run
    )
    release = create_draft(args.repo, args.tag, commit)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(
            f"tag={args.tag}\npackage_release={release}\ncommit={commit}\ncontrol_commit={control_commit}\ncandidate_run={candidate_run or 0}\n"
        )
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write(
                f"Product tag: `{args.tag}`\n\nProduct commit: `{commit}`\n\nControl commit: `{control_commit}`\n"
            )


if __name__ == "__main__":
    main()
