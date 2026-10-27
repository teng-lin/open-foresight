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
needed platform, 1 when a check failed, 2 for invalid input or an inconsistent
inventory, 3 for an incomplete run (unavailable, not-run, manual, CI-only or
unexecuted-platform requirements). --allow-partial turns 3 into 0 but never
changes the recorded status.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from collections.abc import Callable, Mapping, Sequence
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
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
REUSE_POLICY = (
    "Reused SDKs, build trees, bundles and model fixtures are reported as reused existing outputs. "
    "validate_change neither rebuilds nor verifies their provenance; the named entrypoint does. "
    "A reused output is never presented as a fresh build and a passing check is always a fresh execution of that entrypoint."
)
# CI-selection rules that name a precise, harmless local class; everything else
# from ci_selection is treated as a conservative unknown for local planning.
_QUIET_RULES = {
    "editorial": ("shared-guards",),
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
_IMPORT = re.compile(r"""^\s*(?:import|export)\s+['"]([^'"]+)['"]""", re.M)


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
    blobs: Mapping[str, str | None] | None = None,
) -> dict[str, Any]:
    """Assemble the change set and its content-bound identity from classified paths."""
    classes: dict[str, list[str]] = defaultdict(list)
    for name, paths in paths_by_class.items():
        for path in paths:
            classes[path].append(name)
    entries = []
    for path in sorted(classes):
        content = None if (normalized := normalize_path(path)) is None else _digest_file(root / normalized)
        entries.append(
            {
                "path": path,
                "classes": sorted(classes[path]),
                "sha256": content,
                **({"blob": blobs[path]} if blobs and path in blobs else {}),
            }
        )
    identity = hashlib.sha256(
        json.dumps(
            {"mode": mode, "revision": revision, "merge_base": merge_base, "entries": entries},
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()
    dirty = sorted(path for path, found in classes.items() if set(found) & {"staged", "unstaged", "untracked"})
    return {
        "mode": mode,
        "revision": revision,
        "base": base,
        "merge_base": merge_base,
        "identity_sha256": identity,
        "paths": [entry["path"] for entry in entries],
        "entries": entries,
        "dirty": bool(dirty),
        "dirty_paths": dirty,
        "counts": {name: len(paths_by_class.get(name, ())) for name in CLASSES},
    }


def collect_git(root: Path, base: str | None, include: Sequence[str] = CLASSES) -> dict[str, Any]:
    """Classify committed, staged, unstaged and untracked changes."""
    head = _git(root, "rev-parse", "HEAD").decode().strip()
    merge_base = None
    paths: dict[str, list[str]] = {name: [] for name in CLASSES}
    if base is not None and "committed" in include:
        merge_base = _git(root, "merge-base", base, "HEAD").decode().strip()
        paths["committed"] = _names(_git(root, "diff", "--name-only", "--no-renames", "-z", merge_base, "HEAD", "--"))
    if "staged" in include:
        paths["staged"] = _names(_git(root, "diff", "--cached", "--name-only", "--no-renames", "-z", "--"))
    if "unstaged" in include:
        paths["unstaged"] = _names(_git(root, "diff", "--name-only", "--no-renames", "-z", "--"))
    if "untracked" in include:
        paths["untracked"] = _names(_git(root, "ls-files", "--others", "--exclude-standard", "-z"))
    return build_change_set(root, mode="git", paths_by_class=paths, revision=head, base=base, merge_base=merge_base)


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
    ) | {"revision_declared": revision is not None}


def empty_change_set(reason: str) -> dict[str, Any]:
    return build_change_set(ROOT, mode=reason, paths_by_class={}, revision=None, base=None, merge_base=None)


def support_consumers(root: Path, changed: Sequence[str], files: Sequence[str]) -> list[str]:
    """Files that import (transitively) or mention a changed shared-support file."""
    scanned = [name for name in files if name.startswith(_SUPPORT_SCAN) and name.endswith((".dart", ".py"))]
    support = [path for path in changed if path.startswith(("packages/foresight_test_support/", "tests/service/gated_helper"))]
    if any(not path.endswith(".dart") and PurePosixPath(path).suffix != ".py" for path in support):
        return sorted(scanned)  # pubspec, analysis options: every consumer
    importers: dict[str, set[str]] = defaultdict(set)
    texts: dict[str, str] = {}
    for name in scanned:
        try:
            text = (root / name).read_text(errors="replace")
        except OSError:
            continue
        texts[name] = text
        if not name.endswith(".dart"):
            continue
        for target in _IMPORT.findall(text):
            if target.startswith("package:foresight_test_support/"):
                resolved = "packages/foresight_test_support/lib/" + target.split("/", 1)[1]
            elif target.startswith(("package:", "dart:")):
                continue
            else:
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            importers[resolved].add(name)
    seen = set(support)
    queue = list(support)
    while queue:
        current = queue.pop()
        for importer in importers.get(current, ()):
            if importer not in seen:
                seen.add(importer)
                queue.append(importer)
        base = PurePosixPath(current).name
        if current.endswith(".py"):
            for name, text in texts.items():
                if name not in seen and base in text:
                    seen.add(name)
                    queue.append(name)
    return sorted(seen - set(support))


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
    editorial = inventory.get("benign_globs", {}).get("editorial", [])
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
        if any(boundary_inventory.glob_match(normalized, glob) for glob in editorial) and not matches:
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
        consumers = support_consumers(root, changed, files)
        owners = sorted(entry["id"] for entry in boundaries.values() if any(item["path"] in consumers for item in entry["evidence"]))
        closures.append({"rule": rule_id, "changed": sorted(changed), "consumer_count": len(consumers), "consumers": consumers[:LIST_LIMIT * 4], "boundaries": owners})
    return results, closures


def _gate_order(inventory: Mapping[str, Any]) -> list[str]:
    return list(inventory["gates"])


def ci_selection_report(paths: Sequence[str], inventory: Mapping[str, Any], root: Path) -> dict[str, Any]:
    """Reuse the production selectors; the effective set is their union."""
    authoritative = ci_changes.select_gates(list(paths))
    try:
        candidate: dict[str, Any] = ci_selection.select(list(paths), root=root)
        proposed = candidate["selection"]
        error = None
    except Exception as exception:  # noqa: BLE001 - any selector failure must broaden, not abort
        candidate = {"error": f"{type(exception).__name__}: {exception}"}
        proposed = dict.fromkeys(ci_changes.GATES, True)
        error = candidate["error"]
    effective = {gate: bool(authoritative[gate] or proposed[gate]) for gate in ci_changes.GATES}
    return {
        "authority": "ci_changes.select_gates selects required CI; ci_selection.select is observe-only; this plan unions both and never narrows.",
        "authoritative": authoritative,
        "candidate": candidate.get("selection", candidate),
        "candidate_error": error,
        "effective": effective,
        "required_jobs": candidate.get("required_jobs"),
        "local_gates": {gate: inventory["ci_gate_map"][gate]["gates"] for gate in effective if effective[gate]},
        "platforms": sorted({inventory["ci_gate_map"][gate]["platform"] for gate in effective if effective[gate]}),
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
            record.update(met=True, detail=f"{target} is missing now; {producers[0]} produces it if that check passes earlier in this run", satisfied_by=producers[0])
        else:
            record.update(met=False, detail=f"{target} is missing")
    return record


def _reuse(gate: Mapping[str, Any], context: Context) -> list[dict[str, Any]]:
    records = []
    for entry in gate.get("reuse", ()):
        target = context.path(entry["path"])
        present = target.exists()
        digests = {}
        if present:
            for name in entry.get("digest_files", ()):
                file = context.path(name)
                if file.is_file() and file.stat().st_size <= DIGEST_LIMIT:
                    digests[str(file)] = _digest_file(file)
        records.append(
            {
                "id": entry["id"],
                "path": str(target),
                "present": present,
                "presented_as": "reused existing output, not freshly built or verified by validate_change" if present else "absent; the entrypoint must produce or reject it",
                "sha256": digests,
                "decision": entry["decision"],
            }
        )
    return records


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
            select_boundary(target, {"source": "closure", "rule": closure["rule"], "kind": "import-graph", "reason": f"Imports shared test support changed in {closure['changed'][0]}"})
    if ci["candidate_error"]:
        conservative.append("ci_selection error: " + ci["candidate_error"])
    for gate, selected in ci["effective"].items():
        if selected:
            origin = "ci_changes.select_gates" if ci["authoritative"][gate] else "ci_selection.select (observe-only candidate)"
            for target in inventory["ci_gate_map"][gate]["gates"]:
                select_gate(target, {"source": "ci", "rule": f"ci:{gate}", "kind": "ci-selection", "reason": f"CI gate {gate} is selected by {origin}; its local equivalent is {target}."})
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
        junit=[context.expand(item) for item in gate.get("junit", ())],
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


def run_streaming(
    argv: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    log_path: Path,
    timeout: int,
    stream: TextIO | None = None,
) -> dict[str, Any]:
    """Run an entrypoint, teeing raw output to a log and the terminal under a deadline."""
    stream = stream or sys.stdout
    started = time.monotonic()
    timed_out = threading.Event()
    with log_path.open("wb") as log:
        process = subprocess.Popen(
            list(argv), cwd=cwd, env=dict(env), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True
        )

        def expire() -> None:
            timed_out.set()
            _signal_group(process, signal.SIGTERM)
            killer = threading.Timer(KILL_GRACE_SECONDS, _signal_group, (process, signal.SIGKILL))
            killer.daemon = True
            killer.start()

        watchdog = threading.Timer(timeout, expire)
        watchdog.daemon = True
        watchdog.start()
        try:
            reader = cast(io.BufferedReader, process.stdout)
            while block := reader.read1(1 << 16):
                log.write(block)
                log.flush()
                stream.write(block.decode(errors="replace"))
                stream.flush()
            code = process.wait(timeout=timeout + 2 * KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            _signal_group(process, signal.SIGKILL)
            code = process.wait(timeout=KILL_GRACE_SECONDS)
        finally:
            watchdog.cancel()
    return {"returncode": code, "timed_out": timed_out.is_set(), "seconds": round(time.monotonic() - started, 3), "log": str(log_path)}


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
    env["FORESIGHT_PYTHON"] = sys.executable
    return env, policy


def execute(
    plan: Mapping[str, Any],
    output: Path,
    environ: Mapping[str, str],
    *,
    include_long: bool,
    runner: Callable[..., dict[str, Any]] | None = None,
    stream: TextIO | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Call each selected, runnable entrypoint; record every other check honestly."""
    runner = runner or run_streaming
    env, temp_policy = child_environment(environ, output)
    logs = output / "logs"
    logs.mkdir(mode=0o700, exist_ok=True)
    results: dict[str, dict[str, Any]] = {}
    outcomes: dict[str, str] = {}
    ordered = list(plan["checks"])
    for check in ordered:
        result = {key: check[key] for key in ("id", "title", "kind", "scope", "platforms", "doc", "certifies", "long")}
        result["why"] = check["why"]
        result["entrypoint"] = check.get("entrypoint")
        result["reuse"] = check.get("reuse", [])
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
        elif check["long"] and not include_long:
            result.update(status="not-run", reason=check.get("deferred"))
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
                outcome = runner(
                    check["entrypoint"]["argv"],
                    cwd=Path(check["entrypoint"]["cwd"]),
                    env=env,
                    log_path=logs / f"{check['id']}.log",
                    timeout=check["timeout_seconds"],
                    **({"stream": stream} if stream is not None else {}),
                )
                result.update(
                    status="passed" if outcome["returncode"] == 0 and not outcome["timed_out"] else "failed",
                    returncode=outcome["returncode"],
                    timed_out=outcome["timed_out"],
                    seconds=outcome["seconds"],
                    log=outcome["log"],
                    junit=[validation_evidence.junit_counts(Path(item), started) for item in check.get("junit", ())],
                )
                if result["status"] == "failed":
                    result["reason"] = "timed out" if outcome["timed_out"] else f"exit status {outcome['returncode']}"
        outcomes[check["id"]] = result["status"]
        results[check["id"]] = result
    for result in results.values():
        if result["status"] == "subsumed" and outcomes.get(result["subsumed_by"]) != "passed":
            result.update(status="failed", reason=f"subsuming check {result['subsumed_by']} did not pass")
    return [results[check["id"]] for check in ordered], temp_policy


def reproduction_lines(plan: Mapping[str, Any], argv: Sequence[str]) -> list[str]:
    change = plan["change_set"]
    lines = [f"cd <checkout> && {sys.executable} -m tools.validate_change {' '.join(argv)}"]
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
            out.append(f"      prerequisite {'ok' if item['met'] else 'MISSING'}: {item['detail']}")
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
    environ = os.environ if environ is None else environ
    raw_arguments = list(sys.argv[1:] if argv is None else argv)
    arguments = parse_arguments(raw_arguments)
    try:
        if not arguments.skip_inventory_check:
            try:
                boundary_inventory.verify(root)
            except ValueError as error:
                raise PlanError(str(error)) from error
        inventory = boundary_inventory.load(root)
        if arguments.list_boundaries:
            for boundary in inventory["boundaries"]:
                print(f"{boundary['id']}\t{boundary['gate']}\t{boundary['title']}")
            return 0
        explicit = arguments.files or (read_files(arguments.files_from) if arguments.files_from else None)
        if explicit is not None:
            change_set = explicit_change_set(root, explicit, revision=arguments.revision, base_revision=arguments.base_revision)
        elif arguments.boundary and not arguments.base:
            change_set = empty_change_set("boundary-request")
        else:
            change_set = collect_git(root, arguments.base, arguments.include)
        mode = "plan" if arguments.plan else "run"
        output = None
        if mode == "run" or arguments.output:
            from tools import check_local_validation

            try:
                output = check_local_validation.private_output(arguments.output)
            except ValueError as error:
                raise PlanError(str(error)) from error
        context = Context(root, environ, bundle=arguments.bundle, models=arguments.models, output=output)
        plan = build_plan(inventory, change_set, root, context, requested_boundaries=arguments.boundary, include_long=arguments.include_long)
    except PlanError as error:
        print(f"validate_change: {error}", file=sys.stderr)
        return 2

    started_utc = time.time()
    results: list[dict[str, Any]] = []
    temp_policy = validation_evidence.temp_policy(environ)
    if mode == "run":
        results, temp_policy = execute(plan, cast(Path, output), environ, include_long=arguments.include_long)
        checks = results
    else:
        checks = [dict(check, junit=[]) for check in plan["checks"]]
    unexecuted = [] if mode == "plan" else unexecuted_platforms(plan, checks, context.platform)
    summary = validation_evidence.build_summary(
        mode=mode,
        source={key: plan["change_set"][key] for key in ("mode", "revision", "base", "merge_base", "identity_sha256", "dirty", "dirty_paths", "counts")}
        | {"revision_declared": plan["change_set"].get("revision_declared"), "path_count": len(plan["change_set"]["paths"])},
        invocation={
            "entrypoint": "tools.validate_change",
            "argv": raw_arguments,
            "cwd": str(Path.cwd()),
            "executable": sys.executable,
            "root": str(root),
            "started_epoch": round(started_utc, 3),
        },
        selection={
            "conservative": plan["conservative"],
            "conservative_reasons": plan["conservative_reasons"],
            "ci": plan["ci_selection"]["effective"],
            "boundaries": [boundary["id"] for boundary in plan["boundaries"]],
            "required_platforms": plan["required_platforms"],
        },
        checks=[_evidence_check(check) for check in checks],
        unexecuted_platforms=unexecuted,
        reproduction=reproduction_lines(plan, raw_arguments),
        environ=environ,
        tools=validation_evidence.observe_tools() if mode == "run" else None,
    )
    summary["temp_root_policy"] = temp_policy
    if output is not None:
        (output / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
        validation_evidence.write_summary(summary, output / "evidence.json")
    if arguments.json:
        print(json.dumps({"plan": plan, "evidence": summary}, indent=2, sort_keys=True))
    else:
        print(render(plan, results=results or None, summary=summary if mode == "run" else None))
        if output is not None:
            print(f"Evidence: {output / 'evidence.json'}")
    if mode == "plan":
        return 0
    if summary["status"] == "failed":
        return 1
    if summary["status"] == "full-validation-passed" or arguments.allow_partial:
        return 0
    return 3


def _evidence_check(check: Mapping[str, Any]) -> dict[str, Any]:
    keys = ("id", "title", "kind", "scope", "platforms", "status", "reason", "returncode", "timed_out", "seconds", "log", "junit", "subsumed_by", "long")
    record = {key: check[key] for key in keys if key in check}
    record["entrypoint"] = (check.get("entrypoint") or {}).get("argv")
    record["why"] = [entry["reason"] for entry in check.get("why", ())][:LIST_LIMIT]
    record["reuse"] = [
        {key: item[key] for key in ("id", "path", "present", "presented_as", "sha256")} for item in check.get("reuse", ())
    ]
    record["unavailable"] = [item["detail"] for item in check.get("prerequisites", ()) if not item["met"]]
    if check.get("availability") == "unavailable" and check.get("status") == "planned":
        record["unavailable"] = check.get("unavailable_reasons", [])
    return record


if __name__ == "__main__":
    raise SystemExit(main())
