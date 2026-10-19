#!/usr/bin/env python3
"""Require two successful Dart JSON event streams to cover identical outcomes."""

import argparse
from collections import Counter
import json
from pathlib import Path


def outcomes(path):
    suites = {}
    tests = {}
    completed = set()
    result: Counter[tuple[str, str, bool]] = Counter()
    done = False
    with path.open() as stream:
        for line in stream:
            event = json.loads(line)
            kind = event["type"]
            if done:
                raise ValueError("Events after completed test run")
            if kind == "suite":
                suite = event["suite"]
                suites[suite["id"]] = suite["path"]
            elif kind == "testStart":
                test = event["test"]
                if test["id"] in tests:
                    raise ValueError("Duplicate test start")
                tests[test["id"]] = (suites[test["suiteID"]], test["name"])
            elif kind == "testDone":
                identity = event["testID"]
                if identity in completed or identity not in tests:
                    raise ValueError("Unmatched test completion")
                completed.add(identity)
                if event["result"] != "success":
                    raise ValueError("Unsuccessful test outcome")
                if not event["hidden"]:
                    result[(*tests[identity], event["skipped"])] += 1
            elif kind == "done":
                if event.get("success") is not True or completed != tests.keys():
                    raise ValueError("Unsuccessful or incomplete test run")
                done = True
    if not done or not result:
        raise ValueError("Missing complete, nonempty test run")
    return result


def compare(first, second):
    before, after = outcomes(first), outcomes(second)
    if before != after:
        raise ValueError(
            "Coverage benchmark changed test identities or skip outcomes: "
            f"{sum((before - after).values())} removed, "
            f"{sum((after - before).values())} added"
        )
    count = sum(before.values())
    skipped = sum(count for (*_, skip), count in before.items() if skip)
    print(f"Core benchmark matched: {count - skipped} passed, {skipped} skipped")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plain", type=Path)
    parser.add_argument("coverage", type=Path)
    args = parser.parse_args()
    compare(args.plain, args.coverage)


if __name__ == "__main__":
    main()
