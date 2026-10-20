#!/usr/bin/env python3
"""Observe WS3 selection; production retains its current required check closure.

Rules combine by union. This module never authorizes phase-level acceptance
skips, stage retirement, main receipts or publication. The standalone sanitizer
workflow remains advisory and its own path filter is the source of truth.
"""

import argparse
from fnmatch import fnmatchcase
import hashlib
import importlib
import json
from pathlib import Path, PurePosixPath
import re


ROOT = Path(__file__).resolve().parents[1]
GATES = ("macos", "linux-build", "linux-test", "linux-document-imports", "packaging", "dmg")
ACCEPTANCE = ("acceptance-cpu", "acceptance-audio", "acceptance-deb")
KNOWN_ESCAPES = {102, 110, 112, 119, 137, 144}
# This is deliberately explicit: changing a release control cannot change the
# application's compiled source, but must exercise current installer contracts.
RELEASE_ONLY = {
    ".github/workflows/release.yml", ".github/workflows/release-acceptance.yml",
    ".github/workflows/linux-packages.yml", ".github/workflows/macos-release.yml",
    "tools/release_inputs.py", "tools/release_upload.py", "tools/prepare_release.py",
    "tools/release_asset_acceptance.py", "tools/release_acceptance_report.py",
    "tools/reuse_release_acceptance.py", "tools/github_release.py",
}


def _module(name):
    return importlib.import_module("tools." + name if __package__ else name)


def application_selection():
    """Full application tier for sweeps; installer matrix remains conditional."""
    return {name: name != "packaging" for name in GATES}


def closure(selected):
    """Prerequisites and their mandatory in-run consumers reach a fixed point."""
    if set(selected) != set(GATES) or any(type(v) is not bool for v in selected.values()):
        raise ValueError("Invalid candidate gate selection")
    selected = dict(selected)
    if selected["packaging"]:
        selected["linux-build"] = True
        selected["dmg"] = True
    if selected["linux-test"] or selected["linux-document-imports"]:
        selected["linux-build"] = True
    if selected["linux-build"]:
        selected["linux-test"] = True
        selected["linux-document-imports"] = True
    if selected["macos"]:
        selected["dmg"] = True
    return selected


def required_jobs(selected, *, tier="", arch_retired=False):
    selected = closure(selected)
    jobs = {name for name, value in selected.items() if value}
    if selected["linux-build"]:
        jobs.update(ACCEPTANCE)
        if tier != "release" and not arch_retired:
            jobs.add("linux-native")
    return sorted(jobs)


def sanitizer_paths(root=ROOT):
    # The classifier runs before dependency installation. Accept only the
    # current simple quoted path-list grammar; changes to that grammar fail
    # closed, and a contract test compares this list with the YAML parser.
    text = (root / ".github/workflows/native-sanitizers.yml").read_text()
    match = re.search(r"(?m)^  pull_request:\n    paths:\n((?:      - [^\n]+\n)+)", text)
    if match is None:
        raise ValueError("Invalid authoritative sanitizer path inventory")
    paths = []
    for line in match[1].splitlines():
        item = line.removeprefix("      - ")
        if not re.fullmatch(r"['\"][A-Za-z0-9_./*?-]+['\"]", item) or item[0] != item[-1]:
            raise ValueError("Invalid authoritative sanitizer path inventory")
        paths.append(item[1:-1])
    return tuple(paths)


def path_rule(path, *, root=ROOT):
    """Return an explicit owner or the conservative unknown/application owner."""
    legacy = _module("ci_changes")
    contracts = _module("platform_python_tests")
    parsed = PurePosixPath(path)
    if not path or parsed.is_absolute() or ".." in parsed.parts or "\\" in path:
        return "unknown", tuple(name for name in GATES if name != "packaging")
    if path.startswith("packaging/notices/"):
        return "installed-notice", GATES
    if path.startswith("packaging/macos/"):
        return "apple-package-input", ("macos", "dmg")
    if path == "packaging/acceptance.Dockerfile":
        return "acceptance-input", ("linux-build",)
    if path in {"packaging/minimal-grpc.cmake", "packaging/sanitizer-grpc.cmake"}:
        return "native-sdk-input", tuple(name for name in GATES if name != "packaging")
    if path.startswith(("docs/", ".github/ISSUE_TEMPLATE/")) or parsed.suffix == ".md":
        return "editorial", ()
    owners = contracts.owner_gates(path)
    if owners:
        return "host-contract", owners
    if parsed.parent == PurePosixPath("tests") and parsed.name.startswith("test_") and parsed.suffix == ".py":
        # Existing installer/DMG contracts retain their explicit external owner.
        if path in legacy.PACKAGING_FILES:
            return "package-contract", ("packaging",)
        return "portable-quality", ()
    if path in legacy.MAINTENANCE:
        return "maintenance", ()
    if path in RELEASE_ONLY:
        return "release-control", ("packaging",)
    if path in legacy.MACOS_FILES or path.startswith("apps/desktop/macos/"):
        return "apple-input", ("macos", "dmg")
    if path in legacy.PACKAGING_FILES or path == "tools/ci_package_sandbox.sh" or path.startswith(("packaging/", "tools/package")):
        return "package-input", ("packaging",)
    if path in legacy.LINUX_FILES or path.startswith("apps/desktop/linux/"):
        return "linux-input", ("linux-build",)
    return "application-or-unknown", tuple(name for name in GATES if name != "packaging")


def select(paths, *, force=False, labels=(), root=ROOT):
    """Candidate only; force/live ci:full broadens to every platform gate."""
    selected = dict.fromkeys(GATES, force or "ci:full" in labels)
    reasons = []
    for path in sorted(set(paths)):
        rule, owners = path_rule(path, root=root)
        for gate in owners:
            selected[gate] = True
        reasons.append({"path": path, "rule": rule, "owners": list(owners)})
    selected = closure(selected)
    patterns = sanitizer_paths(root)
    return {
        "schema": 1, "mode": "observe-only", "permits_skipping": False,
        "selection": selected, "required_jobs": required_jobs(selected),
        "sanitizers": any(fnmatchcase(path, pattern) for path in paths for pattern in patterns),
        "sanitizer_paths": list(patterns), "paths": reasons,
    }


def referenced_owners(root=ROOT):
    """Audit repository paths referenced by every workflow and composite action."""
    found = set()
    for directory in (root / ".github/workflows", root / ".github/actions"):
        for path in directory.rglob("*.yml"):
            for name in re.findall(r"(?:tools|packaging|cmake|native|services|packages|apps|tests|\.github/actions|\.github/workflows)/[A-Za-z0-9_./-]+", path.read_text()):
                if (root / name).is_file():
                    found.add(name)
    return [{"path": name, "rule": path_rule(name, root=root)[0], "jobs": required_jobs(closure({gate: gate in path_rule(name, root=root)[1] for gate in GATES}))} for name in sorted(found)]


def live_labels(repository, pull_request, *, api=None):
    """Read current labels, never the potentially stale pull_request event copy."""
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository or "") or type(pull_request) is not int or pull_request < 1:
        raise ValueError("Explicit repository and positive PR number required")
    api = api or _module("ci_artifacts").api
    labels: set[str] = set()
    page = 1
    while True:
        rows = api(repository, f"issues/{pull_request}/labels?per_page=100&page={page}")
        if not isinstance(rows, list) or any(not isinstance(row, dict) or not isinstance(row.get("name"), str) for row in rows):
            raise ValueError("Malformed live PR labels")
        labels.update(row["name"] for row in rows)
        if len(rows) < 100:
            return labels
        page += 1


def replay(snapshot, *, root=ROOT):
    """Replay complete frozen PR changed-path lists without requiring Git history."""
    if snapshot.get("schema") != 1 or snapshot.get("repository") != "teng-lin/open-foresight":
        raise ValueError("Invalid selector replay repository/schema")
    prs = snapshot.get("prs", [])
    if len(prs) < 50 or len({pr["number"] for pr in prs}) != len(prs):
        raise ValueError("Replay needs at least 50 distinct merged PRs")
    if not KNOWN_ESCAPES.issubset({pr["number"] for pr in prs}):
        raise ValueError("Replay is missing known historical escapes")
    results = []
    for pr in prs:
        files = pr["files"]
        if not pr.get("mergedAt") or len(files) != pr["changedFiles"]:
            raise ValueError("Incomplete merged PR changed-file inventory")
        paths = sorted({name for row in files for name in (row["filename"], row.get("previous_filename")) if name})
        candidate = select(paths, root=root)
        if pr["number"] in KNOWN_ESCAPES and not {"macos", *ACCEPTANCE}.issubset(candidate["required_jobs"]):
            raise ValueError(f"Historical escape #{pr['number']} loses platform/acceptance coverage")
        results.append({"number": pr["number"], "source": pr["mergeCommit"]["oid"], "paths": paths, "candidate": candidate})
    return {"schema": 1, "mode": "observe-only", "repository": snapshot["repository"], "source_baseline": snapshot["source_baseline"], "count": len(results), "prs": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    raw = args.replay.read_bytes()
    if hashlib.sha256(raw).hexdigest() != args.sha256:
        parser.error("Selector replay checksum mismatch")
    report = replay(json.loads(raw))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
