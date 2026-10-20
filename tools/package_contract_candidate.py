#!/usr/bin/env python3
"""Select a verified main application fixture for package-only contract tests."""

import argparse
import json
import os
from pathlib import Path
import re

from tools import ci_artifacts


def retrieve(repository, base, destination, run_id=0):
    if not re.fullmatch(r"[a-f0-9]{40}", base):
        raise ValueError("Package contracts require a reviewed main baseline SHA")
    if type(run_id) is not int or run_id < 0:
        raise ValueError("Producer run must be a nonnegative run ID")
    page = 1
    while True:
        items = ci_artifacts.api(
            repository,
            f"actions/runs/{run_id}/artifacts?per_page=100&page={page}"
            if run_id
            else f"actions/artifacts?per_page=100&page={page}",
        )["artifacts"]
        for item in items:
            match = re.fullmatch(r"ci-linux-app-([a-f0-9]{40})", item.get("name", ""))
            if not match or item.get("expired"):
                continue
            source = match[1]
            if ci_artifacts.api(repository, f"compare/{source}...{base}")[
                "status"
            ] not in ("ahead", "identical"):
                continue
            producer = item["workflow_run"]["id"]
            if run_id and producer != run_id:
                continue
            run = ci_artifacts.api(repository, f"actions/runs/{producer}")
            if not ci_artifacts.application_jobs(
                repository, run, "linux-app", item, consumer="pr-package-contract"
            ):
                continue
            if not ci_artifacts.pull(
                repository,
                "linux-app",
                source,
                destination,
                source_run=producer,
                consumer="pr-package-contract",
            ):
                raise ValueError(
                    "Qualified package fixture became unavailable; preserve outputs and inspect artifacts"
                )
            identity = ci_artifacts.application_distribution(
                destination, "linux-app", source
            )
            return {
                "source": source,
                "version": identity["version"],
                "producer_run": str(producer),
            }
        if len(items) < 100:
            raise ValueError(
                "No retained verified main application fixture is available. Supply/restore a compatible candidate; package contracts never compile applications or SDKs."
            )
        page += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--run-id", type=int, default=0)
    args = parser.parse_args()
    values = retrieve(
        os.environ["GITHUB_REPOSITORY"], args.base, args.directory, args.run_id
    )
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")
    print(json.dumps(values))


if __name__ == "__main__":
    main()
