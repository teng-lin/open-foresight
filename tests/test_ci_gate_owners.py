"""Required platform results follow actual host owners and never hide Arch failures."""

from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
import xml.etree.ElementTree as ET

import pytest
import yaml

from tools import ci_changes as changes, platform_python_tests as contracts
from tools import run_dmg_contracts as dmg

ROOT = Path(__file__).resolve().parents[1]


def results(selection, tier=""):
    jobs = {
        name: {"result": "success" if value else "skipped"}
        for name, value in selection.items()
    }
    jobs["changes"] = {"result": "success"}
    jobs["linux-native"] = {
        "result": "success"
        if selection["linux-build"] and tier != "release"
        else "skipped"
    }
    return jobs


@pytest.mark.parametrize("tier", ["", "pr", "sweep", "preview", "release"])
def test_selected_arch_failure_cannot_hide_behind_green_ubuntu(tier):
    selection = changes.select_gates(["native/source.cpp"])
    jobs = results(selection, tier)
    changes.check_gates(jobs, selection, tier)
    for outcome in ["failure", "cancelled", "skipped", None]:
        if outcome == jobs["linux-native"]["result"]:
            continue
        with pytest.raises(ValueError, match="linux-native"):
            changes.check_gates(
                {**jobs, "linux-native": {"result": outcome}}, selection, tier
            )
    with pytest.raises(ValueError, match="Invalid CI tier"):
        changes.check_gates(jobs, selection, "unknown")


def test_every_host_inventory_selects_its_real_owners_and_notice_selects_apple():
    for path in set(contracts.SHARED).union(
        *contracts.PLATFORM.values(), contracts.EXTERNAL
    ):
        selection = changes.select_gates([path])
        assert all(selection[owner] for owner in contracts.owner_gates(path)), path
    assert all(changes.select_gates(["packaging/notices/vendor.md"]).values())
    report = changes.selection_report(["README.md"])
    assert report["superseded"] is False
    assert not any(report["selection"].values())
    # This SHARED file also owns a real makepkg probe, deselected on hosts.
    selected = changes.select_gates(["tests/test_linux_packages.py"])
    assert {"macos", "dmg", "packaging", "linux-build", "linux-test"} <= {
        gate for gate, value in selected.items() if value
    }


def test_dmg_is_independent_of_linux_bundle_and_required_for_apple_inputs():
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    assert jobs["dmg"]["needs"] == "changes"
    assert "dmg" in jobs["platform-checks"]["needs"]
    assert (
        jobs["platform-checks"]["steps"][-1]["env"]["CI_TIER"] == "${{ inputs.tier }}"
    )
    selection = changes.select_gates(["packaging/macos/entitlements.plist"])
    assert {key for key, value in selection.items() if value} == {"macos", "dmg"}
    for outcome in ["failure", "cancelled", "skipped", None]:
        jobs = results(selection)
        jobs["dmg"] = {"result": outcome}
        with pytest.raises(ValueError, match="dmg"):
            changes.check_gates(jobs, selection)


@pytest.mark.parametrize("outcome", ["success", "skip", "failure", "error", "missing"])
def test_dmg_runner_retains_junit_and_rejects_skipped_missing_or_failed_contracts(
    tmp_path, outcome, monkeypatch
):
    class Fixture(unittest.TestCase):
        def test_contract(self):
            if outcome == "skip":
                self.skipTest("Apple unavailable")
            if outcome == "failure":
                self.fail("failed signed execution")
            if outcome == "error":
                raise RuntimeError("failed image mount")

    suite = unittest.TestSuite(
        Fixture("test_contract") for _ in range(1 if outcome == "missing" else 2)
    )
    monkeypatch.setattr(dmg, "REQUIRED_CONTRACTS", {Fixture("test_contract").id()})
    if outcome == "missing":
        # Simulate a loader/executor mismatch, independently of suite size.
        suite.countTestCases = lambda: 2
    report = tmp_path / "evidence/contracts.xml"
    assert (dmg.run(suite, report) == 0) == (outcome == "success")
    root = ET.parse(report).getroot()  # noqa: S314 - Locally generated runner fixture.
    assert int(root.get("tests")) == (1 if outcome == "missing" else 2)
    assert list(root.iter("testcase"))


def test_dmg_diagnostics_keep_errors_and_timeout_output_bounded(monkeypatch, capsys):
    attempts = iter(
        [
            SimpleNamespace(returncode=-9, stdout="diagnostic", stderr="killed"),
            OSError("missing"),
            subprocess.TimeoutExpired("log", 15),
        ]
    )

    def run(command, **kwargs):
        assert kwargs["timeout"] == 15
        value = next(attempts)
        if isinstance(value, Exception):
            raise value
        return value

    monkeypatch.setattr(dmg.subprocess, "run", run)
    dmg.diagnostics()
    stderr = capsys.readouterr().err
    assert "exit=-9" in stderr and "killed" in stderr
    assert "Diagnostic unavailable" in stderr


def test_dmg_main_uses_actual_owned_suite_and_preserves_exit(monkeypatch, tmp_path):
    monkeypatch.setattr(
        dmg.sys, "argv", ["dmg", "--output", str(tmp_path / "report.xml")]
    )
    monkeypatch.setattr(dmg.sys, "platform", "darwin")
    monkeypatch.setattr(
        dmg.unittest.defaultTestLoader, "discover", lambda *args: "owned-suite"
    )
    monkeypatch.setattr(
        dmg, "run", lambda suite, output: 7 if suite == "owned-suite" else 0
    )
    observed = []
    monkeypatch.setattr(dmg, "diagnostics", lambda: observed.append(True))
    assert dmg.main() == 7
    assert observed == [True]


@pytest.mark.parametrize("skip", [False, True])
def test_dmg_class_setup_errors_and_skips_still_produce_diagnostic_junit(
    tmp_path, capsys, skip
):
    class Fixture(unittest.TestCase):
        @classmethod
        def setUpClass(cls):
            if skip:
                raise unittest.SkipTest("Apple setup unavailable")
            raise RuntimeError("Apple setup failed")

        def test_contract(self):
            pass

    report = tmp_path / "class-error.xml"
    assert (
        dmg.run(unittest.defaultTestLoader.loadTestsFromTestCase(Fixture), report) == 1
    )
    root = ET.parse(report).getroot()  # noqa: S314 - Locally generated error fixture.
    assert root.find("testcase/skipped" if skip else "testcase/error") is not None
    diagnostic = capsys.readouterr().err
    assert "ran=0" in diagnostic and "expected=1" in diagnostic


def test_dmg_suite_inventory_can_grow_but_cannot_lose_either_existing_contract(tmp_path, monkeypatch):
    class Fixture(unittest.TestCase):
        def test_contract(self):
            pass

    monkeypatch.setattr(dmg, "REQUIRED_CONTRACTS", {Fixture("test_contract").id()})
    for count in (2, 3):
        suite = unittest.TestSuite(Fixture("test_contract") for _ in range(count))
        assert dmg.run(suite, tmp_path / f"contracts-{count}.xml") == 0
    for count in (0, 1):
        suite = unittest.TestSuite(Fixture("test_contract") for _ in range(count))
        assert dmg.run(suite, tmp_path / f"missing-{count}.xml") == 1


def test_dmg_runner_rejects_replacing_an_owned_contract_with_an_unrelated_test(tmp_path, monkeypatch):
    class Fixture(unittest.TestCase):
        def test_signing(self):
            pass

        def test_upgrade(self):
            pass

        def test_unrelated(self):
            pass

    required = {Fixture(name).id() for name in ("test_signing", "test_upgrade")}
    monkeypatch.setattr(dmg, "REQUIRED_CONTRACTS", required)
    replaced = unittest.TestSuite(Fixture(name) for name in ("test_signing", "test_unrelated"))
    assert dmg.run(replaced, tmp_path / "replaced.xml") == 1
    complete = unittest.defaultTestLoader.loadTestsFromTestCase(Fixture)
    assert dmg.run(complete, tmp_path / "complete.xml") == 0


def test_dmg_required_ids_match_both_actual_owned_contracts():
    suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"), "test_dmg_contract.py")

    def identities(node):
        if isinstance(node, unittest.TestSuite):
            return {name for child in node for name in identities(child)}
        return {node.id()}

    assert len(dmg.REQUIRED_CONTRACTS) == 2
    assert dmg.REQUIRED_CONTRACTS <= identities(suite)


def test_dmg_evidence_preserves_each_failed_attempt():
    config = yaml.safe_load((ROOT / ".github/workflows/dmg-contracts.yml").read_text())
    upload = next(
        step for step in config["jobs"]["dmg"]["steps"]
        if step.get("uses", "").startswith("actions/upload-artifact@")
    )
    assert upload["if"] == "always()"
    assert upload["with"]["name"] == "dmg-contract-evidence-${{ github.run_id }}-${{ github.run_attempt }}"
    assert "overwrite" not in upload["with"]


@pytest.mark.parametrize("path", [
    "tests/contracts/test_descriptor.py",
    "tests/contracts/test_owned_descriptors.py",
    "tests/inference/test_legacy_query_executor.py",
    "tests/inference/test_litert_identity.py",
])
def test_nested_inventory_keeps_full_validation_until_selector_qualification(path):
    assert all(changes.select_gates([path]).values())
