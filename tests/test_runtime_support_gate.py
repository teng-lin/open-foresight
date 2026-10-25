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
