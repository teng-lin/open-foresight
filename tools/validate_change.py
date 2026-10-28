#!/usr/bin/env python3
"""Explain, and optionally run, the validation a change needs.

    .venv/bin/python -m tools.validate_change --base origin/main --plan
    .venv/bin/python -m tools.validate_change --base origin/main
    .venv/bin/python -m tools.validate_change --boundary service-helper
    .venv/bin/python -m tools.validate_change --files tools/build.sh --plan

Change set. With Git, the plan is the union of four classes: committed (the
merge base of --base and HEAD to HEAD), staged (index against HEAD), unstaged
(working tree against index) and untracked (not ignored). --include narrows the
classes; without --base the committed class is empty. Renames are reported as a
delete plus an add so both locations select consumers. Without Git metadata (a
source export) pass --files/--files-from; no Git command runs, and --revision /
--base-revision only label the evidence. The change identity hashes path,
class and content, so a dirty tree is never confused with its HEAD.

Selection evolves the existing selectors: `ci_changes.select_gates` stays the
authoritative required-CI selection and `ci_selection.select` its observed
candidate; this module only adds local checks and consumers and never removes a
required CI gate. Paths no rule recognizes, and paths that fail normalization,
select every boundary and gate. Execution calls the checked-in entrypoints named
by `tools/boundary_inventory.json`; it copies none of their commands.

Exit status: 0 for a plan or a run in which every selected check passed on every
needed platform, 1 when a check failed, 2 for invalid input, an inconsistent
inventory or unwritable evidence, 3 for an incomplete run (unavailable, not-run,
manual, CI-only, unexecuted-platform or empty-change-set requirements) and 128
plus the signal number after an interruption (130 for Ctrl-C, 143 for SIGTERM,
129 for SIGHUP). --allow-partial turns 3 into 0 and --baseline-only accepts an
empty change set; neither changes the recorded evidence of what was exercised.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from collections.abc import Callable, Iterator, Mapping, Sequence
import contextlib
import fnmatch
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import Any, TextIO, cast

from tools import boundary_inventory, ci_changes, ci_selection, validation_evidence

ROOT = Path(__file__).resolve().parents[1]
PLAN_SCHEMA = 1
PLAN_KIND = "foresight-validation-plan"
CLASSES = ("committed", "staged", "unstaged", "untracked")
GIT_TIMEOUT = 300
DIGEST_LIMIT = 512 * 1024 * 1024
LIST_LIMIT = 25
KILL_GRACE_SECONDS = 10
READER_GRACE_SECONDS = 2
REUSE_POLICY = (
    "Reused SDKs, build trees, bundles and model fixtures are reported as reused existing outputs. "
    "validate_change neither rebuilds nor verifies their provenance; the named entrypoint does. "
    "A reused output is never presented as a fresh build and a passing check is always a fresh execution of that entrypoint."
)
# CI-selection rules that name a precise, harmless local class; everything else
# from ci_selection is treated as a conservative unknown for local planning.
_QUIET_RULES = {
    "maintenance": ("shared-guards", "python-coverage"),
    "portable-quality": ("shared-guards", "python-coverage"),
    "host-contract": ("shared-guards", "python-coverage", "platform-contracts"),
}
_SUPPORT_SCAN = (
    "packages/foresight_core/test/",
    "packages/foresight_core/bin/",
    "packages/foresight_core/tool/",
    "packages/foresight_test_support/lib/",
    "apps/desktop/test/",
    "apps/desktop/test_support/",
    "apps/desktop/integration_test/",
    "tests/service/",
)
# import, export, part and part of; conditional imports carry several quoted URIs.
_DIRECTIVE = re.compile(r"^\s*(import|export|part\s+of|part)\s+([^;]*);", re.M)
_QUOTED = re.compile(r"""['"]([^'"]+)['"]""")


class PlanError(ValueError):
    """Invalid input or an inconsistent inventory; maps to exit status 2."""


def normalize_path(raw: str) -> str | None:
    """A repository-relative POSIX path, or None when it must be treated as unknown."""
    if not raw or "\0" in raw or "\\" in raw or raw.startswith("/"):
        return None
    path = PurePosixPath(raw)
    if ".." in path.parts or path.as_posix() in (".", ""):
        return None
    return path.as_posix()


def _digest_file(path: Path) -> str | None:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while block := stream.read(1 << 20):
                digest.update(block)
        return digest.hexdigest()
    except OSError:
        return None


def _content(path: Path) -> tuple[str | None, str]:
    """Content digest and state: ok, absent (deleted or never present) or unreadable."""
    try:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while block := stream.read(1 << 20):
                digest.update(block)
        return digest.hexdigest(), "ok"
    except (FileNotFoundError, NotADirectoryError):
        return None, "absent"
    except OSError:
        return None, "unreadable"


def _git(root: Path, *arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(root), *arguments], capture_output=True, check=True, timeout=GIT_TIMEOUT
        ).stdout
    except FileNotFoundError as error:
        raise PlanError("git is not available; pass --files for a source export without Git metadata") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        raise PlanError(f"git {' '.join(arguments[:2])} failed: {detail}") from error


def _names(output: bytes) -> list[str]:
    return [name for name in output.decode(errors="surrogateescape").split("\0") if name]


def build_change_set(
    root: Path,
    *,
    mode: str,
    paths_by_class: Mapping[str, Sequence[str]],
    revision: str | None,
    base: str | None,
    merge_base: str | None,
    dirty: bool | None = None,
    dirty_paths: Sequence[str] = (),
    excluded_classes: Sequence[str] = (),
    dirty_unknown: str | None = None,
    excluded_dirty_paths: Sequence[str] = (),
) -> dict[str, Any]:
    """Assemble the change set and its content-bound identity from classified paths.

    `dirty` is None when the working tree was not inspected (explicit file lists),
    with `dirty_unknown` saying why; it is never guessed as False.
    """
    classes: dict[str, list[str]] = defaultdict(list)
    for name, paths in paths_by_class.items():
        for path in paths:
            classes[path].append(name)
    entries = []
    for path in sorted(classes):
        normalized = normalize_path(path)
        content, state = (None, "invalid-path") if normalized is None else _content(root / normalized)
        entries.append({"path": path, "classes": sorted(classes[path]), "sha256": content, "content": state})
    # Every dirty path is bound into the identity, even one outside the selected classes.
    dirty_state = []
    for path in sorted(dirty_paths):
        normalized = normalize_path(path)
        content, state = (None, "invalid-path") if normalized is None else _content(root / normalized)
        dirty_state.append([path, content, state])
    identity = hashlib.sha256(
        json.dumps(
            {"mode": mode, "revision": revision, "merge_base": merge_base, "entries": entries, "dirty": dirty_state},
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()
    return {
        "mode": mode,
        "revision": revision,
        "base": base,
        "merge_base": merge_base,
        "identity_sha256": identity,
        "paths": [entry["path"] for entry in entries],
        "entries": entries,
        "dirty": dirty,
        "dirty_paths": sorted(dirty_paths),
        "dirty_unknown": dirty_unknown,
        "excluded_classes": sorted(excluded_classes),
        "excluded_dirty_paths": sorted(excluded_dirty_paths),
        "unreadable_paths": [entry["path"] for entry in entries if entry["content"] == "unreadable"],
        "counts": {name: len(paths_by_class.get(name, ())) for name in CLASSES},
    }


def _checkout_top(root: Path) -> Path:
    """The top-level directory of the Git checkout containing `root`."""
    return Path(_git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()


def collect_git(root: Path, base: str | None, include: Sequence[str] = CLASSES) -> dict[str, Any]:
    """Classify committed, staged, unstaged and untracked changes.

    Dirtiness is always computed from the staged, unstaged and untracked classes,
    so `include` can narrow the selected paths but never hide a dirty tree.
    """
    top = _checkout_top(root)
    if top != root.resolve():
        raise PlanError(
            f"{root} is not the top of a Git checkout (it is inside the repository at {top}); "
            "a source export must be planned with --files, not with that repository's state"
        )
    head = _git(root, "rev-parse", "HEAD").decode().strip()
    merge_base = None
    paths: dict[str, list[str]] = {name: [] for name in CLASSES}
    if base is not None and "committed" in include:
        merge_base = _git(root, "merge-base", base, "HEAD").decode().strip()
        paths["committed"] = _names(_git(root, "diff", "--name-only", "--no-renames", "-z", merge_base, "HEAD", "--"))
    everything = {
        "staged": _names(_git(root, "diff", "--cached", "--name-only", "--no-renames", "-z", "--")),
        "unstaged": _names(_git(root, "diff", "--name-only", "--no-renames", "-z", "--")),
        "untracked": _names(_git(root, "ls-files", "--others", "--exclude-standard", "-z")),
    }
    for name, found in everything.items():
        if name in include:
            paths[name] = found
    dirty_paths = sorted({path for found in everything.values() for path in found})
    return build_change_set(
        root,
        mode="git",
        paths_by_class=paths,
        revision=head,
        base=base,
        merge_base=merge_base,
        dirty=bool(dirty_paths),
        dirty_paths=dirty_paths,
        excluded_classes=[name for name in CLASSES if name not in include],
        excluded_dirty_paths=sorted({path for name, found in everything.items() if name not in include for path in found}),
    )


def explicit_change_set(
    root: Path, files: Sequence[str], *, revision: str | None = None, base_revision: str | None = None
) -> dict[str, Any]:
    """An explicit file list; no Git command runs and revisions are declared labels."""
    cleaned = []
    for raw in files:
        normalized = normalize_path(raw[2:] if raw.startswith("./") else raw)
        cleaned.append(normalized if normalized is not None else raw)
    return build_change_set(
        root,
        mode="explicit",
        paths_by_class={"explicit": sorted(set(cleaned))},
        revision=revision,
        base=base_revision,
        merge_base=None,
        dirty=None,
        dirty_unknown="explicit file list: the working tree was not inspected",
    ) | {"revision_declared": revision is not None}


def empty_change_set(reason: str, note: str = "no change set was collected") -> dict[str, Any]:
    return build_change_set(
        ROOT, mode=reason, paths_by_class={}, revision=None, base=None, merge_base=None, dirty=None, dirty_unknown=note
    )


def _directive_targets(name: str, text: str) -> list[tuple[str, str]]:
    """(kind, repository path) for each import/export/part directive in a Dart file."""
    targets = []
    for kind, body in _DIRECTIVE.findall(text):
        for target in _QUOTED.findall(body):  # includes every URI of a conditional import
            if target.startswith("package:foresight_test_support/"):
                resolved = "packages/foresight_test_support/lib/" + target.split("/", 1)[1]
            elif target.startswith(("package:", "dart:")):
                continue
            else:
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            targets.append((kind.split()[0] if kind.startswith("part") else kind, resolved))
    return targets


def support_consumers(
    root: Path, changed: Sequence[str], files: Sequence[str], errors: list[str] | None = None
) -> list[str]:
    """Files that import (transitively) or mention a changed shared-support file.

    A file that cannot be read is returned as a consumer and described in `errors`
    rather than dropped. `part` and `part of` link a file and its library both ways.
    """
    scanned = [
        name
        for name in files
        if (name.startswith(_SUPPORT_SCAN) and name.endswith((".dart", ".py"))) or (name.startswith("tests/") and name.endswith(".py"))
    ]
    support = list(changed)
    if any(not path.endswith(".dart") and PurePosixPath(path).suffix != ".py" for path in support):
        return sorted(scanned)  # pubspec, analysis options: every consumer
    importers: dict[str, set[str]] = defaultdict(set)
    texts: dict[str, str] = {}
    unreadable: set[str] = set()
    for name in scanned:
        try:
            text = (root / name).read_text(errors="replace")
        except OSError as error:
            unreadable.add(name)
            if errors is not None:
                errors.append(f"closure scan could not read {name} ({type(error).__name__}); it is treated as a consumer")
            continue
        texts[name] = text
        if not name.endswith(".dart"):
            continue
        for kind, resolved in _directive_targets(name, text):
            importers[resolved].add(name)
            if kind == "part":
                importers[name].add(resolved)  # a part also depends on its library
    seen = set(support)
    queue = list(support)
    while queue:
        current = queue.pop()
        for importer in importers.get(current, ()):
            if importer not in seen:
                seen.add(importer)
                queue.append(importer)
        # A file mentioned by name is a consumer: Python tests read Dart fixtures (and
        # the Python twin of a Dart fixture), and the twin pairs read each other.
        base = PurePosixPath(current).name
        stem = re.compile(rf"\b{re.escape(PurePosixPath(current).stem)}\b")
        for name, text in texts.items():
            # A Python helper is also imported by module name (`from tests.source_export import ...`).
            mentioned = base in text or (current.endswith(".py") and stem.search(text) is not None)
            if name not in seen and mentioned and (current.endswith(".py") or name.endswith(".py")):
                seen.add(name)
                queue.append(name)
    return sorted((seen | unreadable) - set(support))


def editorial(path: str, patterns: Sequence[str]) -> bool:
    """Documentation that no test reads as a fixture.

    A pattern with a slash is a glob; one without matches only files in the
    repository root, so `*.md` never covers a Markdown fixture under a test tree.
    """
    return any(
        boundary_inventory.glob_match(path, pattern) if "/" in pattern else ("/" not in path and fnmatch.fnmatchcase(path, pattern))
        for pattern in patterns
    )


def classify_paths(
    paths: Sequence[str],
    inventory: Mapping[str, Any],
    root: Path,
    files: Sequence[str],
    ci_rule: Callable[[str], str] | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Per-path rule matches and the downstream-consumer closures they imply."""
    boundaries = {entry["id"]: entry for entry in inventory["boundaries"]}
    ci_rule = ci_rule or (lambda path: ci_selection.path_rule(path, root=root)[0])
    editorial_patterns = inventory.get("benign_globs", {}).get("editorial", [])
    results = []
    closures: list[dict[str, Any]] = []
    support_paths: dict[str, list[str]] = defaultdict(list)
    for path in paths:
        normalized = normalize_path(path)
        matches: list[dict[str, Any]] = []
        if normalized is None:
            results.append(
                {"path": path, "unknown": True, "matches": [{"rule": "invalid-path", "kind": "unknown", "boundaries": ["*"], "gates": ["*"], "reason": "Path is empty, absolute, traverses upward or is not POSIX; treated as unknown."}]}
            )
            continue
        for rule in inventory["impact_rules"]:
            if any(boundary_inventory.glob_match(normalized, glob) for glob in (*rule["globs"], *rule.get("reserved_globs", ()))):
                matches.append({"rule": rule["id"], "kind": rule["kind"], "boundaries": rule["boundaries"], "gates": rule["gates"], "reason": rule["reason"]})
                if rule.get("closure"):
                    support_paths[rule["id"]].append(normalized)
        for boundary in boundaries.values():
            direct = any(boundary_inventory.glob_match(normalized, trigger) for trigger in boundary.get("triggers", ()))
            tested = any(entry["path"] == normalized for entry in boundary["evidence"])
            if direct or tested:
                matches.append(
                    {
                        "rule": f"boundary:{boundary['id']}",
                        "kind": "direct-trigger" if direct else "direct-test",
                        "boundaries": [boundary["id"]],
                        "gates": [boundary["gate"], *boundary.get("also_gates", ())],
                        "reason": f"{normalized} is a {'producer/consumer source' if direct else 'cited test'} of the {boundary['id']} boundary.",
                    }
                )
        if editorial(normalized, editorial_patterns) and not matches:
            matches.append({"rule": "editorial", "kind": "editorial", "boundaries": [], "gates": ["shared-guards"], "reason": "Documentation only; document links and inventories are guarded by the shared checks."})
        unknown = False
        if not matches:
            rule_name = ci_rule(normalized)
            if rule_name in _QUIET_RULES:
                matches.append({"rule": f"ci_selection:{rule_name}", "kind": "ci-known", "boundaries": [], "gates": list(_QUIET_RULES[rule_name]), "reason": f"ci_selection classifies this path as {rule_name}; no boundary consumes it."})
            else:
                unknown = True
                matches.append({"rule": f"unknown:{rule_name}", "kind": "unknown", "boundaries": ["*"], "gates": ["*"], "reason": f"No boundary or closure rule recognizes this path (ci_selection: {rule_name}); every boundary and gate is selected."})
        results.append({"path": normalized, "unknown": unknown, "matches": matches})
    for rule_id, changed in support_paths.items():
        scan_errors: list[str] = []
        consumers = support_consumers(root, changed, files, scan_errors)
        owners = sorted(entry["id"] for entry in boundaries.values() if any(item["path"] in consumers for item in entry["evidence"]))
        closures.append({"rule": rule_id, "changed": sorted(changed), "consumer_count": len(consumers), "consumers": consumers[:LIST_LIMIT * 4], "boundaries": owners, "errors": scan_errors})
    return results, closures


def _gate_order(inventory: Mapping[str, Any]) -> list[str]:
    return list(inventory["gates"])


def ci_selection_report(paths: Sequence[str], inventory: Mapping[str, Any], root: Path) -> dict[str, Any]:
    """Reuse the production selectors; the effective set is their union.

    Required jobs beyond the six gates (acceptance, Arch/native) and the sanitizer
    workflow's path filter come from the same ci_selection module and are mapped to
    local, CI-only or manual gates; none is dropped.
    """
    authoritative = ci_changes.select_gates(list(paths))
    try:
        candidate: dict[str, Any] = ci_selection.select(list(paths), root=root)
        proposed = candidate["selection"]
        error = None
    except Exception as exception:  # noqa: BLE001 - any selector failure must broaden, not abort
        candidate = {"error": f"{type(exception).__name__}: {exception}"}
        proposed = dict.fromkeys(ci_changes.GATES, True)
        error = candidate["error"]
    union = {gate: bool(authoritative[gate] or proposed[gate]) for gate in ci_changes.GATES}
    # Prerequisites and mandatory in-run consumers (for example linux-document-imports
    # with linux-build) are selected CI work too; the closure only adds gates.
    effective = ci_selection.closure(union)
    jobs = set(ci_selection.required_jobs(effective)) | set(candidate.get("required_jobs") or ())
    job_map = inventory["ci_job_map"]
    unmapped = sorted(job for job in jobs if job not in effective and job not in job_map)
    # Without a candidate the sanitizer filter is unknown: select it.
    sanitizers = bool(candidate.get("sanitizers", True))
    platforms = {inventory["ci_gate_map"][gate]["platform"] for gate in effective if effective[gate]}
    platforms.update(job_map[job]["platform"] for job in jobs if job in job_map)
    if sanitizers:
        platforms.add("linux")
    return {
        "authority": "ci_changes.select_gates selects required CI; ci_selection.select is observe-only; this plan unions both and never narrows.",
        "authoritative": authoritative,
        "candidate": candidate.get("selection", candidate),
        "candidate_error": error,
        "effective": effective,
        "required_jobs": sorted(jobs),
        "unmapped_jobs": unmapped,
        "sanitizers": sanitizers,
        "local_gates": {gate: inventory["ci_gate_map"][gate]["gates"] for gate in effective if effective[gate]},
        "job_gates": {job: job_map[job]["gates"] for job in sorted(jobs) if job in job_map},
        "platforms": sorted(platforms),
    }


class Context:
    """Placeholder values for a gate's entrypoint, resolved for this host."""

    def __init__(
        self,
        root: Path,
        environ: Mapping[str, str],
        *,
        bundle: Path | None = None,
        models: Path | None = None,
        output: Path | None = None,
        host: str | None = None,
    ) -> None:
        self.root = root
        self.platform = host or validation_evidence.host_identity()["platform"]
        build = Path(environ.get("FORESIGHT_BUILD_DIR", "build"))
        self.values = {
            "python": sys.executable,
            "platform": self.platform,
            "build_dir": str(build if build.is_absolute() else root / build),
            "native_library": "libforesight_native.dylib" if self.platform == "macos" else "libforesight_native.so",
            "bundle": str(bundle or root / "dist/open-foresight"),
            "models": str(models or root / "build/acceptance-models"),
            "output": str(output) if output else "<evidence-dir>",
        }

    def expand(self, text: str) -> str:
        for key, value in self.values.items():
            text = text.replace("{" + key + "}", value)
        return text

    def path(self, text: str) -> Path:
        expanded = Path(self.expand(text))
        return expanded if expanded.is_absolute() else self.root / expanded


def _requirement(requirement: Mapping[str, Any], context: Context, runnable: Mapping[str, bool]) -> dict[str, Any]:
    kind = requirement["kind"]
    record: dict[str, Any] = {"requirement": dict(requirement)}
    if kind == "executable":
        found = shutil.which(requirement["name"])
        record.update(met=found is not None, detail=found or f"{requirement['name']} is not on PATH")
    elif kind == "python":
        wanted = tuple(int(part) for part in requirement["version"].split("."))
        record.update(met=sys.version_info[: len(wanted)] == wanted, detail=f"running {sys.version.split()[0]}, needs {requirement['version']}")
    else:
        target = context.path(requirement["path"])
        producers = [name for name in requirement.get("produced_by", ()) if runnable.get(name)]
        if target.exists():
            record.update(met=True, detail=str(target))
        elif producers:
            record.update(met=True, detail=f"{target} is not present yet; it is produced by the earlier selected stage {producers[0]}, if that stage passes in this run", satisfied_by=producers[0])
        else:
            record.update(met=False, detail=f"{target} is missing")
    return record


def observe_reuse(record: dict[str, Any]) -> dict[str, Any]:
    """Stat a reuse entry and digest its key files; called at plan time and again at execution."""
    target = Path(record["path"])
    record["present"] = target.exists()
    digests: dict[str, str | None] = {}
    skipped: dict[str, str] = {}
    if record["present"]:
        for name in record["digest_files"]:
            file = Path(name)
            try:
                info = file.stat()
            except OSError as error:
                skipped[name] = f"digest_skipped: {type(error).__name__}"
                continue
            if not file.is_file():
                skipped[name] = "digest_skipped: not a regular file"
            elif info.st_size > DIGEST_LIMIT:
                skipped[name] = f"digest_skipped: larger than {DIGEST_LIMIT} bytes"
            elif (digest := _digest_file(file)) is None:
                skipped[name] = "digest_skipped: unreadable"
            else:
                digests[name] = digest
    record["sha256"] = digests
    record["digest_skipped"] = skipped
    record["presented_as"] = (
        "reused existing output, not freshly built or verified by validate_change"
        if record["present"]
        else "absent; the entrypoint must produce or reject it"
    )
    return record


def _reuse(gate: Mapping[str, Any], context: Context) -> list[dict[str, Any]]:
    return [
        observe_reuse(
            {
                "id": entry["id"],
                "path": str(context.path(entry["path"])),
                "digest_files": [str(context.path(name)) for name in entry.get("digest_files", ())],
                "decision": entry["decision"],
            }
        )
        for entry in gate.get("reuse", ())
    ]


def build_plan(
    inventory: Mapping[str, Any],
    change_set: Mapping[str, Any],
    root: Path,
    context: Context,
    *,
    requested_boundaries: Sequence[str] = (),
    include_long: bool = False,
    files: Sequence[str] | None = None,
) -> dict[str, Any]:
    """The explainable plan: selected boundaries, gates, reuse and unavailability."""
    paths = list(change_set["paths"])
    files = list(files) if files is not None else boundary_inventory.repo_files(root)
    known = {entry["id"]: entry for entry in inventory["boundaries"]}
    for name in requested_boundaries:
        if name not in known:
            raise PlanError(f"Unknown boundary {name!r}; choose from: {', '.join(sorted(known))}")
    classified, closures = classify_paths(paths, inventory, root, files)
    ci = ci_selection_report(paths, inventory, root)

    boundary_why: dict[str, list[dict[str, Any]]] = defaultdict(list)
    gate_why: dict[str, list[dict[str, Any]]] = defaultdict(list)
    conservative: list[str] = []

    def select_boundary(identifier: str, why: dict[str, Any]) -> None:
        targets = list(known) if identifier == "*" else [identifier]
        for target in targets:
            boundary_why[target].append(why)

    def select_gate(identifier: str, why: dict[str, Any]) -> None:
        for target in _gate_order(inventory) if identifier == "*" else [identifier]:
            gate_why[target].append(why)

    for item in classified:
        if item["unknown"]:
            conservative.append(item["path"])
        for match in item["matches"]:
            why = {"source": "rule", "rule": match["rule"], "kind": match["kind"], "path": item["path"], "reason": match["reason"]}
            for target in match["boundaries"]:
                select_boundary(target, why)
            for target in match["gates"]:
                select_gate(target, why)
    for closure in closures:
        for target in closure["boundaries"]:
            select_boundary(target, {"source": "closure", "rule": closure["rule"], "kind": "import-graph", "reason": f"Imports or names the shared test support changed in {closure['changed'][0]}"})
    if ci["candidate_error"]:
        conservative.append("ci_selection error: " + ci["candidate_error"])
    for gate, selected in ci["effective"].items():
        if selected:
            origin = "ci_changes.select_gates" if ci["authoritative"][gate] else "ci_selection.select (observe-only candidate)"
            for target in inventory["ci_gate_map"][gate]["gates"]:
                select_gate(target, {"source": "ci", "rule": f"ci:{gate}", "kind": "ci-selection", "reason": f"CI gate {gate} is selected by {origin}; its local equivalent is {target}."})
    for job in ci["required_jobs"]:
        if job in ci["job_gates"]:
            for target in ci["job_gates"][job]:
                select_gate(target, {"source": "ci", "rule": f"ci-job:{job}", "kind": "ci-selection", "reason": f"Required CI job {job} (ci_selection.required_jobs) maps to local gate {target}."})
    for job in ci["unmapped_jobs"]:
        conservative.append(f"required CI job {job} has no gate mapping")
        select_gate("*", {"source": "ci", "rule": f"ci-job:{job}", "kind": "unknown", "reason": f"Required CI job {job} has no inventory mapping; every gate is selected."})
    if ci["sanitizers"]:
        select_gate("native-sanitizers", {"source": "ci", "rule": "ci:sanitizers", "kind": "ci-selection", "reason": "ci_selection reports that the native-sanitizers workflow path filter matches this change (or could not be evaluated)."})
    for closure in closures:
        for message in closure["errors"]:
            conservative.append(message)
    for name in requested_boundaries:
        select_boundary(name, {"source": "request", "rule": "--boundary", "kind": "explicit", "reason": f"Boundary {name} was requested explicitly."})
    select_gate("shared-guards", {"source": "always", "rule": "baseline", "kind": "always", "reason": "Shared guards are required before every push."})
    for identifier in boundary_why:
        boundary = known[identifier]
        for target in (boundary["gate"], *boundary.get("also_gates", ())):
            select_gate(target, {"source": "boundary", "rule": f"boundary:{identifier}", "kind": "owning-gate", "reason": f"Selected boundary {identifier} is owned by or also exercised through gate {target}."})

    order = _gate_order(inventory)
    selected_gates = [name for name in order if name in gate_why]
    # A check is runnable when platform, prerequisites and (for planned
    # producers) their own availability hold; resolve producers first.
    runnable: dict[str, bool] = {}
    checks: dict[str, dict[str, Any]] = {}
    for _ in range(len(selected_gates) + 1):
        changed = False
        for name in selected_gates:
            check = _check(name, inventory["gates"][name], context, runnable, gate_why[name], paths, include_long)
            checks[name] = check
            value = check["availability"] == "runnable"
            if runnable.get(name) != value:
                runnable[name] = value
                changed = True
        if not changed:
            break
    for name, gate in inventory["gates"].items():
        for subsumed in gate.get("subsumes", ()):
            if name in checks and subsumed in checks and include_long and checks[name]["availability"] == "runnable":
                checks[subsumed]["subsumed_by"] = name

    boundaries = [_boundary(known[name], boundary_why[name], inventory, checks, context) for name in known if name in boundary_why]
    needed = set(ci["platforms"])
    for item in boundaries:
        needed.update(item["platforms"])
    return {
        "schema": PLAN_SCHEMA,
        "kind": PLAN_KIND,
        "host_platform": context.platform,
        "change_set": {key: value for key, value in change_set.items() if key != "entries"},
        "paths": classified,
        "closure": closures,
        "ci_selection": ci,
        "boundaries": boundaries,
        "checks": [checks[name] for name in selected_gates],
        "conservative": bool(conservative),
        "conservative_reasons": sorted(set(conservative)),
        "empty_change_set": not paths,
        "required_platforms": sorted(needed),
        "reuse_policy": REUSE_POLICY,
        "include_long": include_long,
    }


def _check(
    name: str,
    gate: Mapping[str, Any],
    context: Context,
    runnable: Mapping[str, bool],
    why: list[dict[str, Any]],
    paths: Sequence[str],
    include_long: bool,
) -> dict[str, Any]:
    kind = gate["kind"]
    check: dict[str, Any] = {
        "id": name,
        "title": gate["title"],
        "kind": kind,
        "scope": gate.get("scope", "host"),
        "platforms": gate["platforms"],
        "doc": gate["doc"],
        "certifies": gate["certifies"],
        "long": gate["long"],
        "why": _unique(why),
        "status": "planned",
    }
    if kind != "command":
        check.update(
            availability=kind,
            requirement=gate.get("requirement"),
            ci_job=gate.get("ci_job"),
            reason=gate.get("requirement"),
        )
        return check
    reasons = []
    if context.platform not in gate["platforms"]:
        reasons.append(f"requires {'/'.join(gate['platforms'])}; this host is {context.platform}")
    prerequisites = [_requirement(requirement, context, runnable) for requirement in gate.get("requires", ())]
    reasons.extend(item["detail"] for item in prerequisites if not item["met"])
    check.update(
        entrypoint={"argv": [context.expand(token) for token in gate["argv"]], "cwd": str(context.root)},
        timeout_seconds=gate["timeout_seconds"],
        prerequisites=prerequisites,
        reuse=_reuse(gate, context),
        junit=[str(context.path(item)) for item in gate.get("junit", ())],
        availability="unavailable" if reasons else "runnable",
        unavailable_reasons=reasons,
        reason="; ".join(reasons) if reasons else None,
    )
    if gate["long"] and not include_long and not reasons:
        check["deferred"] = "long-running; add --include-long to execute it"
    return check


def _unique(entries: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], dict[str, Any]] = {}
    for entry in entries:
        key = (entry["source"], entry["rule"], entry["kind"])
        record = grouped.setdefault(key, {**entry, "paths": []})
        record.pop("path", None)
        if entry.get("path") and entry["path"] not in record["paths"]:
            record["paths"].append(entry["path"])
    result = []
    for record in grouped.values():
        record["path_count"] = len(record["paths"])
        record["paths"] = record["paths"][:LIST_LIMIT]
        result.append(record)
    return result


def _boundary(
    boundary: Mapping[str, Any],
    why: list[dict[str, Any]],
    inventory: Mapping[str, Any],
    checks: Mapping[str, Mapping[str, Any]],
    context: Context,
) -> dict[str, Any]:
    gate_ids = [boundary["gate"], *boundary.get("also_gates", ())]
    gates = [
        {"id": gate, "kind": inventory["gates"][gate]["kind"], "availability": checks[gate]["availability"], "reason": checks[gate].get("reason")}
        for gate in gate_ids
        if gate in checks
    ]
    counts: dict[str, int] = defaultdict(int)
    for entry in boundary["evidence"]:
        counts[entry["kind"]] += 1
        if entry.get("skip_gate"):
            counts["conditional-on-skip-gate"] += 1
        if entry.get("excluded"):
            counts["run-explicitly-only"] += 1
    owning = inventory["gates"][boundary["gate"]]
    unverified = list(boundary.get("gaps", ()))
    unverified.extend(
        f"{item['id']}: {item['availability']}{' - ' + item['reason'] if item['reason'] else ''}"
        for item in gates
        if item["availability"] != "runnable"
    )
    unverified.extend(
        f"{item['id']}: deferred - {checks[item['id']]['deferred']}" for item in gates if checks[item["id"]].get("deferred")
    )
    unverified.extend(f"manual: {entry['path']}" for entry in boundary["evidence"] if entry["kind"] == "manual")
    return {
        "id": boundary["id"],
        "title": boundary["title"],
        "why": _unique(why),
        "producer": boundary["producer"],
        "consumer": boundary["consumer"],
        "invariants": boundary["invariants"],
        "owner": boundary["owner"],
        "owner_responsibility": inventory["owners"][boundary["owner"]],
        "execution_modes": boundary["execution_modes"],
        "platforms": boundary["platforms"],
        "prerequisites": boundary["prerequisites"],
        "owning_gate": boundary["gate"],
        "gates": gates,
        "mapping": "executable" if owning["kind"] == "command" else owning["kind"],
        "requirement": owning.get("requirement"),
        "evidence_summary": dict(counts),
        "unverified": unverified,
    }


def unexecuted_platforms(plan: Mapping[str, Any], checks: Sequence[Mapping[str, Any]], host: str) -> list[str]:
    """Needed platforms that no passing host-scoped check covered."""
    host_scoped = [check for check in checks if check["scope"] == "host"]
    host_clear = all(check["status"] in ("passed", "subsumed") for check in host_scoped if check["kind"] == "command")
    executed = {host} if host_clear and any(check["status"] == "passed" and check["scope"] == "host" for check in checks) else set()
    return sorted(set(plan["required_platforms"]) - executed)


class SignalInterrupt(KeyboardInterrupt):
    """A SIGTERM or SIGHUP routed through the same path as Ctrl-C."""

    def __init__(self, signum: int) -> None:
        super().__init__(f"signal {signum}")
        self.signum = signum


@contextlib.contextmanager
def interrupt_signals() -> Iterator[None]:
    """Turn SIGTERM and SIGHUP into SignalInterrupt for the duration; restore afterwards."""
    previous: dict[int, Any] = {}

    def handle(signum: int, frame: Any) -> None:
        raise SignalInterrupt(signum)

    try:
        for number in (signal.SIGTERM, signal.SIGHUP):
            previous[number] = signal.signal(number, handle)
    except ValueError:  # not the main thread: signals cannot be routed
        pass
    try:
        yield
    finally:
        for restored, handler in previous.items():
            signal.signal(restored, handler)


@contextlib.contextmanager
def deferred_signals() -> Iterator[list[int]]:
    """Hold SIGINT, SIGTERM and SIGHUP while results are published; yield those received."""
    received: list[int] = []
    previous: dict[int, Any] = {}

    def record(signum: int, frame: Any) -> None:
        received.append(signum)

    try:
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[number] = signal.signal(number, record)
    except ValueError:
        pass
    try:
        yield received
    finally:
        for restored, handler in previous.items():
            signal.signal(restored, handler)


def _exited(process: subprocess.Popen[bytes], timeout: float) -> bool:
    """Whether the leader has exited, without reaping it.

    An unreaped leader keeps its process-group id reserved, so a later killpg
    cannot hit an unrelated group that reused the number.
    """
    deadline = time.monotonic() + timeout
    while True:
        if hasattr(os, "waitid"):
            try:
                if os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG) is not None:
                    return True
            except ChildProcessError:
                return True  # already reaped by someone else
        elif process.poll() is not None:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)


class _Unkillable(Exception):
    """The entrypoint survived SIGKILL."""


def run_streaming(
    argv: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    log_path: Path,
    timeout: int,
    stream: TextIO | None = None,
) -> dict[str, Any]:
    """Run an entrypoint, teeing raw output to a log and the terminal under a deadline.

    The deadline bounds the entrypoint itself, not its output pipe: a descendant that
    escaped the process group and still holds the pipe cannot extend the run. It is
    reported as `leaked_descendants`, separately from `timed_out`, which is set only
    when the entrypoint was still running at the deadline. The leader is reaped last,
    so the group is signalled only while its id is still reserved, and the group is
    killed on every path, including interruption. An entrypoint that survives
    SIGKILL is a failed outcome, not an exception.
    """
    stream = stream or sys.stdout
    started = time.monotonic()
    outcome: dict[str, Any] = {
        "returncode": None, "timed_out": False, "leaked_descendants": False, "error": None, "log": str(log_path),
        "started": False, "group_survivors": None, "unkillable": False,
    }
    try:
        log = log_path.open("wb")
    except OSError as error:
        outcome.update(error=f"cannot open the log: {type(error).__name__}: {error}", seconds=0.0)
        return outcome
    with log:
        try:
            process = subprocess.Popen(
                list(argv), cwd=cwd, env=dict(env), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True
            )
        except OSError as error:
            outcome.update(error=f"cannot start the entrypoint: {type(error).__name__}: {error}", seconds=0.0)
            return outcome
        outcome["started"] = True
        problems: list[str] = []
        closing = threading.Event()

        def pump() -> None:
            reader = cast(io.BufferedReader, process.stdout)
            terminal = True
            while True:
                try:
                    block = reader.read1(1 << 16)
                except (OSError, ValueError):
                    return
                if not block:
                    return
                if not problems and not closing.is_set():
                    try:
                        log.write(block)
                        log.flush()
                    except (OSError, ValueError) as error:  # ValueError: the log was closed under a leaked reader
                        problems.append(f"log write failed: {type(error).__name__}: {error}")
                if terminal and not closing.is_set():
                    try:
                        stream.write(block.decode(errors="replace"))
                        stream.flush()
                    except (OSError, ValueError):
                        terminal = False  # the raw log stays authoritative

        thread = threading.Thread(target=pump, daemon=True)
        thread.start()
        reaped = False
        try:
            if not _exited(process, timeout):
                outcome["timed_out"] = True
                _signal_group(process, signal.SIGTERM)
                if not _exited(process, KILL_GRACE_SECONDS):
                    _signal_group(process, signal.SIGKILL)
                    if not _exited(process, KILL_GRACE_SECONDS):
                        raise _Unkillable
            thread.join(timeout=READER_GRACE_SECONDS)
            # Before anything kills the group: who is still in it besides the
            # exited leader? None means the probe itself failed.
            members = _group_members(process.pid)
            outcome["group_survivors"] = None if members is None else bool(members)
            if thread.is_alive():
                _signal_group(process, signal.SIGKILL)
                thread.join(timeout=READER_GRACE_SECONDS)
                outcome["leaked_descendants"] = thread.is_alive()
            _signal_group(process, signal.SIGKILL)  # survivors in the group, while the id is reserved
            outcome["returncode"] = process.wait(timeout=KILL_GRACE_SECONDS)
            reaped = True
        except _Unkillable:
            outcome["error"] = "the entrypoint did not exit after SIGKILL"
            outcome["unkillable"] = True
        finally:
            closing.set()
            if not reaped:
                _signal_group(process, signal.SIGKILL)
                try:
                    outcome["returncode"] = process.wait(timeout=KILL_GRACE_SECONDS)
                except subprocess.TimeoutExpired:
                    outcome["unkillable"] = True  # never reaped: nothing about its group can be vouched for
    if problems and not outcome["error"]:
        outcome["error"] = problems[0]
    outcome["seconds"] = round(time.monotonic() - started, 3)
    return outcome


def _group_members(leader: int) -> list[int] | None:
    """Live (not zombie) members of the leader's process group other than the leader."""
    try:
        listing = subprocess.run(
            ["ps", "-A", "-o", "pid=,pgid=,stat="], capture_output=True, text=True, timeout=10, check=True
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    members = []
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0].isdigit() and fields[1].isdigit():
            if int(fields[1]) == leader and int(fields[0]) != leader and not fields[2].startswith("Z"):
                members.append(int(fields[0]))
    return members


def _signal_group(process: subprocess.Popen[bytes], number: int) -> None:
    try:
        os.killpg(process.pid, number)
    except (ProcessLookupError, PermissionError):
        pass


def child_environment(environ: Mapping[str, str], output: Path) -> tuple[dict[str, str], dict[str, Any]]:
    """Inherit compliant private temp roots; otherwise create them under the evidence directory."""
    policy = validation_evidence.temp_policy(environ)
    env = dict(environ)
    if not policy["compliant"]:
        for name, child in (("TMPDIR", "tmp"), ("FORESIGHT_TEST_TEMP_ROOT", "t")):
            root = output / child
            root.mkdir(mode=0o700, exist_ok=True)
            env[name] = str(root)
        policy = {**validation_evidence.temp_policy(env), "source": "created under the evidence directory", "inherited": policy}
    else:
        policy = {**policy, "source": "inherited"}
    if not policy["compliant"]:
        broken = [name for name, root in policy["roots"].items() if not root.get("compliant")]
        raise PlanError(
            "Temp-root policy is not met (private, canonical, owned and at most "
            f"{validation_evidence.SHORT_TEMP_LIMIT} characters for Unix sockets): {', '.join(broken)}; "
            "use a shorter private --output directory"
        )
    env["FORESIGHT_PYTHON"] = sys.executable
    return env, policy


def check_phases(entry: Mapping[str, Any], availability: str) -> dict[str, str]:
    """Setup, body and teardown of one check, only as far as this tool observed them.

    Setup is whether the entrypoint could be started here; the body is the
    entrypoint's own outcome (its exit status, not later evidence checks such as
    JUnit); teardown is what the tool saw of its process group when the
    entrypoint ended. `clean` means no member was left in the group; it does not
    cover a descendant that left the group, which is never observed. Anything the
    tool could not see is `unknown`, and a phase that did not run is `not-run`.
    """
    setup = {"ci-only": "not-applicable", "manual": "not-applicable", "unavailable": "unavailable"}.get(availability, "ok")
    if entry.get("subsumed_by"):
        return {"setup": "ok", "body": "not-applicable", "teardown": "not-applicable"}
    if entry.get("interrupted"):
        if entry.get("interrupted_before_start"):
            return {"setup": "failed", "body": "not-run", "teardown": "not-run"}
        return {"setup": "ok", "body": "interrupted", "teardown": "unknown"}
    if "started" not in entry:
        return {"setup": setup, "body": "not-run", "teardown": "not-run"}
    if not entry["started"]:
        return {"setup": "failed", "body": "not-run", "teardown": "not-run"}
    if entry.get("timed_out"):
        body = "timed-out"
    else:
        body = "passed" if entry.get("returncode") == 0 else "failed"
    if entry.get("unkillable"):
        teardown = "unknown"
    elif entry.get("timed_out"):
        teardown = "killed-after-timeout"
    elif entry.get("leaked_descendants"):
        teardown = "leaked-descendants"
    elif entry.get("group_survivors") is None:
        teardown = "unknown"
    elif entry["group_survivors"]:
        teardown = "group-survivors-killed"
    else:
        teardown = "clean"
    return {"setup": setup, "body": body, "teardown": teardown}


def _outcome_status(outcome: Mapping[str, Any]) -> tuple[str, str | None]:
    """Status and reason for an entrypoint's run outcome."""
    if outcome.get("error"):
        return "failed", str(outcome["error"])
    if outcome.get("timed_out"):
        return "failed", "timed out"
    if outcome.get("leaked_descendants"):
        return "failed", "a descendant escaped the process group and kept the output open after the entrypoint exited"
    if outcome["returncode"] != 0:
        return "failed", f"exit status {outcome['returncode']}"
    return "passed", None


def execute(
    plan: Mapping[str, Any],
    output: Path,
    environ: Mapping[str, str],
    *,
    include_long: bool,
    runner: Callable[..., dict[str, Any]] | None = None,
    stream: TextIO | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Call each selected, runnable entrypoint; record every other check honestly.

    An interruption (Ctrl-C, SIGTERM or SIGHUP) while a check is being prepared, run
    or its JUnit read, or an I/O failure, is recorded as a failed check and the rest
    of the runnable checks as not run, keeping the results so far.
    """
    runner = runner or run_streaming
    env, temp_policy = child_environment(environ, output)
    logs = output / "logs"
    logs.mkdir(mode=0o700, exist_ok=True)
    results: dict[str, dict[str, Any]] = {}
    outcomes: dict[str, str] = {}
    ordered = list(plan["checks"])
    interrupted = False
    for check in ordered:
        result = {key: check[key] for key in ("id", "title", "kind", "scope", "platforms", "doc", "certifies", "long")}
        result["why"] = check["why"]
        result["entrypoint"] = check.get("entrypoint")
        result["reuse"] = [dict(item) for item in check.get("reuse", [])]
        result["prerequisites"] = check.get("prerequisites", [])
        availability = check["availability"]
        result["reason"] = check.get("reason")
        if availability in ("ci-only", "manual"):
            result["status"] = availability
        elif availability == "unavailable":
            result["status"] = "unavailable"
        elif check.get("subsumed_by"):
            result["status"] = "subsumed"
            result["subsumed_by"] = check["subsumed_by"]
            result["reason"] = (
                f"claimed: the inventory declares that {check['subsumed_by']} re-runs this check; "
                "that was not independently verified"
            )
        elif check["long"] and not include_long:
            result.update(status="not-run", reason=check.get("deferred"))
        elif interrupted:
            result.update(status="not-run", reason="the run was interrupted")
        else:
            blocked = [
                item["satisfied_by"]
                for item in check["prerequisites"]
                if item.get("satisfied_by") and outcomes.get(item["satisfied_by"]) != "passed"
            ]
            if blocked:
                result.update(status="not-run", reason=f"prerequisite {blocked[0]} did not pass in this run")
            else:
                started = time.time()
                log_path = logs / f"{check['id']}.log"
                entered = False
                try:
                    for item in result["reuse"]:
                        # The plan-time observation can be stale by now; record what is there at execution.
                        item["at_execution"] = {
                            key: observe_reuse({"path": item["path"], "digest_files": item.get("digest_files", [])})[key]
                            for key in ("present", "sha256", "digest_skipped")
                        }
                    try:
                        entered = True
                        outcome = runner(
                            check["entrypoint"]["argv"],
                            cwd=Path(check["entrypoint"]["cwd"]),
                            env=env,
                            log_path=log_path,
                            timeout=check["timeout_seconds"],
                            **({"stream": stream} if stream is not None else {}),
                        )
                    except OSError as error:
                        outcome = {"returncode": None, "timed_out": False, "leaked_descendants": False, "error": f"could not run the entrypoint: {type(error).__name__}: {error}", "seconds": 0.0, "log": None, "started": False}
                    status, reason = _outcome_status(outcome)
                    result.update(
                        status=status,
                        reason=reason,
                        returncode=outcome["returncode"],
                        timed_out=bool(outcome.get("timed_out")),
                        leaked_descendants=bool(outcome.get("leaked_descendants")),
                        started=bool(outcome.get("started", True)),
                        group_survivors=outcome.get("group_survivors", False),
                        seconds=outcome["seconds"],
                        log=outcome["log"],
                        junit=[validation_evidence.junit_counts(Path(item), started) for item in check.get("junit", ())],
                    )
                    if status == "passed" and (problems := validation_evidence.junit_problems(result["junit"])):
                        # Declared JUnit evidence must exist, be fresh and show executed passing tests.
                        result.update(status="failed", reason="JUnit evidence does not support a pass: " + "; ".join(problems))
                except KeyboardInterrupt as signalled:
                    # Ctrl-C, SIGTERM or SIGHUP during reuse observation, the entrypoint or JUnit parsing.
                    interrupted = True
                    result.update(
                        status="failed", reason="interrupted", interrupted=True, interrupted_before_start=not entered,
                        interrupt_signal=getattr(signalled, "signum", int(signal.SIGINT)),
                        log=str(log_path) if log_path.exists() else None, seconds=round(time.time() - started, 3),
                    )
        outcomes[check["id"]] = result["status"]
        results[check["id"]] = result
    for result in results.values():
        if result["status"] == "subsumed" and outcomes.get(result["subsumed_by"]) != "passed":
            result.update(status="failed", reason=f"subsuming check {result['subsumed_by']} did not pass")
    for check in ordered:
        results[check["id"]]["phases"] = check_phases(results[check["id"]], check["availability"])
    return [results[check["id"]] for check in ordered], temp_policy


def reproduction_lines(plan: Mapping[str, Any], argv: Sequence[str]) -> list[str]:
    change = plan["change_set"]
    lines = [f"cd <checkout> && {shlex.join([sys.executable, '-m', 'tools.validate_change', *argv])}"]
    if change["mode"] == "git":
        lines.append(f"Source revision {change['revision']}; base {change['base']} (merge base {change['merge_base']}); dirty={change['dirty']}.")
    else:
        lines.append(f"Explicit change set {change['identity_sha256']}; no Git metadata was read.")
    lines.append("Platform and account conditions are recorded in this summary; a hosted-only job cannot be reproduced from it alone.")
    return lines


def render(plan: Mapping[str, Any], *, results: Sequence[Mapping[str, Any]] | None = None, summary: Mapping[str, Any] | None = None) -> str:
    """Human-readable plan (and, after a run, the per-check outcome)."""
    change = plan["change_set"]
    out = [
        f"Change set: {len(change['paths'])} path(s), mode={change['mode']}, identity={change['identity_sha256'][:16]}, dirty={change['dirty']}",
    ]
    if change["mode"] == "git":
        out.append(f"  revision={change['revision']} base={change['base']} merge-base={change['merge_base']} counts={change['counts']}")
    if plan["conservative"]:
        out.append("Conservative selection (unknown inputs): " + "; ".join(plan["conservative_reasons"][:LIST_LIMIT]))
    ci = plan["ci_selection"]
    selected_ci = ", ".join(gate for gate, value in ci["effective"].items() if value)
    out.append("CI selection (authoritative, never narrowed): " + (selected_ci or "none"))
    out.append(f"Required platforms: {', '.join(plan['required_platforms']) or 'none'}; this host: {plan['host_platform']}")
    out.append("")
    out.append("Boundaries")
    for boundary in plan["boundaries"]:
        out.append(f"  {boundary['id']} -> {boundary['owning_gate']} [{boundary['mapping']}] owner={boundary['owner']}")
        for entry in boundary["why"]:
            out.append(f"      why: {entry['reason']} ({entry['path_count']} path(s))" if entry.get("path_count") else f"      why: {entry['reason']}")
        for item in boundary["unverified"]:
            out.append(f"      unverified: {item}")
    out.append("")
    out.append("Checks")
    by_id = {item["id"]: item for item in results or ()}
    for check in plan["checks"]:
        status = by_id[check["id"]]["status"] if check["id"] in by_id else check["availability"]
        out.append(f"  {check['id']} [{status}] {check['title']}")
        if check.get("entrypoint"):
            out.append("      run: " + " ".join(check["entrypoint"]["argv"]))
        for entry in check["why"]:
            out.append(f"      why: {entry['reason']}")
        for item in check.get("prerequisites", ()):
            label = "MISSING" if not item["met"] else f"pending ({item['satisfied_by']})" if item.get("satisfied_by") else "ok"
            out.append(f"      prerequisite {label}: {item['detail']}")
        for item in check.get("reuse", ()):
            out.append(f"      reuse: {item['presented_as']} ({item['path']})")
        if check.get("reason"):
            out.append(f"      note: {check['reason']}")
        if check.get("deferred"):
            out.append(f"      deferred: {check['deferred']}")
        if check["id"] in by_id and by_id[check["id"]].get("log"):
            out.append(f"      log: {by_id[check['id']]['log']}")
    if summary is not None:
        out.append("")
        out.append(f"Result: {summary['status']} (full_validation={summary['full_validation']})")
        for reason in summary["not_full_validation_reasons"]:
            out.append(f"  - {reason}")
    out.append("")
    out.append(REUSE_POLICY)
    return "\n".join(out)


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", help="base revision; committed changes are merge-base(BASE, HEAD)..HEAD")
    parser.add_argument("--files", nargs="+", metavar="PATH", help="explicit changed files; no Git command runs")
    parser.add_argument("--files-from", metavar="FILE", help="read explicit files (newline or NUL separated); - is stdin")
    parser.add_argument("--include", default=",".join(CLASSES), help="comma-separated Git classes: " + ", ".join(CLASSES))
    parser.add_argument("--revision", help="declared source revision label for --files evidence")
    parser.add_argument("--base-revision", help="declared base revision label for --files evidence")
    parser.add_argument("--boundary", action="append", default=[], metavar="NAME", help="select a boundary explicitly (repeatable)")
    parser.add_argument("--list-boundaries", action="store_true")
    parser.add_argument("--plan", action="store_true", help="explain the plan without executing anything")
    parser.add_argument("--json", action="store_true", help="print the plan or run summary as JSON")
    parser.add_argument("--output", type=Path, help="evidence directory (under /var/tmp, private and empty for a run)")
    parser.add_argument("--include-long", action="store_true", help="also execute long-running checks")
    parser.add_argument("--bundle", type=Path, help="prepared application bundle for integration gates")
    parser.add_argument("--models", type=Path, help="model fixture directory for integration gates")
    parser.add_argument("--allow-partial", action="store_true", help="exit 0 for an incomplete run without failures")
    parser.add_argument("--baseline-only", action="store_true", help="accept an empty change set: validate only the baseline and requested boundaries")
    parser.add_argument("--skip-inventory-check", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args(argv)
    if arguments.files and arguments.base:
        parser.error("--files and --base are mutually exclusive")
    if arguments.files and arguments.files_from:
        parser.error("--files and --files-from are mutually exclusive")
    include = [name for name in arguments.include.split(",") if name]
    if not include or set(include) - set(CLASSES):
        parser.error("--include takes a comma-separated subset of " + ", ".join(CLASSES))
    arguments.include = include
    return arguments


def read_files(source: str) -> list[str]:
    text = sys.stdin.read() if source == "-" else Path(source).read_text(errors="surrogateescape")
    return [item for item in text.split("\0" if "\0" in text else "\n") if item]


def main(argv: Sequence[str] | None = None, root: Path = ROOT, environ: Mapping[str, str] | None = None) -> int:
    """Run the planner. SIGTERM and SIGHUP are routed like Ctrl-C for the whole call.

    An interruption while checks run is recorded (kill the entrypoint's group, write
    the evidence, exit 128 plus the signal number). Once results exist they are
    published with signals held. An interruption during argument handling, planning
    or the digesting of reused outputs for the plan happens before any check ran: it
    exits the same way but writes no evidence, because there is nothing to record.
    """
    with interrupt_signals():
        try:
            return _main(argv, root, environ)
        except KeyboardInterrupt as signalled:
            print("validate_change: interrupted before any result existed; no evidence was written", file=sys.stderr)
            return 128 + getattr(signalled, "signum", int(signal.SIGINT))


def _main(argv: Sequence[str] | None, root: Path, environ: Mapping[str, str] | None) -> int:
    environ = os.environ if environ is None else environ
    raw_arguments = list(sys.argv[1:] if argv is None else argv)
    arguments = parse_arguments(raw_arguments)
    mode = "plan" if arguments.plan else "run"
    output = None
    try:
        inventory_verified = not arguments.skip_inventory_check
        if inventory_verified:
            try:
                boundary_inventory.verify(root)
            except ValueError as error:
                raise PlanError(str(error)) from error
        inventory = boundary_inventory.load(root)
        if arguments.list_boundaries:
            for boundary in inventory["boundaries"]:
                print(f"{boundary['id']}\t{boundary['gate']}\t{boundary['title']}")
            return 0
        explicit = arguments.files
        if arguments.files_from:
            explicit = read_files(arguments.files_from)
            if not explicit:
                raise PlanError(f"{arguments.files_from} lists no paths; an empty change set is not a change")
        if explicit is not None:
            change_set = explicit_change_set(root, explicit, revision=arguments.revision, base_revision=arguments.base_revision)
        else:
            try:
                change_set = collect_git(root, arguments.base, arguments.include)
            except PlanError:
                if not arguments.boundary or arguments.base:
                    raise
                change_set = empty_change_set("boundary-request", note="no change set was collected: git could not describe the checkout")
        if mode == "run" or arguments.output:
            from tools import check_local_validation

            try:
                output = check_local_validation.private_output(arguments.output)
            except ValueError as error:
                raise PlanError(str(error)) from error
        context = Context(root, environ, bundle=arguments.bundle, models=arguments.models, output=output)
        plan = build_plan(inventory, change_set, root, context, requested_boundaries=arguments.boundary, include_long=arguments.include_long)
    except (PlanError, OSError, KeyError, ValueError) as error:
        print(f"validate_change: {type(error).__name__}: {error}" if not isinstance(error, PlanError) else f"validate_change: {error}", file=sys.stderr)
        return 2

    incomplete: list[str] = []
    if not inventory_verified:
        incomplete.append("the boundary inventory consistency check was skipped (--skip-inventory-check)")
    if plan["empty_change_set"] and not arguments.baseline_only:
        incomplete.append("empty change set: nothing was selected beyond the baseline" + (" and the requested boundaries" if arguments.boundary else "") + "; pass --baseline-only to validate only that")
    change = plan["change_set"]
    if change["excluded_dirty_paths"]:
        incomplete.append(
            "dirty paths in excluded classes were not selected: " + ", ".join(change["excluded_dirty_paths"][:LIST_LIMIT])
        )
    if change["unreadable_paths"]:
        incomplete.append("change-set content was unreadable for: " + ", ".join(change["unreadable_paths"][:LIST_LIMIT]))

    started_utc = time.time()
    results: list[dict[str, Any]] = []
    temp_policy = validation_evidence.temp_policy(environ)
    if mode == "run":
        try:
            results, temp_policy = execute(plan, cast(Path, output), environ, include_long=arguments.include_long)
        except PlanError as error:
            print(f"validate_change: {error}", file=sys.stderr)
            return 2
        checks = results
    else:
        checks = [dict(check, junit=[]) for check in plan["checks"]]
    with deferred_signals() as received:
        unexecuted = [] if mode == "plan" else unexecuted_platforms(plan, checks, context.platform)
        build: dict[str, Any] = dict(
            mode=mode,
            source={key: change[key] for key in ("mode", "revision", "base", "merge_base", "identity_sha256", "dirty", "dirty_paths", "dirty_unknown", "excluded_classes", "excluded_dirty_paths", "unreadable_paths", "counts")}
            | {"revision_declared": change.get("revision_declared"), "path_count": len(change["paths"])},
            invocation={
                "entrypoint": "tools.validate_change",
                "argv": raw_arguments,
                "cwd": str(Path.cwd()),
                "executable": sys.executable,
                "root": str(root),
                "started_epoch": round(started_utc, 3),
                "inventory_verified": inventory_verified,
                "baseline_only": arguments.baseline_only,
            },
            selection={
                "conservative": plan["conservative"],
                "conservative_reasons": plan["conservative_reasons"],
                "ci": plan["ci_selection"]["effective"],
                "ci_required_jobs": plan["ci_selection"]["required_jobs"],
                "sanitizers": plan["ci_selection"]["sanitizers"],
                "boundaries": [boundary["id"] for boundary in plan["boundaries"]],
                "required_platforms": plan["required_platforms"],
            },
            checks=[_evidence_check(check) for check in checks],
            unexecuted_platforms=unexecuted,
            reproduction=reproduction_lines(plan, raw_arguments),
            environ=environ,
            incomplete_reasons=incomplete,
            temp_root_policy=temp_policy,
        )
        summary: dict[str, Any] | None
        try:
            summary = validation_evidence.build_summary(
                **build,
                tools=validation_evidence.observe_tools() if mode == "run" else None,
                pins=validation_evidence.pinned_tools(root),
            )
        except (OSError, ValueError, KeyError, TypeError) as error:
            # A completed run's results are printed even when its evidence cannot be built.
            summary = None
            print(f"validate_change: the evidence could not be built: {type(error).__name__}: {error}", file=sys.stderr)
        # Results first: a failure to publish evidence must not lose a completed run's output.
        if arguments.json:
            print(json.dumps({"plan": plan, "evidence": summary}, indent=2, sort_keys=True))
        else:
            print(render(plan, results=results or None, summary=summary if mode == "run" else None))
        written = summary is not None
        if output is not None and summary is not None:
            try:
                (output / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
                validation_evidence.write_summary(summary, output / "evidence.json")
                if not arguments.json:
                    print(f"Evidence: {output / 'evidence.json'}")
            except (OSError, ValueError) as error:
                written = False
                print(f"validate_change: the evidence could not be written: {type(error).__name__}: {error}", file=sys.stderr)
    signals = [number for check in checks if (number := check.get("interrupt_signal"))] + received
    if signals:
        return 128 + signals[0]
    if summary is None:
        return 2
    if mode == "plan":
        return 0 if written else 2
    if summary["status"] == "failed":
        return 1
    if not written:
        return 2
    if summary["status"] == "full-validation-passed" or arguments.allow_partial:
        return 0
    return 3


def _evidence_check(check: Mapping[str, Any]) -> dict[str, Any]:
    keys = ("id", "title", "kind", "scope", "platforms", "status", "reason", "returncode", "timed_out", "leaked_descendants", "interrupted", "seconds", "log", "junit", "subsumed_by", "long", "phases", "started", "group_survivors", "unkillable")
    record = {key: check[key] for key in keys if key in check}
    if "phases" not in record:
        record["phases"] = check_phases(check, check.get("availability", "runnable"))
    record["entrypoint"] = (check.get("entrypoint") or {}).get("argv")
    record["why"] = [entry["reason"] for entry in check.get("why", ())][:LIST_LIMIT]
    record["reuse"] = [
        {key: item[key] for key in ("id", "path", "present", "presented_as", "sha256", "digest_skipped", "at_execution") if key in item}
        for item in check.get("reuse", ())
    ]
    record["unavailable"] = [item["detail"] for item in check.get("prerequisites", ()) if not item["met"]]
    if check.get("availability") == "unavailable" and check.get("status") == "planned":
        record["unavailable"] = check.get("unavailable_reasons", [])
    return record


if __name__ == "__main__":
    raise SystemExit(main())
