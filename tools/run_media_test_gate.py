#!/usr/bin/env python3
"""Build and select the verified fixed worker for an explicit Linux test gate.

This application-test prerequisite does not change dependency SDKs or ordinary
build/test-only behavior. Run it inside run_ci_user, before the unchanged gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools import build_media_worker, media_worker_package

ROOT = Path(__file__).resolve().parents[1]


def prepare_environment(
    cache: Path,
    output: Path,
    *,
    fetch: bool,
    jobs: int,
    environment: dict[str, str],
) -> dict[str, str]:
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise ValueError("The media test prerequisite requires Linux x86_64")
    if os.geteuid() == 0:
        raise ValueError("Run the media test prerequisite as the CI workspace owner")
    if not 1 <= jobs <= 32:
        raise ValueError("Media build jobs must be between 1 and 32")
    build_media_worker.build(cache, output, fetch=fetch, jobs=jobs)
    output = output.resolve(strict=True)
    prepared = media_worker_package.prepare(ROOT, output, "linux-x86_64")
    if prepared.assembly_protocol != 1:
        raise ValueError("The media test prerequisite requires assembly protocol 1")
    worker = output / "foresight-media-worker"
    digest = hashlib.sha256(prepared.binary).hexdigest()
    selected = dict(environment)
    selected.update(
        FORESIGHT_TEST_MEDIA_WORKER=str(worker),
        FORESIGHT_TEST_MEDIA_BUILD_ID=prepared.build_id,
        FORESIGHT_TEST_MEDIA_SHA256=digest,
        FORESIGHT_TEST_MEDIA_CDHASH="",
    )
    with (output / "media-test-selection.json").open("x") as receipt:
        json.dump(
            {
                "worker": str(worker),
                "build_id": prepared.build_id,
                "sha256": digest,
                "source_receipt_sha256": prepared.source_receipt_sha256,
                "uid": os.geteuid(),
                "scope": "Current-source fixed worker for the following test gate",
            },
            receipt,
            indent=2,
        )
        receipt.write("\n")
    return selected


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("An explicit test gate command is required after --")
    environment = prepare_environment(
        args.cache,
        args.output,
        fetch=args.fetch,
        jobs=args.jobs,
        environment=dict(os.environ),
    )
    # Replace this process: the original gate still owns signals, exit status
    # and its existing deadlines. There is no unobserved intermediary child.
    os.execvpe(command[0], command, environment)  # noqa: S606 - Explicit non-root gate vector; preserve its process ownership.


if __name__ == "__main__":
    main()
