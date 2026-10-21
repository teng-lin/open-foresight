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
        *contracts.PLATFORM.values(), contracts.QUALITY_ONLY, contracts.EXTERNAL
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
@pytest.mark.parametrize("isolated", [False, True])
def test_runner_preserves_pytest_exit_status_and_subprocess_output(
    monkeypatch, status, isolated, tmp_path
):
    commands = []
    extra = (
        [
            "--basetemp",
            str(tmp_path / "private pytest"),
            "--cache-dir",
            str(tmp_path / "private cache"),
        ]
        if isolated
        else []
    )
    monkeypatch.setattr(
        contracts.sys, "argv", ["contracts", "--platform", "macos", *extra]
    )

    def run(command, **kwargs):
        commands.append((command, kwargs))
        return SimpleNamespace(returncode=status)

    monkeypatch.setattr(contracts.subprocess, "run", run)
    monkeypatch.setattr(contracts, "verify_execution", lambda *args: None)
    with pytest.raises(SystemExit) as result:
        contracts.main()
    assert result.value.code == status
    command, options = commands[0]
    expected = (
        [
            "--basetemp",
            str(tmp_path / "private pytest"),
            "-o",
            "cache_dir=" + str(tmp_path / "private cache"),
        ]
        if isolated
        else []
    )
    assert command == [*contracts.command("macos"), *expected]
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

    filename = "macos.yml" if platform == "macos" else "linux-platform-stages.yml"
    workflow = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
    job = "macos" if platform == "macos" else "native-linux"
    steps = workflow["jobs"][job]["steps"]
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
        "macos",
        "linux-native",
        "linux-document-imports",
        "linux-build",
        "linux-test",
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


@pytest.mark.parametrize("mode", ["all", "skipped", "missing", "partial", "empty"])
def test_junit_execution_requires_each_assigned_file(tmp_path, monkeypatch, mode):
    monkeypatch.setattr(contracts, "SHARED", ("tests/test_one.py", "tests/test_two.py"))
    monkeypatch.setattr(contracts, "PLATFORM", {"linux": ()})
    path = tmp_path / "results.xml"
    cases = '<testcase classname="tests.test_one.Example"/>'
    if mode == "all":
        cases += '<testcase classname="tests.test_two"/>'
    elif mode == "skipped":
        cases += '<testcase classname="tests.test_two"><skipped/></testcase>'
    elif mode == "partial":
        cases += '<testcase classname="tests.test_two_extra"/>'
    elif mode == "empty":
        cases = ""
    path.write_text(f"<testsuites><testsuite>{cases}</testsuite></testsuites>")
    if mode == "all":
        contracts.verify_execution("linux", path)
    else:
        with pytest.raises(ValueError, match="absent or wholly skipped.*test_two.py"):
            contracts.verify_execution("linux", path)


def test_platform_lists_execute_once_under_required_aggregate():
    import yaml

    workflows = ROOT / ".github/workflows"
    main = yaml.safe_load((workflows / "macos.yml").read_text())

    def commands(workflow, name):
        job = workflow["jobs"][name]
        if "uses" in job and job["uses"].startswith("./.github/workflows/"):
            called = yaml.safe_load((ROOT / job["uses"]).read_text())
            return [
                step.get("run", "")
                for child in called["jobs"].values()
                for step in child.get("steps", [])
            ]
        runs = [step.get("run", "") for step in job.get("steps", [])]
        if name == "linux-test":
            assert any("build_linux_container.sh --test-only" in run for run in runs)
            # The sole required Linux test runner executes this transferred-tree
            # entrypoint, where platform inventory and actual JUnit audit run.
            runs.append((ROOT / "tools/linux_container_test.sh").read_text())
        return runs

    required = main["jobs"]["platform-checks"]["needs"]
    runs = [command for name in required for command in commands(main, name)]
    for platform in contracts.PLATFORM:
        assert sum(
            f"tools/platform_python_tests.py --platform {platform}" in run
            for run in runs
        ) == (2 if platform == "linux" else 1)
    # Ubuntu and retained Arch are distinct required host environments.
    assert "linux-native" in required
    assert "tests/test_rpm_scriptlets.py" not in contracts.command("linux")
    assert "tests/test_acceptance_image_cache.py" not in contracts.command("linux")
    fedora = (workflows / "package-contracts.yml").read_text()
    assert 'if [[ "$FORMAT" == rpm ]]' in fedora
    assert "-p test_rpm_scriptlets.py" in fedora
    acceptance = main
    steps = acceptance["jobs"]["linux-test"]["steps"]
    fixture = next(
        i
        for i, step in enumerate(steps)
        if "pytest tests/test_acceptance_image_cache.py" in step.get("run", "")
    )
    assert steps[fixture]["env"]["FORESIGHT_DOCKER_CACHE_TEST"] == "1"
    assert any(
        "build_linux_container.sh --test-only" in step.get("run", "")
        for step in steps[:fixture]
    )
    assert "FROM ${SDK_IMAGE}" in (ROOT / "packaging/ci-tooling.Dockerfile").read_text()
    assert "FROM ${TOOLING_IMAGE}" in (ROOT / "packaging/build.Dockerfile").read_text()
    assert (
        "ubuntu:24.04@sha256:" in (ROOT / "packaging/sdk-core.Dockerfile").read_text()
    )


def test_acceptance_weekly_and_pr_selection_uses_merge_base():
    text = (ROOT / ".github/workflows/macos.yml").read_text()
    assert 'BASE=$(git merge-base "$BASE" HEAD)' in text
    preview = (ROOT / ".github/workflows/preview-packages.yml").read_text()
    assert "cron: '23 7 * * *'" in preview
    assert 'tools/ci_preview_audit.py plan --source "$SOURCE"' in preview
    audit = (ROOT / "tools/ci_preview_audit.py").read_text()
    assert "if not full and audited_this_week(repository, now):" in audit
    assert "weekly-external-audit-completion-" in audit
    assert not (ROOT / ".github/workflows/integration-acceptance.yml").exists()


def test_loader_identity_retains_real_ctest_ownership():
    path = "tests/inference/test_litert_identity.py"
    assert path in contracts.EXTERNAL
    assert path not in contracts.SHARED
    source = (ROOT / "native/CMakeLists.txt").read_text()
    assert "add_test(NAME native_litert_identity" in source
    assert "../" + path in source
    assert "sentencepiece==0.2.1" in (ROOT / "requirements-dev.txt").read_text()
