#!/usr/bin/env python3
"""Prepare a reviewed snapshot update; this tool never pushes repository state."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def update(snapshot, root=ROOT):
    date = datetime.strptime(snapshot, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    if date > datetime.now(timezone.utc):
        raise ValueError("Snapshot must not be in the future")
    pins = root / "tools/pins.json"
    values = json.loads(pins.read_text())
    values["ubuntu_snapshot"] = snapshot
    pins.write_text(json.dumps(values, indent=2) + "\n")
    for path in (root / "packaging").glob("*.Dockerfile"):
        source = path.read_text()
        if "ARG UBUNTU_SNAPSHOT=" in source:
            path.write_text(
                re.sub(
                    r"ARG UBUNTU_SNAPSHOT=\d{8}T\d{6}Z",
                    "ARG UBUNTU_SNAPSHOT=" + snapshot,
                    source,
                )
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True)
    update(parser.parse_args().snapshot)
