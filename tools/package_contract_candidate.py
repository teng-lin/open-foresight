#!/usr/bin/env python3
"""Select a verified main application fixture for package-only contract tests."""

import argparse
import json
import os
from pathlib import Path
import re

from tools import ci_artifacts


def retrieve(repository, base, destination):
    if not re.fullmatch(r"[a-f0-9]{40}", base):
        raise ValueError("Package contracts require a reviewed main baseline SHA")
    page = 1
    while True:
        items = ci_artifacts.api(
            repository, f"actions/artifacts?per_page=100&page={page}"
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
            run_id = item["workflow_run"]["id"]
            run = ci_artifacts.api(repository, f"actions/runs/{run_id}")
            if run.get("head_sha") != source or not ci_artifacts.application_jobs(
                repository, run, "linux-app", item
            ):
                continue
            if not ci_artifacts.pull(
                repository, "linux-app", source, destination, source_run=run_id
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
                "producer_run": str(run_id),
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
    args = parser.parse_args()
    values = retrieve(os.environ["GITHUB_REPOSITORY"], args.base, args.directory)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")
    print(json.dumps(values))


if __name__ == "__main__":
    main()
