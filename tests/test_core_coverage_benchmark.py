"""Exercise the real shell gate without downloading or compiling an SDK."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from tests.test_pull_request_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]


def test_hosted_benchmark_is_manual_macos_only_and_preserves_both_coverage_gates():
    def workflow(name):
        return parse_workflow((ROOT / ".github/workflows" / name).read_text())

    parent = workflow("macos.yml")
    dispatch = parent["on"]["workflow_dispatch"]["inputs"]["core_coverage_benchmark"]
    assert dispatch["type"] == "boolean"
    assert dispatch["default"] is False
    caller = parent["jobs"]["macos-stages"]
    assert (
        caller["with"]["core_coverage_benchmark"]
        == "${{ inputs.core_coverage_benchmark || false }}"
    )
    macos = workflow("macos-platform-stages.yml")
    linux = workflow("linux-platform-stages.yml")
    assert (
        macos["on"]["workflow_call"]["inputs"]["core_coverage_benchmark"]["default"]
        is False
    )
    assert macos["env"]["FORESIGHT_COVERAGE"] == "1"
    assert macos["env"]["FORESIGHT_CORE_COVERAGE_MIN"] == "90"
    assert "FORESIGHT_COVERAGE" not in linux["env"]
    assert (
        linux["on"]["workflow_call"]["inputs"]["core_coverage_benchmark"]["default"]
        is False
    )
    assert (
        parent["jobs"]["linux-native"]["with"]["core_coverage_benchmark"]
        == "${{ inputs.core_coverage_benchmark || false }}"
    )
    for config in (macos, linux):
        assert "FORESIGHT_CORE_COVERAGE_BENCHMARK" not in config["env"]
        for name, job in config["jobs"].items():
            for step in job.get("steps", []):
                setting = step.get("env", {}).get("FORESIGHT_CORE_COVERAGE_BENCHMARK")
                if (
                    config == macos
                    and name == "core-macos"
                    and step.get("id") == "stage"
                ):
                    assert (
                        setting == "${{ inputs.core_coverage_benchmark && '1' || '0' }}"
                    )
                else:
                    assert setting is None
                if (
                    config == linux
                    and name == "core-linux"
                    and step.get("id") == "stage"
                ):
                    assert (
                        step["env"]["FORESIGHT_COVERAGE"]
                        == "${{ inputs.core_coverage_benchmark && '1' || '0' }}"
                    )
                    assert step["env"]["FORESIGHT_CORE_COVERAGE_MIN"] == "90"


@pytest.fixture
def gate(tmp_path):
    root = tmp_path / "repo"
    (root / "tools").mkdir(parents=True)
    (root / "packages/foresight_core").mkdir(parents=True)
    (root / "apps/desktop").mkdir(parents=True)
    for name in (
        "build_dart_gates.sh",
        "ci_timing.sh",
        "coverage_core.sh",
        "check_coverage.py",
        "compare_test_runs.py",
    ):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    binary = tmp_path / "bin"
    binary.mkdir()
    dart = binary / "dart"
    dart.write_text(
        f"#!{sys.executable}\n"
        + """import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['COMMANDS'], 'a') as stream:
    stream.write(json.dumps({'args': args, 'tool': sys.argv[0], 'native': os.getenv('FORESIGHT_NATIVE_LIBRARY'),
                             'helper': os.getenv('FORESIGHT_HELPER')}) + '\\n')
if args[0] == 'analyze':
    sys.exit(int(os.getenv('ANALYSIS_EXIT', '0')))
if args[0] == 'test':
    coverage = any(arg.startswith('--coverage=') for arg in args)
    code = int(os.getenv('COVERED_EXIT' if coverage else 'PLAIN_EXIT', '0'))
    if code:
        sys.exit(code)
    for arg in args:
        if arg.startswith('--file-reporter=json:'):
            output = pathlib.Path(arg.split('json:', 1)[1])
            skipped = coverage and os.getenv('CHANGED_SKIP') == '1'
            events = [
                {'type': 'suite', 'suite': {'id': 1, 'path': 'test/example_test.dart'}},
                {'type': 'testStart', 'test': {'id': 2, 'suiteID': 1, 'name': 'example'}},
                {'type': 'testDone', 'testID': 2, 'result': 'success',
                 'skipped': skipped, 'hidden': False},
                {'type': 'done', 'success': True},
            ]
            output.write_text(''.join(json.dumps(e) + '\\n' for e in events))
elif args[:2] == ['run', 'coverage:format_coverage']:
    output = pathlib.Path(next(arg.split('=', 1)[1] for arg in args if arg.startswith('--out=')))
    covered = int(os.getenv('COVERED_LINES', '9'))
    output.write_text('SF:lib/example.dart\\n' + ''.join(
        f'DA:{i + 1},{int(i < covered)}\\n' for i in range(10)) + 'end_of_record\\n')
"""
    )
    dart.chmod(0o700)
    shutil.copy2(dart, binary / "flutter")
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("FORESIGHT_")
    }
    environment.update(
        PATH=f"{binary}:{os.defpath}", COMMANDS=str(tmp_path / "commands")
    )
    return root, environment


def run(gate, platform="linux", stage="core", **settings):
    root, environment = gate
    result = subprocess.run(
        [
            "bash",
            str(root / "tools/build_dart_gates.sh"),
            stage,
            platform,
            str(root / "build"),
            sys.executable,
        ],
        env={**environment, **settings},
        capture_output=True,
        text=True,
        timeout=30,
    )
    commands = [
        json.loads(line)
        for line in Path(environment["COMMANDS"]).read_text().splitlines()
    ]
    return result, commands


@pytest.mark.parametrize("coverage", ["0", "1"])
def test_default_runs_full_suite_once_and_keeps_native_and_hook_gates(gate, coverage):
    result, commands = run(
        gate, FORESIGHT_COVERAGE=coverage, FORESIGHT_CORE_COVERAGE_MIN="90"
    )
    assert result.returncode == 0, result.stdout + result.stderr
    tests = [command for command in commands if command["args"][0] == "test"]
    assert len(tests) == 1
    assert not any(arg.endswith(".dart") for arg in tests[0]["args"])
    assert any(arg.startswith("--coverage=") for arg in tests[0]["args"]) == (
        coverage == "1"
    )
    assert tests[0]["native"].endswith("build/native/libforesight_native.so")
    assert tests[0]["helper"].endswith("build/services/helper/ForesightHelper")
    assert any(
        command["args"][0] == "-DFORESIGHT_ENABLE_TEST_HOOKS=true"
        for command in commands
    )
    assert sum(command["args"][:2] == ["compile", "exe"] for command in commands) == 2


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_benchmark_runs_both_full_suites_and_preserves_coverage_threshold(
    gate, platform
):
    result, commands = run(gate, platform, FORESIGHT_CORE_COVERAGE_BENCHMARK="1")
    assert result.returncode == 0, result.stdout + result.stderr
    tests = [command for command in commands if command["args"][0] == "test"]
    assert len(tests) == 2
    assert not any(arg.startswith("--coverage=") for arg in tests[0]["args"])
    assert any(arg.startswith("--coverage=") for arg in tests[1]["args"])
    assert "minimum 90%" in result.stdout
    assert "Core benchmark matched: 1 passed, 0 skipped" in result.stdout


def test_benchmark_uses_the_same_overridden_dart_and_supplied_python(gate):
    _, environment = gate
    binary = Path(environment["PATH"].split(":")[0])
    override = binary / "alternate dart"
    shutil.copy2(binary / "dart", override)
    result, commands = run(
        gate,
        FORESIGHT_CORE_COVERAGE_BENCHMARK="1",
        FORESIGHT_DART=str(override),
        FORESIGHT_PYTHON="/missing/inherited-python",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    tests = [command for command in commands if command["args"][0] == "test"]
    assert len(tests) == 2
    assert all(command["tool"] == str(override) for command in tests)
    formatter = next(
        command
        for command in commands
        if command["args"][:2] == ["run", "coverage:format_coverage"]
    )
    assert formatter["tool"] == str(override)


def test_repeated_plain_and_benchmark_runs_keep_only_current_event_streams(gate):
    root, _ = gate
    reports = root / "test-results/linux/core"
    for settings, expected in [
        ({}, {"core.events.jsonl"}),
        (
            {"FORESIGHT_CORE_COVERAGE_BENCHMARK": "1"},
            {"plain.events.jsonl", "coverage.events.jsonl"},
        ),
        ({}, {"core.events.jsonl"}),
    ]:
        result, _ = run(gate, **settings)
        assert result.returncode == 0, result.stdout + result.stderr
        assert {path.name for path in reports.glob("*.events.jsonl")} == expected


@pytest.mark.parametrize("stage", ["core", "desktop"])
def test_failed_analysis_removes_only_current_stage_old_events(gate, stage):
    root, _ = gate
    reports = root / f"test-results/linux/{stage}"
    reports.mkdir(parents=True)
    (reports / "old.events.jsonl").write_text("old execution")
    (reports / "diagnostic.log").write_text("preserved diagnostic")
    sibling = root / "test-results/macos" / stage / "old.events.jsonl"
    sibling.parent.mkdir(parents=True)
    sibling.write_text("other platform")
    result, _ = run(gate, stage=stage, ANALYSIS_EXIT="7")
    assert result.returncode == 7
    assert not list(reports.glob("*.events.jsonl"))
    assert (reports / "diagnostic.log").read_text() == "preserved diagnostic"
    assert sibling.read_text() == "other platform"


@pytest.mark.parametrize(
    "settings,expected",
    [
        ({"PLAIN_EXIT": "7"}, "exit 7"),
        ({"COVERED_EXIT": "8"}, "exit 8"),
        ({"COVERED_LINES": "8"}, "minimum 90%"),
        ({"CHANGED_SKIP": "1"}, "changed test identities or skip outcomes"),
    ],
)
def test_failed_baseline_coverage_or_outcome_comparison_stops_compilation(
    gate, settings, expected
):
    result, commands = run(gate, FORESIGHT_CORE_COVERAGE_BENCHMARK="1", **settings)
    assert result.returncode != 0
    assert expected in result.stdout + result.stderr
    assert all(command["args"][0] != "compile" for command in commands)
