#!/usr/bin/env python3
"""Guard dedicated language/model cache saves independently of job permissions."""

import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import api  # noqa: E402

PUBLISHERS = {
    "publish-common-caches": ("linux-cache-publish.yml",),
    "publish-arch-caches": ("linux-cache-publish.yml",),
    "publish-macos-models": ("macos-cache-publish.yml", "linux-cache-publish.yml"),
}


def current_main(environment=None, *, fetch=None, head=None):
    env = os.environ if environment is None else environment
    fetch = fetch or api
    repository, source = env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_SHA", "")
    if (
        not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
        or not re.fullmatch(r"[a-f0-9]{40}", source)
        or env.get("GITHUB_REF") != "refs/heads/main"
        or env.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
        or env.get("GITHUB_WORKFLOW_REF")
        not in (
            repository + "/.github/workflows/" + workflow + "@refs/heads/main"
            for workflow in PUBLISHERS.get(env.get("GITHUB_JOB", ""), ())
        )
    ):
        raise ValueError("Shared cache saves require a dedicated main-only publisher")
    if head is None:
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, timeout=30
        ).strip()
    if head != source:
        raise ValueError("Cache publisher checkout differs from its reviewed source")
    # A stale run preserves its warm files, but does not publish a stale request.
    return fetch(repository, "commits/main").get("sha") == source


def main():
    current = current_main()
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"current={str(current).lower()}\n")
    print(
        "Current reviewed main cache publisher"
        if current
        else "Main advanced; next independent reconciliation owns cache freshness"
    )


if __name__ == "__main__":
    main()
