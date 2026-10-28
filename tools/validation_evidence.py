#!/usr/bin/env python3
"""Versioned, allowlist-based evidence summary for boundary validation runs.

The summary records what a run selected, executed, skipped and could not
execute, together with the account, temp-root and environment conditions needed
to reproduce it. It never dumps the full environment: only names in
`ENV_ALLOWLIST` are read. It carries no credentials, transcripts, profile data
or model assets. A missing prerequisite or an unexecuted platform can never
produce `full-validation-passed`.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timezone
import grp
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any
import xml.etree.ElementTree as ET

SCHEMA = 1
KIND = "foresight-validation-evidence"
# Every other variable stays unread. FORESIGHT_* is deliberately not a prefix
# rule: credentials such as FORESIGHT_CI_GOOGLE_REFRESH_TOKEN share that prefix.
ENV_ALLOWLIST = (
    "CI",
    "GITHUB_ACTIONS",
    "GITHUB_REPOSITORY",
    "GITHUB_REF",
    "GITHUB_REF_NAME",
    "GITHUB_EVENT_NAME",
    "GITHUB_SHA",
    "GITHUB_RUN_ID",
    "GITHUB_RUN_ATTEMPT",
    "GITHUB_JOB",
    "GITHUB_WORKFLOW",
    "RUNNER_OS",
    "RUNNER_ARCH",
    "RUNNER_ENVIRONMENT",
    "FORESIGHT_BUILD_DIR",
    "FORESIGHT_PLATFORM",
    "FORESIGHT_PYTHON",
    "FORESIGHT_BUILD_JOBS",
    "FORESIGHT_PARALLEL_GATES",
    "FORESIGHT_PYTEST_WORKERS",
    "FORESIGHT_REQUIRE_DART_GATES",
    "FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE",
    "FORESIGHT_TEST_TEMP_ROOT",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "TZ",
)
MAX_VALUE_LENGTH = 512
STATUSES = ("full-validation-passed", "partial", "failed", "plan-only")
CHECK_STATUSES = ("planned", "passed", "failed", "unavailable", "not-run", "manual", "ci-only", "subsumed")
# Conditions under which a Unix-socket path is known to fit Linux and Darwin limits.
SHORT_TEMP_LIMIT = 48
TOOL_PROBES = {
    "git": ["git", "--version"],
    "cmake": ["cmake", "--version"],
    "ninja": ["ninja", "--version"],
    "protoc": ["protoc", "--version"],
    "dart": ["dart", "--version"],
    "actionlint": ["actionlint", "-version"],
    "shellcheck": ["shellcheck", "--version"],
}


def _printable(value: str) -> str:
    text = "".join(char if char.isprintable() else "?" for char in value)
    return text if len(text) <= MAX_VALUE_LENGTH else text[:MAX_VALUE_LENGTH] + "..."


def collect_environment(environ: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return only allowlisted variables that are set."""
    environ = os.environ if environ is None else environ
    return {name: _printable(environ[name]) for name in ENV_ALLOWLIST if name in environ}


def account_identity(environ: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Real and effective IDs, supplementary groups and the NSS account home.

    Setting HOME alone does not change the NSS account, so both are recorded.
    """
    environ = os.environ if environ is None else environ
    uid = os.getuid()
    groups = []
    for group_id in sorted(set(os.getgroups())):
        try:
            name = grp.getgrgid(group_id).gr_name
        except KeyError:
            name = None
        groups.append({"gid": group_id, "name": name})
    try:
        account = pwd.getpwuid(uid)
        nss: dict[str, Any] = {"name": account.pw_name, "home": account.pw_dir, "shell": account.pw_shell}
    except KeyError:
        nss = {"name": None, "home": None, "shell": None}
    home = environ.get("HOME")
    return {
        "uid": uid,
        "gid": os.getgid(),
        "euid": os.geteuid(),
        "egid": os.getegid(),
        "groups": groups,
        "nss": nss,
        # HOME is outside the environment allowlist; only whether it agrees is kept.
        "home_env_set": home is not None,
        "home_matches_nss": home is not None and home == nss["home"],
    }


def _umask() -> int:
    mask = os.umask(0)
    os.umask(mask)
    return mask


def temp_policy(environ: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Inspect each temp root against the private, canonical, short policy."""
    environ = os.environ if environ is None else environ
    roots: dict[str, Any] = {}
    for name in ("TMPDIR", "FORESIGHT_TEST_TEMP_ROOT"):
        value = environ.get(name)
        if value is None:
            roots[name] = {"set": False}
            continue
        record: dict[str, Any] = {"set": True, "value": _printable(value), "length": len(value)}
        try:
            info = os.lstat(value)
            record.update(
                canonical=os.path.realpath(value) == value,
                mode=oct(stat.S_IMODE(info.st_mode)),
                owned_by_current_user=info.st_uid == os.getuid(),
                private=not stat.S_IMODE(info.st_mode) & 0o077,
                short=len(value) <= SHORT_TEMP_LIMIT,
            )
            record["compliant"] = (
                stat.S_ISDIR(info.st_mode)
                and record["canonical"]
                and record["owned_by_current_user"]
                and record["private"]
                and record["short"]
            )
        except OSError as error:
            record.update(compliant=False, error=type(error).__name__)
        roots[name] = record
    return {"roots": roots, "umask": oct(_umask()), "compliant": all(r.get("compliant") for r in roots.values())}


def host_identity() -> dict[str, str]:
    return {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "platform": "macos" if sys.platform == "darwin" else "linux" if sys.platform.startswith("linux") else sys.platform,
        "python": platform.python_version(),
    }


def observe_tools(
    names: Sequence[str] = tuple(TOOL_PROBES),
    run: Callable[..., Any] = subprocess.run,
    which: Callable[[str], str | None] = shutil.which,
) -> dict[str, Any]:
    """First line of each tool's version output, or null when it is absent."""
    observed: dict[str, Any] = {"python": sys.version.split()[0]}
    for name in names:
        executable = which(TOOL_PROBES[name][0])
        if executable is None:
            observed[name] = None
            continue
        try:
            result = run([executable, *TOOL_PROBES[name][1:]], capture_output=True, text=True, timeout=30, check=False)
            lines = (result.stdout + result.stderr).strip().splitlines()
            if result.returncode:
                observed[name] = f"probe failed: exit {result.returncode}" + (f": {_printable(lines[0])}" if lines else "")
            else:
                observed[name] = _printable(lines[0]) if lines else ""
        except (OSError, subprocess.SubprocessError) as error:
            observed[name] = f"probe failed: {type(error).__name__}"
    return observed


def junit_counts(path: Path, started: float) -> dict[str, Any]:
    """Counts from a JUnit file written during this run; stale files are not counted."""
    try:
        info = path.stat()
    except OSError:
        return {"path": str(path), "present": False}
    if info.st_mtime < started - 1:
        return {"path": str(path), "present": True, "stale": True}
    try:
        root = ET.parse(path).getroot()  # noqa: S314 - local runner output
    except (ET.ParseError, OSError) as error:
        return {"path": str(path), "present": True, "stale": False, "error": type(error).__name__}
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    total = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
    try:
        for suite in suites:
            for key in total:
                total[key] += int(suite.get(key, 0))
    except ValueError:
        # A malformed count is unreadable evidence, never a crash and never zero.
        return {"path": str(path), "present": True, "stale": False, "error": "malformed count attribute"}
    return {"path": str(path), "present": True, "stale": False, **total, "executed": total["tests"] - total["skipped"]}


def junit_problems(reports: Sequence[Mapping[str, Any]]) -> list[str]:
    """Why declared JUnit evidence cannot support a pass; empty when it can."""
    problems = []
    for report in reports:
        name = report.get("path", "?")
        if not report.get("present"):
            problems.append(f"{name}: report missing")
        elif report.get("stale"):
            problems.append(f"{name}: report was not written during this run")
        elif report.get("error"):
            problems.append(f"{name}: report unreadable ({report['error']})")
        elif report["failures"] or report["errors"]:
            problems.append(f"{name}: {report['failures']} failure(s), {report['errors']} error(s) recorded")
        elif report["executed"] <= 0:
            problems.append(f"{name}: no executed tests")
    return problems


def summarize_checks(checks: Sequence[Mapping[str, Any]]) -> dict[str, int]:
    counts = dict.fromkeys(CHECK_STATUSES, 0)
    for check in checks:
        counts[check["status"]] += 1
    tests = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0, "executed": 0}
    for check in checks:
        for report in check.get("junit", ()):
            if report.get("present") and not report.get("stale") and "tests" in report:
                for key in tests:
                    tests[key] += report[key]
    return {
        "selected": len(checks),
        **counts,
        "executed": counts["passed"] + counts["failed"],
        **{f"junit_{key}": value for key, value in tests.items()},
    }


def classify(
    mode: str,
    checks: Sequence[Mapping[str, Any]],
    unexecuted_platforms: Sequence[str],
    incomplete_reasons: Sequence[str] = (),
) -> tuple[str, list[str]]:
    """Return the overall status and the reasons it is not a full success."""
    if mode == "plan":
        return "plan-only", ["Plan mode executes nothing."]
    reasons = list(incomplete_reasons)
    for check in checks:
        status = check["status"]
        if status == "failed":
            reasons.append(f"{check['id']}: failed")
        elif status not in ("passed", "subsumed"):
            reasons.append(f"{check['id']}: {status}" + (f" ({check['reason']})" if check.get("reason") else ""))
    if unexecuted_platforms:
        reasons.append("unexecuted platforms: " + ", ".join(unexecuted_platforms))
    if any(check["status"] == "failed" for check in checks):
        return "failed", reasons
    if reasons:
        return "partial", reasons
    return "full-validation-passed", []


def build_summary(
    *,
    mode: str,
    source: Mapping[str, Any],
    invocation: Mapping[str, Any],
    selection: Mapping[str, Any],
    checks: Sequence[Mapping[str, Any]],
    unexecuted_platforms: Sequence[str],
    reproduction: Sequence[str],
    environ: Mapping[str, str] | None = None,
    tools: Mapping[str, Any] | None = None,
    now: datetime | None = None,
    incomplete_reasons: Sequence[str] = (),
) -> dict[str, Any]:
    status, reasons = classify(mode, checks, unexecuted_platforms, incomplete_reasons)
    summary = {
        "schema": SCHEMA,
        "kind": KIND,
        "created_utc": (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": mode,
        "status": status,
        "full_validation": status == "full-validation-passed",
        "not_full_validation_reasons": reasons,
        "source": dict(source),
        "invocation": dict(invocation),
        "host": host_identity(),
        "account": account_identity(environ),
        "temp_root_policy": temp_policy(environ),
        "environment": collect_environment(environ),
        "tools": dict(tools) if tools is not None else None,
        "selection": dict(selection),
        "checks": [dict(check) for check in checks],
        "counts": summarize_checks(checks),
        "unexecuted_platforms": list(unexecuted_platforms),
        "incomplete_reasons": list(incomplete_reasons),
        "reproduction": list(reproduction),
    }
    validate_summary(summary)
    return summary


def validate_summary(summary: Mapping[str, Any]) -> None:
    """Reject a malformed summary or a success claim its own checks contradict."""
    required = (
        "schema", "kind", "created_utc", "mode", "status", "full_validation", "source", "invocation",
        "host", "account", "temp_root_policy", "environment", "selection", "checks", "counts",
        "unexecuted_platforms", "reproduction",
    )
    missing = [key for key in required if key not in summary]
    if missing:
        raise ValueError("Evidence summary lacks: " + ", ".join(missing))
    if summary["schema"] != SCHEMA or summary["kind"] != KIND:
        raise ValueError("Unsupported evidence summary schema")
    if summary["status"] not in STATUSES:
        raise ValueError("Unknown evidence status")
    unknown = sorted(set(summary["environment"]) - set(ENV_ALLOWLIST))
    if unknown:
        raise ValueError("Evidence environment is outside the allowlist: " + ", ".join(unknown))
    if any(check["status"] not in CHECK_STATUSES for check in summary["checks"]):
        raise ValueError("Unknown check status")
    if summary["full_validation"] != (summary["status"] == "full-validation-passed"):
        raise ValueError("full_validation contradicts status")
    if summary["full_validation"] and (
        summary["mode"] != "run"
        or summary["unexecuted_platforms"]
        or summary.get("incomplete_reasons")
        or any(check["status"] not in ("passed", "subsumed") for check in summary["checks"])
    ):
        raise ValueError("A full-validation claim needs a run with every selected check passed and no unexecuted platform")


def write_summary(summary: Mapping[str, Any], destination: Path) -> Path:
    """Atomically publish the validated summary as an owner-only regular file."""
    validate_summary(summary)
    if destination.is_symlink():
        raise ValueError("Evidence destination must not be a symlink")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".evidence-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps(summary, indent=2, sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    return destination
