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


def verify(root=ROOT):
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
    for folder in ["apps/desktop/test", "packages/foresight_core/test"]:
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
