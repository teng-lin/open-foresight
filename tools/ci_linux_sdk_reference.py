#!/usr/bin/env python3
"""Retain and restore the exact SDK artifact used by a qualified Linux bundle."""

import argparse
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import integration_application as application  # noqa: E402
from tools import linux_sdk_artifacts as sdk  # noqa: E402


def validate(value, repository, source):
    if (
        not isinstance(value, dict)
        or value.get("schema") != 1
        or not re.fullmatch(r"[a-f0-9]{40}", source)
        or value.get("source") != source
        or value.get("repository") != repository
        or value.get("route") not in ("producer", "in-run")
        or any(
            type(value.get(key)) is not int or value[key] < 1
            for key in ("run_id", "artifact_id")
        )
        or not isinstance(value.get("artifact_digest"), str)
        or not re.fullmatch(r"sha256:[a-f0-9]{64}", value["artifact_digest"])
    ):
        raise ValueError("Invalid exact SDK reference for the qualified application")
    if value["route"] == "in-run" and (
        type(value.get("attempt")) is not int
        or value["attempt"] < 1
        or not isinstance(value.get("head_repository"), str)
        or not re.fullmatch(
            r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value["head_repository"]
        )
    ):
        raise ValueError("Invalid source-scoped in-run SDK reference")
    return value


def write(path, repository, source):
    fork = bool(os.environ.get("FORK_SDK_ID"))
    value = {
        "schema": 1,
        "source": source,
        "repository": repository,
        "route": "in-run" if fork else "producer",
        "run_id": int(os.environ["GITHUB_RUN_ID"] if fork else os.environ["SDK_RUN"]),
        "artifact_id": int(os.environ["FORK_SDK_ID"] if fork else os.environ["SDK_ID"]),
        "artifact_digest": os.environ["FORK_SDK_DIGEST"]
        if fork
        else os.environ["SDK_DIGEST"],
    }
    if fork:
        value.update(
            attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]),
            head_repository=os.environ["HEAD_REPOSITORY"],
        )
    validate(value, repository, source)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    return value


def restore(path, directory, repository, source, own_pr=0):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
        raise ValueError("SDK reference must be a regular qualified bundle entry")
    value = validate(json.loads(path.read_text()), repository, source)
    if value["route"] == "producer":
        if not artifacts.pull(
            repository,
            "linux-sdk",
            artifacts.fingerprint("linux-sdk"),
            directory,
            own_head=source,
            own_pr=own_pr,
            source_run=value["run_id"],
            artifact_id=value["artifact_id"],
            artifact_digest=value["artifact_digest"],
        ):
            raise ValueError(
                "The bundle's exact verified SDK artifact is unavailable; preserve compatible producers and retry this consumer"
            )
    else:
        application.retrieve(
            repository,
            value["head_repository"],
            source,
            value["run_id"],
            value["artifact_id"],
            value["attempt"],
            value["artifact_digest"].removeprefix("sha256:"),
            directory,
            component="linux-sdk",
            shadow=True,
        )
    sdk.write_outputs(sdk.resolve(directory, load_registry=True))
    (directory / "image.tar").unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("write", "restore"))
    parser.add_argument("--source", required=True)
    parser.add_argument(
        "--reference", type=Path, default=Path("artifacts/sdk-reference.json")
    )
    parser.add_argument("--directory", type=Path, default=Path("build/consumer-sdk"))
    parser.add_argument("--own-pr", type=int, default=0)
    args = parser.parse_args()
    if args.command == "write":
        write(args.reference, os.environ["GITHUB_REPOSITORY"], args.source)
    else:
        restore(
            args.reference,
            args.directory,
            os.environ["GITHUB_REPOSITORY"],
            args.source,
            args.own_pr,
        )


if __name__ == "__main__":
    main()
