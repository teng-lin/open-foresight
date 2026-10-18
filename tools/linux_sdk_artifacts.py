#!/usr/bin/env python3
"""Retain Linux dependency images without publishing from pull requests."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.sdk_build_recipe import docker_build_command  # noqa: E402

COMPONENTS = ("linux-core", "linux-litert", "linux-whisper", "linux-sdk")
REGISTRY_IMAGE = re.compile(r"ghcr\.io/[a-z0-9/_.-]+@sha256:[a-f0-9]{64}")
IMAGE_ID = re.compile(r"sha256:[a-f0-9]{64}")


def local_tag(component):
    if component not in COMPONENTS:
        raise ValueError("Unknown Linux SDK component")
    return f"foresight-{component.removeprefix('linux-')}:pr"


def run(arguments, timeout=1800):
    subprocess.run(arguments, check=True, timeout=timeout)


def inspect(image):
    value = json.loads(
        subprocess.check_output(
            ["docker", "image", "inspect", image, "--format", "{{json .}}"],
            text=True,
            timeout=300,
        )
    )
    if not IMAGE_ID.fullmatch(value.get("Id", "")):
        raise ValueError("Invalid Docker image configuration ID")
    if (value.get("Os"), value.get("Architecture")) != ("linux", "amd64"):
        raise ValueError("Linux SDK image must target linux/amd64")
    return value["Id"]


def record(prefix, component):
    local_tag(component)
    value = json.loads((prefix / "image.json").read_text())
    if value.get("transport", "registry") == "registry":
        if not REGISTRY_IMAGE.fullmatch(value.get("image", "")):
            raise ValueError("Unpinned SDK registry image")
        return value
    if (
        value.get("schema") != 1
        or value.get("transport") != "docker-archive"
        or value.get("component") != component
        or value.get("identity") != artifacts.fingerprint(component)
        or value.get("platform") != "linux/amd64"
        or not IMAGE_ID.fullmatch(value.get("image_id", ""))
    ):
        raise ValueError("Linux SDK archive identity or platform mismatch")
    archive = prefix / "image.tar"
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("Linux SDK archive must be a regular file")
    if artifacts.digest(archive) != value.get("archive_sha256"):
        raise ValueError("Linux SDK archive checksum mismatch")
    return value


def load(prefix, component, tag):
    """Load a qualified component into this job's Docker daemon."""
    value = record(prefix, component)
    if value.get("transport", "registry") == "registry":
        image = value["image"]
        run(["docker", "pull", image])
    else:
        image = value["image_id"]
        run(["docker", "image", "load", "--input", str(prefix / "image.tar")])
    loaded = inspect(image)
    if value.get("transport") == "docker-archive" and loaded != image:
        raise ValueError("Loaded SDK image configuration ID mismatch")
    run(["docker", "image", "tag", image, tag])
    return tag


def resolve(prefix, component="linux-sdk"):
    """Keep registry manifests immutable; load retained PR images locally."""
    value = record(prefix, component)
    if value.get("transport", "registry") == "registry":
        return value["image"]
    return load(prefix, component, local_tag(component))


def promote(prefix, component, tag):
    """Publish an approved saved image without recompiling its dependencies."""
    if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
        raise RuntimeError("Pull requests cannot publish SDK images")
    value = record(prefix, component)
    if value.get("transport", "registry") == "registry":
        return value["image"]
    load(prefix, component, tag)
    run(["docker", "push", tag])
    return tag


def qualify(component, image):
    inspect(image)
    if component in ("linux-core", "linux-sdk"):
        version = subprocess.check_output(
            ["docker", "run", "--rm", image, "/opt/toolchain/bin/protoc", "--version"],
            text=True,
            timeout=300,
        ).strip()
        if version != "libprotoc 35.1":
            raise ValueError("Retained SDK protobuf version mismatch")
    else:
        path = (
            "/opt/litert-extensions/build-manifest.json"
            if component == "linux-litert"
            else "/opt/whisper-runtime/whisper-cli"
        )
        run(["docker", "run", "--rm", image, "test", "-s", path], timeout=300)


def produce(component, output, repository, own_head="", own_pr=0):
    """Reuse one qualified component, or build it from qualified parent images."""
    image = local_tag(component)
    identity = artifacts.fingerprint(component)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        temporary = Path(directory)
        prefix = temporary / "payload"
        reused = artifacts.pull(
            repository, component, identity, prefix, own_head=own_head, own_pr=own_pr
        )
        if reused:
            # pull() has verified the trusted, successful producer attempt and
            # envelope checksum. Validate component/platform/image metadata and
            # the saved-image checksum before forwarding its qualified output.
            # Consumers still inspect the actual image after loading it.
            record(prefix, component)
            artifacts.pack(component, identity, prefix, output)
            return
        else:
            parent_images = {}
            for parent in artifacts.PARENTS.get(component, []):
                parent_prefix = temporary / parent
                if not artifacts.pull(
                    repository,
                    parent,
                    artifacts.fingerprint(parent),
                    parent_prefix,
                    wait=300,
                    own_head=own_head,
                    own_pr=own_pr,
                ):
                    raise RuntimeError(f"Qualified parent {parent} is unavailable")
                parent_image = load(parent_prefix, parent, local_tag(parent))
                shutil.rmtree(parent_prefix)
                parent_images[parent] = parent_image
            run(
                docker_build_command(component, image, parent_images, artifacts.ROOT),
                timeout=10800,
            )
        qualify(component, image)
        if not reused:
            prefix.mkdir()
            image_id = inspect(image)
            archive = prefix / "image.tar"
            run(["docker", "image", "save", "--output", str(archive), image_id])
            (prefix / "image.json").write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "transport": "docker-archive",
                        "component": component,
                        "identity": identity,
                        "image_id": image_id,
                        "platform": "linux/amd64",
                        "archive_sha256": artifacts.digest(archive),
                    }
                )
                + "\n"
            )
        artifacts.pack(component, identity, prefix, output)


def write_outputs(image, application_cache=True):
    cache = image.split("@")[0] + ":app-buildcache-x86-64" if "@" in image else ""
    if destination := os.environ.get("GITHUB_OUTPUT"):
        with open(destination, "a") as stream:
            stream.write(f"image={image}\n")
            if application_cache:
                stream.write(f"cache={cache}\n")
    print(f"Qualified SDK image: {image}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("produce", "resolve", "promote"))
    parser.add_argument("--component", choices=COMPONENTS, default="linux-sdk")
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--discard-archive", action="store_true")
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-head", default="")
    parser.add_argument("--own-pr", type=int, default=0)
    args = parser.parse_args()
    if args.command == "produce":
        if args.output is None:
            parser.error("produce requires --output")
        produce(
            args.component, args.output, args.repository, args.own_head, args.own_pr
        )
    else:
        if args.prefix is None:
            parser.error("--prefix is required")
        if args.command == "promote":
            if args.tag is None:
                parser.error("promote requires --tag")
            image = promote(args.prefix, args.component, args.tag)
        else:
            image = resolve(args.prefix, args.component)
        write_outputs(image, application_cache=args.command == "resolve")
        if args.discard_archive:
            (args.prefix / "image.tar").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
