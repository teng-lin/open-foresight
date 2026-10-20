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
from tools.ci_artifacts import api
from tools.github_release import release_for_tag


def candidate_runs(repository, commit, run_id=None, *, consumer="release-preparation"):
    if consumer not in ("release-preparation", "release-candidate"):
        raise ValueError(
            "Only fully tested release-tier candidate discovery is supported"
        )
    from tools import ci_release_candidates as tested

    if consumer == "release-candidate" and not os.environ.get("RELEASE_SOURCE_FLOOR"):
        return {}
    control = api(repository, "commits/main")["sha"]
    tested.source_policy(repository, commit, control)
    record = tested.find(
        repository,
        commit,
        run_id or 0,
        current_run=int(os.environ.get("GITHUB_RUN_ID", "0")),
    )
    return (
        {component: record["run_id"] for component in ("linux-app", "macos-app")}
        if record
        else {}
    )


def verified_candidates(repository, commit, candidate_run):
    """Read the exact completed candidate once; packaging never waits or builds."""
    if type(candidate_run) is not int or candidate_run < 1:
        raise ValueError("Release preparation requires a positive tested candidate run")
    runs = candidate_runs(repository, commit, candidate_run)
    if set(runs) != {"linux-app", "macos-app"} or any(
        run != candidate_run for run in runs.values()
    ):
        raise ValueError(
            "Fully tested release candidates are unavailable; no packaging or builds were started"
        )
    return runs


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
    parser.add_argument(
        "--candidate-run",
        type=int,
        required=True,
        help="Original completed release-tier run verified by preflight",
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
    candidate_run = verified_candidates(args.repo, commit, args.candidate_run)
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
