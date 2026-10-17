#!/usr/bin/env python3
"""Content-addressed CI dependencies and exact-commit application promotion."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    "macos-sdk": ["tools/build_macos_sdk.py"],
    "macos-runtime": [
        "tools/build_macos_runtimes.py",
        "tools/build_litert_extensions.py",
        "tools/litert_extensions.py",
        "tools/test_litert_status_abi.py",
        "requirements-litert-macos.lock",
        "third_party/litert_lm/stop-token-sequences.patch",
        "third_party/litert_lm/macos-trivial-abi.patch",
    ],
    "linux-core": [
        "packaging/sdk-core.Dockerfile",
        "packaging/minimal-grpc.cmake",
        "requirements-dev.lock",
        "requirements-litert.lock",
    ],
    "linux-litert": [
        "packaging/sdk-litert.Dockerfile",
        "tools/build_litert_extensions.py",
        "tools/litert_extensions.py",
        "tools/test_litert_status_abi.py",
        "third_party/litert_lm/stop-token-sequences.patch",
        "third_party/litert_lm/linux-trivial-abi.patch",
    ],
    "linux-whisper": [
        "packaging/sdk-whisper.Dockerfile",
        "tools/build_whisper_vulkan.py",
    ],
    "linux-sdk": ["packaging/sdk.Dockerfile"],
}
PARENTS = {
    "linux-litert": ["linux-core"],
    "linux-whisper": ["linux-core"],
    "linux-sdk": ["linux-core", "linux-litert", "linux-whisper"],
}
JOBS = {
    "macos-sdk": "Build macOS sdk",
    "macos-runtime": "Build macOS runtime",
    "linux-sdk": "Assemble Linux SDK",
    "linux-core": "Build Linux core",
    "linux-litert": "Build Linux litert",
    "linux-whisper": "Build Linux whisper",
}


def fingerprint(component, root=ROOT):
    """Bind a component to its recipe, source pins, flags and parent identities."""
    record = {
        "schema": 1,
        "component": component,
        "files": {name: digest(root / name) for name in FILES[component]},
        "parents": {
            name: fingerprint(name, root) for name in PARENTS.get(component, [])
        },
    }
    return hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def name(component, identity):
    if component not in (*FILES, "macos-app", "linux-app") or not re.fullmatch(
        r"[a-f0-9]{40}|[a-f0-9]{64}", identity
    ):
        raise ValueError("Invalid artifact identity")
    return f"ci-{component}-{identity}"


def pack(component, identity, prefix, output):
    """Archive verified outputs with executable modes, symlinks and a digest."""
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "payload.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1) as stream:
        stream.add(prefix, arcname="payload")
    (output / "identity.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "component": component,
                "identity": identity,
                "sha256": digest(archive),
                "source_commit": os.environ.get("GITHUB_SHA", ""),
            },
            indent=2,
        )
        + "\n"
    )


def unpack(component, identity, source, destination):
    """Reject mismatched or escaping archives before installing a fresh prefix."""
    record = json.loads((source / "identity.json").read_text())
    archive = source / "payload.tar.gz"
    if (record.get("schema"), record.get("component"), record.get("identity")) != (
        1,
        component,
        identity,
    ):
        raise ValueError("Artifact identity mismatch")
    if digest(archive) != record["sha256"]:
        raise ValueError("Artifact archive checksum mismatch")
    if destination.exists() or destination.is_symlink():
        raise ValueError("Artifact destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        with tarfile.open(archive) as stream:
            if any(
                not (m.name == "payload" or m.name.startswith("payload/"))
                for m in stream.getmembers()
            ):
                raise ValueError("Unexpected artifact archive root")
            stream.extractall(temporary, filter="data")
        (Path(temporary) / "payload").rename(destination)


def api(repository, route):
    env = dict(os.environ)
    env.pop("GH_DEBUG", None)
    return json.loads(
        subprocess.check_output(
            ["gh", "api", f"repos/{repository}/{route}"], env=env, timeout=300
        )
    )


def trusted_run(
    run, component, own_head="", repository="teng-lin/open-foresight", own_pr=0
):
    """Dependencies come from main, merged sources, or this repository's own PR."""
    workflow = (
        ".github/workflows/macos.yml"
        if component.endswith("-app")
        else ".github/workflows/ci-dependencies.yml"
    )
    if (
        run.get("path") != workflow
        or run.get("event")
        not in ("push", "workflow_dispatch", "schedule", "pull_request")
        or (run.get("head_repository") or {}).get("full_name") != repository
    ):
        return False
    if component.endswith("-app"):
        return (
            run.get("head_branch") == "main"
            and run.get("event") in ("push", "workflow_dispatch")
            and run.get("conclusion") == "success"
        )
    if run.get("head_branch") == "main" and run.get("event") != "pull_request":
        return True
    if (
        run.get("event") == "workflow_dispatch"
        and own_head
        and run.get("head_sha") == own_head
    ):
        return True
    return (
        run.get("event") == "pull_request"
        and bool(own_pr)
        and any(pr["number"] == own_pr for pr in run.get("pull_requests", []))
    )


def merged_source(repository, run):
    """A source commit reachable from main has completed repository review."""
    if not re.fullmatch(r"[a-f0-9]{40}", run.get("head_sha", "")):
        return False
    comparison = api(repository, f"compare/{run['head_sha']}...main")
    return comparison["status"] in ("ahead", "identical")


def pull(repository, component, identity, prefix, wait=0, own_head="", own_pr=0):
    artifact_name = name(component, identity)
    deadline = time.monotonic() + wait
    while True:
        artifacts = api(
            repository, f"actions/artifacts?name={artifact_name}&per_page=100"
        )["artifacts"]
        for artifact in artifacts:
            if artifact["expired"] or artifact["name"] != artifact_name:
                continue
            run = api(repository, f"actions/runs/{artifact['workflow_run']['id']}")
            if not trusted_run(run, component, own_head, repository, own_pr):
                # An approved dependency PR can be reused after merge without
                # republishing/recompiling it in main's namespace. Forks and
                # application candidates never use this exception.
                if (
                    component.endswith("-app")
                    or run.get("path") != ".github/workflows/ci-dependencies.yml"
                    or run.get("event") not in ("pull_request", "workflow_dispatch")
                    or (run.get("head_repository") or {}).get("full_name") != repository
                    or not merged_source(repository, run)
                ):
                    continue
            if component.endswith("-app"):
                if run["head_sha"] != identity:
                    continue
            else:
                jobs = api(repository, f"actions/runs/{run['id']}/jobs?per_page=100")[
                    "jobs"
                ]
                if not any(
                    j["name"] == JOBS[component] and j.get("conclusion") == "success"
                    for j in jobs
                ):
                    continue
            with tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / "artifact.zip"
                with archive.open("wb") as stream:
                    subprocess.run(
                        [
                            "gh",
                            "api",
                            f"repos/{repository}/actions/artifacts/{artifact['id']}/zip",
                        ],
                        stdout=stream,
                        check=True,
                        timeout=300,
                    )
                source = Path(temporary) / "download"
                source.mkdir()
                with zipfile.ZipFile(archive) as stream:
                    if len(stream.namelist()) != 2 or set(stream.namelist()) != {
                        "identity.json",
                        "payload.tar.gz",
                    }:
                        raise ValueError("Unexpected artifact download members")
                    stream.extractall(source)  # noqa: S202 - Archive members are validated immediately above; links are retained.
                unpack(component, identity, source, prefix)
            print(
                f"Using {artifact_name} from verified workflow run {run['id']}",
                flush=True,
            )
            return True
        if time.monotonic() >= deadline:
            return False
        print(f"Waiting for verified dependency/candidate {artifact_name}", flush=True)
        time.sleep(min(20, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("keys", "pack", "pull"))
    parser.add_argument("--component", choices=(*FILES, "macos-app", "linux-app"))
    parser.add_argument("--identity")
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--repository",
        default=os.environ.get("GITHUB_REPOSITORY", "teng-lin/open-foresight"),
    )
    parser.add_argument("--wait", type=int, default=0)
    parser.add_argument("--optional", action="store_true")
    parser.add_argument("--own-head", default="")
    parser.add_argument("--own-pr", type=int, default=0)
    args = parser.parse_args()
    if args.command == "keys":
        keys = {key: fingerprint(key) for key in FILES}
        for key, value in keys.items():
            print(f"{key}={value}")
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a") as stream:
                stream.write("".join(f"{key}={value}\n" for key, value in keys.items()))
        return
    if not args.component or not args.prefix:
        parser.error("--component and --prefix are required")
    identity = args.identity or fingerprint(args.component)
    name(args.component, identity)
    if args.command == "pack":
        if not args.output:
            parser.error("--output is required")
        pack(args.component, identity, args.prefix, args.output)
    elif not pull(
        args.repository,
        args.component,
        identity,
        args.prefix,
        args.wait,
        args.own_head,
        args.own_pr,
    ):
        if args.optional:
            raise SystemExit(4)
        raise SystemExit(
            "Verified artifact unavailable. Run ci-dependencies.yml on main (or manually on this reviewed dependency PR), or finish the exact-commit main candidate build. No implicit compilation was started."
        )


if __name__ == "__main__":
    main()
