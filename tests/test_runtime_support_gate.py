"""Consumer stage gates must validate finished products before running clients."""

import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def gate_tree(tmp_path):
    root = tmp_path / "source"
    tools = root / "tools"
    tools.mkdir(parents=True)
    shutil.copyfile(
        ROOT / "tools/runtime_support_gate.sh", tools / "runtime_support_gate.sh"
    )
    # This fixture checks shell sequencing/export contracts, not receipt bytes.
    # The separate receipt suite verifies exact source/marker/artifact binding.
    (tools / "diagnostic_product_receipt.py").write_text(
        "import os, sys\n"
        "print('receipt:' + '|'.join(sys.argv[1:]))\n"
        "sys.exit(int(os.environ.get('FIXTURE_RECEIPT_EXIT', '0')))\n"
    )
    return root, tmp_path / "build"


def run_gate(root, build, exit_code):
    return subprocess.run(
        [
            "bash",
            "-euc",
            'source "$1/tools/runtime_support_gate.sh"; '
            'foresight_verify_runtime_support "$1" "$2" "$3"; '
            'printf "consumer:%s|%s|%s\\n" "$FORESIGHT_TEST_SQL_SUPPORT_LIBRARY" "$FORESIGHT_HELPER" "$FORESIGHT_TEST_HELPER"',
            "gate-fixture",
            str(root),
            str(build),
            sys.executable,
        ],
        env={**os.environ, "FIXTURE_RECEIPT_EXIT": str(exit_code)},
        text=True,
        capture_output=True,
        timeout=10,
    )


def test_gate_verifies_explicit_build_and_exports_separate_test_helper(gate_tree):
    root, build = gate_tree
    result = run_gate(root, build, 0)
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"receipt:--root|{root}|--build|{build}/native|--verify" in result.stdout
    assert (
        f"{build}/services/helper/ForesightHelper|{build}/services/helper/ForesightHelperTest"
        in result.stdout
    )
    assert f"{build}/native/libforesight_sql_support." in result.stdout


def test_failed_receipt_preserves_failure_and_prevents_consumer(gate_tree):
    root, build = gate_tree
    result = run_gate(root, build, 23)
    assert result.returncode == 23, result.stdout + result.stderr
    assert "receipt:" in result.stdout
    assert "consumer:" not in result.stdout


@pytest.mark.parametrize("worker_exit", [0, 23])
def test_source_service_compilation_uses_receipt_verified_explicit_roots(
    gate_tree, tmp_path, worker_exit
):
    import json

    root, build = gate_tree
    build.mkdir()
    (root / "packages/foresight_core").mkdir(parents=True)
    for name in ("build_dart_gates.sh", "ci_timing.sh"):
        shutil.copyfile(ROOT / "tools" / name, root / "tools" / name)
    (root / "tools/verify_toolchain_pins.py").write_text(
        "print('fixture public pin verification')\n"
    )
    (root / "tools/build_diagnostic_worker.py").write_text(
        "import sys,json,pathlib,os\n"
        "sys.exit(int(os.environ['FIXTURE_WORKER_EXIT'])) if os.environ['FIXTURE_WORKER_EXIT'] != '0' else None\n"
        "args=sys.argv[1:]; output=pathlib.Path(args[args.index('--defines-output')+1])\n"
        "source=args[args.index('--root')+1]; build=args[args.index('--build')+1]\n"
        "assert args[args.index('--mode')+1]=='aot'\n"
        "defines=['-DFORESIGHT_DIAGNOSTIC_TEST_CONTEXT=true', '-DFORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR='+source, '-DFORESIGHT_DIAGNOSTIC_BUILD_ROOT='+build, '-DFORESIGHT_DIAGNOSTIC_NATIVE_ID='+'a'*64, '-DFORESIGHT_DIAGNOSTIC_BUILD_ID='+'b'*64, '-DFORESIGHT_DIAGNOSTIC_CATALOG_ID='+'c'*64, '-DFIXTURE_SPACES=one two']\n"
        "output.write_bytes(b'\\0'.join(item.encode() for item in defines)+b'\\0')\n"
    )
    binary = tmp_path / "bin"
    binary.mkdir()
    calls = tmp_path / "dart-calls.jsonl"
    dart = binary / "dart"
    dart.write_text(
        "#!/usr/bin/env python3\nimport json,os,sys\n"
        "with open(os.environ['FIXTURE_DART_CALLS'],'a') as stream: stream.write(json.dumps(sys.argv[1:])+'\\n')\n"
    )
    dart.chmod(0o755)
    result = subprocess.run(
        [
            "bash",
            str(root / "tools/build_dart_gates.sh"),
            "core",
            "linux",
            str(build),
            sys.executable,
        ],
        env={
            **os.environ,
            "PATH": f"{binary}:{os.environ['PATH']}",
            "FORESIGHT_BUILD_MODE": "build-only",
            "FIXTURE_DART_CALLS": str(calls),
            "FIXTURE_WORKER_EXIT": str(worker_exit),
        },
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == worker_exit, result.stdout + result.stderr
    compilations = [
        args
        for line in calls.read_text().splitlines()
        if (args := json.loads(line))[:2] == ["compile", "exe"]
    ]
    assert len(compilations) == (0 if worker_exit else 2)
    for args in compilations:
        assert "-DFORESIGHT_DIAGNOSTIC_TEST_CONTEXT=true" in args
        assert f"-DFORESIGHT_DIAGNOSTIC_SOURCE_ANCHOR={root.resolve()}" in args
        assert f"-DFORESIGHT_DIAGNOSTIC_BUILD_ROOT={build.resolve()}" in args
        assert "-DFORESIGHT_DIAGNOSTIC_NATIVE_ID=" + "a" * 64 in args
        assert "-DFORESIGHT_DIAGNOSTIC_BUILD_ID=" + "b" * 64 in args
        assert "-DFORESIGHT_DIAGNOSTIC_CATALOG_ID=" + "c" * 64 in args
        assert "-DFIXTURE_SPACES=one two" in args


@pytest.mark.parametrize("worker_exit", [0, 29])
def test_worker_gate_uses_current_sdk_and_explicit_aot_verification(
    gate_tree, tmp_path, worker_exit
):
    root, build = gate_tree
    binary = tmp_path / "sdk/bin"
    binary.mkdir(parents=True)
    (binary / "dart").write_text("fixture executable")
    (binary / "dart").chmod(0o755)
    (root / "tools/build_diagnostic_worker.py").write_text(
        "import os,sys\nprint('worker:'+'|'.join(sys.argv[1:]))\n"
        "sys.exit(int(os.environ['FIXTURE_WORKER_EXIT']))\n"
    )
    result = subprocess.run(
        [
            "bash",
            "-euc",
            'source "$1/tools/runtime_support_gate.sh"; '
            'foresight_diagnostic_worker "$1" "$2" "$3" --verify; echo consumer',
            "fixture",
            str(root),
            str(build),
            sys.executable,
        ],
        env={
            **os.environ,
            "PATH": f"{binary}:{os.environ['PATH']}",
            "FIXTURE_WORKER_EXIT": str(worker_exit),
        },
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == worker_exit, result.stdout + result.stderr
    assert f"--sdk|{binary.parent.resolve()}" in result.stdout
    assert "--mode|aot|--verify" in result.stdout
    assert (
        f"--package-config|{root}/packages/foresight_core/.dart_tool/package_config.json"
        in result.stdout
    )
    assert ("consumer" in result.stdout.splitlines()) is (worker_exit == 0)
