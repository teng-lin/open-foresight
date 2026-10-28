#!/usr/bin/env python3
"""Aggregate validation evidence packets into a descriptive reliability report.

    .venv/bin/python -m tools.reliability_report DIRECTORY [--minimum-sample N]
        [--json] [--write-baseline FILE [--replace]]

DIRECTORY holds `evidence.json` packets written by `tools.validate_change`
(local runs, or artifacts downloaded from CI). The report counts what the packets
say about each check: outcomes by check, platform, hosted or local origin,
selection (conservative or narrowed), cache state and attempt, plus a rollup per
boundary. Plan-only packets execute nothing and are not counted. It is descriptive of its own window and nothing else:

- every packet is untrusted input: only regular files (never symlinks) under a
  size cap are read, a total byte budget and a file-count cap bound the work, each
  packet must pass the evidence validation, and anything rejected is counted by
  reason, never printed;
- nothing a packet contains reaches the output as text: groups are keyed by check
  and boundary ids taken from this checkout's boundary inventory and by closed
  vocabularies, so an unknown id is counted as unknown and never shown;
- a rate is withheld below the minimum sample ("insufficient sample") and the
  denominator, the excluded outcomes and the cancellations are shown beside every
  rate, using `ci_stats.failure_rate` and `ci_stats.percentile`;
- only the first run of a change identity counts as an independent sample; later
  runs of the same identity are reported separately as qualification repeats, so a
  green rerun never offsets a failed first run;
- cancellations, checks that never started, unavailable, manual, CI-only,
  subsumed and planned checks are excluded from the rate and counted;
- local and hosted runs are never mixed, and plan-only packets execute nothing;
- the report states its own window and is a fresh baseline: it is never compared
  with an earlier or frozen window, and it makes no improvement, regression or
  "flaky" claim.

Exit status: 0 for a complete report, 2 for an unusable directory or argument,
3 for a report cut short by a cap (it is still printed, marked incomplete, and no
baseline file is written from it).
"""

from __future__ import annotations

import argparse
from collections import Counter
from collections.abc import Mapping, Sequence
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

from tools import boundary_inventory, ci_stats, validation_evidence, validation_replay

KIND = "foresight-reliability-report"
SCHEMA = 1
DEFAULT_MINIMUM_SAMPLE = 20
MAX_FILES = 5000
MAX_DIRECTORIES = 500
MAX_DEPTH = 6  # `gh run download` nests an artifact four directories below the run
MAX_TOTAL_BYTES = 256 * 1024 * 1024
TIMESTAMP = "%Y-%m-%dT%H:%M:%SZ"
PLATFORMS = ("linux", "macos")
# check status -> outcome in ci_stats' vocabulary; only success and failure are eligible for a rate
OUTCOMES = {"passed": "success", "failed": "failure"}
EXCLUDED = {
    "unavailable": "unavailable", "not-run": "not-run", "manual": "not-applicable", "ci-only": "not-applicable",
    "subsumed": "subsumed", "planned": "planned",
}
REJECTIONS = (
    "not-a-regular-file", "too-large", "unreadable", "not-json", "not-an-evidence-summary", "invalid-evidence",
    "bad-timestamp", "duplicate", "file-cap", "byte-budget", "depth-cap",
)
# Data that exists but was not read: the report cannot claim to be complete. (Content that is invalid, a duplicate or
# deliberately ignored, such as a symlink, is a rejection that loses nothing.)
INCOMPLETE = ("unreadable", "too-large", "file-cap", "byte-budget", "depth-cap")


def collect_files(directory: Path) -> tuple[list[Path], Counter[str], bool]:
    """Candidate *.json files below [directory], no symlinks followed; and whether a cap cut the walk short."""
    files: list[Path] = []
    rejected: Counter[str] = Counter()
    pending = [(directory, 0)]
    directories = 0
    complete = True
    while pending:
        current, depth = pending.pop()
        directories += 1
        if directories > MAX_DIRECTORIES:
            complete = False
            break
        try:
            entries = sorted(os.scandir(current), key=lambda entry: entry.name)
        except OSError:
            rejected["unreadable"] += 1  # a directory we could not list may hold packets: INCOMPLETE says so
            continue
        for entry in entries:
            try:
                if entry.is_dir(follow_symlinks=False):
                    if depth < MAX_DEPTH:
                        pending.append((Path(entry.path), depth + 1))
                    else:
                        rejected["depth-cap"] += 1  # not read, and INCOMPLETE says so
                elif entry.name.endswith(".json"):
                    if entry.is_file(follow_symlinks=False):
                        files.append(Path(entry.path))
                    else:
                        rejected["not-a-regular-file"] += 1
            except OSError:
                rejected["unreadable"] += 1
            if len(files) > MAX_FILES:
                rejected["file-cap"] += 1
                return files[:MAX_FILES], rejected, False
    return files, rejected, complete


def read_packet(path: Path) -> tuple[bytes | None, str | None]:
    """(bytes, None) of a regular, size-bounded file, or (None, the rejection class)."""
    try:
        return validation_replay.read_packet_bytes(path), None
    except ValueError as error:
        return None, "too-large" if "larger than" in str(error) else "not-a-regular-file"
    except OSError:
        return None, "unreadable"


def parse_timestamp(value: Any) -> datetime | None:
    try:
        return datetime.strptime(value, TIMESTAMP) if isinstance(value, str) else None
    except ValueError:
        return None


def known_ids(inventory: Mapping[str, Any]) -> tuple[dict[str, tuple[str, ...]], set[str]]:
    """gate id -> the boundaries it serves, and the known boundary ids, from this checkout's inventory."""
    served: dict[str, list[str]] = {name: [] for name in inventory["gates"]}  # every gate, so ci-only and manual ones are attributed
    boundaries = set()
    for boundary in inventory["boundaries"]:
        boundaries.add(boundary["id"])
        for gate in (boundary.get("gate"), *(boundary.get("also_gates") or ())):
            if gate in served:
                served[gate].append(boundary["id"])
    return {name: tuple(sorted(set(ids))) for name, ids in served.items()}, boundaries


def finite_seconds(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) and 0 <= value < 10**7 else None


def cache_state(check: Mapping[str, Any]) -> str:
    reuse = check.get("reuse")
    if not isinstance(reuse, list) or not reuse:
        return "none"
    present = [(item.get("at_execution") or {}).get("present", item.get("present")) if isinstance(item, dict) else None for item in reuse]
    return "reused" if any(value is True for value in present) else "fresh"


def classify(check: Mapping[str, Any]) -> tuple[str, str | None]:
    """(ci_stats outcome, why it is excluded or None) for one recorded check."""
    status = check["status"]
    if status in OUTCOMES:
        if status == "failed":
            if check.get("interrupted"):
                return "cancelled", "cancelled"
            if check.get("subsumed_by"):
                return "subsumed-failed", "subsumed"
            if (check.get("phases") or {}).get("setup") == "failed":
                return "setup-failure", "never-started"
        return OUTCOMES[status], None
    return EXCLUDED.get(status, "unknown"), EXCLUDED.get(status, "unknown")


def observations(packet: Mapping[str, Any], created: datetime, services: Mapping[str, tuple[str, ...]]) -> list[dict[str, Any]]:
    """One observation per recorded check of a run packet, with only closed-vocabulary fields."""
    platform = packet["host"].get("platform")
    environment = packet["environment"]
    selection = (packet.get("selection") or {}).get("conservative")
    identity = (packet["source"] or {}).get("identity_sha256")
    result = []
    for check in packet["checks"]:
        name = check["id"]
        outcome, excluded = classify(check)
        result.append(
            {
                "created": created,
                "identity": identity if isinstance(identity, str) and identity else None,
                "check": name if name in services else "unknown-check",
                "boundaries": services.get(name, ()),
                "platform": platform if platform in PLATFORMS else "other",
                "origin": "hosted" if environment.get("GITHUB_ACTIONS") == "true" else "local",
                "selection": "conservative" if selection is True else "narrowed" if selection is False else "unknown",
                "cache": cache_state(check),
                "outcome": outcome,
                "excluded": excluded,
                "seconds": finite_seconds(check.get("seconds")) if outcome in ("success", "failure") else None,
            }
        )
    return result


def sequence(packet: Mapping[str, Any]) -> float:
    """The recorded start time with sub-second precision, to order packets created in the same second; 0 if absent."""
    value = (packet.get("invocation") or {}).get("started_epoch")
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else 0.0


def ingest(directory: Path, services: Mapping[str, tuple[str, ...]]) -> dict[str, Any]:
    files, rejected, complete = collect_files(directory)
    seen: set[str] = set()
    packets: list[tuple[datetime, float, str, Mapping[str, Any]]] = []
    budget = MAX_TOTAL_BYTES
    plans = 0
    for path in files:
        data, reason = read_packet(path)
        if data is None:
            rejected[reason or "unreadable"] += 1
            continue
        budget -= len(data)
        if budget < 0:
            rejected["byte-budget"] += 1
            complete = False
            break
        digest = hashlib.sha256(data).hexdigest()
        if digest in seen:
            rejected["duplicate"] += 1
            continue
        seen.add(digest)
        try:
            packet = json.loads(data)
        except (ValueError, RecursionError):
            rejected["not-json"] += 1
            continue
        if not isinstance(packet, dict) or packet.get("kind") != validation_evidence.KIND:
            rejected["not-an-evidence-summary"] += 1
            continue
        try:
            validation_evidence.validate_summary(packet)
            created = parse_timestamp(packet["created_utc"])
            if created is None:
                rejected["bad-timestamp"] += 1
                continue
            if packet["mode"] != "run":
                plans += 1
                continue
            packets.append((created, sequence(packet), digest, packet))
        except Exception:  # noqa: BLE001 - untrusted input: whatever it breaks is a rejection, not a traceback
            rejected["invalid-evidence"] += 1
    packets.sort(key=lambda item: (item[0], item[1], item[2]))
    rows: list[dict[str, Any]] = []
    for created, _sequence, _digest, packet in packets:
        try:
            rows.extend(observations(packet, created, services))
        except Exception:  # noqa: BLE001
            rejected["invalid-evidence"] += 1
    first_seen: set[tuple[Any, ...]] = set()
    for row in rows:
        key = (row["identity"], row["check"], row["platform"], row["origin"])
        if row["identity"] is None:
            row["attempt"] = "unidentified"
        elif row["outcome"] not in ("success", "failure"):
            row["attempt"] = "excluded"  # an attempt that never executed, was cancelled or was unavailable consumes no slot
        elif key in first_seen:
            row["attempt"] = "repeat"
        else:
            row["attempt"] = "first"
            first_seen.add(key)
    return {"rows": rows, "rejected": rejected, "complete": complete, "plans": plans, "packets": len(packets), "files": len(files)}


def summarize(rows: Sequence[Mapping[str, Any]], minimum: int) -> dict[str, Any]:
    outcomes = [row["outcome"] for row in rows]
    rate = ci_stats.failure_rate(outcomes)
    enough = rate["eligible"] >= minimum
    seconds = [row["seconds"] for row in rows if row["seconds"] is not None]
    return {
        "observations": len(rows),
        "outcomes": rate["outcomes"],
        "eligible": rate["eligible"],
        "failed": rate["failed"],
        "excluded": len(rows) - rate["eligible"],
        "rate": rate["rate"] if enough else None,
        "label": None if enough else f"insufficient sample ({rate['eligible']} eligible, {minimum} needed)",
        "seconds": {"n": len(seconds), "p50": ci_stats.percentile(seconds, 0.5), "p90": ci_stats.percentile(seconds, 0.9)} if enough and seconds else None,
    }


def group(rows: Sequence[Mapping[str, Any]], fields: Sequence[str], minimum: int, split: tuple[str, str] | None = None) -> list[dict[str, Any]]:
    """Rows grouped by [fields]; with [split] = (row field, key name) a row counts once for each value of a list field."""
    buckets: dict[tuple[str, ...], list[Mapping[str, Any]]] = {}
    for row in rows:
        values: Sequence[str | None] = (row[split[0]] or ("unmapped",)) if split else (None,)
        for value in values:
            key = ((str(value),) if split else ()) + tuple(str(row[field]) for field in fields)
            buckets.setdefault(key, []).append(row)
    names = ([split[1]] if split else []) + list(fields)
    return [{"key": dict(zip(names, key, strict=True)), **summarize(items, minimum)} for key, items in sorted(buckets.items())]


def recurring_failures(rows: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Failures of the same check on the same platform and origin across at least two distinct change identities."""
    failing: dict[tuple[str, str, str], list[Mapping[str, Any]]] = {}
    for row in rows:
        if row["outcome"] == "failure" and row["attempt"] != "repeat":
            failing.setdefault((row["check"], row["platform"], row["origin"]), []).append(row)
    result = []
    for (check, platform, origin), items in sorted(failing.items()):
        identities = {row["identity"] or id(row) for row in items}
        if len(identities) >= 2:
            result.append(
                {
                    "check": check, "platform": platform, "origin": origin, "failed_first_runs": len(items),
                    "distinct_changes": len(identities),
                    "first": min(row["created"] for row in items).strftime(TIMESTAMP),
                    "last": max(row["created"] for row in items).strftime(TIMESTAMP),
                }
            )
    return result


def overall(rows: Sequence[Mapping[str, Any]], minimum: int) -> list[dict[str, Any]]:
    """Totals per origin and platform: a rate over mixed local and hosted runs would describe neither."""
    result = []
    for origin, platform in sorted({(row["origin"], row["platform"]) for row in rows}):
        subset = [row for row in rows if (row["origin"], row["platform"]) == (origin, platform)]
        result.append(
            {
                "key": {"origin": origin, "platform": platform},
                "all_observations": summarize(subset, minimum),
                "first_runs_only": summarize([row for row in subset if row["attempt"] != "repeat"], minimum),
                "qualification_repeats_only": summarize([row for row in subset if row["attempt"] == "repeat"], minimum),
            }
        )
    return result


def build_report(directory: Path, inventory: Mapping[str, Any], minimum: int = DEFAULT_MINIMUM_SAMPLE) -> dict[str, Any]:
    services, _boundaries = known_ids(inventory)
    ingested = ingest(directory, services)
    rows = ingested["rows"]
    rejected = {reason: ingested["rejected"].get(reason, 0) for reason in REJECTIONS}
    complete = ingested["complete"] and not any(rejected[reason] for reason in INCOMPLETE)
    stamps = [row["created"] for row in rows]
    return {
        "kind": KIND,
        "schema": SCHEMA,
        "complete": complete,
        "minimum_sample": minimum,
        "window": {
            "first": min(stamps).strftime(TIMESTAMP) if stamps else None,
            "last": max(stamps).strftime(TIMESTAMP) if stamps else None,
        },
        "baseline": "fresh: this window only; no earlier or frozen window is read or compared",
        "inputs": {
            "files_considered": ingested["files"], "run_packets_used": ingested["packets"],
            "plan_only_packets_not_counted": ingested["plans"], "rejected": rejected,
            "limits": {"files": MAX_FILES, "directories": MAX_DIRECTORIES, "bytes": MAX_TOTAL_BYTES},
        },
        "overall": overall(rows, minimum),
        "by_check": group(rows, ("check", "platform", "origin", "selection", "cache", "attempt"), minimum),
        "by_boundary": group(rows, ("platform", "origin", "attempt"), minimum, split=("boundaries", "boundary")),
        "recurring_first_run_failures": recurring_failures(rows),
        "notes": [
            "Rates describe this window only. No improvement, regression or flakiness claim is made from them.",
            "A rate is shown only at or above the minimum sample of eligible runs; below it the counts stand alone.",
            "Cancelled, never-started, unavailable, manual, CI-only, subsumed and planned checks are excluded from the rate and counted.",
            "Only the first executed run (passed or failed) of a change identity is an independent sample; later executed runs are qualification repeats and never offset a failed first run. An attempt that never executed (not run, unavailable, cancelled) is shown as excluded and consumes no slot.",
            "Packets created in the same second are ordered by their recorded start time when present, else by content digest.",
            "A check counts toward every boundary it serves, so boundary rows overlap. Local and hosted runs are never mixed.",
            "Boundary names come from this checkout's inventory; packets from another revision may map differently.",
            "The execution mode (source or compiled) is not recorded in a packet, so it is not a dimension here.",
        ],
    }


def _cell(value: Any) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def _rejected_line(rejected: Mapping[str, int]) -> str:
    counted = ", ".join(f"{reason} {count}" for reason, count in rejected.items() if count)
    return f"- Rejected (counted, never shown): {counted}." if counted else "- Rejected: none."


def render(report: Mapping[str, Any]) -> str:
    """Markdown from the report's own numbers and closed vocabularies; deterministic."""
    window = report["window"]
    lines = [
        "# Validation reliability report",
        "",
        f"Window: {window['first'] or 'none'} to {window['last'] or 'none'}. {report['baseline']}.",
        f"Complete: {'yes' if report['complete'] else 'NO, a cap cut the read short'}. Minimum sample: {report['minimum_sample']} eligible runs.",
        "",
        "## Inputs",
        f"- Files considered: {report['inputs']['files_considered']}; run packets used: {report['inputs']['run_packets_used']}; "
        f"plan-only packets not counted: {report['inputs']['plan_only_packets_not_counted']}.",
        _rejected_line(report["inputs"]["rejected"]),
        "",
        "## Overall",
        "| Origin | Platform | Scope | Observations | Eligible | Failed | Excluded | Rate | Note |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for entry in report["overall"]:
        for name in ("all_observations", "first_runs_only", "qualification_repeats_only"):
            scope = entry[name]
            lines.append(
                f"| {entry['key']['origin']} | {entry['key']['platform']} | {name.replace('_', ' ')} | {scope['observations']} | {scope['eligible']} | "
                f"{scope['failed']} | {scope['excluded']} | {_cell(scope['rate'])} | {scope['label'] or ''} |"
            )
    for title, key, columns in (
        ("By check", "by_check", ("check", "platform", "origin", "selection", "cache", "attempt")),
        ("By boundary", "by_boundary", ("boundary", "platform", "origin", "attempt")),
    ):
        lines += ["", f"## {title}", "| " + " | ".join(columns) + " | Obs | Eligible | Failed | Excluded | Rate | p50 s | p90 s | Note |", "| " + " | ".join("---" for _ in range(len(columns) + 8)) + " |"]
        for row in report[key]:
            seconds = row["seconds"] or {}
            lines.append(
                "| " + " | ".join(row["key"][column] for column in columns)
                + f" | {row['observations']} | {row['eligible']} | {row['failed']} | {row['excluded']} | {_cell(row['rate'])} | {_cell(seconds.get('p50'))} | {_cell(seconds.get('p90'))} | {row['label'] or ''} |"
            )
    lines += ["", "## Recurring first-run failures", "Same check, platform and origin, failed on at least two distinct change identities."]
    if report["recurring_first_run_failures"]:
        lines += ["| Check | Platform | Origin | Failed first runs | Distinct changes | First | Last |", "| --- | --- | --- | --- | --- | --- | --- |"]
        lines += [
            f"| {item['check']} | {item['platform']} | {item['origin']} | {item['failed_first_runs']} | {item['distinct_changes']} | {item['first']} | {item['last']} |"
            for item in report["recurring_first_run_failures"]
        ]
    else:
        lines.append("None.")
    lines += ["", "## Notes", *(f"- {note}" for note in report["notes"]), ""]
    return "\n".join(lines)


def publish(report: Mapping[str, Any], destination: Path, replace: bool = False) -> Path:
    """Atomically write the baseline as an owner-only regular file; never over a symlink or, unasked, a file."""
    if destination.is_symlink():
        raise ValueError("The baseline destination must not be a symlink")
    if destination.exists() and not replace:
        raise ValueError("The baseline already exists; pass --replace to write a new one")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".reliability-", dir=destination.parent)  # created 0600
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    return destination


def main(argv: Sequence[str] | None = None, inventory: Mapping[str, Any] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, allow_abbrev=False)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--minimum-sample", type=int, default=DEFAULT_MINIMUM_SAMPLE)
    parser.add_argument("--json", action="store_true", help="print the report as JSON instead of Markdown")
    parser.add_argument("--write-baseline", type=Path, help="also write the JSON report here as a fresh baseline")
    parser.add_argument("--replace", action="store_true", help="allow --write-baseline to replace an existing file")
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    if arguments.minimum_sample < 1:
        print("reliability_report: --minimum-sample must be at least 1", file=sys.stderr)
        return 2
    if not arguments.directory.is_dir() or arguments.directory.is_symlink():
        print("reliability_report: the evidence directory must be a real directory", file=sys.stderr)
        return 2
    report = build_report(arguments.directory, boundary_inventory.load() if inventory is None else inventory, arguments.minimum_sample)
    print(json.dumps(report, indent=2, sort_keys=True) if arguments.json else render(report))
    if arguments.write_baseline is not None:
        if not report["complete"]:
            print("reliability_report: the read was cut short by a cap, so no baseline is written", file=sys.stderr)
            return 3
        try:
            publish(report, arguments.write_baseline, arguments.replace)
        except (OSError, ValueError) as error:
            print(f"reliability_report: {type(error).__name__}: {error}", file=sys.stderr)
            return 2
    return 0 if report["complete"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
