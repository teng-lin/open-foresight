#!/usr/bin/env python3
"""Enforce line coverage on the already-filtered LCOV artifact."""

import argparse
import math
from pathlib import Path


def line_counts(path):
    """Merge repeated source/line records; LCOV checksums are optional."""
    hits: dict[tuple[str, int], int] = {}
    source = None
    for record in Path(path).read_text().splitlines():
        if record.startswith("SF:"):
            source = record[3:]
        elif record == "end_of_record":
            source = None
        elif record.startswith("DA:"):
            if not source:
                raise ValueError("LCOV line data has no source file")
            raw_number, raw_count, *_ = record[3:].split(",")
            number, count = int(raw_number), int(raw_count)
            if number < 1 or count < 0:
                raise ValueError("Invalid LCOV line number or execution count")
            key = (source, number)
            hits[key] = max(hits.get(key, 0), count)
    if not hits:
        raise ValueError("LCOV report contains no executable lines")
    return sum(count > 0 for count in hits.values()), len(hits)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--label", default="Core")
    parser.add_argument("--minimum", type=float, required=True)
    args = parser.parse_args()
    if not math.isfinite(args.minimum) or not 0 <= args.minimum <= 100:
        parser.error("--minimum must be between 0 and 100")
    try:
        covered, total = line_counts(args.report)
    except (OSError, ValueError) as error:
        parser.exit(2, f"Invalid coverage report: {error}\n")
    percentage = covered * 100 / total
    print(
        f"{args.label} line coverage: {percentage:.2f}% ({covered}/{total}); minimum {args.minimum:g}%"
    )
    return 0 if covered * 100 >= args.minimum * total else 1


if __name__ == "__main__":
    raise SystemExit(main())
