"""Candidate WS3 rules preserve required owners without narrowing production."""

import copy
import hashlib
import json
import sys
from pathlib import Path

import pytest

from tools import ci_changes, ci_selection as selection

FIXTURE = Path(__file__).parent / "fixtures/ci-selector-50-prs.json"


@pytest.mark.parametrize("path,owner,required,absent", [
    ("docs/guide.md", "editorial", set(), {"macos", "linux-build"}),
    ("tests/test_release_latest.py", "portable-quality", set(), {"macos", "linux-build"}),
    ("packaging/notices/example.md", "installed-notice", {"macos", "packaging", "dmg"}, set()),
    ("packaging/macos/entitlements.plist", "apple-package-input", {"macos", "dmg"}, {"linux-build", "packaging"}),
    ("tools/package_macos.py", "apple-input", {"macos", "dmg"}, {"linux-build"}),
    ("tests/test_macos_tools.py", "host-contract", {"macos", "dmg"}, {"linux-build"}),
    ("tests/test_dmg_contract.py", "host-contract", {"macos", "dmg"}, {"linux-build"}),
    ("tests/test_linux_packages.py", "host-contract", {"macos", "packaging", "linux-build", "dmg"}, set()),
    ("tests/test_app_dependency_cmake.py", "host-contract", {"macos", "linux-build"}, set()),
    ("tests/test_rpm_scriptlets.py", "host-contract", {"packaging", "linux-build", "dmg"}, set()),
    ("packaging/acceptance.Dockerfile", "acceptance-input", {"linux-build", "linux-test"}, {"macos", "packaging"}),
    ("packaging/minimal-grpc.cmake", "native-sdk-input", {"macos", "linux-build"}, {"packaging"}),
    (".github/workflows/release.yml", "release-control", {"macos", "linux-build", "packaging"}, set()),
    ("tools/ci_package_sandbox.sh", "package-input", {"macos", "linux-build", "packaging", "linux-document-imports"}, set()),
    ("apps/desktop/linux/CMakeLists.txt", "linux-input", {"linux-build", "linux-test"}, {"macos"}),
    ("tools/build.sh", "application-or-unknown", {"macos", "linux-build"}, {"packaging"}),
    ("new/unknown.input", "application-or-unknown", {"macos", "linux-build"}, {"packaging"}),
    ("../escape", "unknown", {"macos", "linux-build"}, {"packaging"}),
    ("", "unknown", {"macos", "linux-build"}, {"packaging"}),
])
def test_explicit_rules_and_closure(path, owner, required, absent):
    report = selection.select([path])
    assert report["mode"] == "observe-only" and report["permits_skipping"] is False
    assert report["paths"][0]["rule"] == owner
    assert required.issubset(report["required_jobs"])
    assert absent.isdisjoint(report["required_jobs"])
    if report["selection"]["linux-build"]:
        assert set(selection.ACCEPTANCE).issubset(report["required_jobs"])
        assert "linux-native" in report["required_jobs"]


def test_union_is_order_independent_and_release_does_not_require_arch():
    a, b = "apps/desktop/macos/example.mm", "packaging/ci/package-and-test.sh"
    assert selection.select([a, b])["selection"] == selection.select([b, a])["selection"]
    jobs = selection.required_jobs(selection.application_selection(), tier="release")
    assert "linux-native" not in jobs and "packaging" not in jobs
    assert set(selection.ACCEPTANCE).issubset(jobs)
    assert "linux-native" not in selection.required_jobs(selection.application_selection(), arch_retired=True)


@pytest.mark.parametrize("force,labels", [(True, ()), (False, ("ci:full",))])
def test_force_and_live_full_label_select_all_gates(force, labels):
    assert all(selection.select(["docs/guide.md"], force=force, labels=labels)["selection"].values())


def test_sanitizer_inventory_is_exactly_workflows_authoritative_filter():
    assert selection.select(["native/example.cpp"])["sanitizers"] is True
    assert selection.select(["docs/guide.md"])["sanitizers"] is False
    assert selection.select(["native/example.cpp"])["sanitizer_paths"] == list(selection.sanitizer_paths())


def test_bad_closure_or_workflow_inventory_fails_closed(tmp_path):
    with pytest.raises(ValueError, match="candidate gate"):
        selection.closure({"macos": True})
    paths = tmp_path / ".github/workflows"
    paths.mkdir(parents=True)
    (paths / "native-sanitizers.yml").write_text('"on": {pull_request: {paths: []}}')
    with pytest.raises(ValueError, match="sanitizer path"):
        selection.sanitizer_paths(tmp_path)


def test_live_label_lookup_uses_current_paginated_api_and_propagates_errors():
    calls = []

    def api(repository, route):
        calls.append((repository, route))
        return [{"name": "other"}] * 100 if route.endswith("page=1") else [{"name": "ci:full"}]

    assert selection.live_labels("owner/repo", 17, api=api) == {"other", "ci:full"}
    assert calls[-1] == ("owner/repo", "issues/17/labels?per_page=100&page=2")
    with pytest.raises(ValueError, match="positive PR"):
        selection.live_labels("--invalid", 0, api=api)
    with pytest.raises(ValueError, match="Malformed"):
        selection.live_labels("owner/repo", 17, api=lambda *args: {})


def test_checksum_frozen_50_pr_replay_preserves_every_known_escape():
    raw = FIXTURE.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == FIXTURE.with_suffix(".sha256").read_text().split()[0]
    report = selection.replay(json.loads(raw))
    assert report["count"] == 50
    assert selection.KNOWN_ESCAPES.issubset({pr["number"] for pr in report["prs"]})
    assert all(pr["candidate"]["permits_skipping"] is False for pr in report["prs"])


@pytest.mark.parametrize("fault", ["schema", "missing", "duplicate", "escape", "files", "unmerged"])
def test_incomplete_or_foreign_replay_cannot_pass(fault):
    snapshot = json.loads(FIXTURE.read_bytes())
    if fault == "schema":
        snapshot["schema"] = 2
    elif fault == "missing":
        snapshot["prs"].pop()
    elif fault == "duplicate":
        snapshot["prs"][-1] = copy.deepcopy(snapshot["prs"][0])
    elif fault == "escape":
        next(pr for pr in snapshot["prs"] if pr["number"] == 102)["number"] = 999
    elif fault == "files":
        snapshot["prs"][0]["files"].pop()
    else:
        snapshot["prs"][0]["mergedAt"] = None
    with pytest.raises(ValueError):
        selection.replay(snapshot)


def test_candidate_and_production_have_same_gate_schema():
    assert set(selection.GATES) == set(ci_changes.GATES)


def test_reference_audit_covers_every_real_workflow_and_action_input():
    owners = selection.referenced_owners()
    assert {row["path"] for row in owners}.issuperset({"tools/ci_changes.py", "tools/build.sh", "tools/ci_package_sandbox.sh"})
    assert all(row["jobs"] or row["rule"] in {"editorial", "portable-quality", "maintenance"} for row in owners)


def test_replay_rejects_a_known_escape_that_would_lose_acceptance():
    snapshot = json.loads(FIXTURE.read_bytes())
    row = next(pr for pr in snapshot["prs"] if pr["number"] == 102)
    row["files"] = [{"filename": "docs/incorrectly-classified.md"}]
    row["changedFiles"] = 1
    with pytest.raises(ValueError, match="Historical escape"):
        selection.replay(snapshot)


def test_unsupported_sanitizer_path_syntax_and_api_errors_fail_closed(tmp_path):
    path = tmp_path / ".github/workflows/native-sanitizers.yml"
    path.parent.mkdir(parents=True)
    path.write_text('  pull_request:\n    paths:\n      - 17\n')
    with pytest.raises(ValueError, match="sanitizer path"):
        selection.sanitizer_paths(tmp_path)
    def unavailable(*args):
        raise RuntimeError("transport unavailable")
    with pytest.raises(RuntimeError, match="transport unavailable"):
        selection.live_labels("owner/repo", 1, api=unavailable)


def test_replay_cli_requires_correct_frozen_checksum_and_writes_report(tmp_path, monkeypatch):
    output = tmp_path / "out/report.json"
    args = ["selection", "--replay", str(FIXTURE), "--sha256", "wrong", "--output", str(output)]
    monkeypatch.setattr(sys, "argv", args)
    with pytest.raises(SystemExit, match="2"):
        selection.main()
    args[4] = FIXTURE.with_suffix(".sha256").read_text().split()[0]
    selection.main()
    assert json.loads(output.read_text())["count"] == 50


def test_live_full_label_broadens_real_classifier_cli_after_event_snapshot(tmp_path, monkeypatch):
    output = tmp_path / "selection.json"
    monkeypatch.setattr(sys, "argv", ["changes", "--base", "a" * 40, "--pull-request", "17", "--repository", "owner/repo", "--json-output", str(output)])
    monkeypatch.setattr(ci_changes.subprocess, "check_output", lambda *args, **kwargs: b"docs/guide.md\0")
    monkeypatch.setattr(ci_changes.subprocess, "run", lambda *args, **kwargs: None)
    calls = []
    def labels(repository, number):
        calls.append((repository, number))
        return {"ci:full"}
    monkeypatch.setattr(selection, "live_labels", labels)
    ci_changes.main()
    report = json.loads(output.read_text())
    assert calls == [("owner/repo", 17)]
    assert report["force"] is True and all(report["selection"].values())
    assert report["candidate"]["mode"] == "observe-only"


@pytest.mark.parametrize("ref,event,force", [("refs/pull/999/merge", "pull_request", True), ("refs/heads/main", "workflow_dispatch", False), ("refs/heads/main", "push", True), ("refs/heads/main", "workflow_dispatch", True)])
def test_candidate_cli_is_main_only_full_qualification(tmp_path, monkeypatch, ref, event, force):
    output = tmp_path / "selection.json"
    arguments = ["changes", "--base", "a" * 40, "--candidate", "--json-output", str(output)]
    if force:
        arguments.append("--force")
    monkeypatch.setattr(sys, "argv", arguments)
    monkeypatch.setenv("GITHUB_REF", ref)
    monkeypatch.setenv("GITHUB_EVENT_NAME", event)
    monkeypatch.setattr(ci_changes.subprocess, "check_output", lambda *args, **kwargs: b"docs/guide.md\0")
    monkeypatch.setattr(ci_changes.subprocess, "run", lambda *args, **kwargs: None)
    if ref == "refs/heads/main" and event == "workflow_dispatch" and force:
        ci_changes.main()
        assert json.loads(output.read_text())["qualification_mode"] is True
    else:
        with pytest.raises(ValueError, match="reviewed-main full"):
            ci_changes.main()


def test_full_candidate_uses_qualified_retirement_without_narrowing_selected_suites(tmp_path, monkeypatch):
    def output(command, **kwargs):
        return "a" * 40 + "\n" if command[1] == "rev-parse" else b"docs/guide.md\0"
    monkeypatch.setattr(ci_changes.subprocess, "check_output", output)
    monkeypatch.setattr(ci_changes.subprocess, "run", lambda *args, **kwargs: None)
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "schedule")
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "outputs"))
    def activated(report, **kwargs):
        assert report["qualification_mode"] and report["force"]
        assert all(report["selection"].values())
        report["arch_retired"] = True
        return report
    monkeypatch.setattr(ci_changes, "activate_report", activated)
    monkeypatch.setattr(sys, "argv", ["changes", "--base", "HEAD", "--force", "--candidate", "--activate", "--json-output", str(tmp_path / "selection.json")])
    ci_changes.main()
    report = json.loads((tmp_path / "selection.json").read_text())
    assert report["arch_retired"] and all(report["selection"].values())
    assert "arch_retired=true" in (tmp_path / "outputs").read_text()
