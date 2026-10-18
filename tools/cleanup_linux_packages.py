#!/usr/bin/env python3
"""Plan or apply retirement of obsolete tagged Linux GHCR dependency images."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.ci_artifacts import fingerprint  # noqa: E402

REPO = "teng-lin/open-foresight"
COMPONENTS = ("linux-core", "linux-litert", "linux-whisper", "linux-sdk")
ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    )
)


def api(path, method="GET"):
    output = subprocess.check_output(
        ["gh", "api", "--method", method, path], timeout=300
    )
    return json.loads(output) if output.strip() else None


def pages(path, key=None):
    result = []
    for page in range(1, 10000):
        data = api(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
        rows = data[key] if key else data
        result.extend(rows)
        if len(rows) < 100:
            return result
    raise RuntimeError("Pagination did not terminate")


def versions_path(component):
    package = urllib.parse.quote("open-foresight/" + component, safe="")
    return f"users/teng-lin/packages/container/{package}/versions"


def tags(version):
    return set(version["metadata"]["container"]["tags"])


def candidates(versions, identity, protected):
    if not any(identity in tags(v) for v in versions):
        raise RuntimeError("Current identity is not published; refusing cleanup")
    keep = {identity, "current", "buildcache", "app-buildcache-x86-64"}
    return [
        v
        for v in versions
        if tags(v) and not tags(v) & keep and v["name"] not in protected
    ]


def protected_manifests(component, versions, identity):
    package = "teng-lin/open-foresight/" + component
    url = "https://ghcr.io/token?" + urllib.parse.urlencode(
        {"service": "ghcr.io", "scope": f"repository:{package}:pull"}
    )
    with urllib.request.urlopen(url, timeout=60) as response:  # noqa: S310 - fixed HTTPS registry
        token = json.load(response)["token"]
    roots = {
        v["name"]
        for v in versions
        if tags(v) & {identity, "current", "buildcache", "app-buildcache-x86-64"}
    }
    protected = set()
    while roots:
        digest = roots.pop()
        if digest in protected:
            continue
        protected.add(digest)
        request = urllib.request.Request(
            f"https://ghcr.io/v2/{package}/manifests/{digest}",
            headers={"Authorization": "Bearer " + token, "Accept": ACCEPT},
        )
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 - fixed HTTPS registry
            manifest = json.load(response)
        roots.update(m["digest"] for m in manifest.get("manifests") or [])
    return protected


def obsolete_artifact(name, identities):
    match = re.fullmatch(
        r"(?:receipt-)?ci-(linux-(?:core|litert|whisper|sdk))-([a-f0-9]{64})", name
    )
    return bool(match and match.group(2) in identities.get(match.group(1), set()))


def make_plan():
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, timeout=30
    ).strip()
    if api(f"repos/{REPO}/commits/main")["sha"] != head:
        raise RuntimeError("Checkout must match current main")
    plan: dict[str, Any] = {
        "repository": REPO,
        "head": head,
        "packages": {},
        "artifacts": [],
    }
    retired = {}
    for component in COMPONENTS:
        identity = fingerprint(component)
        versions = pages(versions_path(component))
        protected = protected_manifests(component, versions, identity)
        obsolete = candidates(versions, identity, protected)
        plan["packages"][component] = {"identity": identity, "versions": obsolete}
        retired[component] = {
            tag
            for v in obsolete
            for tag in tags(v)
            if re.fullmatch(r"[a-f0-9]{64}", tag)
        }
    plan["artifacts"] = [
        a
        for a in pages(f"repos/{REPO}/actions/artifacts", "artifacts")
        if obsolete_artifact(a["name"], retired)
    ]
    return plan


def apply(plan):
    # Refresh and compare the entire plan before the first mutation.
    fresh = make_plan()

    def signature(value):
        return (
            value["repository"],
            value["head"],
            {
                c: (
                    p["identity"],
                    sorted(
                        (v["id"], v["name"], sorted(tags(v))) for v in p["versions"]
                    ),
                )
                for c, p in value["packages"].items()
            },
            sorted((a["id"], a["name"]) for a in value["artifacts"]),
        )

    if signature(plan) != signature(fresh):
        raise RuntimeError("Registry/artifacts/main changed; generate a new plan")
    for status in ("in_progress", "queued", "waiting", "pending", "requested"):
        runs = api(f"repos/{REPO}/actions/runs?status={status}&per_page=1")
        if runs["total_count"]:
            raise RuntimeError("CI is active; wait before applying cleanup")
    for artifact in fresh["artifacts"]:
        api(f"repos/{REPO}/actions/artifacts/{artifact['id']}", "DELETE")
        print("Deleted descriptor:", artifact["name"], flush=True)
    for component, package in fresh["packages"].items():
        for version in package["versions"]:
            path = f"{versions_path(component)}/{version['id']}"
            actual = api(path)
            if actual["name"] != version["name"] or tags(actual) != tags(version):
                raise RuntimeError("Image tags changed during cleanup; stopping")
            api(path, "DELETE")
            print("Deleted image:", component, version["name"], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="linux-package-cleanup.json")
    parser.add_argument("--apply", type=Path, metavar="PLAN")
    args = parser.parse_args()
    if args.apply:
        apply(json.loads(args.apply.read_text()))
    else:
        plan = make_plan()
        Path(args.output).write_text(json.dumps(plan, indent=2) + "\n")
        print(f"Plan: {args.output}")
        for component, package in plan["packages"].items():
            print(
                component,
                "keep",
                package["identity"],
                "retire",
                len(package["versions"]),
                "versions",
            )
        print("Retire", len(plan["artifacts"]), "obsolete descriptor/receipt artifacts")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Cleanup stopped: {error}") from None
