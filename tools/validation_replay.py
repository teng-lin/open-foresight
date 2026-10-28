#!/usr/bin/env python3
"""Read a validation evidence packet and say how to reproduce it, and what cannot be.

    .venv/bin/python -m tools.validation_replay PACKET [--check] [--json]

The packet is an `evidence.json` written by `tools.validate_change`. The replay
prints the recorded invocation and each failed check, then lists the conditions
this host does not match: the packet's own reproduction gaps (unexecuted
platforms, pin mismatches, unverified labels) plus differences between the
recorded host and this one (operating system and image, architecture, Python,
tool versions, account, temp roots, revision and cleanliness of this checkout).

A packet is untrusted input. Everything printed from it is labelled "recorded,
unverified" and has control characters escaped. A reproduction command is
printed only for an entrypoint that is a repository `tools.*` module, and a
check's entrypoint only when it matches that gate's definition in the boundary
inventory; anything else is reported as unrecorded.

The replay never runs a recorded command. On this host it runs only `git status`
and `git rev-parse` (without optional locks) and the tools' `--version` probes
(`flutter --version` may touch the Flutter SDK cache), each with a short timeout.
`--check` exits 1 while any gap remains, 2 for an unreadable or corrupt packet.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Mapping, Sequence
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
from typing import Any, cast

from tools import validation_evidence

Gap = dict[str, str]


MAX_PACKET_BYTES = 8 << 20
PROBE_TIMEOUT_SECONDS = 10
# The only entrypoint `tools.validate_change` records for itself; any other module is not offered.
REPLAYABLE_ENTRYPOINTS = ("tools.validate_change",)
TEXT_LIMIT = 400
LIST_LIMIT = 200


def read_packet_bytes(path: Path) -> bytes:
    """The packet's bytes, refusing anything that is not a regular file of bounded size.

    The file is opened without blocking and inspected through the descriptor, so a
    FIFO or device cannot hang the replay and a swap after the check changes nothing.
    """
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("not a regular file")
        chunks = []
        remaining = MAX_PACKET_BYTES + 1
        while remaining > 0 and (block := os.read(descriptor, min(1 << 20, remaining))):
            chunks.append(block)
            remaining -= len(block)
        data = b"".join(chunks)
        if len(data) > MAX_PACKET_BYTES:
            raise ValueError(f"larger than {MAX_PACKET_BYTES} bytes")
        return data
    finally:
        os.close(descriptor)


def load_packet(path: Path) -> dict[str, Any]:
    """Read and validate a packet (schema 1 or 2); raises ValueError if unusable.

    Validation messages quote packet strings (an environment key, a phase name, a
    check id), so every message leaves here neutralized.
    """
    try:
        return _load_packet(path)
    except ValueError as error:
        raise ValueError(neutralize(str(error))) from error


def _load_packet(path: Path) -> dict[str, Any]:
    try:
        packet = json.loads(read_packet_bytes(path))
    except (OSError, ValueError, RecursionError) as error:  # ValueError: bad JSON, bad bytes, size and type refusals
        raise ValueError(f"Cannot read packet {path}: {type(error).__name__}") from error
    if not isinstance(packet, dict):
        raise ValueError(f"Packet {path} is not a JSON object")
    try:
        validation_evidence.validate_summary(packet)
        analyze(packet, NEUTRAL_HOST, gates={})  # a packet the replay cannot read is rejected here, not half-printed
    except ValueError:
        raise
    except Exception as error:  # untrusted input: whatever it breaks is a refusal, not a traceback
        raise ValueError(f"Packet {path} is malformed ({type(error).__name__})") from error
    return packet


def neutralize(text: str) -> str:
    """Text safe to print: only printable ASCII passes, everything else is escaped, length is bounded.

    A backslash is escaped too, so literal `\\x1b` text in a packet is distinguishable from an
    escaped ESC. Non-ASCII characters are escaped wholesale: invisible ones (zero-width, Hangul
    filler, braille blank, variation selectors, combining marks) and look-alikes cannot be told
    apart by a reader.
    """
    pieces = []
    for char in text:
        code = ord(char)
        if char == "\\":
            pieces.append("\\\\")
        elif 0x20 <= code <= 0x7E:
            pieces.append(char)
        else:
            pieces.append(f"\\x{code:02x}" if code < 0x100 else f"\\u{code:04x}" if code < 0x10000 else f"\\U{code:08x}")
    clean = "".join(pieces)
    return clean if len(clean) <= TEXT_LIMIT else clean[:TEXT_LIMIT] + "...[truncated]"


def clean(value: Any) -> Any:
    """[value] with every string neutralized, recursively; other scalars are kept."""
    if isinstance(value, str):
        return neutralize(value)
    if isinstance(value, Mapping):
        return {neutralize(str(key)): clean(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [clean(item) for item in value]
    return value if value is None or isinstance(value, (bool, int, float)) else neutralize(str(value))


def load_gates(root: Path = validation_evidence.ROOT) -> dict[str, list[str]]:
    """Each command gate's argv template from the boundary inventory of this checkout."""
    try:
        gates = json.loads((root / "tools/boundary_inventory.json").read_text())["gates"]
        return {name: list(gate["argv"]) for name, gate in gates.items() if gate.get("kind") == "command"}
    except (OSError, ValueError, KeyError, TypeError):
        return {}


_PLACEHOLDERS = {
    "python": r"(?:[^\s|;&<>$`'\"]*/)?python[0-9.]*",
    "platform": r"linux|macos",
}
_DEFAULT_PLACEHOLDER = r"[^\s|;&<>$`'\"]{1,512}"
_TEMP_DIRECTORIES = ("/tmp/", "/var/tmp/", "/private/tmp/", "/private/var/tmp/", "/dev/shm/")  # noqa: S108 - a denylist; nothing is created here


def _placeholder_ok(token: str, names: Sequence[str]) -> bool:
    if not token.isprintable() or re.search(r"(?:^|/)\.\.(?:/|$)", token) or len(token) > 1024:
        return False
    if "python" in names:
        return not token.startswith(_TEMP_DIRECTORIES)
    return not token.startswith("/tmp/")  # noqa: S108


def matches_gate(argv: Any, template: Sequence[str] | None) -> bool:
    """Whether a recorded argv is the gate's template with its `{placeholders}` filled in plausibly.

    `{python}` must be an interpreter named python or python3.N, without spaces or
    shell metacharacters, outside the temporary directories; `{platform}` linux or
    macos; every other placeholder a printable path of bounded length without
    whitespace, shell metacharacters or `..`, and not under /tmp. The match
    decides whether a command is shown, never whether it is safe to run.
    """
    if template is None or not isinstance(argv, list) or len(argv) != len(template):
        return False
    for token, pattern in zip(argv, template, strict=True):
        if not isinstance(token, str):
            return False
        names = re.findall(r"\{([a-z_]+)\}", pattern)
        pieces = re.split(r"\{[a-z_]+\}", pattern)
        expression = re.escape(pieces[0])
        for name, piece in zip(names, pieces[1:], strict=True):
            expression += f"(?:{_PLACEHOLDERS.get(name, _DEFAULT_PLACEHOLDER)})" + re.escape(piece)
        if not re.fullmatch(expression, token) or (names and not _placeholder_ok(token, names)):
            return False
    return True


def observe_git(root: Path, run: Callable[..., Any] = subprocess.run) -> dict[str, Any]:
    """Revision and dirtiness of the checkout this tool runs from; null when Git cannot say."""
    if not (root / ".git").exists():
        return {"revision": None, "dirty": None}

    def git(*arguments: str) -> str | None:
        try:
            result = run(["git", "--no-optional-locks", "-C", str(root), *arguments], capture_output=True, text=True, timeout=PROBE_TIMEOUT_SECONDS, check=False)
        except (OSError, subprocess.SubprocessError):
            return None
        return result.stdout if result.returncode == 0 else None

    revision = git("rev-parse", "HEAD")
    status = git("status", "--porcelain", "--untracked-files=normal")
    return {
        "revision": revision.strip() or None if revision is not None else None,
        "dirty": bool(status.strip()) if status is not None else None,
    }


def observe_host() -> dict[str, Any]:
    """The conditions of this host that a packet records."""
    identity = validation_evidence.host_identity()
    account = validation_evidence.account_identity()
    return {
        "host": identity,
        "tools": validation_evidence.observe_tools(timeout=PROBE_TIMEOUT_SECONDS),
        "uid": account["uid"],
        "nss_name": account["nss"]["name"],
        "temp_compliant": validation_evidence.temp_policy()["compliant"],
        "image": validation_evidence.image_identity({}),
        **observe_git(validation_evidence.ROOT),
    }


# Used only to prove a packet is readable before it is reported on.
NEUTRAL_HOST: dict[str, Any] = {
    "host": {}, "tools": {}, "uid": None, "nss_name": None, "temp_compliant": True, "image": {}, "revision": None, "dirty": None,
}


def reproduction_command(packet: Mapping[str, Any], root: Path = validation_evidence.ROOT) -> tuple[str | None, str]:
    """The recorded invocation as one shell-quoted line, or None with the reason it is not offered.

    Only `tools.validate_change`, the one entrypoint that records packets, is
    offered, so a packet cannot make the replay print `pip install ...` or any
    other repository tool with attacker arguments.
    """
    invocation = packet["invocation"]
    entrypoint = invocation.get("entrypoint") or "tools.validate_change"
    arguments = invocation.get("argv", [])
    if entrypoint not in REPLAYABLE_ENTRYPOINTS or not (root / "tools" / f"{entrypoint[6:]}.py").is_file():
        return None, "unrecorded: the recorded entrypoint is not one this replay offers (only tools.validate_change)"
    if not isinstance(arguments, list) or not all(isinstance(token, str) for token in arguments):
        return None, "unrecorded: the recorded arguments are not a list of text"
    return shlex.join([".venv/bin/python", "-m", entrypoint, *arguments]), "recorded, unverified"


def failing_checks(packet: Mapping[str, Any], gates: Mapping[str, Sequence[str]] | None = None) -> list[dict[str, Any]]:
    """Checks that did not pass; an entrypoint is shown only if it matches the gate's definition."""
    gates = load_gates() if gates is None else gates
    result = []
    for check in packet["checks"]:
        if check["status"] in ("passed", "subsumed", "planned"):
            continue
        entrypoint = check.get("entrypoint")
        offered = bool(entrypoint) and matches_gate(entrypoint, gates.get(check["id"]))
        result.append(
            {
                "id": check["id"],
                "status": check["status"],
                "reason": check.get("reason"),
                "command": shlex.join(entrypoint) if offered else None,
                "command_status": "matches the repository's gate definition" if offered else "unrecorded: " + (
                    "no entrypoint was recorded" if not entrypoint else "it does not match this checkout's gate definition"
                ),
                "log": check.get("log"),
                "phases": {key: value for key, value in (check.get("phases") or {}).items() if key in validation_evidence.PHASE_VALUES} or None,
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
        if any(isinstance(item, str) and item.startswith("probe failed") for item in (value, now)):
            add(f"tool-probe-failed:{name}", f"recorded {value!r}, this host {now!r}; a failed probe says nothing about the version")
        elif value is not None and now is None:
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
    for key in ("os_id", "os_version_id"):
        before = (packet.get("image") or {}).get(key)
        now = (here.get("image") or {}).get(key)
        if before is not None and before != now:
            add(f"image-differs:{key}", f"recorded {before!r}, this host {now!r}")
    source = packet["source"]
    if source.get("revision") and not source.get("revision_declared"):
        if here.get("revision") is None:
            add("revision-unobserved-here", "this checkout's revision could not be read, so it cannot be compared")
        elif here["revision"] != source["revision"]:
            add("revision-differs", "this checkout is at a different revision than the recorded run")
    if here.get("dirty") is True:
        add("dirty-here", "this checkout has uncommitted changes")
    elif here.get("dirty") is None:
        add("dirty-unobserved-here", "whether this checkout has uncommitted changes could not be read")
    return gaps


def analyze(
    packet: Mapping[str, Any],
    here: Mapping[str, Any] | None = None,
    gates: Mapping[str, Sequence[str]] | None = None,
) -> dict[str, Any]:
    """Everything a replay reports; [here] and [gates] are injected by tests. Strings are neutralized."""
    here = observe_host() if here is None else here
    # A packet cannot hide a gap by omitting it: what its own contents imply is added to what it recorded.
    recorded = list(packet.get("reproduction_gaps") or [])
    known = {gap["code"] for gap in recorded}
    recorded += [gap for gap in validation_evidence.derive_gaps(packet) if gap["code"] not in known]
    mismatches = host_mismatches(packet, here)
    command, command_status = reproduction_command(packet)
    failing = failing_checks(packet, gates)
    report = {
        "provenance": "recorded, unverified: read from the packet, not re-checked",
        "schema": packet["schema"],
        "mode": packet["mode"],
        "status": packet["status"],
        "source": {key: packet["source"].get(key) for key in ("mode", "revision", "base", "merge_base", "identity_sha256", "dirty")},
        "command": command,
        "command_status": command_status,
        "cwd": packet["invocation"].get("cwd"),
        "root": packet["invocation"].get("root"),
        "failing_checks": failing[:LIST_LIMIT],
        "failing_check_count": len(failing),
        "recorded_gaps": recorded[:LIST_LIMIT],
        "host_mismatches": mismatches[:LIST_LIMIT],
        "gap_count": len(recorded) + len(mismatches),
        "note": "This replay runs nothing recorded and cannot prove a hosted failure reproduces.",
    }
    return cast(dict[str, Any], clean(report))


def render(report: Mapping[str, Any]) -> str:
    lines = [
        f"Everything below is {report['provenance']}",
        f"Packet: schema {report['schema']}, {report['mode']}, status {report['status']}",
        f"Source: {report['source']}",
    ]
    if report["command"]:
        lines += [f"Reproduce from {report['root']} (recorded cwd {report['cwd']}):", f"  {report['command']}"]
    else:
        lines.append(f"Reproduce: {report['command_status']}")
    for check in report["failing_checks"]:
        lines.append(f"Check {check['id']}: {check['status']}" + (f" ({check['reason']})" if check["reason"] else ""))
        lines.append(f"  entrypoint: {check['command']}" if check["command"] else f"  entrypoint: {check['command_status']}")
        if check["log"]:
            lines.append(f"  retained log: {check['log']}")
        if check["phases"]:
            lines.append(f"  phases: {check['phases']}")
    hidden = report["failing_check_count"] - len(report["failing_checks"])
    if hidden:
        lines.append(f"... {hidden} more failing checks not shown")
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
