"""Core fanout is configurable without changing workload or local defaults."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


def run_gate(
    tmp_path: Path, budget: str | None, args: list[str], code: int = 0
) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
    source = tmp_path / "source"
    (source / "tools").mkdir(parents=True)
    (source / "packages/foresight_core").mkdir(parents=True)
    (source / "tools/run_core_tests.sh").write_bytes(
        (ROOT / "tools/run_core_tests.sh").read_bytes()
    )
    log = tmp_path / "calls.jsonl"
    fake = tmp_path / "dart"
    fake.write_text(
        '#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\na=sys.argv[1:]\nwith open(os.environ["CALLS"],"a") as f:f.write(json.dumps(a)+"\\n")\nif a[0].endswith("processors.dart"):\n assert "Platform.numberOfProcessors" in Path(a[0]).read_text()\n print(16)\nif a[0]=="test":sys.exit(int(os.environ["TEST_CODE"]))\n'
    )
    fake.chmod(0o755)
    env = os.environ.copy()
    env.pop("FORESIGHT_CORE_TEST_CONCURRENCY", None)
    env.update(
        FORESIGHT_DART=str(fake),
        CALLS=str(log),
        TEST_CODE=str(code),
        TMPDIR=str(tmp_path),
    )
    if budget is not None:
        env["FORESIGHT_CORE_TEST_CONCURRENCY"] = budget
    result = subprocess.run(
        ["bash", str(source / "tools/run_core_tests.sh"), *args],
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
    )
    return result, [
        json.loads(line) for line in log.read_text().splitlines()
    ] if log.exists() else []


def test_default_keeps_exact_test_arguments(tmp_path: Path) -> None:
    result, calls = run_gate(tmp_path, None, ["test/a.dart", "--coverage=coverage"])
    assert result.returncode == 0
    assert calls == [
        ["run", "tool/warm_boundary_analysis.dart"],
        ["test", "test/a.dart", "--coverage=coverage"],
    ]


def test_budget_preserves_workload_and_reports_cpu(tmp_path: Path) -> None:
    result, calls = run_gate(tmp_path, "2", ["test/a.dart", "--coverage=coverage"], 7)
    assert result.returncode == 7
    assert calls[0] == ["run", "tool/warm_boundary_analysis.dart"]
    assert calls[1][0].endswith("/processors.dart")
    assert calls[2] == ["test", "--concurrency=2", "test/a.dart", "--coverage=coverage"]
    assert "concurrency=2 Dart-processors=16 available-processors=" in result.stderr


@pytest.mark.parametrize("budget", ["", "0", "-1", "2x"])
def test_invalid_budget_fails_before_dart(tmp_path: Path, budget: str) -> None:
    result, calls = run_gate(tmp_path, budget, [])
    assert result.returncode == 2
    assert calls == []
    assert "positive integer" in result.stderr


@pytest.mark.parametrize(
    "args", [["--concurrency", "3"], ["--concurrency=3"], ["-j", "3"], ["-j3"]]
)
def test_explicit_cli_still_controls_local_fanout(
    tmp_path: Path, args: list[str]
) -> None:
    result, calls = run_gate(tmp_path, "2", args)
    assert result.returncode == 0
    assert calls[-1] == ["test", *args]
    assert "concurrency=explicit-cli" in result.stderr


def test_ci_budget_is_scoped_to_core_consumers() -> None:
    import yaml

    linux = yaml.safe_load(
        (ROOT / ".github/workflows/linux-platform-stages.yml").read_text()
    )
    arch = yaml.safe_load((ROOT / ".github/workflows/arch-drift.yml").read_text())
    assert "FORESIGHT_CORE_TEST_CONCURRENCY" not in linux.get("env", {})
    assert "FORESIGHT_CORE_TEST_CONCURRENCY" not in arch.get("env", {})
    configured = [
        step["name"]
        for workflow in (linux, arch)
        for job in workflow["jobs"].values()
        for step in job.get("steps", [])
        if step.get("env", {}).get("FORESIGHT_CORE_TEST_CONCURRENCY") == "2"
    ]
    assert configured == [
        "Validate or restore the core stage",
        "Build and test with the current Arch toolchain",
    ]
