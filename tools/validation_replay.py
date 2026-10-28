#!/usr/bin/env python3
"""Read a validation evidence packet and say how to reproduce it, and what cannot be.

    .venv/bin/python -m tools.validation_replay PACKET [--check] [--json]

The packet is an `evidence.json` written by `tools.validate_change`. The replay
prints the exact entrypoint, arguments and working directory of the run and of
each check that did not pass, then lists the conditions this host does not
match: the packet's own reproduction gaps (unexecuted platforms, pin mismatches,
unverified labels) plus differences between the recorded host and this one
(operating system, architecture, Python, tool versions, account, temp roots).

It never runs anything. A replay that lists no gap still does not prove a hosted
failure reproduces: the recorded conditions are what this tool could observe.
`--check` exits 1 while any gap remains, 2 for an unreadable packet.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Mapping
import json
from pathlib import Path
import shlex
import sys
from typing import Any

from tools import validation_evidence

Gap = dict[str, str]


def load_packet(path: Path) -> dict[str, Any]:
    """Read and validate a packet (schema 1 or 2); raises ValueError if unusable."""
    try:
        packet = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"Cannot read packet {path}: {error}") from error
    if not isinstance(packet, dict):
        raise ValueError(f"Packet {path} is not a JSON object")
    validation_evidence.validate_summary(packet)
    return packet


def observe_host() -> dict[str, Any]:
    """The conditions of this host that a packet records."""
    identity = validation_evidence.host_identity()
    account = validation_evidence.account_identity()
    return {
        "host": identity,
        "tools": validation_evidence.observe_tools(),
        "uid": account["uid"],
        "nss_name": account["nss"]["name"],
        "temp_compliant": validation_evidence.temp_policy()["compliant"],
    }


def reproduction_command(packet: Mapping[str, Any]) -> str:
    """The recorded invocation as one shell-quoted line."""
    invocation = packet["invocation"]
    entrypoint = invocation.get("entrypoint") or "tools.validate_change"
    return shlex.join([".venv/bin/python", "-m", entrypoint, *invocation.get("argv", [])])


def failing_checks(packet: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Checks that did not pass, each with its own entrypoint and retained log."""
    result = []
    for check in packet["checks"]:
        if check["status"] in ("passed", "subsumed", "planned"):
            continue
        entrypoint = check.get("entrypoint")
        result.append(
            {
                "id": check["id"],
                "status": check["status"],
                "reason": check.get("reason"),
                "command": shlex.join(entrypoint) if entrypoint else None,
                "log": check.get("log"),
                "phases": check.get("phases"),
            }
        )
    return result


def host_mismatches(packet: Mapping[str, Any], here: Mapping[str, Any]) -> list[Gap]:
    """Differences between the recorded host and [here]; each is a reason a replay may differ."""
    gaps: list[Gap] = []

    def add(code: str, detail: str) -> None:
        gaps.append({"code": code, "detail": detail})

    recorded = packet["host"]
    current = here["host"]
    for key in ("platform", "machine", "system"):
        if recorded.get(key) != current.get(key):
            add(f"host-differs:{key}", f"recorded {recorded.get(key)!r}, this host {current.get(key)!r}")
    if recorded.get("release") != current.get("release"):
        add("host-differs:release", f"recorded OS release {recorded.get('release')!r}, this host {current.get('release')!r}")
    if recorded.get("python", "").split(".")[:2] != current.get("python", "").split(".")[:2]:
        add("host-differs:python", f"recorded {recorded.get('python')}, this host {current.get('python')}")
    for name, value in sorted((packet.get("tools") or {}).items()):
        now = here["tools"].get(name)
        if name == "python":
            continue
        if value is not None and now is None:
            add(f"tool-missing:{name}", f"recorded {value!r}, absent on this host")
        elif value is not None and now != value:
            add(f"tool-differs:{name}", f"recorded {value!r}, this host {now!r}")
    account = packet["account"]
    if (account.get("uid") == 0) != (here["uid"] == 0):
        add("account-differs:root", f"recorded uid {account.get('uid')}, this host uid {here['uid']}")
    recorded_name = (account.get("nss") or {}).get("name")
    if recorded_name != here["nss_name"]:
        add("account-differs:nss-name", f"recorded {recorded_name!r}, this host {here['nss_name']!r}")
    if packet["temp_root_policy"].get("compliant") and not here["temp_compliant"]:
        add("temp-root-differs", "the packet's temp roots met the policy; this shell's do not")
    return gaps


def analyze(packet: Mapping[str, Any], here: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Everything a replay reports; [here] is injected by tests."""
    here = observe_host() if here is None else here
    recorded = list(packet.get("reproduction_gaps") or validation_evidence.derive_gaps(packet))
    mismatches = host_mismatches(packet, here)
    return {
        "schema": packet["schema"],
        "mode": packet["mode"],
        "status": packet["status"],
        "source": {key: packet["source"].get(key) for key in ("mode", "revision", "base", "merge_base", "identity_sha256", "dirty")},
        "command": reproduction_command(packet),
        "cwd": packet["invocation"].get("cwd"),
        "root": packet["invocation"].get("root"),
        "failing_checks": failing_checks(packet),
        "recorded_gaps": recorded,
        "host_mismatches": mismatches,
        "gap_count": len(recorded) + len(mismatches),
        "note": "This replay runs nothing and cannot prove a hosted failure reproduces.",
    }


def render(report: Mapping[str, Any]) -> str:
    lines = [
        f"Packet: schema {report['schema']}, {report['mode']}, status {report['status']}",
        f"Source: {report['source']}",
        f"Reproduce from {report['root']} (recorded cwd {report['cwd']}):",
        f"  {report['command']}",
    ]
    for check in report["failing_checks"]:
        lines.append(f"Check {check['id']}: {check['status']}" + (f" ({check['reason']})" if check["reason"] else ""))
        if check["command"]:
            lines.append(f"  entrypoint: {check['command']}")
        if check["log"]:
            lines.append(f"  retained log: {check['log']}")
        if check["phases"]:
            lines.append(f"  phases: {check['phases']}")
    for title, key in (("Recorded gaps", "recorded_gaps"), ("Differences on this host", "host_mismatches")):
        lines.append(f"{title}: {len(report[key])}")
        lines.extend(f"  - {gap['code']}: {gap['detail']}" for gap in report[key])
    lines.append(report["note"])
    return "\n".join(lines)


def main(
    argv: list[str] | None = None,
    observe: Callable[[], Mapping[str, Any]] = observe_host,
) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("packet", type=Path)
    parser.add_argument("--check", action="store_true", help="exit 1 while any gap remains")
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        packet = load_packet(arguments.packet)
    except ValueError as error:
        print(f"validation_replay: {error}", file=sys.stderr)
        return 2
    report = analyze(packet, observe())
    print(json.dumps(report, indent=2, sort_keys=True) if arguments.json else render(report))
    return 1 if arguments.check and report["gap_count"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
