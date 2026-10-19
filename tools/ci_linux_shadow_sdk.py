#!/usr/bin/env python3
"""Resolve shadow SDKs before building only an unavailable assembled SDK layer."""

import argparse
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import ci_dependency_wait as waiter  # noqa: E402
from tools import integration_application as application  # noqa: E402
from tools import linux_sdk_artifacts as sdk  # noqa: E402


def load(prefix):
    image = sdk.resolve(prefix, load_registry=True)
    # The loaded and inspected image retains the SDK; discard only its verified
    # transport copy, as other application consumers do after loading it.
    (prefix / "image.tar").unlink(missing_ok=True)
    return image


def prepare(repository, source, own_pr, fork, directory):
    identity = artifacts.fingerprint("linux-sdk")
    prefix = directory / "verified"
    if waiter.fetch(
        repository, "linux-sdk", prefix, source, own_pr, 1800, optional=fork
    ):
        sdk.write_outputs(load(prefix))
        return False
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
    result = sdk.produce("linux-sdk", produced, repository, source, own_pr)
    if result == "approved-original":
        # A compatible producer may become visible between the two lookups.
        if not waiter.fetch(
            repository, "linux-sdk", prefix, source, own_pr, 0, optional=True
        ):
            raise RuntimeError("Approved SDK became unavailable during verified reuse")
        sdk.write_outputs(load(prefix))
        return False
    artifacts.unpack("linux-sdk", identity, produced, prefix)
    image = load(prefix)
    application.save_sdk(
        source, image, directory / "in-run", shadow=True, source_prefix=prefix
    )
    sdk.write_outputs(image)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write("in_run=true\n")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--own-pr", type=int, default=0)
    parser.add_argument("--fork", action="store_true")
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    prepare(
        os.environ["GITHUB_REPOSITORY"],
        args.source,
        args.own_pr,
        args.fork,
        args.directory,
    )


if __name__ == "__main__":
    main()
