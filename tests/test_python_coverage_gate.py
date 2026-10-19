"""The repository coverage policy measures children and fails below its threshold."""

import configparser
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def test_coverage_instruments_children_and_counts_unexecuted_production_files(tmp_path):
    policy = (ROOT / ".coveragerc").read_text()
    config = configparser.ConfigParser()
    config.read_string(policy)
    assert config.getboolean("run", "branch")
    assert config.getfloat("report", "fail_under") >= 95
    (tmp_path / ".coveragerc").write_text(policy)
    (tmp_path / "tools").mkdir()
    (tmp_path / "packaging").mkdir()
    (tmp_path / "native").mkdir()
    (tmp_path / "tools/parent.py").write_text(
        "import subprocess\nimport sys\n"
        'subprocess.run([sys.executable, "tools/child.py", sys.argv[1]], check=True, timeout=10)\n'
    )
    (tmp_path / "tools/child.py").write_text(
        'import sys\nif sys.argv[1] == "yes":\n    print("positive child")\nelse:\n    print("negative child")\n'
    )
    (tmp_path / "packaging/cold.py").write_text("answer = 42\nprint(answer)\n")
    (tmp_path / "tools/test_harness.py").write_text(
        'raise RuntimeError("opt-in harness is outside production coverage")\n'
    )
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("COVERAGE", "COV_CORE"))
    }

    def run(*args, success=True):
        result = subprocess.run(
            [sys.executable, "-m", "coverage", *args],
            cwd=tmp_path,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if success:
            assert result.returncode == 0, result.stdout + result.stderr
        return result

    run("run", "tools/parent.py", "yes")
    run("combine")
    failed = run("report", success=False)
    assert failed.returncode == 2
    assert "fail-under=95" in failed.stdout
    run("json", "--fail-under=0", "-o", "first.json")
    files = json.loads((tmp_path / "first.json").read_text())["files"]
    assert files["tools/child.py"]["summary"]["covered_lines"] > 0
    assert files["packaging/cold.py"]["summary"]["covered_lines"] == 0
    assert "tools/test_harness.py" not in files
    run("run", "tools/parent.py", "no")
    run("run", "packaging/cold.py")
    run("combine", "--append")
    run("report")
