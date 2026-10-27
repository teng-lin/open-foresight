"""Bounded xdist scheduling keeps whole-file coverage and crash failures."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "parallel_pytest", ROOT / "tools/pytest_parallel.py"
)
assert SPEC and SPEC.loader
parallel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parallel)


@pytest.mark.parametrize(
    ("cpus", "affinity", "ci", "expected"),
    [
        (16, 16, "", 4),
        (16, 2, "", 2),
        (2, 16, "", 2),
        (16, 16, "true", 2),
        (1, 1, "true", 1),
        (None, 16, "", 1),
    ],
)
def test_default_budget_honors_available_cpus_affinity_and_ci(
    monkeypatch, cpus, affinity, ci, expected
):
    monkeypatch.setattr(parallel.os, "process_cpu_count", lambda: cpus, raising=False)
    monkeypatch.setattr(
        parallel.os,
        "sched_getaffinity",
        lambda _pid: set(range(affinity)),
        raising=False,
    )
    assert parallel.worker_budget({"CI": ci}) == expected


def test_cpu_fallback_and_unavailable_affinity_are_bounded(monkeypatch):
    monkeypatch.delattr(parallel.os, "process_cpu_count", raising=False)
    monkeypatch.setattr(parallel.os, "cpu_count", lambda: 8)

    def unavailable(_pid):
        raise OSError("controlled unsupported affinity")

    monkeypatch.setattr(parallel.os, "sched_getaffinity", unavailable, raising=False)
    assert parallel.worker_budget({}) == 4
    monkeypatch.delattr(parallel.os, "sched_getaffinity")
    assert parallel.worker_budget({"FORESIGHT_PYTEST_WORKERS": "1"}) == 1


@pytest.mark.parametrize("value", ["0", "-1", "5", "auto", "2.5", "", "١"])
def test_invalid_worker_budgets_fail_before_execution(monkeypatch, value):
    monkeypatch.setattr(parallel.os, "process_cpu_count", lambda: 16, raising=False)
    monkeypatch.setattr(
        parallel.os, "sched_getaffinity", lambda _pid: set(range(16)), raising=False
    )
    with pytest.raises(ValueError, match="FORESIGHT_PYTEST_WORKERS"):
        parallel.worker_budget({"FORESIGHT_PYTEST_WORKERS": value})


def test_requested_budget_cannot_exceed_ci_bound(monkeypatch):
    monkeypatch.setattr(parallel.os, "process_cpu_count", lambda: 16, raising=False)
    monkeypatch.setattr(
        parallel.os, "sched_getaffinity", lambda _pid: set(range(16)), raising=False
    )
    assert parallel.worker_budget({"CI": "true", "FORESIGHT_PYTEST_WORKERS": "2"}) == 2
    with pytest.raises(ValueError, match="between 1 and 2"):
        parallel.worker_budget({"CI": "true", "FORESIGHT_PYTEST_WORKERS": "3"})


def test_exec_preserves_caller_arguments_and_enforces_distribution(monkeypatch, capsys):
    class Executed(Exception):
        pass

    observed = []

    def execute(path, arguments):
        observed.append((path, arguments))
        raise Executed

    args = [
        "--basetemp",
        "/owned/private",
        "tests",
        "--dist=each",
        "--max-worker-restart=9",
    ]
    monkeypatch.setattr(parallel.sys, "argv", ["driver", *args])
    monkeypatch.setattr(parallel, "worker_budget", lambda _env: 2)
    monkeypatch.setattr(parallel.os, "execv", execute)
    with pytest.raises(Executed):
        parallel.main()
    assert observed == [
        (
            sys.executable,
            [
                sys.executable,
                "-m",
                "pytest",
                *args,
                "--numprocesses=2",
                "--dist=loadfile",
                "--max-worker-restart=0",
            ],
        )
    ]
    assert "whole-file distribution; no crash restarts" in capsys.readouterr().out


def test_invalid_budget_returns_nonzero_without_exec(monkeypatch, capsys):
    def invalid(_env):
        raise ValueError("controlled invalid worker budget")

    monkeypatch.setattr(parallel, "worker_budget", invalid)
    monkeypatch.setattr(
        parallel.os, "execv", lambda *_args: pytest.fail("must not exec")
    )
    assert parallel.main() == 2
    assert capsys.readouterr().err == "controlled invalid worker budget\n"


def nested_gate(tmp_path: Path, *, missing: bool = False, crash: bool = False):
    root = tmp_path / "selection"
    (root / "tools").mkdir(parents=True)
    for name in ("coverage.sh", "pytest_parallel.py"):
        (root / "tools" / name).write_bytes((ROOT / "tools" / name).read_bytes())
    (root / ".coveragerc").write_text(
        "[run]\nbranch=True\npatch=subprocess\nrelative_files=True\nsource=toy\n"
        "[report]\nfail_under=95\n[html]\ndirectory=coverage/python/html\n"
        "[xml]\noutput=coverage/python/coverage.xml\n[lcov]\noutput=coverage/python/lcov.info\n"
    )
    (root / "pytest.ini").write_text("[pytest]\n")
    (root / "toy.py").write_text(
        "def choose(flag):\n    if flag:\n        return 'yes'\n    return 'no'\n"
        + ("\ndef uncalled():\n    return 17\n" if missing else "")
    )
    test_dir = root / "checks"
    test_dir.mkdir()
    record = (
        "import os,pathlib,toy\n"
        "def record():\n"
        " p=pathlib.Path(os.environ['WORKER_RECORD'])/(__name__+'.txt')\n"
        " with p.open('a') as f:f.write(os.environ['PYTEST_XDIST_WORKER']+'\\n')\n"
    )
    (test_dir / "test_first.py").write_text(
        record
        + "def test_first():\n assert toy.choose(True)=='yes'\n record()\n"
        + "def test_same_file():\n assert toy.choose(True)=='yes'\n record()\n"
    )
    (test_dir / "test_second.py").write_text(
        record
        + "import subprocess,sys\n"
        + "def test_python_subprocess():\n"
        + " subprocess.run([sys.executable,'-c',\"import toy; assert toy.choose(False)=='no'\"],check=True,timeout=10)\n"
        + " record()\n"
    )
    if crash:
        (test_dir / "test_crash.py").write_text(
            "import os\ndef test_crash():\n os._exit(73)\n"
        )
    records = root / "worker-records"
    records.mkdir()
    env = dict(
        os.environ,
        FORESIGHT_PYTHON=sys.executable,
        FORESIGHT_PYTEST_WORKERS="2",
        WORKER_RECORD=str(records),
        COVERAGE_FILE=str(root / ".coverage"),
    )
    env.pop("CI", None)
    env.pop("PYTEST_ADDOPTS", None)
    return root, env


def run_nested(root: Path, env: dict[str, str], *, verbose: bool = False):
    result = subprocess.run(
        [
            "bash",
            str(root / "tools/coverage.sh"),
            "checks",
            "--basetemp",
            str(root / "private-tests"),
            "-v" if verbose else "-q",
            "--cov-report=json:coverage/python/coverage.json",
        ],
        cwd=root,
        env=env,
        capture_output=True,
        timeout=90,
        check=False,
    )
    (root / "stdout.log").write_bytes(result.stdout)
    (root / "stderr.log").write_bytes(result.stderr)
    return result


def test_real_workers_combine_branch_and_python_subprocess_coverage(tmp_path):
    root, env = nested_gate(tmp_path)
    result = run_nested(root, env)
    assert result.returncode == 0, result.stdout + result.stderr
    totals = json.loads((root / "coverage/python/coverage.json").read_text())["totals"]
    assert totals["missing_lines"] == 0
    assert totals["missing_branches"] == 0 and totals["num_branches"] > 0
    assert (root / "coverage/python/coverage.xml").is_file()
    records = [
        p.read_text().splitlines() for p in (root / "worker-records").glob("*.txt")
    ]
    assert sorted(map(len, records)) == [1, 2]
    assert all(len(set(group)) == 1 for group in records), (
        "A file must stay on one worker"
    )
    assert len({worker for group in records for worker in group}) == 2
    assert (root / "coverage/python/lcov.info").is_file()
    assert (root / "coverage/python/html/index.html").is_file()


def test_real_parallel_coverage_floor_failure_remains_nonzero(tmp_path):
    root, env = nested_gate(tmp_path, missing=True)
    result = run_nested(root, env)
    assert result.returncode != 0
    assert b"3 passed" in result.stdout
    assert b"95" in result.stdout + result.stderr


def test_real_crashed_worker_is_not_restarted_or_hidden(tmp_path):
    root, env = nested_gate(tmp_path, crash=True)
    result = run_nested(root, env, verbose=True)
    assert result.returncode != 0
    combined = (result.stdout + result.stderr).lower()
    assert b"crashed" in combined
    assert b"worker restarting disabled" in combined
    assert b"replacing crashed worker" not in combined
    assert b"test_crash" in combined


def test_quality_keeps_its_existing_report_formats_and_paths():
    import yaml

    workflow = yaml.safe_load((ROOT / ".github/workflows/quality.yml").read_text())
    step = next(
        value
        for value in workflow["jobs"]["python"]["steps"]
        if value.get("name") == "Offline Python unit tests"
    )
    assert step["run"] == (
        "python tools/pytest_parallel.py --cov --cov-config=.coveragerc "
        "--cov-report=term --cov-report=xml --durations=20 "
        "--junitxml=coverage/python/junit.xml"
    )
