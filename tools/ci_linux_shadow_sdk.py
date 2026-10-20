#!/usr/bin/env python3
"""Resolve shadow SDKs before building only an unavailable assembled SDK layer."""

import argparse
import json
import os
import re
import shutil
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import ci_dependency_wait as waiter  # noqa: E402
from tools import integration_application as application  # noqa: E402
from tools import linux_sdk_artifacts as sdk  # noqa: E402


def reference(prefix, repository):
    """Forward the original verified artifact, never a fresh cache lookup."""
    for name in ("source-qualification.json", "approved-source.json"):
        path = prefix / name
        if path.is_file() and not path.is_symlink():
            value = json.loads(path.read_text())
            run_id, artifact_id = value.get("producer_run"), value.get("artifact_id")
            checksum = value.get("artifact_digest")
            if (
                type(run_id) is not int
                or run_id < 1
                or type(artifact_id) is not int
                or artifact_id < 1
            ):
                raise ValueError("Verified SDK lacks its original artifact reference")
            if name == "approved-source.json":
                metadata = artifacts.api(repository, f"actions/artifacts/{artifact_id}")
                if (
                    metadata.get("id") != artifact_id
                    or metadata.get("workflow_run", {}).get("id") != run_id
                ):
                    raise ValueError("Approved SDK artifact reference changed")
                checksum = metadata.get("digest")
            if not isinstance(checksum, str) or not re.fullmatch(
                r"sha256:[a-f0-9]{64}", checksum
            ):
                raise ValueError("Verified SDK lacks its original artifact checksum")
            if output := os.environ.get("GITHUB_OUTPUT"):
                with open(output, "a") as stream:
                    stream.write(
                        f"producer_run={run_id}\nproducer_artifact_id={artifact_id}\nproducer_artifact_digest={checksum}\n"
                    )
            return {
                "producer_run": run_id,
                "artifact_id": artifact_id,
                "artifact_digest": checksum,
                "source_receipt": value.get(
                    "source_receipt", value.get("original_source_receipt")
                ),
            }
    raise ValueError("Verified SDK lacks its original producer qualification")


def load(prefix, *, retain_archive=False):
    image = sdk.resolve(prefix, load_registry=True)
    # The loaded and inspected image retains the SDK; discard only its verified
    # transport copy, as other application consumers do after loading it.
    if not retain_archive:
        (prefix / "image.tar").unlink(missing_ok=True)
    return image


def forward(prefix, directory, source, image, *, reuse_archive):
    application.save_sdk(
        source,
        image,
        directory / "in-run",
        shadow=True,
        source_prefix=prefix,
        reuse_archive=reuse_archive,
    )
    shutil.rmtree(prefix)
    sdk.write_outputs(image)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write("in_run=true\n")
    return True


def prepare(repository, source, own_pr, fork, directory, *, validate_in_run=False):
    if validate_in_run:
        ref = re.fullmatch(
            r"refs/pull/([1-9][0-9]*)/(?:merge|head)", os.getenv("GITHUB_REF", "")
        )
        if (
            os.getenv("GITHUB_EVENT_NAME") != "pull_request"
            or ref is None
            or int(ref[1]) != own_pr
            or os.getenv("CI_TIER") != "pr"
            or os.getenv("SHADOW_PREVIEW", "false") != "false"
        ):
            raise ValueError(
                "SDK transport validation requires this PR's ref and pr tier, without preview"
            )
    identity = artifacts.fingerprint("linux-sdk")
    prefix = directory / "verified"
    if waiter.fetch(
        repository,
        "linux-sdk",
        prefix,
        source,
        own_pr,
        1800,
        optional=fork or validate_in_run,
    ):
        original = reference(prefix, repository)
        if validate_in_run:
            descriptor = sdk.record(prefix, "linux-sdk")
            reuse_archive = descriptor.get("transport", "registry") == "docker-archive"
            image = load(prefix, retain_archive=reuse_archive)
            print(
                "Shadow SDK transport validation: forwarding the current qualified image "
                "with its original provenance; transport export is not an SDK compilation.",
                flush=True,
            )
            print(
                "Original SDK qualification: " + json.dumps(original, sort_keys=True),
                flush=True,
            )
            return forward(
                prefix, directory, source, image, reuse_archive=reuse_archive
            )
        sdk.write_outputs(load(prefix))
        return False
    if validate_in_run:
        raise RuntimeError(
            "SDK transport validation requires an existing qualified SDK; no SDK build is allowed"
        )
    if not fork:
        raise RuntimeError(artifacts.unavailable_message("linux-sdk", identity))
    print(
        "Shadow fork SDK: no compatible verified assembled SDK is available. "
        "Reuse qualified core/LiteRT/Whisper parents and read-only registry layers; "
        "build only the assembled SDK layer if its cached output is unavailable. "
        "Missing qualified parents and network/provenance errors remain fatal.",
        flush=True,
    )
    produced = directory / "produced"
    result = sdk.produce(
        "linux-sdk", produced, repository, source, own_pr, retain_payload=prefix
    )
    if result == "reused":
        reference(prefix, repository)
        sdk.write_outputs(load(prefix))
        return False
    if result != "built":
        raise ValueError("Unexpected SDK producer result")
    image = load(prefix, retain_archive=True)
    return forward(prefix, directory, source, image, reuse_archive=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--fork", action="store_true")
    parser.add_argument(
        "--validate-in-run-transport",
        action="store_true",
        help="PR-only: forward an existing qualified SDK through an in-run archive without compiling",
    )
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    prepare(
        os.environ["GITHUB_REPOSITORY"],
        args.source,
        args.own_pr,
        args.fork,
        args.directory,
        validate_in_run=args.validate_in_run_transport,
    )


if __name__ == "__main__":
    main()
