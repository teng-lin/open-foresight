#!/usr/bin/env python3
"""Qualify migration history against freshly fetched main, outside stage caches."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = "c28a1561b5091645718462169bc6c0cfd0040943"
CORE = Path("packages/foresight_core")
CHECKER = CORE / "tool/migration_guard.dart"
MANIFEST = CORE / "lib/src/persistence/migration_manifest.json"


def run(command: list[str], *, cwd: Path, timeout: int = 180) -> str:
    result = subprocess.run(
        command, cwd=cwd, capture_output=True, text=True, timeout=timeout
    )
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", flush=True)
    result.check_returncode()
    return result.stdout.strip()


def export(root: Path, commit: str, destination: Path) -> None:
    archive = destination.with_suffix(".tar")
    run(["git", "archive", "--format=tar", f"--output={archive}", commit], cwd=root)
    destination.mkdir()
    with tarfile.open(archive) as source:
        source.extractall(destination, filter="data")


def check(root: Path, repository_url: str, dart: str, scratch: Path) -> dict:
    # This is a real main ref fetched from the platform-owned repository URL,
    # never a candidate manifest/ref or the PR checkout's origin tracking ref.
    ref = "refs/foresight/migration-reviewed-main"
    run(
        [
            "git",
            "fetch",
            "--no-tags",
            "--no-recurse-submodules",
            repository_url,
            f"+refs/heads/main:{ref}",
        ],
        cwd=root,
    )
    main = run(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=root)
    if not re.fullmatch(r"[a-f0-9]{40}", main):
        raise ValueError("Fetched main did not resolve to a full source commit")
    trusted = scratch / "main"
    export(root, main, trusted)
    bootstrap = not (trusted / MANIFEST).is_file()
    arguments = [
        "check",
        "--candidate-root",
        str(root),
        "--trusted-root",
        str(trusted),
        "--trusted-commit",
        main,
    ]
    if bootstrap:
        # No override: the original frozen fixtures have exactly this reviewed
        # origin. An unrelated main advance is fine; changed migration closures
        # or a different fixture provenance must fail the Dart checker.
        run(["git", "merge-base", "--is-ancestor", BOOTSTRAP, main], cwd=root)
        origin = scratch / "bootstrap"
        export(root, BOOTSTRAP, origin)
        arguments += [
            "--bootstrap",
            "--bootstrap-root",
            str(origin),
            "--bootstrap-commit",
            BOOTSTRAP,
        ]
    elif not (trusted / CHECKER).is_file():
        raise ValueError("Reviewed main manifest has no authoritative checker")

    # Run main's executable with main's locked dependencies first. A candidate
    # tool/manifest edit cannot replace or rebaseline that immutable check.
    owners = [root] if bootstrap else [trusted, root]
    for owner in owners:
        run([dart, "pub", "get", "--enforce-lockfile"], cwd=owner / CORE)
        run([dart, "run", str(owner / CHECKER), *arguments], cwd=owner / CORE)
    receipt = {
        "trusted_main": main,
        "bootstrap": bootstrap,
        "checker_runs": len(owners),
    }
    print(json.dumps(receipt, sort_keys=True))
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", default="dart")
    args = parser.parse_args()
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError(
            "GITHUB_REPOSITORY must identify the platform-owned repository"
        )
    with tempfile.TemporaryDirectory(prefix="migration-main-") as temporary:
        check(ROOT, f"https://github.com/{repository}.git", args.dart, Path(temporary))


if __name__ == "__main__":
    main()
