#!/usr/bin/env python3
"""Exercise cloud services using distribution configuration from the built bundle."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess

KEYS = ("FORESIGHT_SEARCH_API_KEY", "FORESIGHT_WEB_CONTENT_API_KEY")


def configuration(bundle):
    if bundle.suffix == ".app":
        resources = bundle.resolve() / "Contents/Resources"
        values = json.loads((resources / "runtime.json").read_text())
        if not all(values.get(key) for key in KEYS):
            raise ValueError(
                "Full cloud acceptance requires bundled distribution configuration"
            )
        return {"FORESIGHT_RESOURCES": str(resources)}
    values = {}
    for line in (bundle / "open-foresight").read_text().splitlines():
        for key in KEYS:
            if line.startswith(f"export {key}="):
                tokens = shlex.split(line.split("=", 1)[1])
                if len(tokens) != 1:
                    raise ValueError("Malformed bundled cloud configuration")
                values[key] = tokens[0]
    if not all(values.get(key) for key in KEYS):
        raise ValueError(
            "Full cloud acceptance requires bundled distribution configuration"
        )
    return values


def verify(bundle, output):
    env = dict(os.environ)
    for key in (*KEYS, "FORESIGHT_RESOURCES"):
        env.pop(key, None)
    env.update(configuration(bundle))
    core = Path(__file__).resolve().parents[1] / "packages/foresight_core"
    subprocess.run(
        ["dart", "pub", "get", "--enforce-lockfile"], cwd=core, check=True, timeout=300
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stream:
        subprocess.run(
            ["dart", "run", "tool/verify_cloud_services.dart", "--download-query"],
            cwd=core,
            env=env,
            stdout=stream,
            check=True,
            timeout=3600,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    verify(args.bundle, args.output)
