#!/usr/bin/env python3
"""Require every Dart skip registration to have an explicit validation path."""

import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
GATES = {
    "platform",
    "core-native",
    "fast",
    "models",
    "virtual-audio",
    "reference-models",
    "reference-tokenizer",
    "saved-profile",
}


def conditions(text):
    result = []
    for match in re.finditer(r"\bskip\s*:", text):
        expression = []
        for line in text[match.end() :].splitlines():
            expression.append(line.strip())
            if line.rstrip().endswith(","):
                break
        result.append(" ".join(expression).strip().removesuffix(","))
    return result


def verify_probes(root=ROOT):
    inventory = json.loads((root / "tools/integration_probes.json").read_text())
    if inventory.get("schema") != 1:
        raise ValueError("Unsupported probe inventory")
    expected = {entry["path"]: entry for entry in inventory["entries"]}
    actual = {
        str(path.relative_to(root))
        for pattern in ("test_*.py", "accept_*.py")
        for path in (root / "tools").glob(pattern)
    }
    if len(expected) != len(inventory["entries"]) or actual != expected.keys():
        raise ValueError(
            "Unlisted or stale tooling probes: "
            + ", ".join(sorted(actual ^ expected.keys()))
        )
    for path, entry in expected.items():
        if not entry.get("reason", "").strip():
            raise ValueError("Probe needs a reason: " + path)
        if entry.get("mode") == "manual":
            if (
                f"`{path}`"
                not in (root / "docs/validation/integration-gates.md").read_text()
            ):
                raise ValueError("Manual probe is absent from its index: " + path)
        elif entry.get("mode") == "automated":
            if not entry.get("wiring") or not any(
                Path(path).name in (root / source).read_text()
                for source in entry["wiring"]
            ):
                raise ValueError("Automated probe has no executable wiring: " + path)
        else:
            raise ValueError("Invalid probe mode: " + path)
    return len(expected)


def verify(root=ROOT):
    verify_probes(root)
    inventory = json.loads((root / "tools/integration_skips.json").read_text())
    if inventory["schema"] != 1:
        raise ValueError("Unsupported integration inventory")
    expected = {}
    for entry in inventory["entries"]:
        if (
            entry["path"] in expected
            or entry["gate"] not in GATES
            or not entry["reason"].strip()
        ):
            raise ValueError("Invalid or duplicate integration inventory entry")
        expected[entry["path"]] = entry["conditions"]
    actual = {}
    for folder in [
        "apps/desktop/test",
        "apps/desktop/integration_test",
        "packages/foresight_core/test",
    ]:
        for path in (root / folder).rglob("*.dart"):
            found = conditions(path.read_text())
            if found:
                actual[str(path.relative_to(root))] = found
    if actual != expected:
        changed = sorted(
            key
            for key in actual.keys() | expected.keys()
            if actual.get(key) != expected.get(key)
        )
        raise ValueError(
            "Review validation paths for changed skip conditions: " + ", ".join(changed)
        )
    return sum(map(len, actual.values()))


if __name__ == "__main__":
    print(f"{verify()} skip registrations have explicit validation paths.")
