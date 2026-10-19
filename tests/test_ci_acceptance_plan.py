"""Acceptance proposals never skip validation; unknown dependencies select all."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from tools import ci_acceptance_plan as selection
from tests.test_pull_request_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "name",
    [
        "native/foresight_native.cpp",
        "services/inference/main.cpp",
        "services/speech/worker.cpp",
        "services/helper/main.cpp",
        "packages/foresight_core/lib/src/answer_retrieval.dart",
        "packages/foresight_core/lib/src/recording.dart",
        "packages/foresight_core/lib/src/service.dart",
        "packages/foresight_test_support/lib/remote_service.dart",
        "apps/desktop/lib/main.dart",
        "apps/desktop/pubspec.lock",
        "tools/integration_gates.py",
        "tools/ci_acceptance_plan.py",
        ".github/workflows/integration-acceptance.yml",
        "packaging/notices/runtime.md",
        "unknown/new-runtime",
        "../docs/deceptive.md",
    ],
)
def test_runtime_shared_unknown_and_invalid_inputs_select_every_phase(name):
    report = selection.plan([name])
    assert all(report["proposed"].values())
    assert report["permits_skipping"] is False


@pytest.mark.parametrize("phase", selection.PHASES)
def test_suite_entry_points_are_audited_individually(phase):
    for name in selection.SUITE_INPUTS[phase]:
        assert (ROOT / name).is_file(), name
        report = selection.plan([name])
        assert report["proposed"] == {
            candidate: candidate == phase for candidate in selection.PHASES
        }
        assert report["mode"] == "observe-only"


def test_mixed_changes_union_their_dependencies():
    report = selection.plan(
        [
            "docs/platforms/ci-performance.md",
            "apps/desktop/test/live_recording_test.dart",
            "tools/accept_software_gpu.py",
        ]
    )
    assert report["proposed"] == {
        "cpu-models": False,
        "software-gpu": True,
        "virtual-audio": True,
    }


@pytest.mark.parametrize(
    "event", ["schedule", "workflow_dispatch", "workflow_run", "push"]
)
def test_main_and_manual_and_nightly_backstops_are_always_full(event):
    assert all(selection.plan(["docs/README.md"], event)["proposed"].values())


def test_cli_diff_covers_rename_and_deleted_inputs_without_external_history(tmp_path):
    repo = tmp_path / "fixture"
    repo.mkdir()
    env = {
        **os.environ,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_SYSTEM": os.devnull,
    }

    def git(*args):
        return subprocess.check_output(
            ["git", "-C", str(repo), *args], env=env, timeout=30, text=True
        ).strip()

    git("init", "-q")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "user.name", "Fixture")
    (repo / "runtime.cpp").write_text("shared code")
    git("add", ".")
    git("commit", "-qm", "fixed baseline")
    fork = git("rev-parse", "HEAD")
    (repo / "unrelated-main-runtime.cpp").write_text("new main-only dependency")
    git("add", ".")
    git("commit", "-qm", "main advances independently")
    base = git("rev-parse", "HEAD")
    git("checkout", "-qb", "fixture-pr", fork)
    (repo / "docs").mkdir()
    git("mv", "runtime.cpp", "docs/renamed.md")
    git("commit", "-qm", "move runtime")
    report = tmp_path / "report.json"
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "tools/ci_acceptance_plan.py"),
            "--root",
            str(repo),
            "--base",
            base,
            "--event",
            "pull_request",
            "--output",
            str(report),
        ],
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )
    assert result.returncode == 0, result.stderr
    parsed = json.loads(report.read_text())
    assert parsed["changed_paths"] == ["docs/renamed.md", "runtime.cpp"]
    assert all(parsed["proposed"].values())
    assert parsed == json.loads(result.stdout)


def test_missing_git_observer_still_records_full_proposal(tmp_path):
    output = tmp_path / "report.json"
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "tools/ci_acceptance_plan.py"),
            "--root",
            str(tmp_path),
            "--base",
            "a" * 40,
            "--event",
            "pull_request",
            "--output",
            str(output),
        ],
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, "PATH": str(tmp_path)},
    )
    assert result.returncode == 0, result.stderr
    report = json.loads(output.read_text())
    assert all(report["proposed"].values())
    assert report["permits_skipping"] is False


@pytest.mark.parametrize("base", ["", "0" * 40, "a" * 40])
def test_missing_or_unavailable_history_cannot_propose_skips(tmp_path, base):
    output = tmp_path / "report.json"
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "tools/ci_acceptance_plan.py"),
            "--root",
            str(tmp_path),
            "--base",
            base,
            "--event",
            "pull_request",
            "--output",
            str(output),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    report = json.loads(output.read_text())
    assert all(report["proposed"].values())
    assert report["permits_skipping"] is False


def test_observer_is_uploaded_and_never_controls_phase_execution():
    workflow = parse_workflow(
        (ROOT / ".github/workflows/integration-acceptance.yml").read_text()
    )
    assert workflow["on"]["schedule"] == [{"cron": "43 5 * * *"}]
    steps = workflow["jobs"]["changes"]["steps"]
    observer = next(
        step for step in steps if "ci_acceptance_plan.py" in step.get("run", "")
    )
    assert observer["env"]["EVENT"] == "${{ github.event_name }}"
    assert observer["continue-on-error"] is True
    upload = next(
        step for step in steps if "actions/upload-artifact@" in step.get("uses", "")
    )
    assert upload["if"] == "always()"
    assert upload["continue-on-error"] is True
    assert upload["with"]["path"] == "test-results/acceptance-selection.json"
    outputs = workflow["jobs"]["changes"]["outputs"]
    assert set(outputs) == {"linux_bundle"}
    phases = workflow["jobs"]["ubuntu-package"]["steps"]
    for name in (
        "Real CPU model, helper, citation and cancellation gates",
        "Shipped GPU runtimes on software Vulkan",
        "Private virtual-audio and device-recovery gates",
    ):
        step = next(step for step in phases if step.get("name") == name)
        assert (
            step["if"]
            == "${{ !cancelled() && steps.acceptance-image.outcome == 'success' && steps.fixtures.outcome == 'success' }}"
        )
