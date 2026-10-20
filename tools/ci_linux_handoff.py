#!/usr/bin/env python3
"""Transfer the exact /src tree between Ubuntu build and test containers.

The verified dependency-only image retains build/_deps on both runners. Only
application/compiler outputs and the source actually compiled enter the archive.
The manifest binds every byte, mode, link and nanosecond timestamp to the source,
CI input identity and original producer. It is never a cached test result.
"""

import argparse
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

# Packaged installers and their bundle travel separately; tests consume build/.
EXCLUDED = {".git", ".venv", "build/_deps", "dist"}
EXTERNAL_LINK_ROOTS = ("/opt/", "/usr/")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def portable_input(directory, revision, *, required=False):
    """Bind separately transported package bytes without copying them into /src."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from tools.release_asset_acceptance import verify_checksum

    if directory.is_symlink() or directory.parent.is_symlink():
        raise ValueError("Handoff package directory must be regular")
    packages = list(directory.glob("*.tar.gz"))
    if not packages and not required:
        return None
    if len(packages) != 1:
        raise ValueError("Handoff requires one unambiguous portable package")
    package = packages[0]
    checksum = package.with_name(package.name + ".sha256")
    metadata = package.with_name(package.name + ".build.json")
    if list(directory.glob("*.build.json")) != [metadata]:
        raise ValueError("Handoff requires unambiguous package metadata")
    if any(
        path.is_symlink() or not path.is_file()
        for path in (package, checksum, metadata)
    ):
        raise ValueError("Handoff package and sidecars must be regular files")
    actual = verify_checksum(package, checksum)
    record = json.loads(metadata.read_text())
    if (
        not isinstance(record, dict)
        or record.get("revision") != revision
        or record.get("sha256") != actual
        or record.get("format") != "tar"
    ):
        raise ValueError(
            "Handoff package metadata differs from its actual source/bytes"
        )
    return {
        "name": package.name,
        "size": package.stat().st_size,
        "sha256": actual,
        "checksum_sha256": digest(checksum),
        "metadata_sha256": digest(metadata),
    }


def excluded(name):
    return any(name == item or name.startswith(item + "/") for item in EXCLUDED)


def safe_name(name):
    path = PurePosixPath(name)
    if (
        not name
        or str(path) != name
        or path.is_absolute()
        or ".." in path.parts
        or excluded(name)
    ):
        raise ValueError("Unsafe handoff member: " + name)
    return path


def safe_link(name, target):
    if Path(target).is_absolute():
        if ".." in PurePosixPath(target).parts:
            raise ValueError("Untrusted absolute handoff link: " + name)
        if target.startswith(("/src/", *EXTERNAL_LINK_ROOTS)):
            return
        raise ValueError("Untrusted absolute handoff link: " + name)
    normalized = os.path.normpath(str(PurePosixPath(name).parent / target))
    if normalized == ".." or normalized.startswith("../"):
        raise ValueError("Escaping handoff symlink: " + name)


def entry(path, root):
    info = path.lstat()
    result = {"mode": stat.S_IMODE(info.st_mode), "mtime_ns": info.st_mtime_ns}
    if path.is_symlink():
        target = os.readlink(path)
        safe_link(path.relative_to(root).as_posix(), target)
        return {**result, "kind": "symlink", "target": target}
    if path.is_dir():
        return {**result, "kind": "directory"}
    if path.is_file():
        return {**result, "kind": "file", "size": info.st_size, "sha256": digest(path)}
    raise ValueError("Special file in source/build handoff: " + str(path))


def inventory(root):
    result = {}
    for directory, names, files in os.walk(root, followlinks=False):
        for name in sorted(names + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if excluded(relative):
                if name in names:
                    names.remove(name)
                continue
            safe_name(relative)
            result[relative] = entry(path, root)
    return dict(sorted(result.items()))


def input_identity(sdk_image, qualification, recipe, snapshot):
    """Image rebuilds may differ; the verified SDK/seed/recipe inputs may not."""
    image_id = subprocess.check_output(
        ["docker", "image", "inspect", "--format", "{{.Id}}", sdk_image],
        text=True,
        timeout=60,
    ).strip()
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", image_id):
        raise ValueError("Invalid verified SDK image ID")
    if not re.fullmatch(r"\d{8}T\d{6}Z", snapshot):
        raise ValueError("Invalid pinned Ubuntu snapshot")
    # The complete recipe now contains only dependency and CI tooling stages.
    # Hash its actual bytes; no deleted application-stage delimiter is needed.
    record = {
        "schema": 1,
        "sdk_image_id": image_id,
        "dependency_seed_sha256": digest(qualification),
        "ci_recipe_sha256": digest(recipe),
        "snapshot": snapshot,
    }
    return {**record, "identity": hashlib.sha256(canonical(record)).hexdigest()}


def pack(root, output, revision, inputs, tier="pr", label=""):
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("Handoff requires the exact source revision")
    if tier not in ("pr", "sweep", "preview", "release", "local") or (
        tier == "release" and label
    ):
        raise ValueError("Invalid handoff tier/label")
    root, output = root.resolve(), output.resolve()
    if output.is_relative_to(root):
        raise ValueError("Handoff output must be outside the compiled source tree")
    output.mkdir(parents=True, exist_ok=True)
    portable = portable_input(root / "dist/packages", revision)
    files = inventory(root)
    archive = output / "source-build.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1) as stream:
        for name, record in files.items():
            path = root / name
            info = stream.gettarinfo(str(path), arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.pax_headers = {
                **info.pax_headers,
                "mtime": str(Decimal(record["mtime_ns"]) / Decimal(10**9)),
            }
            if record["kind"] == "file":
                # Never represent repeated file inodes as archive hardlinks.
                info.type, info.linkname = tarfile.REGTYPE, ""
                info.size = record["size"]
                with path.open("rb") as source:
                    stream.addfile(info, source)
            else:
                stream.addfile(info)
    manifest = {
        "schema": 1,
        "source": revision,
        "tier": tier,
        "label": label,
        "inputs": json.loads(inputs.read_text()),
        "archive_sha256": digest(archive),
        "producer": {
            key: os.environ.get(key, "")
            for key in (
                "GITHUB_REPOSITORY",
                "GITHUB_WORKFLOW",
                "GITHUB_RUN_ID",
                "GITHUB_RUN_ATTEMPT",
            )
        },
        "files": files,
        **({"portable_package": portable} if portable is not None else {}),
    }
    (output / "source-build.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    print(
        f"Source/build handoff: {len(files)} entries, {archive.stat().st_size} compressed bytes"
    )
    return manifest


def restore(directory, root, revision, inputs):
    manifest = json.loads((directory / "source-build.json").read_text())
    archive = directory / "source-build.tar.gz"
    if (
        manifest.get("schema") != 1
        or manifest.get("source") != revision
        or manifest.get("inputs") != json.loads(inputs.read_text())
        or manifest.get("archive_sha256") != digest(archive)
    ):
        raise ValueError("Source/build checksum, source or input identity mismatch")
    expected = manifest["files"]
    if not isinstance(expected, dict) or not expected:
        raise ValueError("Empty handoff manifest")
    for name, record in expected.items():
        safe_name(name)
        if record.get("kind") == "symlink":
            safe_link(name, record["target"])
        if (
            type(record.get("mtime_ns")) is not int
            or record["mtime_ns"] < 0
            or type(record.get("mode")) is not int
            or not 0 <= record["mode"] <= 0o777
        ):
            raise ValueError("Invalid handoff timestamp/mode")
    for name in expected:
        for parent in PurePosixPath(name).parents:
            if expected.get(str(parent), {}).get("kind") == "symlink":
                raise ValueError("Handoff member descends through a symlink")
    root.mkdir(parents=True, exist_ok=True)
    if (root / "build/_deps").is_symlink():
        raise ValueError("Seed dependency tree must be a regular directory")
    # The dependency-only image is allowed to contribute only _deps. Replace
    # its minimal application root and generated files with the exact build.
    for child in root.iterdir():
        if child.name == "build" and child.is_dir() and not child.is_symlink():
            for nested in child.iterdir():
                if nested.name != "_deps":
                    remove(nested)
        else:
            remove(child)
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)) or set(names) != set(expected):
            raise ValueError("Handoff archive differs from manifest inventory")
        for member in members:
            safe_name(member.name)
            record = expected[member.name]
            if (
                (member.isfile() and record["kind"] == "file")
                or (member.isdir() and record["kind"] == "directory")
                or (
                    member.issym()
                    and record["kind"] == "symlink"
                    and member.linkname == record["target"]
                )
            ):
                continue
            raise ValueError("Handoff archive type/link mismatch")
        stream.extractall(root, filter="tar")  # noqa: S202 - Exact names, types and link targets validated above.
    for name, record in sorted(
        expected.items(), key=lambda item: -len(PurePosixPath(item[0]).parts)
    ):
        path = root / name
        if not path.is_symlink():
            path.chmod(record["mode"])
        os.utime(
            path, ns=(record["mtime_ns"], record["mtime_ns"]), follow_symlinks=False
        )
    if inventory(root) != expected:
        raise ValueError("Restored handoff content, modes or timestamps differ")
    print("Verified exact source/build manifest and preserved dependency tree")
    return manifest


def remove(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def qualify(directory, revision, run_id, attempt, artifact_id, checksum, repository):
    """Bind an in-run handoff to the original successful upload and attempt."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from tools import ci_artifacts as artifacts
    from tools.ci_producer_trust import PRODUCERS
    from tools.integration_application import original_producer

    if (
        not re.fullmatch(r"[a-f0-9]{40}", revision)
        or not re.fullmatch(r"[a-f0-9]{64}", checksum)
        or any(
            type(value) is not int or value < 1
            for value in (run_id, attempt, artifact_id)
        )
    ):
        raise ValueError("Invalid handoff producer identity")
    run = artifacts.api(repository, f"actions/runs/{run_id}")
    consumer = (
        "release-handoff"
        if run.get("path") == ".github/workflows/release.yml"
        else "shadow-handoff"
    )
    producer = PRODUCERS[consumer]
    if (
        run.get("id") != run_id
        or not producer.matches_run(run)
        or (run.get("repository") or {}).get("full_name") != repository
        or (run.get("event") == "pull_request" and run.get("head_sha") != revision)
    ):
        raise ValueError("Handoff producer repository/workflow/source mismatch")
    if consumer == "release-handoff" and (
        run.get("head_branch") != "main"
        or (run.get("head_repository") or {}).get("full_name") != repository
        or (
            revision != run.get("head_sha")
            and artifacts.api(
                repository, f"compare/{revision}...{run.get('head_sha', '')}"
            ).get("status")
            not in ("ahead", "identical")
        )
    ):
        raise ValueError("Release handoff source must be reviewed main ancestry")
    artifact = artifacts.api(repository, f"actions/artifacts/{artifact_id}")
    if (
        artifact.get("id") != artifact_id
        or artifact.get("name") != f"linux-src-build-{run_id}-{attempt}"
        or artifact.get("expired") is not False
        or artifact.get("digest") != "sha256:" + checksum
        or artifact.get("workflow_run", {}).get("id") != run_id
    ):
        raise ValueError("Handoff differs from the original artifact upload")
    job = original_producer(
        repository,
        run["head_sha"],
        run_id,
        attempt,
        artifact,
        consumer=consumer,
    )
    if directory.exists() or directory.is_symlink():
        raise ValueError("Choose an absent handoff output directory")
    with tempfile.TemporaryDirectory(prefix="linux-handoff-") as temporary:
        archive = Path(temporary) / "handoff.zip"
        artifacts.download_zip(repository, artifact, archive)
        with zipfile.ZipFile(archive) as stream:
            if len(stream.namelist()) != 2 or set(stream.namelist()) != {
                "source-build.json",
                "source-build.tar.gz",
            }:
                raise ValueError("Unexpected handoff artifact members")
            directory.mkdir(parents=True)
            stream.extractall(directory)  # noqa: S202 - Exact flat members and ZIP digest verified.
    manifest = json.loads((directory / "source-build.json").read_text())
    expected_tier = (
        "release"
        if consumer == "release-handoff"
        else "pr"
        if run["event"] == "pull_request"
        else "preview"
        if run["path"] == ".github/workflows/preview-packages.yml"
        else "sweep"
    )
    if manifest.get("tier") != expected_tier or (
        expected_tier != "preview" and manifest.get("label") != ""
    ):
        raise ValueError(
            "Handoff receipt tier or label differs from its producer scope"
        )
    recorded = manifest.get("producer", {})
    if (
        manifest.get("source") != revision
        or recorded.get("GITHUB_REPOSITORY") != repository
        or recorded.get("GITHUB_RUN_ID") != str(run_id)
        or recorded.get("GITHUB_RUN_ATTEMPT") != str(attempt)
    ):
        raise ValueError("Handoff receipt differs from its original producer")
    if manifest.get("archive_sha256") != digest(directory / "source-build.tar.gz"):
        raise ValueError("Qualified handoff archive checksum mismatch")
    proof = {
        "manifest_sha256": digest(directory / "source-build.json"),
        "producer_job": job["id"],
    }
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write("".join(f"{key}={value}\n" for key, value in proof.items()))
    print(
        "Verified in-run handoff repository, workflow, original attempt and upload window"
    )
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    identity = commands.add_parser("identity")
    identity.add_argument("--sdk-image", required=True)
    identity.add_argument("--qualification", type=Path, required=True)
    identity.add_argument(
        "--recipe", type=Path, default=Path("packaging/build.Dockerfile")
    )
    identity.add_argument("--snapshot", required=True)
    identity.add_argument("--output", type=Path, required=True)
    producer = commands.add_parser("qualify")
    producer.add_argument("--directory", type=Path, required=True)
    producer.add_argument("--revision", required=True)
    producer.add_argument("--repository", required=True)
    producer.add_argument("--run-id", type=int, required=True)
    producer.add_argument("--attempt", type=int, required=True)
    producer.add_argument("--artifact-id", type=int, required=True)
    producer.add_argument("--artifact-digest", required=True)
    for name in ("pack", "restore"):
        command = commands.add_parser(name)
        command.add_argument("--root", type=Path, default=Path("/src"))
        command.add_argument("--directory", type=Path, required=True)
        command.add_argument("--revision", required=True)
        command.add_argument("--inputs", type=Path, required=True)
        if name == "pack":
            command.add_argument("--tier", default="pr")
            command.add_argument("--label", default="")
    args = parser.parse_args()
    if args.command == "qualify":
        qualify(
            args.directory,
            args.revision,
            args.run_id,
            args.attempt,
            args.artifact_id,
            args.artifact_digest,
            args.repository,
        )
    elif args.command == "identity":
        value = input_identity(
            args.sdk_image, args.qualification, args.recipe, args.snapshot
        )
        args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        print(value["identity"])
    elif args.command == "pack":
        pack(
            args.root, args.directory, args.revision, args.inputs, args.tier, args.label
        )
    else:
        restore(args.directory, args.root, args.revision, args.inputs)


if __name__ == "__main__":
    main()
