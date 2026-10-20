"""Candidate WS3 rules preserve required owners without narrowing production."""

import copy
import hashlib
import json
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
    ("tests/test_dmg_contract.py", "host-contract", {"dmg"}, {"linux-build"}),
    ("tests/test_app_dependency_cmake.py", "host-contract", {"macos", "linux-build"}, set()),
    ("tests/test_rpm_scriptlets.py", "host-contract", {"packaging", "linux-build", "dmg"}, set()),
    ("packaging/acceptance.Dockerfile", "acceptance-input", {"linux-build", "linux-test"}, {"macos", "packaging"}),
    ("packaging/minimal-grpc.cmake", "native-sdk-input", {"macos", "linux-build"}, {"packaging"}),
    (".github/workflows/release.yml", "release-control", {"linux-build", "packaging"}, {"macos"}),
    ("tools/ci_package_sandbox.sh", "package-input", {"linux-build", "packaging", "linux-document-imports"}, {"macos"}),
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
