"""Optional rollout discovery must broaden checks without masking producer errors."""

import copy
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

import pytest

from tools import ci_changes as changes, ci_acceptance_plan as acceptance
from tools import ci_qualification_index as index, ci_main_evidence as evidence
from tools import ci_main_coordinator as coordinator, ci_rollout as rollout
from tests.test_ci_main_evidence import FixtureReader, SOURCE, BEFORE, run
from tests.test_ci_rollout import Evidence, REPOSITORY

ERRORS = [subprocess.CalledProcessError(1, ["gh", "api"], stderr="rate limited"), RuntimeError("API unavailable"), OSError("Network unavailable")]


@pytest.mark.parametrize("error", ERRORS)
def test_optional_index_failure_returns_one_broad_reason_and_producer_still_fails(error):
    def unavailable(*args, **kwargs):
        raise copy.copy(error)
    result = index.resolve(SOURCE, repository=REPOSITORY, api=unavailable)
    assert set(result) == rollout.CAPABILITIES
    assert all(value["active"] is False and type(error).__name__ in value["reason"] for value in result.values())
    with pytest.raises(type(error)):
        index.load(REPOSITORY, api=unavailable)
    with pytest.raises(type(error)):
        index.collect(REPOSITORY, SOURCE, api=unavailable)


@pytest.mark.parametrize("error", ERRORS)
def test_optional_arch_and_status_outages_restore_owner_with_recorded_reason(error):
    reader = FixtureReader()
    with patch("tools.ci_qualification_index.capability", side_effect=error):
        assert not reader.arch_retired(SOURCE)
        assert "linux-native" in reader.application_owners(SOURCE)
        assert type(error).__name__ in reader.arch_retirement_reasons[SOURCE]
        result = coordinator.activation(reader, SOURCE)
    assert result["active"] is False and str(error) in result["reason"]


def test_phase_planner_uses_the_same_verified_decision_without_another_index_load(tmp_path, monkeypatch):
    calls = []
    decisions = {name: {"active": True} for name in rollout.CAPABILITIES}
    def resolve(source, **kwargs):
        calls.append(source)
        return decisions
    monkeypatch.setattr(index, "resolve", resolve)
    report = changes.activate_report(changes.selection_report(["tools/accept_software_gpu.py"]), source=SOURCE, repository=REPOSITORY)
    assert calls == [SOURCE]
    selection = tmp_path / "selection.json"
    selection.write_text(json.dumps(report))
    monkeypatch.setenv("GITHUB_SHA", SOURCE)
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setattr(acceptance, "changed_paths", lambda *args: ["tools/accept_software_gpu.py"])
    monkeypatch.setattr(sys, "argv", ["acceptance", "--activate", "--selection-report", str(selection), "--base", BEFORE, "--event", "pull_request", "--output", str(tmp_path / "phases.json")])
    with patch("tools.ci_qualification_index.load", side_effect=AssertionError("Second process must not fetch the index")):
        acceptance.main()
    assert calls == [SOURCE]
    result = json.loads((tmp_path / "phases.json").read_text())
    assert result["executed"] == {"cpu-models": False, "software-gpu": True, "virtual-audio": False}
    assert json.loads(selection.read_text())["acceptance_phases"] == result["executed"]


def test_report_for_another_source_cannot_narrow_current_acceptance(tmp_path, monkeypatch):
    selection = tmp_path / "selection.json"
    selection.write_text(json.dumps({"force": False, "activation_source": BEFORE, "activation_repository": REPOSITORY, "activation": {"acceptance_narrowing": {"active": True}}}))
    monkeypatch.setenv("GITHUB_SHA", SOURCE)
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setattr(acceptance, "changed_paths", lambda *args: ["tools/accept_software_gpu.py"])
    monkeypatch.setattr(sys, "argv", ["acceptance", "--activate", "--selection-report", str(selection), "--base", BEFORE, "--event", "pull_request", "--output", str(tmp_path / "phases.json")])
    acceptance.main()
    assert all(json.loads((tmp_path / "phases.json").read_text())["executed"].values())


@pytest.mark.parametrize("error", ERRORS)
def test_live_label_outage_forces_all_fresh_checks_without_fetching_capabilities(tmp_path, monkeypatch, error):
    from tools import ci_selection
    def output(command, **kwargs):
        return SOURCE + "\n" if command[1] == "rev-parse" else b"docs/guide.md\0"
    def unavailable(*args, **kwargs):
        raise copy.copy(error)
    monkeypatch.setattr(changes.subprocess, "check_output", output)
    monkeypatch.setattr(changes.subprocess, "run", lambda *args, **kwargs: None)
    monkeypatch.setattr(ci_selection, "live_labels", unavailable)
    monkeypatch.setattr(index, "resolve", lambda *args, **kwargs: pytest.fail("No extra optional reads after label outage"))
    monkeypatch.setattr(sys, "argv", ["changes", "--base", BEFORE, "--pull-request", "42", "--repository", REPOSITORY, "--activate", "--json-output", str(tmp_path / "selection.json")])
    changes.main()
    result = json.loads((tmp_path / "selection.json").read_text())
    assert result["force"] and all(result["selection"].values())
    assert not result["arch_retired"]
    assert type(error).__name__ in result["label_lookup_failure"]


def test_lapsed_retirement_on_green_sweep_dispatches_fresh_validation():
    reader = FixtureReader()
    previous = run(40, source=SOURCE, event="workflow_dispatch")
    previous["display_title"] = f"Main sweep {SOURCE} [production]"
    reader.origins.append(previous)
    with patch.object(coordinator, "authorize"), patch.object(reader, "proposal", return_value={"decision": "sweep"}), patch.object(coordinator, "selected_on_push", return_value={}), patch.object(coordinator, "sweep_receipt", side_effect=evidence.RetirementQualificationLapsed("expired original retirement proof")), patch.object(reader, "api") as api:
        result = coordinator.reconcile(reader, SOURCE, BEFORE)
    assert result["decision"] == "sweep-requested"
    assert "expired" in result["reason"]
    assert api.call_args.args[1].endswith("macos.yml/dispatches")
    assert api.call_args.args[3]["inputs"]["sweep_namespace"] == "production"


def test_missing_needed_kind_short_circuits_before_any_descriptor_download(tmp_path):
    for name in ("tools/ci_changes.py", "tools/ci_selection.py", ".github/workflows/macos.yml"):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("reviewed input")
    fixture = Evidence(tmp_path)
    fixture.add("observer")
    with pytest.raises(ValueError, match="publisher"):
        rollout.authorize(fixture.index, root=tmp_path, source=SOURCE, capabilities=["main_receipts"], repository=REPOSITORY, api=fixture.api, download=lambda *args: pytest.fail("Must reject missing publisher before downloads"))


def test_real_tooling_exercise_recipe_exists_and_has_exact_stage_marker():
    root = Path(__file__).resolve().parents[1]
    recipe = root / "packaging/ci-tooling.Dockerfile"
    assert recipe.is_file()
    assert recipe.read_bytes().count(b"FROM ${SDK_IMAGE} AS ci-tooling\n") == 1
    assert "qualification-consumers" in (root / ".github/workflows/linux-cache-publish.yml").read_text()


def test_all_routing_capabilities_share_one_authenticated_index_read(tmp_path):
    from tests.test_ci_qualification_index import IndexEvidence
    for name in ("tools/ci_changes.py", "tools/ci_selection.py", ".github/workflows/macos.yml"):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("reviewed input")
    fixture = IndexEvidence(tmp_path)
    fixture.add("selector-replay")
    fixture.verify("path_selection")
    fixture.publish()
    calls, downloads = [], []
    def api(repository, route):
        calls.append(route)
        return fixture.api(repository, route)
    def download(repository, artifact, target):
        downloads.append(artifact["id"])
        fixture.download(repository, artifact, target)
    result = index.resolve(SOURCE, root=tmp_path, repository=REPOSITORY, api=api, download=download)
    assert result["path_selection"]["active"] is True
    assert all(result[name]["active"] is False for name in rollout.CAPABILITIES - {"path_selection"})
    assert len([route for route in calls if route.startswith("actions/artifacts?name=ci-qualification-index")]) == 1
    assert downloads == [999, 1]


def test_source_receipt_api_errors_still_propagate_without_a_validation_claim():
    reader = FixtureReader()
    def unavailable(route):
        raise RuntimeError("Original receipt API unavailable")
    with patch.object(reader, "get", side_effect=unavailable):
        with pytest.raises(RuntimeError, match="Original receipt"):
            reader.proposal(SOURCE, BEFORE, dict.fromkeys(evidence.APPLICATION, True))


def test_unrelated_green_sweep_provenance_error_does_not_trigger_lapse_recovery():
    reader = FixtureReader()
    previous = run(40, source=SOURCE, event="workflow_dispatch")
    previous["display_title"] = f"Main sweep {SOURCE} [production]"
    reader.origins.append(previous)
    with patch.object(coordinator, "authorize"), patch.object(reader, "proposal", return_value={"decision": "sweep"}), patch.object(coordinator, "selected_on_push", return_value={}), patch.object(coordinator, "sweep_receipt", side_effect=ValueError("Artifact checksum mismatch")), patch.object(coordinator, "dispatch") as dispatch:
        result = coordinator.reconcile(reader, SOURCE, BEFORE)
    assert result["decision"] == "failed"
    dispatch.assert_not_called()


def test_qualification_fixture_zip_checksums_do_not_depend_on_wall_clock(tmp_path, monkeypatch):
    import zipfile
    from tests.test_ci_qualification_index import IndexEvidence
    for name in ("tools/ci_changes.py", "tools/ci_selection.py", ".github/workflows/macos.yml"):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("reviewed input")
    fixture = IndexEvidence(tmp_path)
    fixture.add("selector-replay")
    with monkeypatch.context() as clock:
        def unexpected_clock(*args):
            raise AssertionError("Frozen archive metadata must not consult the wall clock")
        clock.setattr(zipfile.time, "localtime", unexpected_clock)
        fixture.verify("path_selection")
        fixture.publish()
        index.capability("path_selection", SOURCE, root=tmp_path, repository=REPOSITORY, api=fixture.api, download=fixture.download)
