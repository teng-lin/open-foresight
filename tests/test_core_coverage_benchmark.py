"""Exercise the real shell gate without downloading or compiling an SDK."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

from tests.test_pull_request_workflows import parse_workflow
from tests.test_build_stages import install_media_prerequisite_fixture

ROOT = Path(__file__).resolve().parents[1]
# Opaque fixture values: the worker helper alone owns the real define recipe.
WORKER_DEFINES = ["-DFIXTURE_WORKER=verified", "-DFIXTURE_ROOT=/a path/with spaces"]


def test_hosted_benchmark_is_linux_only_and_macos_nightly_coverage_is_report_only():
    parent = parse_workflow((ROOT / ".github/workflows/macos.yml").read_text())
    linux = parse_workflow(
        (ROOT / ".github/workflows/linux-platform-stages.yml").read_text()
    )
    assert (
        parent["on"]["workflow_dispatch"]["inputs"]["core_coverage_benchmark"][
            "default"
        ]
        is False
    )
    assert parent["on"]["workflow_call"]["inputs"]["macos_coverage"]["default"] is False
    macos = parent["jobs"]["macos"]
    assert (
        macos["env"]["FORESIGHT_COVERAGE"]
        == "${{ (inputs.tier == 'release' || inputs.macos_coverage) && github.event_name != 'pull_request' && '1' || '0' }}"
    )
    assert macos["env"]["FORESIGHT_CORE_COVERAGE_MIN"] == "0"
    assert "FORESIGHT_CORE_COVERAGE_BENCHMARK" not in str(macos)
    assert (
        parent["jobs"]["linux-native"]["with"]["core_coverage_benchmark"]
        == "${{ inputs.core_coverage_benchmark || false }}"
    )
    core = next(
        step
        for step in linux["jobs"]["core-linux"]["steps"]
        if step.get("id") == "stage"
    )
    assert (
        core["env"]["FORESIGHT_COVERAGE"]
        == "${{ inputs.core_coverage_benchmark && '1' || '0' }}"
    )
    assert core["env"]["FORESIGHT_CORE_COVERAGE_MIN"] == "90"


@pytest.fixture
def gate(tmp_path):
    root = tmp_path / "repo"
    (root / "tools").mkdir(parents=True)
    install_media_prerequisite_fixture(root)
    (root / "packages/foresight_core").mkdir(parents=True)
    (root / "apps/desktop").mkdir(parents=True)
    sqlite = root / "build/macos/libforesight_sqlite3.dylib"
    sqlite.parent.mkdir(parents=True)
    # The fake Dart/Flutter executable records selection without loading FFI.
    sqlite.write_bytes(b"application SQLite fixture")
    for name in (
        "build_dart_gates.sh",
        "ci_timing.sh",
        "coverage_core.sh",
        "run_core_tests.sh",
        "runtime_support_gate.sh",
        "check_coverage.py",
        "compare_test_runs.py",
        "verify_toolchain_pins.py",
        "pins.json",
    ):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    # The real receipt verifier and AOT worker builder need finished native
    # products and an SDK; tests/test_runtime_support_gate.py owns those. Here
    # they record the gate's exact CLI use and honor its exit/NUL-define contract.
    (root / "tools/diagnostic_product_receipt.py").write_text(
        """import json, os, sys
with open(os.environ['SUPPORT_COMMANDS'], 'a') as stream:
    stream.write(json.dumps({'tool': 'receipt', 'args': sys.argv[1:]}) + '\\n')
sys.exit(int(os.getenv('RECEIPT_EXIT', '0')))
"""
    )
    (root / "tools/build_diagnostic_worker.py").write_text(
        """import argparse, json, os, sys
parser = argparse.ArgumentParser()
for option in ('--root', '--build', '--sdk', '--package-config'):
    parser.add_argument(option, required=True)
parser.add_argument('--mode', required=True, choices=['aot'])
parser.add_argument('--defines-output')
parser.add_argument('--verify', action='store_true')
args = parser.parse_args()
with open(os.environ['SUPPORT_COMMANDS'], 'a') as stream:
    stream.write(json.dumps({'tool': 'worker', 'args': sys.argv[1:]}) + '\\n')
code = int(os.getenv('WORKER_EXIT', '0'))
if code:
    sys.exit(code)
defines = [] if os.getenv('WORKER_DEFINES') == 'empty' else json.loads(os.environ['WORKER_DEFINES'])
if args.defines_output:
    with open(args.defines_output, 'wb') as stream:
        stream.write(b''.join(value.encode() + b'\\0' for value in defines))
"""
    )
    binary = tmp_path / "bin"
    binary.mkdir()
    dart = binary / "dart"
    dart.write_text(
        f"#!{sys.executable}\n"
        + """import json, os, pathlib, sys
args = sys.argv[1:]
if len(args) == 1 and args[0].endswith('/locate.dart'):
    assert 'Platform.resolvedExecutable' in pathlib.Path(args[0]).read_text()
    print(pathlib.Path(__file__).resolve())
    sys.exit(0)
with open(os.environ['COMMANDS'], 'a') as stream:
    stream.write(json.dumps({'args': args, 'tool': sys.argv[0], 'native': os.getenv('FORESIGHT_NATIVE_LIBRARY'),
                             'helper': os.getenv('FORESIGHT_HELPER'),
                             'test_helper': os.getenv('FORESIGHT_TEST_HELPER'),
                             'sqlite': os.getenv('FORESIGHT_SQLITE_LIBRARY'),
                             'cache': os.getenv('FORESIGHT_BOUNDARY_ANALYSIS_CACHE'),
                             'cache_mode': (oct(pathlib.Path(os.environ['FORESIGHT_BOUNDARY_ANALYSIS_CACHE']).stat().st_mode & 0o777)
                                            if os.getenv('FORESIGHT_BOUNDARY_ANALYSIS_CACHE') else None),
                             'warmed': (pathlib.Path(os.environ['FORESIGHT_BOUNDARY_ANALYSIS_CACHE'], 'warmed').exists()
                                        if os.getenv('FORESIGHT_BOUNDARY_ANALYSIS_CACHE') else False)}) + '\\n')
if args[0] == 'analyze':
    sys.exit(int(os.getenv('ANALYSIS_EXIT', '0')))
if args == ['--version']:
    print('Dart SDK version: 3.9.2 (stable)')
    sys.exit(0)
if args == ['--version', '--machine']:
    print(json.dumps({'frameworkVersion': '3.35.7',
                      'frameworkRevision': 'adc901062556672b4138e18a4dc62a4be8f4b3c2',
                      'dartSdkVersion': '3.9.2'}))
    sys.exit(0)
if args == ['run', 'tool/warm_boundary_analysis.dart']:
    print('boundary warmer diagnostic', flush=True)
    code = int(os.getenv('WARM_EXIT', '0'))
    if code:
        sys.exit(code)
    pathlib.Path(os.environ['FORESIGHT_BOUNDARY_ANALYSIS_CACHE'], 'warmed').write_text('compiler bundles')
elif args[:2] == ['compile', 'exe']:
    output = pathlib.Path(args[args.index('-o') + 1])
    output.write_bytes(b'controlled compiled host')
    output.chmod(0o700)
elif args[0] == 'test':
    coverage = any(arg.startswith('--coverage=') for arg in args)
    code = int(os.getenv('COVERED_EXIT' if coverage else 'PLAIN_EXIT', '0'))
    if code:
        sys.exit(code)
    if '--coverage' in args:
        output = pathlib.Path('coverage/lcov.info')
        output.parent.mkdir(exist_ok=True)
        output.write_text('SF:lib/current.dart\\n' + ''.join(
            f'DA:{i + 1},{int(i < 9)}\\n' for i in range(10)) + 'end_of_record\\n')
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
        PATH=f"{binary}:{os.defpath}",
        COMMANDS=str(tmp_path / "commands"),
        SUPPORT_COMMANDS=str(tmp_path / "support-commands"),
        WORKER_DEFINES=json.dumps(WORKER_DEFINES),
        GITHUB_RUN_NUMBER="0",
        GITHUB_RUN_ATTEMPT="1",
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
    commands_path = Path(environment["COMMANDS"])
    assert commands_path.is_file(), (
        f"Gate invoked no Dart/Flutter command (exit {result.returncode}):\n"
        + result.stdout
        + result.stderr
    )
    commands = [json.loads(line) for line in commands_path.read_text().splitlines()]
    return result, commands


@pytest.mark.parametrize("coverage", ["0", "1"])
def test_default_runs_full_suite_once_and_keeps_native_and_hook_gates(gate, coverage):
    # The coverage wrapper selects runtime support for the executing host.
    platform = "macos" if sys.platform == "darwin" else "linux"
    result, commands = run(
        gate,
        platform=platform,
        FORESIGHT_COVERAGE=coverage,
        FORESIGHT_CORE_COVERAGE_MIN="90",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    tests = [command for command in commands if command["args"][0] == "test"]
    assert len(tests) == 1
    assert tests[0]["test_helper"] == str(
        gate[0] / "build/services/helper/ForesightHelperTest"
    )
    assert not any(arg.endswith(".dart") for arg in tests[0]["args"])
    assert any(arg.startswith("--coverage=") for arg in tests[0]["args"]) == (
        coverage == "1"
    )
    assert ("--coverage-package=^foresight_core$" in tests[0]["args"]) == (
        coverage == "1"
    )
    suffix = "dylib" if platform == "macos" else "so"
    assert tests[0]["native"] == str(
        gate[0] / f"build/native/libforesight_native.{suffix}"
    )
    assert tests[0]["helper"].endswith("build/services/helper/ForesightHelper")
    assert any(
        command["args"][0] == "-DFORESIGHT_ENABLE_TEST_HOOKS=true"
        for command in commands
    )
    compiled = [c["args"] for c in commands if c["args"][:2] == ["compile", "exe"]]
    assert [args[2:4] for args in compiled] == [WORKER_DEFINES, WORKER_DEFINES]
    root = gate[0].resolve()
    support = support_commands(gate)
    receipts = [row for row in support if row["tool"] == "receipt"]
    producer, worker = [row for row in support if row["tool"] == "worker"]
    assert [row["tool"] for row in support] == [
        "receipt",
        "worker",
        "worker",
        *(["receipt"] if coverage == "1" else []),
    ]
    # The coverage wrapper is a separate consumer and recomputes verification.
    assert receipts == [
        {
            "tool": "receipt",
            "args": [
                "--root",
                str(root),
                "--build",
                str(gate[0] / "build/native"),
                "--verify",
            ],
        }
    ] * (2 if coverage == "1" else 1)
    defines = Path(worker["args"][-1])
    assert worker == {
        "tool": "worker",
        "args": [
            "--root",
            str(root),
            "--build",
            str(root / "build"),
            "--sdk",
            str(Path(gate[1]["PATH"].split(":")[0]).resolve().parent),
            "--package-config",
            str(root / "packages/foresight_core/.dart_tool/package_config.json"),
            "--mode",
            "aot",
            "--verify",
            "--defines-output",
            str(defines),
        ],
    }
    assert producer == {"tool": "worker", "args": worker["args"][:-3]}
    assert defines.parent.parent == root / "build/application"
    assert not defines.parent.exists()


def support_commands(gate):
    path = Path(gate[1]["SUPPORT_COMMANDS"])
    return [json.loads(line) for line in path.read_text().splitlines()]


@pytest.mark.parametrize("platform", ["linux", "macos"])
@pytest.mark.parametrize(
    "run_number,attempt,coverage_first",
    [
        ("0", "1", False),
        ("1", "1", True),
        ("2", "1", False),
        ("1", "2", False),
        ("00008", "00003", False),
        ("00009", "00003", True),
        ("9" * 100 + "8", "7" * 100 + "2", True),
    ],
)
def test_benchmark_runs_both_full_suites_and_preserves_coverage_threshold(
    gate, platform, run_number, attempt, coverage_first
):
    result, commands = run(
        gate,
        platform,
        FORESIGHT_CORE_COVERAGE_BENCHMARK="1",
        GITHUB_RUN_NUMBER=run_number,
        GITHUB_RUN_ATTEMPT=attempt,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    tests = [command for command in commands if command["args"][0] == "test"]
    assert len(tests) == 2
    assert not any(
        arg.endswith(".dart") for command in tests for arg in command["args"]
    )
    assert [
        any(arg.startswith("--coverage=") for arg in command["args"])
        for command in tests
    ] == [coverage_first, not coverage_first]
    modes = ["coverage", "plain"] if coverage_first else ["plain", "coverage"]
    for command, mode in zip(tests, modes, strict=True):
        assert any(arg.endswith(f"/{mode}.events.jsonl") for arg in command["args"])
        assert ("--coverage-package=^foresight_core$" in command["args"]) == (
            mode == "coverage"
        )
    assert f"Core benchmark order: {' then '.join(modes)}" in result.stdout
    assert "minimum 90%" in result.stdout
    assert "Core benchmark matched: 1 passed, 0 skipped" in result.stdout
    sqlite = (
        str(gate[0] / "build/macos/libforesight_sqlite3.dylib")
        if platform == "macos"
        else None
    )
    assert all(command["sqlite"] == sqlite for command in commands)


@pytest.mark.parametrize("stage", ["core", "desktop"])
def test_macos_missing_sqlite_fails_before_any_dart_or_flutter_command(gate, stage):
    root, environment = gate
    sqlite = root / "build/macos/libforesight_sqlite3.dylib"
    sqlite.unlink()
    result = subprocess.run(
        [
            "bash",
            str(root / "tools/build_dart_gates.sh"),
            stage,
            "macos",
            str(root / "build"),
            sys.executable,
        ],
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"Missing application SQLite runtime: {sqlite}" in result.stderr
    assert not Path(environment["COMMANDS"]).exists()


def test_local_benchmark_without_github_counters_defaults_to_plain_first(gate):
    _, environment = gate
    environment.pop("GITHUB_RUN_NUMBER")
    environment.pop("GITHUB_RUN_ATTEMPT")
    result, _ = run(gate, FORESIGHT_CORE_COVERAGE_BENCHMARK="1")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        "Core benchmark order: plain then coverage (run 0, attempt 1)" in result.stdout
    )


@pytest.mark.parametrize("run_number", ["0", "1"])
def test_benchmark_uses_the_same_overridden_dart_and_supplied_python(gate, run_number):
    _, environment = gate
    binary = Path(environment["PATH"].split(":")[0])
    override = binary / "alternate dart"
    shutil.copy2(binary / "dart", override)
    result, commands = run(
        gate,
        FORESIGHT_CORE_COVERAGE_BENCHMARK="1",
        FORESIGHT_DART=str(override),
        FORESIGHT_PYTHON="/missing/inherited-python",
        GITHUB_RUN_NUMBER=run_number,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    tests = [command for command in commands if command["args"][0] == "test"]
    assert len(tests) == 2
    assert all(command["tool"] == str(override) for command in tests)
    warmers = [
        command
        for command in commands
        if command["args"] == ["run", "tool/warm_boundary_analysis.dart"]
    ]
    assert len(warmers) == 2
    assert all(command["tool"] == str(override) for command in warmers)
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
def test_failed_analysis_archives_old_events_and_runs_independent_checks(gate, stage):
    root, _ = gate
    reports = root / f"test-results/linux/{stage}"
    reports.mkdir(parents=True)
    (reports / "old.events.jsonl").write_text("old execution")
    (reports / "diagnostic.log").write_text("preserved diagnostic")
    sibling = root / "test-results/macos" / stage / "old.events.jsonl"
    sibling.parent.mkdir(parents=True)
    sibling.write_text("other platform")
    result, _ = run(gate, stage=stage, ANALYSIS_EXIT="7")
    assert result.returncode == 1
    assert f"{stage} analysis (exit 7;" in result.stdout
    retained = list(reports.glob("checks.*/previous-old.events.jsonl.raw"))
    assert len(retained) == 1 and retained[0].read_text() == "old execution"
    assert (reports / f"{stage}.events.jsonl").is_file()
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
@pytest.mark.parametrize("run_number", ["0", "1"])
def test_failed_baseline_coverage_or_comparison_is_sticky_without_hiding_independent_checks(
    gate, settings, expected, run_number
):
    result, commands = run(
        gate,
        FORESIGHT_CORE_COVERAGE_BENCHMARK="1",
        GITHUB_RUN_NUMBER=run_number,
        **settings,
    )
    assert result.returncode != 0
    assert expected in result.stdout + result.stderr
    compiled = [c for c in commands if c["args"][:2] == ["compile", "exe"]]
    assert len(compiled) == 2
    tests = [command for command in commands if command["args"][0] == "test"]
    assert len(tests) == 2
    assert any(c["args"][0] == "-DFORESIGHT_ENABLE_TEST_HOOKS=true" for c in commands)


@pytest.mark.parametrize("counter", ["GITHUB_RUN_NUMBER", "GITHUB_RUN_ATTEMPT"])
@pytest.mark.parametrize(
    "value", ["-1", "1+1", " 2", "not-a-number", "a[$(touch unsafe)]"]
)
def test_benchmark_rejects_nonnumeric_counters_before_running_tests(
    gate, counter, value
):
    result, commands = run(
        gate, FORESIGHT_CORE_COVERAGE_BENCHMARK="1", **{counter: value}
    )
    assert result.returncode == 2
    assert "requires decimal GITHUB_RUN_NUMBER and GITHUB_RUN_ATTEMPT" in result.stderr
    assert all(command["args"][0] not in {"test", "compile"} for command in commands)
    assert not list(gate[0].rglob("unsafe"))


@pytest.mark.parametrize("attempt", ["0", "000"])
def test_benchmark_rejects_zero_attempts_before_running_tests(gate, attempt):
    result, commands = run(
        gate, FORESIGHT_CORE_COVERAGE_BENCHMARK="1", GITHUB_RUN_ATTEMPT=attempt
    )
    assert result.returncode == 2
    assert "GITHUB_RUN_ATTEMPT must be positive" in result.stderr
    assert all(command["args"][0] not in {"test", "compile"} for command in commands)


def test_overridden_dart_must_match_pins_before_any_stage_work(gate):
    root, _ = gate
    override = root / "wrong dart"
    override.write_text("#!/bin/sh\necho 'Dart SDK version: 0.0.1'\n")
    override.chmod(0o700)
    result, commands = run(gate, FORESIGHT_DART=str(override))
    assert result.returncode != 0
    assert "tools/pins.json requires" in result.stderr
    assert all(command["args"] == ["--version"] for command in commands)


@pytest.mark.parametrize("coverage", ["0", "1"])
def test_warm_failure_blocks_full_suite_and_keeps_independent_hook_and_products(
    gate, coverage
):
    result, commands = run(gate, FORESIGHT_COVERAGE=coverage, WARM_EXIT="23")
    assert result.returncode == 1
    assert "exit 23" in result.stdout
    assert "boundary warmer diagnostic" in result.stdout
    assert all(command["args"][0] != "test" for command in commands)
    assert len([c for c in commands if c["args"][:2] == ["compile", "exe"]]) == 2
    assert any(c["args"][0] == "-DFORESIGHT_ENABLE_TEST_HOOKS=true" for c in commands)
    warmer = next(
        command
        for command in commands
        if command["args"] == ["run", "tool/warm_boundary_analysis.dart"]
    )
    assert not Path(warmer["cache"]).exists()


def test_each_benchmark_suite_warms_a_fresh_private_cache_before_fanout(gate, tmp_path):
    inherited = tmp_path / "inherited cache"
    inherited.mkdir()
    (inherited / "keep").write_text("unrelated cache")
    result, commands = run(
        gate,
        FORESIGHT_CORE_COVERAGE_BENCHMARK="1",
        FORESIGHT_BOUNDARY_ANALYSIS_CACHE=str(inherited),
    )
    assert result.returncode == 0, result.stdout + result.stderr
    warmers = [
        c for c in commands if c["args"] == ["run", "tool/warm_boundary_analysis.dart"]
    ]
    tests = [c for c in commands if c["args"][0] == "test"]
    assert len(warmers) == len(tests) == 2
    assert len({c["cache"] for c in warmers}) == 2
    for warmer, test in zip(warmers, tests, strict=True):
        assert warmer["cache"] == test["cache"] != str(inherited)
        assert warmer["cache_mode"] == test["cache_mode"] == "0o700"
        assert not warmer["warmed"] and test["warmed"]
        assert not Path(test["cache"]).exists()
    assert (inherited / "keep").read_text() == "unrelated cache"


def test_core_wrapper_preserves_arguments_override_environment_and_test_failure(gate):
    root, environment = gate
    binary = Path(environment["PATH"].split(":")[0])
    override = binary / "alternate dart"
    shutil.copy2(binary / "dart", override)
    arguments = ["test/desktop_boundary_test.dart", "--name", "a name with spaces"]
    result = subprocess.run(
        [str(root / "tools/run_core_tests.sh"), *arguments],
        env={
            **environment,
            "FORESIGHT_DART": str(override),
            "PLAIN_EXIT": "19",
            "FORESIGHT_NATIVE_LIBRARY": "/current native",
            "FORESIGHT_HELPER": "/current helper",
        },
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 19, result.stdout + result.stderr
    commands = [
        json.loads(line)
        for line in Path(environment["COMMANDS"]).read_text().splitlines()
    ]
    assert [c["args"] for c in commands] == [
        ["run", "tool/warm_boundary_analysis.dart"],
        ["test", *arguments],
    ]
    assert all(c["tool"] == str(override) for c in commands)
    assert all(
        c["native"] == "/current native" and c["helper"] == "/current helper"
        for c in commands
    )
    assert commands[0]["cache"] == commands[1]["cache"]
    assert commands[1]["warmed"]
    assert not Path(commands[1]["cache"]).exists()


@pytest.mark.parametrize("stage", ["core", "desktop"])
@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_unverified_runtime_support_stops_before_any_dart_or_flutter_command(
    gate, stage, platform
):
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
        env={**environment, "RECEIPT_EXIT": "13"},
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 13, result.stdout + result.stderr
    assert not Path(environment["COMMANDS"]).exists()
    assert [c["tool"] for c in support_commands(gate)] == ["receipt"]


@pytest.mark.parametrize(
    "settings,status,message",
    [
        ({"WORKER_EXIT": "17"}, 17, ""),
        ({"WORKER_DEFINES": "empty"}, 1, "Missing verified worker defines"),
    ],
)
def test_unverified_worker_defines_stop_host_compilation(
    gate, settings, status, message
):
    result, commands = run(gate, **settings)
    assert result.returncode == 1, result.stdout + result.stderr
    if status != 1:
        assert f"exit {status}" in result.stdout
    assert message in result.stderr
    assert not any(command["args"][0] == "test" for command in commands)
    assert "Blocked core suite: diagnostic worker prerequisite failed" in result.stderr
    assert all(command["args"][0] != "compile" for command in commands)
    assert [c["tool"] for c in support_commands(gate)] == (
        ["receipt", "worker"]
        if "WORKER_EXIT" in settings
        else ["receipt", "worker", "worker"]
    )
    assert not list((gate[0] / "build/application").glob(".diagnostic-defines.*"))
