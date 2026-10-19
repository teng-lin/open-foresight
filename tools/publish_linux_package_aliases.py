#!/usr/bin/env python3
"""Publish readable Linux aliases from qualified descriptors for current main."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools import ci_registry as registry  # noqa: E402
from tools.linux_sdk_artifacts import COMPONENTS, record  # noqa: E402

MAX_DESCRIPTOR_BYTES = 16 * 1024 * 1024


def published_descriptor(repository, component, identity):
    """Read a verified main registry descriptor without loading original SDKs.

    Ordinary dependency consumers may prefer an approved archive original.
    Aliases require a publisher's immutable registry reference instead. Keep
    the shared producer, attempt, source and checksum verification intact;
    original provenance inside the descriptor remains data, not authority.
    """
    name = artifacts.name(component, identity)
    errors: list[ValueError] = []
    seen = set()
    page = 1
    while True:
        batch = artifacts.api(
            repository, f"actions/artifacts?name={name}&per_page=100&page={page}"
        )["artifacts"]
        fresh = [item for item in batch if item["id"] not in seen]
        if batch and not fresh:
            raise RuntimeError("Repeated descriptor page; preserve SDK artifacts")
        for item in fresh:
            seen.add(item["id"])
            if (
                item.get("expired")
                or item.get("name") != name
                or type(item.get("size_in_bytes")) is not int
                or not 0 < item["size_in_bytes"] <= MAX_DESCRIPTOR_BYTES
            ):
                continue
            run = artifacts.api(
                repository, f"actions/runs/{item['workflow_run']['id']}"
            )
            if (run.get("repository") or {}).get(
                "full_name"
            ) != repository or not artifacts.trusted_run(
                run, component, repository=repository
            ):
                continue
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / "descriptor.zip"
                artifacts.download_zip(repository, item, archive)
                source = root / "envelope"
                source.mkdir()
                with zipfile.ZipFile(archive) as stream:
                    names = stream.namelist()
                    if len(names) != 2 or set(names) != {
                        "identity.json",
                        "payload.tar.gz",
                    }:
                        raise ValueError("Unexpected registry descriptor ZIP members")
                    for member in names:
                        if stream.getinfo(member).file_size > MAX_DESCRIPTOR_BYTES:
                            raise ValueError("Oversized registry descriptor member")
                        (source / member).write_bytes(stream.read(member))
                receipt = json.loads((source / "identity.json").read_text())
                if not any(
                    job.get("status") == "completed"
                    and artifacts.candidate_verified(
                        repository, run, component, identity, receipt, job, item, errors
                    )
                    for job in artifacts.dependency_jobs(repository, run["id"])
                ):
                    continue
                payload = source / "payload.tar.gz"
                if artifacts.digest(payload) != receipt.get("sha256"):
                    raise ValueError("Registry descriptor payload checksum mismatch")
                # A small historical archive can also pass the transfer bound.
                # Inspect only its metadata; never materialize image.tar or load it.
                with tarfile.open(payload, mode="r|gz") as stream:
                    descriptor = None
                    for entry in stream:
                        if entry.name == "payload/image.json":
                            if not entry.isfile() or entry.size > 65536:
                                raise ValueError("Invalid registry descriptor metadata")
                            incoming = stream.extractfile(entry)
                            if incoming is None:
                                raise ValueError("Missing registry descriptor metadata")
                            descriptor = json.load(incoming)
                            break
                if not isinstance(descriptor, dict):
                    raise ValueError("Missing registry descriptor metadata")
                if descriptor.get("transport", "registry") != "registry":
                    continue
                prefix = root / "descriptor"
                artifacts.unpack(component, identity, source, prefix)
                approval = prefix / "approved-source.json"
                if approval.exists() or approval.is_symlink():
                    raise ValueError("Imported approval cannot authorize an alias")
                return record(prefix, component)
        if len(batch) < 100:
            break
        page += 1
    if errors:
        raise errors[-1]
    raise RuntimeError(
        f"Published {component} registry descriptor unavailable; preserve SDKs "
        "and inspect successful dependency publisher jobs"
    )


def require_main(repository, head):
    main = json.loads(
        subprocess.check_output(
            ["gh", "api", f"repos/{repository}/commits/main"], text=True, timeout=300
        )
    )["sha"]
    if main != head:
        raise RuntimeError("Main advanced; refusing to publish stale aliases")


def publish(repository):
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, timeout=30
    ).strip()
    require_main(repository, head)
    for component in COMPONENTS:
        identity = artifacts.fingerprint(component)
        descriptor = published_descriptor(repository, component, identity)
        image = descriptor.get("image", "")
        expected = f"ghcr.io/{repository.lower()}/{component}"
        if descriptor.get(
            "transport", "registry"
        ) != "registry" or not image.startswith(expected + "@sha256:"):
            raise ValueError(
                "Alias source must be this package's immutable registry image"
            )
        require_main(repository, head)
        alias = expected + ":current"
        subprocess.run(
            [
                "docker",
                "buildx",
                "imagetools",
                "create",
                "--prefer-index=false",
                "--tag",
                alias,
                image,
            ],
            check=True,
            timeout=300,
        )
        if registry.inspect(alias) != image:
            raise RuntimeError(f"Published alias digest mismatch: {alias}")
        print(f"Verified {alias} -> {image}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    publish(args.repository)


if __name__ == "__main__":
    main()
