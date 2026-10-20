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
        ".github/workflows/macos.yml",
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


def test_qualified_plan_controls_phase_steps_but_preserves_acceptance_jobs():
    workflow = parse_workflow((ROOT / ".github/workflows/macos.yml").read_text())
    steps = workflow["jobs"]["changes"]["steps"]
    observer = next(
        step for step in steps if "ci_acceptance_plan.py" in step.get("run", "")
    )
    assert observer["env"]["EVENT"] == "${{ github.event_name }}"
    assert "--activate" in observer["run"]
    assert "continue-on-error" not in observer
    upload = next(
        step
        for step in steps
        if step.get("with", {}).get("path") == "test-results/acceptance-selection.json"
    )
    assert upload["if"] == "always()"
    assert upload["continue-on-error"] is True
    assert upload["with"]["overwrite"] is True
    assert upload["with"]["if-no-files-found"] == "error"
    assert all(
        "proposed" not in value and "acceptance-selection" not in value
        for value in workflow["jobs"]["changes"]["outputs"].values()
    )
    for phase in ("cpu", "audio", "deb"):
        job = workflow["jobs"]["acceptance-" + phase]
        assert "needs.linux-build.result == 'success'" in job["if"]
        assert "proposed" not in job["if"] and "acceptance-selection" not in job["if"]
        run = next(
            step
            for step in job["steps"]
            if step.get("run") == "bash tools/linux_acceptance.sh " + phase
        )
        assert "if" not in run
    commands = (ROOT / "tools/linux_acceptance.sh").read_text()
    for command in (
        "--suite models",
        "tools/accept_software_gpu.py",
        "--suite virtual-audio",
    ):
        assert commands.count(command) == 1, (
            f"Expected one acceptance command: {command}"
        )
    assert "CPU_MODELS_SELECTED" in commands and "SOFTWARE_GPU_SELECTED" in commands
    assert "VIRTUAL_AUDIO_SELECTED" in commands
    assert "test-debian.sh" in commands
    assert '"${ACCEPTANCE_FULL:-false}" == true' in commands
    assert '"${PACKAGING_SELECTED:-false}" == true' in commands


@pytest.mark.parametrize("event,force", [("schedule", False), ("push", False), ("workflow_dispatch", False), ("pull_request", True)])
def test_non_pr_and_forced_acceptance_never_narrows(event, force):
    def must_not_authorize(*args, **kwargs):
        raise AssertionError("Full backstop must not depend on index availability")
    result = selection.activate(selection.plan(["docs/example.md"], event), source="a" * 40, repository="example/repo", force=force, capability=must_not_authorize)
    assert all(result["executed"].values())


def test_phase_narrowing_needs_independent_four_week_capability():
    calls = []
    def qualified(*args, **kwargs):
        calls.append((args, kwargs))
    value = selection.plan(["tools/accept_software_gpu.py"])
    result = selection.activate(value, source="a" * 40, repository="example/repo", capability=qualified)
    assert result["permits_skipping"] is True
    assert result["executed"] == {"cpu-models": False, "software-gpu": True, "virtual-audio": False}
    assert calls[0][0] == ("acceptance_narrowing", "a" * 40)
    def missing(*args, **kwargs):
        raise ValueError("Four weeks have not passed")
    result = selection.activate(selection.plan(["docs/example.md"]), source="a" * 40, repository="example/repo", capability=missing)
    assert all(result["executed"].values())


def test_complete_acceptance_replay_uses_reviewed_frozen_inventory():
    inventory = json.loads((ROOT / "tests/fixtures/ci-selector-50-prs.json").read_text())
    result = selection.replay(inventory)
    assert result["count"] == 50
    assert result["known_escapes"] == [102, 110, 112, 119, 137, 144]
    assert all(all(row["plan"]["proposed"].values()) for row in result["prs"] if row["number"] in result["known_escapes"])


@pytest.mark.parametrize("suite,env", [("cpu", {"CPU_MODELS_SELECTED": "false"}), ("audio", {"SOFTWARE_GPU_SELECTED": "false", "VIRTUAL_AUDIO_SELECTED": "false"})])
def test_qualified_empty_phase_set_avoids_all_docker_work(tmp_path, suite, env):
    result = subprocess.run(["bash", str(ROOT / "tools/linux_acceptance.sh"), suite], cwd=tmp_path, env={**os.environ, **env, "VERSION": "1.0"}, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Qualified phase omission" in (tmp_path / f"test-results/acceptance-{suite}/selection.txt").read_text()
