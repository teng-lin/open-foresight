"""Independent build stages must preserve their prerequisite and failure boundaries."""

import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def build_tree(tmp_path):
    root = tmp_path / "repo"
    tools = root / "tools"
    tools.mkdir(parents=True)
    for name in (
        "build.sh",
        "build_service_gate.sh",
        "runtime_support_gate.sh",
        "ci_timing.sh",
        "check_build_cache.py",
        "verify_toolchain_pins.py",
        "pins.json",
    ):
        shutil.copy2(ROOT / "tools" / name, tools / name)
    (tools / "verify_descriptor.py").write_text("print('descriptor checked')\n")
    for name in ("build_dart_gates.sh",):
        (tools / name).write_text('#!/bin/bash\necho "dart-stage:$1"\n')
    binary = tmp_path / "bin"
    binary.mkdir()
    for name, body in {
        "cmake": 'echo "cmake:$*"; mkdir -p "$FORESIGHT_BUILD_DIR"',
        "ctest": 'echo "ctest:$*"; exit "${FIXTURE_CTEST_EXIT:-0}"',
        "protoc": 'echo "libprotoc 35.1"',
    }.items():
        script = binary / name
        script.write_text("#!/bin/bash\n" + body + "\n")
        script.chmod(0o700)
    build = root / "build"
    build.mkdir()
    return root, {
        **os.environ,
        "CI": "true",
        "PATH": f"{binary}:/usr/bin:/bin",
        "FORESIGHT_BUILD_DIR": str(build),
        "FORESIGHT_PYTHON": shutil.which("python3"),
        # This miniature tree has no dependency seed or reuse verifier. Real
        # dependency-reuse fixtures exercise that production guard separately.
        "FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE": "0",
    }


def run_stage(build_tree, stage, extra=None):
    root, environment = build_tree
    return subprocess.run(
        [
            "/bin/bash",
            str(root / "tools/build.sh"),
            "--platform",
            "linux",
            "--stage",
            stage,
        ],
        env={**environment, **(extra or {})},
        text=True,
        capture_output=True,
        timeout=10,
    )


def test_native_stage_needs_no_dart_or_flutter_and_runs_no_dart_gate(build_tree):
    result = run_stage(build_tree, "native")
    assert result.returncode == 0, result.stderr
    assert "native configure" in result.stdout
    assert "native compile" in result.stdout
    assert "native tests" in result.stdout
    assert "dart-stage" not in result.stdout


def test_native_failure_cannot_be_reported_as_success(build_tree):
    result = run_stage(build_tree, "native", {"FIXTURE_CTEST_EXIT": "7"})
    assert result.returncode == 7
    assert "dart-stage" not in result.stdout


def test_native_reuse_guard_can_be_enabled_and_blocks_compilation(build_tree):
    root, _ = build_tree
    (root / "tools/verify_app_dependency_reuse.py").write_text(
        "import sys\nprint('fixture reuse guard rejected dependency rebuild')\nsys.exit(19)\n"
    )
    result = run_stage(
        build_tree, "native", {"FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE": "1"}
    )
    assert result.returncode == 19, result.stdout + result.stderr
    assert "fixture reuse guard rejected dependency rebuild" in result.stdout
    assert "native compile" not in result.stdout


@pytest.mark.parametrize("stage", ["core", "desktop", "service"])
def test_language_stages_require_their_sdk_before_using_artifacts(build_tree, stage):
    result = run_stage(build_tree, stage)
    assert result.returncode != 0
    assert "Required dart SDK is missing" in result.stderr
    assert "cmake:" not in result.stdout


def test_unknown_stage_is_rejected(build_tree):
    result = run_stage(build_tree, "misspelled")
    assert result.returncode == 2
    assert "Stage must be" in result.stderr


@pytest.mark.parametrize("stage", ["core", "desktop"])
def test_language_stages_do_not_rebuild_native_prerequisites(build_tree, stage):
    _, environment = build_tree
    binary = Path(environment["PATH"].split(":")[0])
    for name in ("dart", "flutter"):
        executable = binary / name
        executable.write_text("#!/bin/bash\nexit 0\n")
        executable.chmod(0o700)
    result = run_stage(build_tree, stage)
    assert result.returncode == 0, result.stderr
    assert f"dart-stage:{stage}" in result.stdout
    assert "cmake:" not in result.stdout
    assert "ctest:" not in result.stdout


def test_service_stage_fails_on_missing_compiled_prerequisites(build_tree):
    _, environment = build_tree
    binary = Path(environment["PATH"].split(":")[0])
    dart = binary / "dart"
    dart.write_text("#!/bin/bash\nexit 0\n")
    dart.chmod(0o700)
    result = run_stage(build_tree, "service")
    assert result.returncode != 0
    assert "Missing stage prerequisite" in result.stderr
    assert "cmake:" not in result.stdout


@pytest.mark.parametrize("state", ["missing", "not-executable"])
def test_service_stage_rejects_missing_or_non_executable_worker_before_tests(
    build_tree, state
):
    root, environment = build_tree
    binary = Path(environment["PATH"].split(":")[0])
    dart = binary / "dart"
    dart.write_text("#!/bin/bash\nexit 0\n")
    dart.chmod(0o700)
    for relative in (
        "application/foresight-service",
        "application/foresight-mcp",
        "services/helper/ForesightHelper",
    ):
        executable = root / "build" / relative
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
    native = root / "build/native/libforesight_native.so"
    native.parent.mkdir(parents=True)
    native.write_bytes(b"native-library")
    worker = root / "build/services/helper/model_worker_fixture"
    if state == "not-executable":
        worker.write_text("#!/bin/sh\nexit 0\n")
        worker.chmod(0o644)
    result = run_stage(build_tree, "service")
    assert result.returncode != 0
    assert str(worker) in result.stderr
    expected = "Missing stage prerequisite" if state == "missing" else "not executable"
    assert expected in result.stderr
    assert "service and MCP integration" not in result.stdout
    assert not (root / "test-results").exists()


def test_service_receipt_failure_blocks_compiled_clients(build_tree):
    root, environment = build_tree
    binary = Path(environment["PATH"].split(":")[0])
    dart = binary / "dart"
    dart.write_text("#!/bin/bash\nexit 0\n")
    dart.chmod(0o700)
    for relative in (
        "application/foresight-service",
        "application/foresight-mcp",
        "services/helper/ForesightHelper",
        "services/helper/model_worker_fixture",
    ):
        executable = root / "build" / relative
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
    native = root / "build/native/libforesight_native.so"
    native.parent.mkdir(parents=True)
    native.write_bytes(b"fixture-native")
    (root / "tools/diagnostic_product_receipt.py").write_text(
        "import sys\nprint('fixture receipt refused')\nsys.exit(29)\n"
    )
    result = run_stage(build_tree, "service")
    assert result.returncode == 29, result.stdout + result.stderr
    assert "fixture receipt refused" in result.stdout
    assert "service and MCP integration" not in result.stdout
    assert not (root / "test-results").exists()


@pytest.fixture
def dart_gate_tree(tmp_path):
    """Run the actual gate shell with controlled command outcomes and receipts."""
    import sys

    root = tmp_path / "repo"
    tools = root / "tools"
    tools.mkdir(parents=True)
    for name in ("build_dart_gates.sh", "ci_timing.sh"):
        shutil.copy2(ROOT / "tools" / name, tools / name)
    (tools / "verify_toolchain_pins.py").write_text("raise SystemExit(0)\n")
    (tools / "run_core_tests.sh").write_text('#!/bin/bash\nexec dart test "$@"\n')
    (tools / "run_core_tests.sh").chmod(0o700)
    (tools / "check_coverage.py").write_text(
        'import os; print("coverage evaluated"); raise SystemExit(int(os.environ.get("FAIL_COVERAGE", "0")))\n'
    )
    (tools / "runtime_support_gate.sh").write_text("""
foresight_verify_runtime_support() { return "${FAIL_RECEIPT:-0}"; }
foresight_diagnostic_worker() {
  printf 'worker:%s\\n' "$*" >> "$COMMAND_LOG"
  if [[ "$*" == *--verify* ]]; then
    [[ "${FAIL_WORKER_VERIFY:-0}" == 0 ]] || return "$FAIL_WORKER_VERIFY"
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --defines-output ]]; then printf '%s\\0' '-Dfixture=true' > "$2"; break; fi
      shift
    done
  else
    return "${FAIL_WORKER_BUILD:-0}"
  fi
}
""")
    binary = tmp_path / "bin"
    binary.mkdir()
    body = """import json,os,pathlib,sys
args=sys.argv[1:]
with open(os.environ['COMMAND_LOG'],'a') as f:f.write(json.dumps([pathlib.Path(sys.argv[0]).name,*args])+'\\n')
kind=args[0] if args else ''
if kind=='compile':
 name=pathlib.Path(args[args.index('-o')+1]).name
 code=int(os.environ.get('FAIL_'+name.replace('foresight-','').upper(),'0'))
 if not code:pathlib.Path(args[args.index('-o')+1]).write_text('compiled '+name)
elif kind.startswith('-D'):code=int(os.environ.get('FAIL_HOOK','0'))
else:code=int(os.environ.get({'pub':'FAIL_DEPENDENCIES','analyze':'FAIL_ANALYSIS','format':'FAIL_FORMAT','test':'FAIL_TEST','build':'FAIL_RELEASE'}.get(kind,'UNUSED'),'0'))
print('controlled '+kind+' exit '+str(code))
raise SystemExit(code)
"""
    for name in ("dart", "flutter"):
        executable = binary / name
        executable.write_text(f"#!{sys.executable}\n" + body)
        executable.chmod(0o700)
    for path in ("packages/foresight_core", "apps/desktop", "build/native"):
        (root / path).mkdir(parents=True)
    environment = {
        **os.environ,
        "PATH": f"{binary}:/usr/bin:/bin",
        "COMMAND_LOG": str(tmp_path / "commands"),
        "FORESIGHT_BUILD_MODE": "all",
    }
    return root, environment


def invoke_dart_gate(tree, gate, **failures):
    import sys

    root, environment = tree
    return subprocess.run(
        [
            "/bin/bash",
            str(root / "tools/build_dart_gates.sh"),
            gate,
            "linux",
            str(root / "build"),
            sys.executable,
        ],
        env={**environment, **{k: str(v) for k, v in failures.items()}},
        text=True,
        capture_output=True,
        timeout=10,
    )


def test_core_collects_analysis_format_tests_hooks_and_both_compile_failures(
    dart_gate_tree,
):
    result = invoke_dart_gate(
        dart_gate_tree,
        "core",
        FAIL_ANALYSIS=3,
        FAIL_FORMAT=4,
        FAIL_TEST=5,
        FAIL_HOOK=6,
        FAIL_SERVICE=7,
        FAIL_MCP=8,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    for label, code in [
        ("core analysis", 3),
        ("core format", 4),
        ("core tests", 5),
        ("core enabled-hook regression", 6),
        ("service compilation", 7),
        ("mcp compilation", 8),
    ]:
        assert f"{label} (exit {code}; log " in result.stdout
    logs = list((dart_gate_tree[0] / "test-results/linux/core").glob("checks.*/*.log"))
    raw = "".join(p.read_text() for p in logs)
    for code in range(3, 9):
        assert f"exit {code}" in raw
    assert not (dart_gate_tree[0] / "build/application/foresight-service").exists()


def test_desktop_failures_do_not_hide_coverage_or_release_compile(dart_gate_tree):
    result = invoke_dart_gate(
        dart_gate_tree,
        "desktop",
        FAIL_ANALYSIS=3,
        FAIL_FORMAT=4,
        FAIL_TEST=5,
        FAIL_COVERAGE=6,
        FAIL_RELEASE=7,
    )
    assert result.returncode == 1
    for label in [
        "desktop analysis",
        "desktop format",
        "desktop tests and coverage",
        "desktop coverage floor",
        "desktop release compilation",
    ]:
        assert f"{label} (exit " in result.stdout
    assert "coverage evaluated" in result.stdout


@pytest.mark.parametrize("failure", ["FAIL_RECEIPT", "FAIL_DEPENDENCIES"])
def test_gate_prerequisite_failure_blocks_dependent_work(dart_gate_tree, failure):
    result = invoke_dart_gate(dart_gate_tree, "core", **{failure: 19})
    assert result.returncode == 19
    assert "core tests" not in result.stdout
    assert "service compilation" not in result.stdout
    if failure == "FAIL_DEPENDENCIES":
        assert "controlled pub exit 19" in result.stdout
        assert list(
            (dart_gate_tree[0] / "test-results/linux/core").glob("checks.*/*.log")
        )


def test_worker_failure_blocks_suite_and_compilation_but_keeps_independent_checks(
    dart_gate_tree,
):
    result = invoke_dart_gate(
        dart_gate_tree, "core", FAIL_WORKER_BUILD=23, FAIL_ANALYSIS=3
    )
    assert result.returncode == 1
    assert "core analysis (exit 3;" in result.stdout
    assert "core format (exit 0;" in result.stdout
    assert "Blocked core suite: diagnostic worker prerequisite failed" in result.stderr
    assert "service compilation" not in result.stdout
    assert "core enabled-hook regression" in result.stdout


def test_native_test_failure_is_sticky_but_does_not_hide_independent_dart_gates(
    build_tree,
):
    root, environment = build_tree
    shutil.copy2(
        ROOT / "tools/parallel_build_gates.py", root / "tools/parallel_build_gates.py"
    )
    binary = Path(environment["PATH"].split(":")[0])
    for name in ("dart", "flutter"):
        executable = binary / name
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)
    result = run_stage(build_tree, "all", {"FIXTURE_CTEST_EXIT": "7"})
    assert result.returncode == 7, result.stdout + result.stderr
    assert "core-build gate (exit 0)" in result.stdout
    assert "desktop-build gate (exit 0)" in result.stdout
    assert "core-checks gate (exit 0)" in result.stdout
    assert "desktop-checks gate (exit 0)" in result.stdout
    assert "Missing stage prerequisite" in result.stdout


def test_gate_preserves_prior_event_output_in_its_new_private_check_directory(
    dart_gate_tree,
):
    root, _ = dart_gate_tree
    reports = root / "test-results/linux/core"
    reports.mkdir(parents=True)
    prior = reports / "core.events.jsonl"
    prior.write_bytes(b"original failed events\n")
    result = invoke_dart_gate(dart_gate_tree, "core")
    assert result.returncode == 0, result.stdout + result.stderr
    retained = list(reports.glob("checks.*/previous-core.events.jsonl.raw"))
    assert (
        len(retained) == 1 and retained[0].read_bytes() == b"original failed events\n"
    )


@pytest.mark.parametrize("compile_exit", [0, 7])
def test_core_releases_only_owned_compile_staging_and_keeps_check_logs(
    dart_gate_tree, compile_exit
):
    root, _ = dart_gate_tree
    application = root / "build/application"
    application.mkdir()
    old = application / "foresight-service"
    old.write_text("old retained host")
    result = invoke_dart_gate(dart_gate_tree, "core", FAIL_SERVICE=compile_exit)
    assert result.returncode == bool(compile_exit)
    assert not list(application.glob(".diagnostic-defines.*"))
    assert (application / "foresight-mcp").read_text() == "compiled foresight-mcp"
    if compile_exit:
        assert old.read_text() == "old retained host"
    logs = "".join(
        p.read_text() for p in (root / "test-results/linux/core").glob("checks.*/*.log")
    )
    assert f"controlled compile exit {compile_exit}" in logs


def test_failed_desktop_run_cannot_qualify_previous_lcov_as_current(dart_gate_tree):
    root, _ = dart_gate_tree
    shutil.copy2(ROOT / "tools/check_coverage.py", root / "tools/check_coverage.py")
    coverage = root / "apps/desktop/coverage"
    coverage.mkdir()
    stale = b"TN:\nSF:controlled.dart\nDA:1,1\nLF:1\nLH:1\nend_of_record\n"
    (coverage / "lcov.info").write_bytes(stale)
    result = invoke_dart_gate(dart_gate_tree, "desktop", FAIL_TEST=7)
    assert result.returncode == 1
    assert "desktop tests and coverage (exit 7;" in result.stdout
    assert "desktop coverage floor (exit 2;" in result.stdout
    assert "Invalid coverage report:" in result.stdout
    assert "Desktop line coverage:" not in result.stdout
    retained = list(
        (root / "test-results/linux/desktop").glob("checks.*/previous-lcov.raw")
    )
    assert len(retained) == 1 and retained[0].read_bytes() == stale
    assert not (coverage / "lcov.info").exists()
    assert "desktop release compilation (exit 0;" in result.stdout
