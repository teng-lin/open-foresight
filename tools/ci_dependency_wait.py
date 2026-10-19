#!/usr/bin/env python3
"""Wait for qualified SDK bytes without changing their producer controls."""

import argparse
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.ci_macos_dependencies import waiting_producers  # noqa: E402


def fetch(
    repository, component, prefix, own_head="", own_pr=0, wait=1800, *, optional=False
):
    identity = artifacts.fingerprint(component)
    deadline = time.monotonic() + max(0, min(wait, 1800))
    while True:
        if artifacts.pull(
            repository,
            component,
            identity,
            prefix,
            own_head=own_head,
            own_pr=own_pr,
        ):
            return True
        running = waiting_producers(repository, component, own_head, own_pr)
        if not running:
            if optional:
                return False
            raise RuntimeError(artifacts.report_unavailable(component, identity))
        if time.monotonic() >= deadline:
            raise RuntimeError(
                artifacts.report_unavailable(component, identity)
                + " Compatible producers are still active; preserve them and retry only this consumer. Their timeout never authorizes a duplicate SDK build."
            )
        print(f"Waiting for verified {component} producer", flush=True)
        time.sleep(min(20, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=tuple(artifacts.FILES), required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-head", default="")
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--wait", type=int, default=1800)
    args = parser.parse_args()
    fetch(
        args.repository,
        args.component,
        args.prefix,
        args.own_head,
        args.own_pr,
        args.wait,
    )


if __name__ == "__main__":
    main()
