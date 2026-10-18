#!/usr/bin/env python3
"""Retain Linux dependency images without publishing from pull requests."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.sdk_build_recipe import docker_build_command  # noqa: E402
from tools import sdk_build_transport  # noqa: E402
from tools.sdk_approval_bridge import descriptor_approval  # noqa: E402

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
            stderr=subprocess.STDOUT,
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
        or (
            value.get("identity") != artifacts.fingerprint(component)
            and not descriptor_approval(
                prefix,
                component,
                value.get("identity"),
                artifacts.fingerprint(component),
                artifacts.digest,
            )
        )
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


def archive_manifests(archive, original):
    """Bind a containerd manifest ID to the receipt's original saved config ID.

    Docker's containerd store addresses images by manifest, unlike the classic
    store's config ID. Read only content-addressed OCI metadata from the already
    checksum-verified archive; load stdout and mutable tags are not authority.
    """
    with tarfile.open(archive, "r:") as saved:
        members = {}
        for member in saved:
            if member.name in members:
                raise ValueError("Duplicate SDK archive member")
            members[member.name] = member

        def read(name):
            member = members.get(name)
            if member is None or not member.isfile() or member.size > 8 * 1024 * 1024:
                raise ValueError("Missing or invalid SDK archive OCI metadata")
            stream = saved.extractfile(member)
            if stream is None:
                raise ValueError("Unreadable SDK archive OCI metadata")
            with stream:
                return stream.read()

        def blob(descriptor):
            digest = descriptor.get("digest", "")
            if not IMAGE_ID.fullmatch(digest):
                raise ValueError("Invalid SDK archive OCI digest")
            data = read("blobs/sha256/" + digest.removeprefix("sha256:"))
            if (
                len(data) != descriptor.get("size")
                or "sha256:" + hashlib.sha256(data).hexdigest() != digest
            ):
                raise ValueError("SDK archive OCI metadata checksum mismatch")
            return json.loads(data)

        index = json.loads(read("index.json"))
        matches = []
        visited: set[str] = set()

        def visit(descriptor, ancestors):
            digest = descriptor.get("digest", "")
            if digest in visited or len(visited) >= 64:
                raise ValueError("Duplicate or excessive SDK archive OCI inventory")
            visited.add(digest)
            document = blob(descriptor)
            children = document.get("manifests")
            if children is not None:
                if not isinstance(children, list):
                    raise ValueError("Invalid SDK archive OCI image inventory")
                for child in children:
                    visit(child, [digest, *ancestors])
                return
            config_descriptor = document.get("config")
            if not isinstance(config_descriptor, dict):
                raise ValueError("SDK archive has an invalid image manifest")
            config = blob(config_descriptor)
            layers = document.get("layers")
            if not isinstance(layers, list):
                raise ValueError("Invalid SDK archive layer inventory")
            for layer in layers:
                layer_digest = layer.get("digest", "")
                member = members.get(
                    "blobs/sha256/" + layer_digest.removeprefix("sha256:")
                )
                if (
                    not IMAGE_ID.fullmatch(layer_digest)
                    or not isinstance(layer.get("mediaType"), str)
                    or not layer["mediaType"].startswith("application/")
                    or member is None
                    or not member.isfile()
                    or member.size != layer.get("size")
                ):
                    raise ValueError("Missing or invalid SDK archive layer blob")
            if original in (digest, config_descriptor["digest"], *ancestors) and (
                config.get("os"),
                config.get("architecture"),
            ) == ("linux", "amd64"):
                matches.append([digest, *ancestors])

        descriptors = index.get("manifests", [])
        if not isinstance(descriptors, list):
            raise ValueError("Invalid SDK archive OCI image inventory")
        for descriptor in descriptors:
            visit(descriptor, [])
        if len(matches) != 1:
            raise ValueError("SDK archive has no unique manifest for original image ID")
        return matches[0]


def load(prefix, component, tag):
    """Load a qualified component into this job's Docker daemon."""
    value = record(prefix, component)
    if value.get("transport", "registry") == "registry":
        image = value["image"]
        run(["docker", "pull", image])
    else:
        image = value["image_id"]
        run(["docker", "image", "load", "--input", str(prefix / "image.tar")])
    try:
        loaded = inspect(image)
    except subprocess.CalledProcessError as error:
        # Only the known config-ID lookup failure permits the OCI lookup. Daemon,
        # permission, transport and platform errors remain fatal.
        diagnostic = error.output or ""
        if isinstance(diagnostic, bytes):
            diagnostic = diagnostic.decode("utf-8", errors="replace")
        if (
            value.get("transport") != "docker-archive"
            or diagnostic.strip()
            != f"Error response from daemon: No such image: {image}"
        ):
            raise
        for candidate in archive_manifests(prefix / "image.tar", value["image_id"]):
            try:
                loaded = inspect(candidate)
            except subprocess.CalledProcessError as candidate_error:
                if str(candidate_error.output).strip() != (
                    f"Error response from daemon: No such image: {candidate}"
                ):
                    raise
            else:
                image = candidate
                break
        else:
            raise ValueError(
                "Verified SDK archive manifests were not loaded"
            ) from error
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


def describe(prefix, component, image, source_prefix=None):
    """Publish a fresh registry descriptor while preserving original provenance.

    The current receipt qualifies the descriptor/promotion. Source qualification
    remains separate data, including its untouched original source receipt and
    any prior reused_from history; it is never imported as approval authority.
    """
    local_tag(component)
    if not REGISTRY_IMAGE.fullmatch(image):
        raise ValueError("Descriptor requires an immutable SDK registry image")
    if prefix.exists() or prefix.is_symlink():
        raise ValueError("Descriptor destination already exists; preserve its outputs")
    qualification = None
    if source_prefix is not None and (
        source_prefix.exists() or source_prefix.is_symlink()
    ):
        if source_prefix.is_symlink() or not source_prefix.is_dir():
            raise ValueError("Verified SDK source prefix must be a directory")
        for name in ("source-qualification.json", "approved-source.json"):
            source = source_prefix / name
            if source.is_symlink():
                raise ValueError("SDK source qualification must be regular")
            if source.is_file():
                qualification = json.loads(source.read_text())
                if not isinstance(qualification, dict):
                    raise ValueError("SDK source qualification must be an object")
                receipt = qualification.get("source_receipt")
                if (
                    not isinstance(receipt, dict)
                    or receipt.get("component") != component
                ):
                    raise ValueError("SDK source qualification component mismatch")
                break
        if qualification is None:
            raise ValueError(
                "Verified SDK promotion is missing its original qualification"
            )
    prefix.mkdir(parents=True)
    (prefix / "image.json").write_text(json.dumps({"image": image}) + "\n")
    if qualification is not None:
        (prefix / "source-qualification.json").write_text(
            json.dumps(qualification, indent=2) + "\n"
        )


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
            if (prefix / "approved-source.json").is_file():
                print(
                    f"Reuse {component}: retaining its approved original receipt and bytes; no new payload or SDK build",
                    flush=True,
                )
                return "approved-original"
            artifacts.pack(component, identity, prefix, output)
            return
        else:
            print(
                f"SDK cache decision for {component} ({identity}): no compatible qualified artifact available; checking read-only registry layers and verified parent images before compiling this component. Network/provenance errors abort rather than authorize a rebuild.",
                flush=True,
            )
            transport = sdk_build_transport.prepare(
                repository,
                component,
                expected_repository=os.environ.get("GITHUB_REPOSITORY", repository),
            )
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
                sdk_build_transport.command(
                    docker_build_command(
                        component, image, parent_images, artifacts.ROOT
                    ),
                    transport,
                ),
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
    parser.add_argument(
        "command", choices=("produce", "resolve", "promote", "describe")
    )
    parser.add_argument("--component", choices=COMPONENTS, default="linux-sdk")
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--source-prefix", type=Path)
    parser.add_argument("--discard-archive", action="store_true")
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--own-head", default="")
    parser.add_argument("--own-pr", type=int, default=0)
    args = parser.parse_args()
    if args.command == "describe":
        if args.prefix is None or args.tag is None:
            parser.error("describe requires --prefix and --tag")
        describe(args.prefix, args.component, args.tag, args.source_prefix)
        return
    if args.command == "produce":
        if args.output is None:
            parser.error("produce requires --output")
        result = produce(
            args.component, args.output, args.repository, args.own_head, args.own_pr
        )
        if destination := os.environ.get("GITHUB_OUTPUT"):
            with open(destination, "a") as stream:
                stream.write(f"original={str(result == 'approved-original').lower()}\n")
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
