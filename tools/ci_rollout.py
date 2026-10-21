#!/usr/bin/env python3
"""Fail-closed qualification index and retained-source closure for CI cutovers.

The committed index starts empty. It cannot bootstrap proof for unmerged code:
every proof is downloaded from its original successful reviewed-main producer,
and actual selected jobs are rechecked through GitHub. This tool never writes to
GitHub, removes checks, changes selection, or publishes production receipts.
"""

import argparse
from datetime import datetime, timedelta
import hashlib
import json
from pathlib import Path
import re
import stat
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_artifacts as artifacts  # noqa: E402
from tools.ci_selection import GATES  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CAPABILITIES = {"main_receipts", "path_selection", "arch_retirement", "acceptance_narrowing"}
LEGACY = {
    ".github/workflows/linux-platform-stages.yml", ".github/actions/setup-linux-stage/action.yml",
    "tools/run_ci_stage.py", "tools/ci_stage_artifacts.py", "tools/ci_stage_cache.py", "tools/ci_stage_environment.py",
}
SUFFIXES = {".py", ".sh", ".json", ".yml", ".yaml", ".toml", ".lock", ".cmake", ".txt", ".cc", ".cpp", ".h", ".hpp", ".mm", ".dart", ".plist", ".swift", ".patch", ".proto", ".ini", ".cfg"}
IGNORED = {".git", ".venv", ".dart_tool", "__pycache__", "build", "dist", ".cache", "coverage", "test-results", "ephemeral", ".symlinks", ".plugin_symlinks", ".flutter-plugins-dependencies", ".flutter-plugins", ".packages"}
KINDS = {
    "nightly": (".github/workflows/preview-packages.yml", "nightly-checks"),
    "arch": (".github/workflows/arch-drift.yml", "arch"),
    "observer": (".github/workflows/main-evidence.yml", "observe"),
    "selector-replay": (".github/workflows/ci-qualification.yml", "qualification-selector-replay"),
    "acceptance-replay": (".github/workflows/ci-qualification.yml", "qualification-acceptance-replay"),
    "archive-sdk": (".github/workflows/ci-qualification.yml", "qualification-archive-sdk"),
    "fork-sdk": (".github/workflows/ci-qualification.yml", "qualification-fork-sdk"),
    "recipe-change": (".github/workflows/ci-qualification.yml", "qualification-recipe-change"),
    "publisher": (".github/workflows/linux-cache-publish.yml", "qualification-consumers"),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def closure(root=ROOT):
    """Hash retained source bytes/modes without Git or generated local output."""
    root = root.resolve()
    if not root.is_dir():
        raise ValueError("Incomplete source export for retained closure")
    record = {}
    for name in (".github", "tools", "packaging", "cmake", "native", "services", "packages", "apps", "proto", "third_party", "tests"):
        for path in (root / name).rglob("*"):
            relative = path.relative_to(root)
            if any(part in IGNORED for part in relative.parts) or relative.as_posix() in LEGACY:
                continue
            if path.is_symlink():
                raise ValueError(f"Retained closure contains a symlink: {relative}")
            if path.is_file():
                record[relative.as_posix()] = {"sha256": digest(path), "mode": stat.S_IMODE(path.stat().st_mode)}
    for path in root.iterdir():
        if path.is_file() and (path.suffix in SUFFIXES or path.name in {"CMakeLists.txt", ".coveragerc"}):
            record[path.name] = {"sha256": digest(path), "mode": stat.S_IMODE(path.stat().st_mode)}
    if not {"tools/ci_changes.py", ".github/workflows/macos.yml", "tools/ci_selection.py"}.issubset(record):
        raise ValueError("Incomplete source export for retained closure")
    checksum = hashlib.sha256(json.dumps(record, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"schema": 1, "sha256": checksum, "files": record}


def control_closure(root=ROOT, *, full=None):
    """Stable coordinator implementation/toolchain contract, not product source.

    Current PR/sweep receipts independently bind application and test bytes.
    Unknown CI tools/actions/configuration remain controls and invalidate this
    contract; ordinary application code cannot revoke the already qualified
    coordinator on every merge.
    """
    record = (full or closure(root))["files"]
    controls = {}
    for name, value in record.items():
        path = Path(name)
        if name.startswith((".github/", "tools/", "packaging/", "cmake/", "tests/fixtures/ci")) or path.name == "CMakeLists.txt" or path.suffix == ".cmake" or path.name in {"pubspec.yaml", "pubspec.lock", "Podfile", "Podfile.lock"} or (path.parent == Path(".") and (path.suffix in {".lock", ".toml", ".ini", ".cfg"} or name == ".coveragerc")) or (name.startswith("tests/test_ci_") and name.endswith(".py")):
            controls[name] = value
    checksum = hashlib.sha256(json.dumps(controls, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"schema": 2, "scope": "ci-controls", "sha256": checksum, "files": controls}


def compare(qualified, current):
    """No retained-path change is approved merely because it is called cleanup."""
    if qualified != current:
        changed = sorted(name for name in qualified.get("files", {}).keys() | current.get("files", {}).keys() if qualified.get("files", {}).get(name) != current.get("files", {}).get(name))
        raise ValueError("Retained candidate closure differs; renew reviewed-main qualification: " + ", ".join(changed))
    return current["sha256"]


def descriptor(source, *, root=ROOT, run_id, attempt, producer_job):
    if not re.fullmatch(r"[0-9a-f]{40}", source or ""):
        raise ValueError("Qualification source must be an immutable commit")
    if any(type(value) is not int or value < 1 for value in (run_id, attempt)) or not producer_job:
        raise ValueError("Explicit original producer run, attempt and job required")
    return {"schema": 1, "mode": "candidate-qualification", "source": source, "closure": closure(root), "superseded": False, "producer": {"run_id": run_id, "attempt": attempt, "job": producer_job}, "control_closure": control_closure(root)}


def full_candidate_selection(value):
    return isinstance(value, dict) and value.get("qualification_mode") is True and value.get("superseded") is False and set(value.get("selection", {})) == set(GATES) and all(required is True for required in value["selection"].values())


def _qualified(entry, *, repository, expected, api, download, controls=False):
    kind = entry.get("kind")
    if kind not in KINDS:
        raise ValueError("Unknown rollout qualification kind")
    if any(type(entry.get(key)) is not int or entry[key] < 1 for key in ("run_id", "artifact_id", "producer_job_id")):
        raise ValueError("Explicit positive original producer and artifact IDs required")
    run = api(repository, f"actions/runs/{entry['run_id']}")
    workflow, gate = KINDS[kind]
    if run.get("repository", {}).get("full_name") != repository:
        raise ValueError("Qualification run repository mismatch")
    attempt = entry["attempt"]
    if type(attempt) is not int or attempt < 1:
        raise ValueError("Qualification needs an original positive attempt")
    if (run.get("path"), run.get("head_branch"), (run.get("head_repository") or {}).get("full_name"), run.get("status"), run.get("conclusion")) != (workflow, "main", repository, "completed", "success"):
        raise ValueError("Qualification is not a successful reviewed-main producer")
    if run.get("event") not in ("schedule", "workflow_dispatch", "push", "workflow_run") or (kind in {"nightly", "arch"} and run.get("event") != "schedule"):
        raise ValueError("Qualification needs the actual scheduled nightly/drift event")
    source = run.get("head_sha")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Invalid qualification source")
    proof = api(repository, f"compare/{source}...main")
    if proof.get("status") not in ("ahead", "identical"):
        raise ValueError("Qualification source is not reachable from reviewed main")
    jobs = []
    page = 1
    while True:
        rows = api(repository, f"actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100&page={page}")["jobs"]
        jobs.extend(rows)
        if len(rows) < 100:
            break
        page += 1
    succeeded = {job["name"].split(" / ")[-1] for job in jobs if job.get("conclusion") == "success"}
    if gate not in succeeded:
        raise ValueError("Qualification gate did not execute successfully in the original attempt")
    if kind == "nightly" and not {"linux-build", "linux-test", "macos", "acceptance-cpu", "acceptance-audio", "acceptance-deb", "platform-checks", "acceptance-checks", "dmg", "publish", "linux (deb)", "linux (rpm)", "linux (arch)"}.issubset(succeeded):
        raise ValueError("Nightly omitted the actual replacement suite closure")
    artifact = api(repository, f"actions/artifacts/{entry['artifact_id']}")
    if artifact.get("name") != "ci-rollout-qualification" or artifact.get("expired") or artifact.get("workflow_run", {}).get("id") != run["id"]:
        raise ValueError("Qualification artifact origin mismatch")
    uploaders = [job for job in jobs if job.get("id") == entry["producer_job_id"] and job.get("conclusion") == "success" and job.get("run_attempt") == attempt and job.get("name", "").split(" / ")[-1] == gate and artifacts.in_producer_attempt(artifact, job)]
    if len(uploaders) != 1:
        raise ValueError("Qualification artifact has no successful original upload window")
    with tempfile.TemporaryDirectory(prefix="ci-rollout-") as temporary:
        path = Path(temporary) / "qualification.zip"
        download(repository, artifact, path)
        if digest(path) != entry["sha256"]:
            raise ValueError("Qualification ZIP checksum mismatch")
        with zipfile.ZipFile(path) as stream:
            if stream.namelist() != ["qualification.json"] or stream.getinfo("qualification.json").file_size > 4 * 1024 * 1024 or stat.S_IFMT(stream.getinfo("qualification.json").external_attr >> 16) not in (0, stat.S_IFREG):
                raise ValueError("Invalid qualification archive")
            result = json.loads(stream.read("qualification.json"))
    if result.get("schema") != 1 or result.get("mode") != "candidate-qualification" or result.get("superseded") is not False or result.get("source") != source:
        raise ValueError("Missing active candidate qualification marker")
    if result.get("producer") != {"run_id": run["id"], "attempt": attempt, "job": uploaders[0]["name"]}:
        raise ValueError("Qualification receipt differs from original uploading job")
    if kind == "nightly" and not full_candidate_selection(result.get("qualification_selection")):
        raise ValueError("Nightly did not actually execute the prepared candidate selector")
    if kind in {"archive-sdk", "fork-sdk", "recipe-change", "publisher"} and result.get("exercise", {}).get("kind") != kind:
        raise ValueError("Qualification lacks its actual SDK transport/recipe exercise")
    if kind == "selector-replay" and (result.get("selector_replay", {}).get("count", 0) < 50 or result.get("selector_replay", {}).get("known_escapes") != [102, 110, 112, 119, 137, 144]):
        raise ValueError("Qualification lacks its full historical selector replay")
    if kind == "acceptance-replay" and (result.get("acceptance_replay", {}).get("count", 0) < 50 or result.get("acceptance_replay", {}).get("known_escapes") != [102, 110, 112, 119, 137, 144]):
        raise ValueError("Qualification lacks its full acceptance dependency replay")
    if kind == "observer" and result.get("observer_case") not in {"identical", "divergent", "partially-selected", "failed-rerun"}:
        raise ValueError("Observation lacks its actual parity case")
    compare(result["control_closure" if controls else "closure"], expected)
    return {"kind": kind, "run_id": run["id"], "source": source, "created_at": run["created_at"], "observer_case": result.get("observer_case")}


def authorize(index, *, root=ROOT, source, capabilities, repository="teng-lin/open-foresight", api=None, download=None, ongoing=False):
    """Return only API-verified eligibility; absence never authorizes activation."""
    if not re.fullmatch(r"[0-9a-f]{40}", source or ""):
        raise ValueError("Activation needs an immutable source SHA")
    requested = set(capabilities)
    if not requested or not requested.issubset(CAPABILITIES):
        raise ValueError("Unknown or empty rollout capability request")
    if index.get("schema") != 1 or index.get("repository") != repository or not requested.issubset(index.get("capabilities", [])):
        raise ValueError("Cutover is inactive: missing reviewed-main qualification index")
    controls = "arch_retirement" not in requested
    if not controls and not ongoing and index.get("source") != source:
        raise ValueError("Rollout source does not match the proposed activation")
    if not re.fullmatch(r"[0-9a-f]{40}", index.get("source", "")):
        raise ValueError("Rollout qualification baseline must be immutable")
    if (api or artifacts.api)(repository, f"compare/{index['source']}...main").get("status") not in ("ahead", "identical"):
        raise ValueError("Qualified coordinator baseline is not reviewed main")
    expected = control_closure(root) if controls else (index["closure"] if ongoing else closure(root))
    if ongoing:
        compare(index["control_closure"], control_closure(root))
    compare(index["control_closure" if controls else "closure"], expected)
    if len({(entry.get("kind"), entry.get("run_id"), entry.get("artifact_id"), entry.get("attempt")) for entry in index["evidence"]}) != len(index["evidence"]):
        raise ValueError("Duplicate qualification evidence cannot multiply green observations")
    needed: set[str] = set()
    if "main_receipts" in requested:
        needed.update(("observer", "publisher"))
    if "path_selection" in requested:
        needed.add("selector-replay")
    if "acceptance_narrowing" in requested:
        needed.add("acceptance-replay")
    if "arch_retirement" in requested or "acceptance_narrowing" in requested:
        needed.update(("nightly", "arch", "archive-sdk", "fork-sdk", "recipe-change"))
    qualified_sets = index.get("qualification_sets", {})
    allowed_artifacts = None
    if all(capability in qualified_sets for capability in requested):
        allowed_artifacts = {artifact for capability in requested for artifact in qualified_sets[capability]}
    entries = [entry for entry in index["evidence"] if entry.get("kind") in needed and (allowed_artifacts is None or entry.get("artifact_id") in allowed_artifacts) and (controls or entry.get("closure_sha256", expected["sha256"]) == expected["sha256"])]
    present = {entry.get("kind") for entry in entries}
    if not needed.issubset(present):
        raise ValueError("Missing actual hosted cutover exercises: " + ", ".join(sorted(needed - present)))
    qualified = [_qualified(entry, repository=repository, expected=expected, api=api or artifacts.api, download=download or artifacts.download_zip, controls=controls) for entry in entries]
    kinds = {row["kind"] for row in qualified}
    if not needed.issubset(kinds):
        raise ValueError("Missing actual hosted cutover exercises: " + ", ".join(sorted(needed - kinds)))
    if "main_receipts" in requested and not {"identical", "divergent", "partially-selected", "failed-rerun"}.issubset({row["observer_case"] for row in qualified if row["kind"] == "observer"}):
        raise ValueError("Main receipt activation lacks actual observer parity cases")
    nights = sorted((row for row in qualified if row["kind"] == "nightly"), key=lambda row: row["created_at"])
    if requested & {"arch_retirement", "acceptance_narrowing"} and len({row["run_id"] for row in nights}) < 2:
        raise ValueError("Retirement needs two distinct actual green nightlies")
    if requested & {"arch_retirement", "acceptance_narrowing"}:
        # A hand-picked pair of green runs must not conceal an intervening red,
        # skipped or incomplete scheduled controller. Enumerate the full window.
        api = api or artifacts.api
        seen = set()
        page = 1
        while True:
            rows = api(repository, f"actions/workflows/preview-packages.yml/runs?event=schedule&branch=main&per_page=100&page={page}")["workflow_runs"]
            for row in rows:
                if not ongoing and row["created_at"] > nights[-1]["created_at"]:
                    raise ValueError("Latest scheduled nightly is not qualified green evidence")
                if nights[0]["created_at"] <= row["created_at"] <= nights[-1]["created_at"]:
                    if row["id"] not in {night["run_id"] for night in nights} or row.get("conclusion") != "success":
                        raise ValueError("Nightly qualification is not consecutive and green")
                    seen.add(row["id"])
            if len(rows) < 100:
                break
            page += 1
        if seen != {night["run_id"] for night in nights}:
            raise ValueError("Scheduled nightly history is incomplete")
    if "acceptance_narrowing" in requested:
        if len({row["run_id"] for row in nights}) < 28 or datetime.fromisoformat(nights[-1]["created_at"].replace("Z", "+00:00")) - datetime.fromisoformat(nights[0]["created_at"].replace("Z", "+00:00")) < timedelta(weeks=4):
            raise ValueError("Acceptance narrowing needs four green weeks of actual observation")
    return {"source": source, "qualified_source": index["source"], "closure_sha256": expected["sha256"], "capabilities": sorted(requested), "qualified": qualified}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--producer-job", required=True)
    parser.add_argument("--exercise-record", type=Path)
    parser.add_argument("--selector-report", type=Path)
    parser.add_argument("--acceptance-report", type=Path)
    parser.add_argument("--selection-report", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    value = descriptor(args.source, root=args.root, run_id=args.run_id, attempt=args.attempt, producer_job=args.producer_job)
    if args.selection_report:
        selection = json.loads(args.selection_report.read_text())
        if not full_candidate_selection(selection):
            parser.error("Incomplete actual full candidate selection")
        value["qualification_selection"] = selection
    if args.exercise_record:
        value["exercise"] = json.loads(args.exercise_record.read_text())
    if args.selector_report:
        report = json.loads(args.selector_report.read_text())
        if report.get("count", 0) < 50 or not {102, 110, 112, 119, 137, 144}.issubset({row["number"] for row in report.get("prs", [])}):
            parser.error("Incomplete actual selector replay")
        value["selector_replay"] = {"count": report["count"], "known_escapes": [102, 110, 112, 119, 137, 144], "sha256": digest(args.selector_report)}
    if args.acceptance_report:
        report = json.loads(args.acceptance_report.read_text())
        if report.get("count", 0) < 50 or report.get("known_escapes") != [102, 110, 112, 119, 137, 144]:
            parser.error("Incomplete actual acceptance dependency replay")
        value["acceptance_replay"] = {"count": report["count"], "known_escapes": report["known_escapes"], "sha256": digest(args.acceptance_report)}
    args.output.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
