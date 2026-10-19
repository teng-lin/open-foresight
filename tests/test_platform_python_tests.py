"""One full Python coverage gate retains explicit platform execution ownership."""

import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace

import pytest

from tools import platform_python_tests as contracts

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def repository(tmp_path):
    for name in set(contracts.SHARED).union(
        *contracts.PLATFORM.values(), contracts.QUALITY_ONLY
    ):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("")
    (tmp_path / "pytest-exclusions.json").write_text("{}")
    return tmp_path


def test_repository_platform_inventory_is_complete():
    contracts.inventory()
    assert all(reason.strip() for reason in contracts.QUALITY_ONLY.values())


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_focused_commands_keep_all_assigned_host_contracts_and_junit(platform):
    command = contracts.command(platform)
    assert command[:3] == [contracts.sys.executable, "-m", "pytest"]
    assert set(contracts.SHARED + contracts.PLATFORM[platform]) <= set(command)
    assert set(contracts.QUALITY_ONLY).isdisjoint(command)
    assert f"--junitxml=coverage/python/{platform}-contracts.xml" in command
    assert "-ra" in command
    assert "--cov" not in command  # Full coverage remains the quality job's gate.


@pytest.mark.parametrize(
    "source,sensitive",
    [
        ("result.name", False),
        ("os.name", True),
        ("import os\nos.name", True),
        ("import os as host_os\nhost_os.name", True),
        ("import pathlib, os as host_os\nhost_os.name", True),
        ("import os as first_os, os as second_os\nsecond_os.name", True),
        ("import os as host_os\nresult.name", False),
        ("import os as host_os\nhost_os.path", False),
        ("import pathlib as host_os\nhost_os.name", False),
        ("import os as host_os, pathlib as paths\npaths.name", False),
        ("sys.platform", True),
        ("platform.machine()", True),
        ("platform.uname()", True),
        ("shutil.which('cmake')", True),
        ("pytest.mark.skipif(True)", True),
        ("unittest.skipUnless(True)", True),
        ("self.skipTest('device required')", True),
        ("pytest.importorskip('native_extension')", True),
        ("raise unittest.SkipTest('host tool unavailable')", True),
        ("raise SkipTest('host tool unavailable')", True),
        ("which('cmake')", True),
        ("from shutil import which as find_tool", True),
        ("from sys import platform as host", True),
        ("from os import name as system_name", True),
        ("from pathlib import Path", False),
    ],
)
def test_inventory_recognizes_host_and_tool_conditions(tmp_path, source, sensitive):
    path = tmp_path / "probe.py"
    path.write_text(source)
    assert contracts.host_sensitive(path) == sensitive


@pytest.mark.parametrize(
    "probe",
    [
        "sys.platform",
        "shutil.which('cmake')",
        "os.name",
        "import os as host_os\nhost_os.name",
    ],
)
def test_unassigned_host_contract_fails_closed(repository, probe):
    (repository / "tests/test_new.py").write_text(probe)
    with pytest.raises(ValueError, match="Assign host-sensitive.*test_new.py"):
        contracts.inventory(repository)


def test_existing_external_suite_ownership_is_not_reassigned(repository):
    name = "tests/integration/test_native.py"
    path = repository / name
    path.parent.mkdir(parents=True)
    path.write_text("sys.platform")
    (repository / "pytest-exclusions.json").write_text(
        json.dumps({name: "CTest owns this"})
    )
    contracts.inventory(repository)


def test_removed_assigned_contract_fails_instead_of_silently_shrinking_suite(
    repository,
):
    name = contracts.SHARED[0]
    (repository / name).unlink()
    with pytest.raises(ValueError, match="Missing platform Python contracts"):
        contracts.inventory(repository)


@pytest.mark.parametrize("status", [0, 7])
def test_runner_preserves_pytest_exit_status_and_subprocess_output(monkeypatch, status):
    commands = []
    monkeypatch.setattr(contracts.sys, "argv", ["contracts", "--platform", "macos"])

    def run(command, **kwargs):
        commands.append((command, kwargs))
        return SimpleNamespace(returncode=status)

    monkeypatch.setattr(contracts.subprocess, "run", run)
    with pytest.raises(SystemExit) as result:
        contracts.main()
    assert result.value.code == status
    command, options = commands[0]
    assert command == contracts.command("macos")
    assert options == {"cwd": ROOT, "timeout": 1800}


def test_full_quality_coverage_is_the_unchanged_authoritative_gate():
    import yaml

    quality = yaml.safe_load((ROOT / ".github/workflows/quality.yml").read_text())
    full = next(
        step["run"]
        for step in quality["jobs"]["python"]["steps"]
        if "--cov-config" in step.get("run", "")
    )
    assert full.startswith("python -m pytest --cov --cov-config=.coveragerc")
    assert "test_" not in full
    assert "fail_under = 95" in (ROOT / ".coveragerc").read_text()


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_platform_workflows_run_host_contracts_instead_of_full_python_suite(platform):
    import yaml

    workflow = yaml.safe_load(
        (ROOT / f".github/workflows/{platform}-platform-stages.yml").read_text()
    )
    steps = workflow["jobs"][f"native-{platform}"]["steps"]
    commands = [step.get("run", "") for step in steps]
    assert (
        sum(
            f"tools/platform_python_tests.py --platform {platform}" in run
            for run in commands
        )
        == 1
    )
    assert not any("tools/coverage.sh" in run for run in commands)
    assert not any("-m pytest" in run for run in commands)
    if platform == "macos":
        assert "tests/test_macos_tools.py" in contracts.command(platform)


def test_workflow_lint_runs_alongside_platform_jobs_without_blocking_selection():
    import yaml

    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    assert "needs" not in jobs["workflow-lint"]
    lint = jobs["workflow-lint"]["steps"]
    assert lint[-2]["run"] == "command -v shellcheck"
    assert lint[-1]["run"] == "go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7"
    assert not any(
        "actionlint" in step.get("run", "") for step in jobs["changes"]["steps"]
    )

    def ancestors(name):
        needs = jobs[name].get("needs", [])
        needs = [needs] if isinstance(needs, str) else needs
        return set(needs).union(*(ancestors(parent) for parent in needs))

    for name in (
        "macos-stages",
        "macos",
        "linux-native",
        "linux-document-imports",
        "linux-bundle",
        "packaging",
    ):
        assert "workflow-lint" not in ancestors(name)
    assert "workflow-lint" in jobs["platform-checks"]["needs"]
    assert jobs["platform-checks"]["if"] == "always()"


@pytest.mark.parametrize("status", ["success", "failure", "cancelled", "skipped", ""])
def test_required_aggregate_rejects_unsuccessful_lint_even_for_editorial_prs(status):
    import yaml

    from tools.ci_changes import select_gates

    job = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"][
        "platform-checks"
    ]
    step = job["steps"][-1]
    selected = select_gates(["docs/example.md"])
    results = {name: {"result": "skipped"} for name in job["needs"]}
    results["changes"] = {"result": "success"}
    results["workflow-lint"] = {"result": status}
    result = subprocess.run(
        ["bash", "-e", "-c", step["run"]],
        cwd=ROOT,
        env={
            **os.environ,
            "NEEDS": json.dumps(results),
            "SELECTION": json.dumps(selected),
            "MAIN": "false",
            "WORKFLOW_LINT": status,
        },
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert (result.returncode == 0) == (status == "success"), (
        result.stdout + result.stderr
    )
