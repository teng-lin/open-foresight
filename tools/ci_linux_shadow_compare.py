#!/usr/bin/env python3
"""Compare the complete shadow/Arch per-test outcomes from this producing run."""

import argparse
from collections import Counter
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.compare_test_runs import outcomes  # noqa: E402

# Native package-manager probes remain in their real distro contracts. These
# differences are explicit and checked directionally; no suite may disappear.
PLATFORM_SKIPS = {
    "test_linux_packages.test_nlohmann_notice_is_listed_in_debian_package": (
        True,
        False,
    ),
}


def unique(root, suffixes):
    paths = [
        path
        for path in root.rglob("*")
        if path.is_file()
        and any(path.as_posix().endswith(suffix) for suffix in suffixes)
    ]
    if len(paths) != 1:
        raise ValueError(
            f"Expected one complete report for {suffixes}, found {len(paths)}"
        )
    return paths[0]


def dart_result(path):
    result: Counter[tuple[str, str, bool]] = Counter()
    for (suite, name, skipped), count in outcomes(path).items():
        # Both runners compile /src or the Arch checkout, but package-relative
        # test paths and names must match exactly.
        suffix = "test/" + suite.rsplit("/test/", 1)[-1] if "/test/" in suite else suite
        result[(suffix, name, skipped)] += count
    return result


def junit_result(path):
    result: Counter[tuple[str, str, bool]] = Counter()
    for case in ET.parse(path).getroot().iter("testcase"):  # noqa: S314 - local test output; no external entities supported.
        if case.find("failure") is not None or case.find("error") is not None:
            raise ValueError("Failed test in " + str(path))
        result[
            (
                case.get("classname", ""),
                case.attrib["name"],
                case.find("skipped") is not None,
            )
        ] += 1
    if not result:
        raise ValueError("Empty JUnit suite: " + str(path))
    return result


def compare(arch, ubuntu, output):
    summary = {}
    definitions = {
        "core": (
            ("/core/core.events.jsonl", "/core/coverage.events.jsonl"),
            dart_result,
        ),
        "desktop": (("/desktop/desktop.events.jsonl",), dart_result),
        "native": (("/native/results.xml",), junit_result),
        "service": (("/service/results.xml",), junit_result),
        "host-python": (("/python/linux-contracts.xml",), junit_result),
    }
    for suite, (suffixes, reader) in definitions.items():
        before, after = reader(unique(arch, suffixes)), reader(unique(ubuntu, suffixes))
        if suite == "service" and any(key[-1] for key in after):
            raise ValueError("Ubuntu compiled service/MCP suite has skipped tests")
        if suite == "host-python":
            for name, (old_skip, new_skip) in PLATFORM_SKIPS.items():
                for values, skipped in ((before, old_skip), (after, new_skip)):
                    matches = [
                        key for key in values if (key[0] + "." + key[1]).endswith(name)
                    ]
                    if len(matches) != 1 or matches[0][-1] != skipped:
                        raise ValueError("Unexpected distro probe outcome: " + name)
                    del values[matches[0]]
        if before != after:
            raise ValueError(
                f"{suite} pass/skip identities differ: {sum((before - after).values())} removed, {sum((after - before).values())} added"
            )
        summary[suite] = {
            "passed": sum(value for key, value in after.items() if not key[-1]),
            "skipped": sum(value for key, value in after.items() if key[-1]),
        }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", type=Path, required=True)
    parser.add_argument("--ubuntu", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    compare(args.arch, args.ubuntu, args.output)


if __name__ == "__main__":
    main()
