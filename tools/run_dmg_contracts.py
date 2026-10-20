#!/usr/bin/env python3
"""Execute the real Apple contracts, retaining fresh JUnit evidence on failure."""

import argparse
from pathlib import Path
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET
from typing import cast

# Keep both existing signing/mount and upgrade/database contracts mandatory,
# while deriving the expected execution count from the suite as it grows.
MINIMUM_CONTRACTS = 2


class ContractResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.cases = {}

    def startTest(self, test):
        super().startTest(test)
        self.case(test)

    def case(self, test):
        # unittest reports class/module setup failures without startTest.
        return self.cases.setdefault(test.id(), ET.Element("testcase", name=test.id()))

    def addFailure(self, test, err):
        super().addFailure(test, err)
        ET.SubElement(self.case(test), "failure").text = self.failures[-1][1]

    def addError(self, test, err):
        super().addError(test, err)
        ET.SubElement(self.case(test), "error").text = self.errors[-1][1]

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        ET.SubElement(self.case(test), "skipped").text = reason


def diagnostics():
    """Bound Apple diagnostics; preserve the contract's original failure result."""
    commands = [
        ["sw_vers"],
        ["xcodebuild", "-version"],
        [
            "/usr/bin/log",
            "show",
            "--last",
            "2m",
            "--style",
            "compact",
            "--predicate",
            'process == "diskimages-helper" OR process == "amfid"',
        ],
    ]
    for command in commands:
        print(f"DMG failure diagnostic: {command!r}", file=sys.stderr, flush=True)
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=15)
            print(
                f"exit={result.returncode}\n{result.stdout[-20000:]}\n{result.stderr[-20000:]}",
                file=sys.stderr,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Diagnostic unavailable: {error}", file=sys.stderr)


def run(suite, output):
    expected = suite.countTestCases()
    result = cast(
        ContractResult,
        unittest.TextTestRunner(verbosity=2, resultclass=ContractResult).run(suite),
    )
    report = ET.Element(
        "testsuite",
        tests=str(result.testsRun),
        failures=str(len(result.failures)),
        errors=str(len(result.errors)),
        skipped=str(len(result.skipped)),
    )
    report.extend(result.cases.values())
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(report).write(output, encoding="utf-8", xml_declaration=True)
    successful = (
        expected >= MINIMUM_CONTRACTS
        and result.wasSuccessful()
        and result.testsRun == expected
        and not result.skipped
    )
    if not successful:
        print(
            f"DMG contracts failed: ran={result.testsRun}, expected={expected}, minimum={MINIMUM_CONTRACTS}, skipped={len(result.skipped)}, failures={len(result.failures)}, errors={len(result.errors)}",
            file=sys.stderr,
        )
    return 0 if successful else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=Path("test-results/dmg/contracts.xml")
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    suite = unittest.defaultTestLoader.discover(
        str(root / "tests"), "test_dmg_contract.py"
    )
    status = run(suite, args.output)
    if status and sys.platform == "darwin":
        diagnostics()
    return status


if __name__ == "__main__":
    sys.exit(main())
