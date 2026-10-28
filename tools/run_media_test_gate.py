#!/usr/bin/env python3
"""Build and select the verified fixed worker for an explicit native test gate.

Core test gates select this application worker before exercising real codecs.
Build-only stages do not need it, and dependency SDKs remain unchanged. Linux
container callers run it inside run_ci_user as the workspace owner.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools import build_media_worker, media_worker_package

ROOT = Path(__file__).resolve().parents[1]
SELECTION_KEYS = (
    "FORESIGHT_TEST_MEDIA_WORKER",
    "FORESIGHT_TEST_MEDIA_BUILD_ID",
    "FORESIGHT_TEST_MEDIA_SHA256",
    "FORESIGHT_TEST_MEDIA_CDHASH",
)


def _build_with_logs(cache: Path, output: Path, *, fetch: bool, jobs: int) -> None:
    previous = set(cache.glob("media-*/build.log"))

    def retain() -> None:
        for log in set(cache.glob("media-*/build.log")) - previous:
            destination = output / "test-build-logs" / log.parent.name
            destination.mkdir(parents=True, mode=0o700)
            shutil.copyfile(log, destination / "build.log")

    try:
        build_media_worker.build(cache, output, fetch=fetch, jobs=jobs)
    except Exception:
        try:
            retain()
        except OSError as error:
            print(f"Could not copy raw media build logs: {error}", file=sys.stderr)
        raise
    retain()


def prepare_environment(
    cache: Path,
    output: Path,
    *,
    fetch: bool,
    jobs: int,
    environment: dict[str, str],
    reuse_selected: bool = False,
    existing_product: Path | None = None,
) -> dict[str, str]:
    host = (platform.system(), platform.machine())
    target = {
        ("Linux", "x86_64"): "linux-x86_64",
        ("Darwin", "arm64"): "darwin-arm64",
    }.get(host)
    if target is None:
        raise ValueError(
            "The media test prerequisite requires Linux x86_64 or macOS arm64"
        )
    if os.geteuid() == 0:
        raise ValueError("Run the media test prerequisite as the CI workspace owner")
    if not 1 <= jobs <= 32:
        raise ValueError("Media build jobs must be between 1 and 32")
    reusing = reuse_selected and any(key in environment for key in SELECTION_KEYS)
    if reusing and existing_product is not None:
        raise ValueError(
            "Selected media identity and existing product are separate modes"
        )
    if reusing:
        worker = Path(environment.get(SELECTION_KEYS[0], ""))
        if not worker.is_absolute() or worker.name != "foresight-media-worker":
            raise ValueError("Invalid selected media worker path")
        product = worker.parent
        output = build_media_worker.private_directory(output)
    elif existing_product is not None:
        if not existing_product.is_absolute():
            raise ValueError("Existing media product path must be absolute")
        product = existing_product
        worker = product / "foresight-media-worker"
        output = build_media_worker.private_directory(output)
    else:
        _build_with_logs(cache, output, fetch=fetch, jobs=jobs)
        product = output.resolve(strict=True)
        worker = product / "foresight-media-worker"
    prepared = media_worker_package.prepare(ROOT, product, target)
    if prepared.assembly_protocol != 1:
        raise ValueError("The media test prerequisite requires assembly protocol 1")
    digest = hashlib.sha256(prepared.binary).hexdigest()
    cdhash = media_worker_package._cdhash(worker) if target == "darwin-arm64" else ""
    if hashlib.sha256(worker.read_bytes()).hexdigest() != digest:
        raise ValueError("Media worker changed during identity verification")
    identity = dict(
        zip(
            SELECTION_KEYS,
            (str(worker), prepared.build_id, digest, cdhash),
            strict=True,
        )
    )
    if reusing and any(
        environment.get(key) != value for key, value in identity.items()
    ):
        raise ValueError("Selected media identity does not match verified worker")
    selected = dict(environment)
    selected.update(identity)
    with (output / "media-test-selection.json").open("x") as receipt:
        json.dump(
            {
                "worker": str(worker),
                "build_id": prepared.build_id,
                "sha256": digest,
                "cdhash": cdhash,
                "target": target,
                "reused_verified_selection": reusing,
                "reused_verified_build": existing_product is not None,
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
    parser.add_argument("--reuse-selected", action="store_true")
    parser.add_argument("--existing-product", type=Path)
    parser.add_argument("--environment-output", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.environment_output is not None and command:
        parser.error("Environment selection and an explicit command are separate modes")
    if not command and args.environment_output is None:
        parser.error("An explicit test gate command is required after --")
    environment = prepare_environment(
        args.cache,
        args.output,
        fetch=args.fetch,
        jobs=args.jobs,
        environment=dict(os.environ),
        reuse_selected=args.reuse_selected,
        existing_product=args.existing_product,
    )
    if args.environment_output is not None:
        # Only four fixed names cross the shell boundary; no eval or sourced text.
        descriptor = os.open(
            args.environment_output,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(descriptor, "wb") as stream:
            for key in SELECTION_KEYS:
                stream.write(key.encode() + b"\0" + environment[key].encode() + b"\0")
        return
    # Replace this process: the original gate still owns signals, exit status
    # and its existing deadlines. There is no unobserved intermediary child.
    sys.stdout.flush()
    sys.stderr.flush()
    os.execvpe(command[0], command, environment)  # noqa: S606 - Explicit non-root gate vector; preserve its process ownership.


if __name__ == "__main__":
    main()
