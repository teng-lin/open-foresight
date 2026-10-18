#!/usr/bin/env python3
"""Recover reviewed Ubuntu dependency objects without compiling or running old code.

The immutable seed is the secret-free tested cache exported by main run
39146018643, attempt 1. Its log records the exact manifest/config/layer digests
below. The original SDK remains provenance, not a blanket compatibility key:
LiteRT or Whisper updates do not invalidate flatc or SentencePiece objects.
"""

import argparse
from decimal import Decimal
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "teng-lin/open-foresight"
REGISTRY = "https://ghcr.io/v2/" + REPOSITORY + "/linux-sdk/"
MANIFEST = "67b3229e8dca34e444843e128e8984f8218df3045d3a2439049b022bdc25ea7e"
CONFIG = "0267817d91ea14bf6e5270302b1207be7fec9323c8ac396d4cc8a8af68bade56"
SOURCE = "886b64e8ba7230e8e91b062da88f836da4b3e6fd"
SDK = "sha256:db4719d854748f2308e0c42d0ca64e50d089e0f59fc5ccc702c1cd3a12092c60"
RUN = 39146018643
JOB = 117730031321
LAYERS = (
    ("c53869ef055c3ae1573d39e01f8ceb41c16359c3e1bc61b2b342a3d78a44067b", 2232102),
    ("8405e3e38775d661e941194e46714759fd84e72eb738fc0586fb947d4289047c", 240184150),
)
RECIPE = "72799264467c154d9174eb57a1e2b014ff7c684c87c1b967a211ca0fe42af4d3"
COMPILER = "13.3.0-6ubuntu2~24.04.1"
TREES = tuple(
    "src/build/_deps/" + dependency + suffix
    for dependency in ("flatbuffers", "sentencepiece")
    for suffix in ("-src", "-build", "-subbuild")
)
REQUIRED = {
    "src/build/_deps/flatbuffers-build/flatc": "99209cc2aae05d72bfc93072db6dbd635818efb5656fd8100269a502bf023b6f",
    "src/build/_deps/sentencepiece-build/src/libsentencepiece.a": "0b5900bdffb0ecfcd4a89eea9118c925252d1de254ef055798fec0ab49d577d3",
}
TOOLCHAIN_PROOF = "3a1b2d3aebcf832dd2ab3524cf8b1ca494063a4063cba5111655f33664eab4d7"
MAX_SELECTED_BYTES = 256 * 1024 * 1024


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical(text):
    return (
        "\n".join(
            line.strip()
            for line in text.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        )
        + "\n"
    )


def validate_recipe(root):
    recipe = (root / "cmake/ForesightInferenceDependencies.cmake").read_text()
    if hashlib.sha256(canonical(recipe).encode()).hexdigest() != RECIPE:
        raise ValueError(
            "Dependency pins/options changed; qualify a compatible seed before rebuilding"
        )
    minimal = (root / "packaging/app-dependencies/CMakeLists.txt").read_text()
    expected = """cmake_minimum_required(VERSION 3.22)
project(open_foresight LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(cmake/ForesightInferenceDependencies.cmake)
"""
    if canonical(minimal) != canonical(expected):
        raise ValueError(
            "Dependency root compiler settings changed; seed needs requalification"
        )


def verify_producer(request=subprocess.check_output):
    def api(path):
        return json.loads(
            request(["gh", "api", "repos/" + REPOSITORY + path], timeout=120)
        )

    run = api(f"/actions/runs/{RUN}")
    job = api(f"/actions/jobs/{JOB}")
    if (
        run.get("repository", {}).get("full_name") != REPOSITORY
        or run.get("head_sha") != SOURCE
        or run.get("head_branch") != "main"
        or run.get("event") != "push"
        or run.get("path") != ".github/workflows/macos.yml"
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or job.get("run_id") != RUN
        or job.get("run_attempt") != 1
        or job.get("name") != "linux-bundle"
        or job.get("conclusion") != "success"
    ):
        raise ValueError("The approved main dependency-cache producer is not qualified")


def validate_sdk_profile(image, status, os_release):
    """Match the actual consumed compiler ABI, not unrelated SDK components."""
    if image.get("Architecture") != "amd64" or image.get("Os") != "linux":
        raise ValueError("Dependency seed requires the Ubuntu amd64 compiler ABI")
    release = dict(
        line.split("=", 1) for line in os_release.splitlines() if "=" in line
    )
    if (
        release.get("ID", "").strip('"') != "ubuntu"
        or release.get("VERSION_ID", "").strip('"') != "24.04"
    ):
        raise ValueError("Dependency seed requires Ubuntu 24.04")
    packages = {}
    for block in status.split("\n\n"):
        values = dict(
            line.split(": ", 1)
            for line in block.splitlines()
            if ": " in line and not line.startswith(" ")
        )
        if values.get("Status") == "install ok installed":
            packages[values.get("Package")] = values
    for name in ("gcc-13", "g++-13", "libstdc++-13-dev"):
        entry = packages.get(name, {})
        if entry.get("Version") != COMPILER or entry.get("Architecture") != "amd64":
            raise ValueError(
                "Compiler package changed: "
                + name
                + "; qualify preserved objects, do not silently rebuild"
            )
    for name, prefix in (("libc6", "2.39-"), ("cmake", "3.28.")):
        if not packages.get(name, {}).get("Version", "").startswith(prefix):
            raise ValueError("Dependency ABI/build-tool version changed: " + name)
    for variable in image.get("Config", {}).get("Env", []):
        key, _, value = variable.partition("=")
        if key in {"CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"} and value:
            raise ValueError("Unqualified compiler environment override: " + key)
    return {
        "compiler_package": COMPILER,
        "platform": "linux/amd64",
        "ubuntu": "24.04",
        "glibc": "2.39",
        "cmake": "3.28",
    }


def toolchain_proof(root=ROOT):
    path = root / "tools/ubuntu_app_dependency_seed.json"
    if digest(path) != TOOLCHAIN_PROOF:
        raise ValueError("Consumed toolchain proof changed without requalification")
    proof = json.loads(path.read_text())
    if (
        proof.get("schema") != 1
        or proof.get("provenance", {}).get("source_commit") != SOURCE
    ):
        raise ValueError("Invalid consumed toolchain proof")
    return proof


def copied_hashes(data, base, wanted=None):
    """Read Docker's tar stream without extracting files or following links."""
    result = {}
    if len(data) > 256 * 1024 * 1024:
        raise ValueError("SDK inspection response exceeds its bounded file budget")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        for member in archive:
            name = safe_name(member.name)
            if not member.isfile():
                continue
            parts = PurePosixPath(name).parts
            if not parts:
                continue
            relative = PurePosixPath(*parts[1:])
            path = str(PurePosixPath(base) / relative)
            if wanted is not None and path not in wanted:
                continue
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("Missing SDK inspection file")
            hasher = hashlib.sha256()
            while chunk := stream.read(1024 * 1024):
                hasher.update(chunk)
            result[path] = hasher.hexdigest()
    return result


def verify_toolchain_files(container, proof, request=subprocess.check_output):
    """Compare only consumed headers, executables and transitive ELF runtimes."""
    expected = proof["files"]
    actual = {}
    for directory in ("/usr/include", "/usr/lib/gcc/x86_64-linux-gnu/13/include"):
        if not any(path.startswith(directory + "/") for path in expected):
            continue
        data = request(["docker", "cp", container + ":" + directory, "-"], timeout=60)
        actual.update(copied_hashes(data, directory, expected))
    for path in expected:
        if path in actual:
            continue
        # -L resolves this explicitly requested file inside the inspected image.
        # The container is never started and no producer executable is run.
        data = request(["docker", "cp", "-L", container + ":" + path, "-"], timeout=60)
        values = copied_hashes(data, str(PurePosixPath(path).parent))
        if len(values) != 1:
            raise ValueError("Invalid single-file SDK inspection: " + path)
        actual[path] = next(iter(values.values()))
    mismatches = [
        path for path, identity in expected.items() if actual.get(path) != identity
    ]
    if mismatches:
        raise ValueError(
            "Consumed SDK compiler/header/runtime bytes differ: "
            + ", ".join(mismatches[:20])
            + ". Preserved objects need a reviewed ABI-compatible migration; this is not permission to rebuild."
        )
    return {"proof_sha256": TOOLCHAIN_PROOF, "matched_files": len(expected)}


def sdk_profile(image, request=subprocess.check_output, root=ROOT):
    info = json.loads(
        request(
            ["docker", "image", "inspect", "--format", "{{json .}}", image],
            text=True,
            timeout=60,
        )
    )
    identifier = info.get("Id", "")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", identifier):
        raise ValueError("Invalid resolved SDK image ID")
    container = request(
        ["docker", "create", "--entrypoint", "/bin/true", identifier],
        text=True,
        timeout=60,
    ).strip()
    if not re.fullmatch(r"[a-f0-9]{12,64}", container):
        raise ValueError("Invalid SDK inspection container")
    try:
        with tempfile.TemporaryDirectory(prefix="app-dependency-sdk-") as temporary:
            path = Path(temporary)
            for source, target in (
                ("/var/lib/dpkg/status", "status"),
                ("/etc/os-release", "os-release"),
            ):
                request(
                    ["docker", "cp", container + ":" + source, str(path / target)],
                    timeout=60,
                )
            profile = validate_sdk_profile(
                info, (path / "status").read_text(), (path / "os-release").read_text()
            )
            closure = verify_toolchain_files(container, toolchain_proof(root), request)
    finally:
        request(["docker", "rm", container], timeout=60)
    return {**profile, **closure, "image_id": identifier, "requested_image": image}


def registry_token():
    with urllib.request.urlopen(
        "https://ghcr.io/token?scope=repository:" + REPOSITORY + "/linux-sdk:pull",
        timeout=60,
    ) as response:
        return json.load(response)["token"]


def fetch(cache, identity, size, endpoint, token):
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / identity
    if destination.exists():
        if (
            destination.is_symlink()
            or destination.stat().st_size != size
            or digest(destination) != identity
        ):
            raise ValueError("Invalid preserved cache blob: " + str(destination))
        return destination
    request = urllib.request.Request(  # noqa: S310 - fixed HTTPS registry.
        REGISTRY + endpoint,  # noqa: S310 - fixed HTTPS registry; digest endpoints only.
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.oci.image.manifest.v1+json",
        },
    )
    descriptor, name = tempfile.mkstemp(prefix="download-", dir=cache)
    partial = Path(name)
    try:
        with (
            os.fdopen(descriptor, "wb") as output,
            urllib.request.urlopen(request, timeout=120) as response,  # noqa: S310 - fixed HTTPS registry.
        ):
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > size:
                    raise ValueError("Registry blob exceeds approved size")
                output.write(chunk)
        if total != size or digest(partial) != identity:
            raise ValueError("Registry blob checksum/size mismatch")
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)
    return destination


def selected(name):
    return any(name == tree or name.startswith(tree + "/") for tree in TREES)


def safe_name(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\0" in name:
        raise ValueError("Unsafe layer member path")
    return path.as_posix()


def remove(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def apply_layers(layers, output):
    """Apply only the dependency closure, honoring overlay whiteouts and mtimes."""
    directories = {}
    total = 0
    for layer in layers:
        with tarfile.open(layer, "r|gz") as archive:
            for member in archive:
                name = safe_name(member.name)
                path = PurePosixPath(name)
                if path.name.startswith(".wh."):
                    target = (
                        path.parent
                        if path.name == ".wh..wh..opq"
                        else path.with_name(path.name[4:])
                    )
                    affected = [
                        str(target) if selected(str(target)) else tree
                        for tree in TREES
                        if selected(str(target)) or tree.startswith(str(target) + "/")
                    ]
                    for item in set(affected):
                        destination = output / item
                        if not destination.parent.resolve().is_relative_to(
                            output.resolve()
                        ):
                            raise ValueError("Whiteout traverses a symlink")
                        if path.name == ".wh..wh..opq" and str(target) == item:
                            if destination.is_dir() and not destination.is_symlink():
                                for child in destination.iterdir():
                                    remove(child)
                        else:
                            remove(destination)
                    continue
                if not selected(name):
                    continue
                if member.mode & ~0o777 or member.size > 64 * 1024 * 1024:
                    raise ValueError("Unqualified dependency member mode/size")
                destination = output / name
                parent = destination.parent
                if not parent.resolve().is_relative_to(output.resolve()):
                    raise ValueError("Dependency member traverses a symlink")
                parent.mkdir(parents=True, exist_ok=True)
                stamp = int(
                    Decimal(str(member.pax_headers.get("mtime", member.mtime)))
                    * 1_000_000_000
                )
                if member.isdir():
                    if destination.is_symlink() or (
                        destination.exists() and not destination.is_dir()
                    ):
                        remove(destination)
                    destination.mkdir(exist_ok=True)
                    directories[name] = (member.mode, stamp)
                    continue
                if member.isfile():
                    total += member.size
                    if total > MAX_SELECTED_BYTES:
                        raise ValueError(
                            "Dependency seed exceeds approved extraction budget"
                        )
                    if destination.exists() or destination.is_symlink():
                        remove(destination)
                    with destination.open("xb") as stream:
                        source = archive.extractfile(member)
                        if source is None:
                            raise ValueError("Missing regular layer member")
                        shutil.copyfileobj(source, stream)
                elif member.issym():
                    if PurePosixPath(member.linkname).is_absolute():
                        raise ValueError("Absolute dependency symlink")
                    target = (parent / member.linkname).resolve()
                    if not target.is_relative_to(output.resolve() / "src/build/_deps"):
                        raise ValueError("Escaping dependency symlink")
                    if destination.exists() or destination.is_symlink():
                        remove(destination)
                    destination.symlink_to(member.linkname)
                elif member.islnk():
                    target = output / safe_name(member.linkname)
                    if (
                        not selected(member.linkname)
                        or target.is_symlink()
                        or not target.is_file()
                        or not target.resolve().is_relative_to(output.resolve())
                    ):
                        raise ValueError("Invalid dependency hardlink")
                    if destination.exists() or destination.is_symlink():
                        remove(destination)
                    os.link(target, destination)
                else:
                    raise ValueError("Unsupported dependency layer member")
                if not destination.is_symlink():
                    destination.chmod(member.mode)
                os.utime(destination, ns=(stamp, stamp), follow_symlinks=False)
    for name, (mode, stamp) in sorted(
        directories.items(), key=lambda row: -len(PurePosixPath(row[0]).parts)
    ):
        path = output / name
        if path.is_dir() and not path.is_symlink():
            path.chmod(mode)
            os.utime(path, ns=(stamp, stamp))


def materialize(layers, output, profile):
    if output.exists() or output.is_symlink():
        raise ValueError(
            "Choose an absent seed output; existing successful outputs are preserved"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="app-dependency-seed-", dir=output.parent))
    try:
        apply_layers(layers, temporary)
        for name, identity in REQUIRED.items():
            if (
                not (temporary / name).is_file()
                or (temporary / name).is_symlink()
                or digest(temporary / name) != identity
            ):
                raise ValueError(
                    "The reviewed dependency output is missing or changed: " + name
                )
        qualification = {
            "schema": 1,
            "producer_run": RUN,
            "producer_job": JOB,
            "source_commit": SOURCE,
            "original_sdk": SDK,
            "cache_manifest": "sha256:" + MANIFEST,
            "recipe_sha256": RECIPE,
            "toolchain_proof_sha256": TOOLCHAIN_PROOF,
            "consumer_sdk": profile,
            "dependency_outputs": REQUIRED,
        }
        (temporary / "qualification.json").write_text(
            json.dumps(qualification, indent=2) + "\n"
        )
        temporary.rename(output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def prepare(image, output, cache, root=ROOT):
    validate_recipe(root)
    verify_producer()
    profile = sdk_profile(image, root=root)
    token = registry_token()
    manifest_path = fetch(cache, MANIFEST, 6858, "manifests/sha256:" + MANIFEST, token)
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("config", {}).get("digest") != "sha256:" + CONFIG:
        raise ValueError("Invalid approved BuildKit config")
    config_path = fetch(cache, CONFIG, 3228, "blobs/sha256:" + CONFIG, token)
    config = json.loads(config_path.read_text())
    if (
        config["records"][0]["layers"][0]["layer"] != 8
        or config["layers"][8] != {"blob": "sha256:" + LAYERS[1][0], "parent": 14}
        or config["layers"][14]["blob"] != "sha256:" + LAYERS[0][0]
    ):
        raise ValueError("Invalid approved layer ordering")
    inventory = {entry["digest"]: entry["size"] for entry in manifest["layers"]}
    for identity, size in LAYERS:
        if inventory.get("sha256:" + identity) != size:
            raise ValueError("Invalid approved layer descriptor")
    layers = [
        fetch(cache, identity, size, "blobs/sha256:" + identity, token)
        for identity, size in LAYERS
    ]
    materialize(layers, output, profile)
    print(
        json.dumps(
            {
                "seed": str(output),
                "reused": True,
                "compiled": False,
                "producer_run": RUN,
            }
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-image", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--cache-dir", type=Path, default=ROOT / "build/app-dependency-blobs"
    )
    args = parser.parse_args()
    prepare(args.sdk_image, args.output, args.cache_dir)


if __name__ == "__main__":
    main()
