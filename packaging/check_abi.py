#!/usr/bin/env python3
"""Reject ELF files newer than the supported glibc/libstdc++ baseline."""

import argparse
import json
from pathlib import Path
import re
import subprocess


def version(text):
    return tuple(map(int, text.split(".")))


def inspect(root, max_glibc, max_glibcxx="3.4.33"):
    records, failures = [], []
    for file in sorted(Path(root).rglob("*")):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        output = subprocess.check_output(
            ["readelf", "--version-info", str(file)], text=True, timeout=300
        )
        needs = output.partition("Version needs section")[2]
        record: dict[str, str | None] = {"path": str(file.relative_to(root))}
        for family, limit in [("GLIBC", max_glibc), ("GLIBCXX", max_glibcxx)]:
            found = re.findall(r"\b" + family + r"_(\d+(?:\.\d+)+)", needs)
            required = max(found, key=version) if found else None
            record[family] = required
            if required and version(required) > version(limit):
                failures.append(
                    f"{record['path']}: {family}_{required} exceeds {limit}"
                )
        records.append(record)
    if not records:
        failures.append("No ELF files found; refusing an empty compatibility audit")
    return {
        "max_glibc": max_glibc,
        "max_glibcxx": max_glibcxx,
        "files": records,
        "failures": failures,
        "passed": not failures,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--max-glibc", default="2.39")
    parser.add_argument("--max-glibcxx", default="3.4.33")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = inspect(args.bundle, args.max_glibc, args.max_glibcxx)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    if report["failures"]:
        raise SystemExit("\n".join(report["failures"]))
    print(f"ABI baseline passed for {len(report['files'])} ELF files")


if __name__ == "__main__":
    main()
