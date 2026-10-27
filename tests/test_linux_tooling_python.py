"""Both Ubuntu runners need supported tooling without replacing model Python."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "failure",
    [
        "",
        "runtime",
        "nonempty",
        "symlink",
        "owner",
        "permissions",
        "venv",
        "pip",
        "imports",
    ],
)
def test_tooling_bootstrap_requires_version_locked_dependencies_and_imports(
    tmp_path, failure
):
    log = tmp_path / "commands.jsonl"
    lock = tmp_path / "requirements-dev.lock"
    lock.write_text("controlled hash-locked dependencies\n")
    runtime = tmp_path / "runtime"
    environment = tmp_path / "environment"
    helper = tmp_path / "bootstrap.sh"
    helper.write_text(
        (ROOT / "tools/linux_tooling_python.sh")
        .read_text()
        .replace("/var/tmp/foresight-tooling-python", str(environment))
    )
    launcher = (
        f"#!{sys.executable}\n"
        "import json,os,pathlib,sys\n"
        "def record(value):\n"
        " with open(os.environ['TOOLING_LOG'],'a') as f: f.write(json.dumps(value)+'\\n')\n"
        "if sys.argv[1:4] == ['-m','pip','install']:\n"
        " record(['pip',*sys.argv[4:]])\n"
        " assert sys.argv[4:6] == ['--require-hashes','-r']\n"
        " assert pathlib.Path(sys.argv[6]).read_text() == 'controlled hash-locked dependencies\\n'\n"
        " sys.exit(9 if os.environ['TOOLING_FAILURE']=='pip' else 0)\n"
        "assert sys.argv[1:3] == ['-I','-c']\n"
        "record(['imports'])\n"
        "if os.environ['TOOLING_FAILURE']=='imports': raise ImportError('controlled missing tooling dependency')\n"
        "exec(sys.argv[3])\n"
    )
    runtime.write_text(
        f"#!{sys.executable}\n"
        "import json,os,pathlib,sys\n"
        "def record(value):\n"
        " with open(os.environ['TOOLING_LOG'],'a') as f: f.write(json.dumps(value)+'\\n')\n"
        "if sys.argv[1:3] == ['-I','-c']:\n"
        " if len(sys.argv) == 5:\n"
        "  record(['environment'])\n"
        "  code=sys.argv[3];target=pathlib.Path(sys.argv[4])\n"
        "  failure=os.environ['TOOLING_FAILURE']\n"
        "  if failure=='nonempty':\n"
        "   target.mkdir(mode=0o700);(target/'retained').write_text('must not reuse')\n"
        "  if failure=='symlink':\n"
        "   other=target.with_name('other');other.mkdir();target.symlink_to(other)\n"
        "  if failure=='permissions':target.mkdir(mode=0o777);target.chmod(0o777)\n"
        "  if failure=='owner':\n"
        "   original=os.geteuid;os.geteuid=lambda:original()+1\n"
        "  sys.argv=['-c',str(target)];exec(code);sys.exit(0)\n"
        " record(['runtime'])\n"
        " if os.environ['TOOLING_FAILURE']=='runtime': sys.version_info=(3,12)\n"
        " exec(sys.argv[3]);sys.exit(0)\n"
        "assert sys.argv[1:3] == ['-m','venv']\n"
        "record(['venv'])\n"
        "if os.environ['TOOLING_FAILURE']=='venv': sys.exit(8)\n"
        "p=pathlib.Path(sys.argv[3])/'bin/python';p.parent.mkdir()\n"
        f"p.write_text({launcher!r});p.chmod(0o755)\n"
    )
    runtime.chmod(0o755)
    script = (
        'source "$1"\n'
        'if foresight_select_tooling_python "$2"; then\n'
        ' printf "selected=%s\\n" "$FORESIGHT_PYTHON"\n'
        'else\n printf "preserved=%s\\n" "$FORESIGHT_PYTHON"\n exit 1\nfi\n'
    )
    result = subprocess.run(
        [
            "bash",
            "-euo",
            "pipefail",
            "-c",
            script,
            "bootstrap",
            str(helper),
            str(tmp_path),
        ],
        env={
            **os.environ,
            "FORESIGHT_TOOLING_PYTHON_RUNTIME": str(runtime),
            "FORESIGHT_PYTHON": "original-model-independent-tooling",
            "TOOLING_LOG": str(log),
            "TOOLING_FAILURE": failure,
        },
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    (tmp_path / "bootstrap.log").write_text(result.stdout + result.stderr)
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    expected = ["runtime", "environment", "venv", "pip", "imports"]
    if failure:
        phase = (
            "environment"
            if failure in {"nonempty", "symlink", "owner", "permissions"}
            else failure
        )
        expected = expected[: expected.index(phase) + 1]
        assert result.returncode != 0
        assert "preserved=original-model-independent-tooling" in result.stdout
    else:
        assert result.returncode == 0, result.stdout + result.stderr
        assert f"selected={environment}/bin/python" in result.stdout
    assert [command[0] for command in commands] == expected


@pytest.mark.parametrize("runner", ["build", "test"])
def test_runner_bootstrap_failure_precedes_copy_or_restore(tmp_path, runner):
    workspace = tmp_path / "workspace"
    (workspace / "tools").mkdir(parents=True)
    (workspace / "tools/linux_tooling_python.sh").write_text(
        "foresight_select_tooling_python() {\n"
        " echo 'controlled tooling bootstrap refusal' >&2\n return 41\n}\n"
    )
    script = (ROOT / f"tools/linux_container_{runner}.sh").read_text()
    script = re.sub(
        r"/(workspace|src|out)", lambda match: str(tmp_path / match[1]), script
    )
    result = subprocess.run(
        ["bash", "-c", script],
        env={
            **os.environ,
            "SOURCE_REVISION": "a" * 40,
            "SOURCE_DATE_EPOCH": "1",
            "OUT_UID": str(os.getuid()),
            "OUT_GID": str(os.getgid()),
            "FORESIGHT_PYTHON": "consumer-must-not-run",
        },
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 41, result.stdout + result.stderr
    assert "controlled tooling bootstrap refusal" in result.stderr
    assert not (tmp_path / "src").exists()
