"""Shadow comparisons require all suites and exact test/pass/skip identities."""

import json
import xml.etree.ElementTree as ET

import pytest

from tools import ci_linux_shadow_compare as comparison


def write_events(path, suite, skipped=False, name="test identity"):
    path.parent.mkdir(parents=True, exist_ok=True)
    events = [
        {"type": "suite", "suite": {"id": 1, "path": suite}},
        {"type": "testStart", "test": {"id": 2, "suiteID": 1, "name": name}},
        {
            "type": "testDone",
            "testID": 2,
            "result": "success",
            "skipped": skipped,
            "hidden": False,
        },
        {"type": "done", "success": True},
    ]
    path.write_text("".join(json.dumps(row) + "\n" for row in events))


def write_junit(path, cases):
    path.parent.mkdir(parents=True, exist_ok=True)
    root = ET.Element("testsuite")
    for classname, name, status in cases:
        case = ET.SubElement(root, "testcase", {"classname": classname, "name": name})
        if status:
            ET.SubElement(case, status)
    ET.ElementTree(root).write(path)


@pytest.fixture
def reports(tmp_path):
    for platform in ("arch", "ubuntu"):
        directory = tmp_path / platform
        for suite in ("core", "desktop"):
            write_events(
                directory / f"test-results/linux/{suite}/{suite}.events.jsonl",
                f"/{platform}/test/sample_test.dart",
            )
        for suite in ("native", "service"):
            write_junit(
                directory / f"test-results/{suite}/results.xml",
                [(suite, "real test", "")],
            )
        cases = [("tests.host", "shared", "")]
        for identity, (arch_skip, ubuntu_skip) in comparison.PLATFORM_SKIPS.items():
            name = identity.rsplit(".", 1)[-1]
            skip = arch_skip if platform == "arch" else ubuntu_skip
            cases.append(("tests.test_linux_packages", name, "skipped" if skip else ""))
        write_junit(directory / "coverage/python/linux-contracts.xml", cases)
    return tmp_path / "arch", tmp_path / "ubuntu", tmp_path / "comparison.json"


def test_comparison_keeps_the_full_suite_counts_and_normalizes_only_checkout_prefixes(
    reports,
):
    arch, ubuntu, output = reports
    summary = comparison.compare(arch, ubuntu, output)
    assert set(summary) == {"core", "desktop", "native", "service", "host-python"}
    assert all(value == {"passed": 1, "skipped": 0} for value in summary.values())
    assert json.loads(output.read_text()) == summary


@pytest.mark.parametrize(
    "failure",
    ["missing", "different", "service-skip", "host-drift", "failed-case", "duplicate"],
)
def test_incomplete_or_different_shadow_reports_fail_closed(reports, failure):
    arch, ubuntu, output = reports
    if failure == "missing":
        (ubuntu / "test-results/linux/core/core.events.jsonl").unlink()
    elif failure == "different":
        write_events(
            ubuntu / "test-results/linux/core/core.events.jsonl",
            "/ubuntu/test/different.dart",
        )
    elif failure == "service-skip":
        write_junit(
            ubuntu / "test-results/service/results.xml",
            [("service", "real test", "skipped")],
        )
    elif failure == "host-drift":
        write_junit(
            ubuntu / "coverage/python/linux-contracts.xml",
            [("tests.host", "shared", "")],
        )
    elif failure == "failed-case":
        write_junit(
            ubuntu / "test-results/native/results.xml",
            [("native", "real test", "failure")],
        )
    else:
        write_events(
            ubuntu / "other/core/core.events.jsonl", "/ubuntu/test/sample_test.dart"
        )
    with pytest.raises(ValueError):
        comparison.compare(arch, ubuntu, output)
    assert not output.exists()


def test_benchmark_uses_covered_full_suite_and_rejects_empty_junit(reports):
    arch, ubuntu, output = reports
    before = ubuntu / "test-results/linux/core/core.events.jsonl"
    before.rename(before.with_name("coverage.events.jsonl"))
    comparison.compare(arch, ubuntu, output)
    path = ubuntu / "empty.xml"
    path.write_text("<testsuite/>")
    with pytest.raises(ValueError, match="Empty"):
        comparison.junit_result(path)
