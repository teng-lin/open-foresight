"""Test-only builds verify a qualified consumer before the unchanged idle guard."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


def invoke(
    tmp_path, *, stage="native", configure_failure=False, work=False, transition=False
):
    root = tmp_path / "project"
    tools = root / "tools"
    tools.mkdir(parents=True)
    for name in (
        "build.sh",
        "ci_timing.sh",
        "verify_application_no_build.py",
        "parallel_build_gates.py",
    ):
        shutil.copy2(ROOT / "tools" / name, tools / name)
    build = root / "build"
    build.mkdir()
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.jsonl"
    cmake = binary / "cmake"
    cmake.write_text(
        "#!" + sys.executable + "\n"
        "import json,os,pathlib,sys\n"
        "args=sys.argv[1:]\n"
        "with open(os.environ['COMMAND_LOG'],'a') as f: f.write(json.dumps(args)+'\\n')\n"
        "if '--build' not in args:\n"
        " if '-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=OFF' in args:\n"
        "  assert pathlib.Path(os.environ['BUILD_ROOT'],'consumer-ready').exists();sys.exit(0)\n"
        " assert args == ['-S',os.environ['PROJECT_ROOT'],'-B',os.environ['BUILD_ROOT'],'-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=ON']\n"
        " if os.environ['CONFIGURE_FAILURE']=='1':\n"
        "  print('current source differs from qualified receipt',file=sys.stderr);sys.exit(5)\n"
        " pathlib.Path(os.environ['BUILD_ROOT'],'consumer-ready').touch()\n"
        "else:\n"
        " if '-n' not in args: sys.exit(0)\n"
        " ready=pathlib.Path(os.environ['BUILD_ROOT'],'consumer-ready').exists()\n"
        " print('cc source.c -o source.o' if not ready or os.environ['PLAN_WORK']=='1' else 'ninja: no work to do.')\n"
    )
    cmake.chmod(0o755)
    ctest_log = tmp_path / "ctest.jsonl"
    ctest = binary / "ctest"
    ctest.write_text(
        "#!" + sys.executable + "\n"
        "import json,os,pathlib,sys\n"
        "assert sys.argv[1:] == ['--test-dir',os.environ['BUILD_ROOT'],"
        "'--output-on-failure','--output-junit',"
        "os.environ['PROJECT_ROOT']+'/test-results/linux/native/results.xml']\n"
        "with open(os.environ['CTEST_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
    )
    ctest.chmod(0o755)
    python = binary / "tool-python"
    python.write_text(
        "#!" + sys.executable + "\n"
        "import os,pathlib,sys\n"
        "if pathlib.Path(sys.argv[1]).name in ('check_build_cache.py','verify_toolchain_pins.py','verify_descriptor.py'): sys.exit(0)\n"
        "os.execv(sys.executable,[sys.executable,*sys.argv[1:]])\n"
    )
    python.chmod(0o755)
    env = dict(
        os.environ,
        CI="false",
        FORESIGHT_REQUIRE_DART_GATES="0",
        FORESIGHT_REQUIRE_APP_DEPENDENCY_REUSE="0",
        FORESIGHT_PYTHON=str(python),
        FORESIGHT_BUILD_DIR=str(build),
        PATH=str(binary) + os.pathsep + "/usr/bin:/bin",
        COMMAND_LOG=str(log),
        CTEST_LOG=str(ctest_log),
        PROJECT_ROOT=str(root),
        BUILD_ROOT=str(build),
        CONFIGURE_FAILURE=str(int(configure_failure)),
        PLAN_WORK=str(int(work)),
    )
    result = subprocess.run(
        [
            "bash",
            str(tools / "build.sh"),
            "--platform",
            "linux",
            "--stage",
            stage,
            "--test-only",
        ],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )
    if transition:
        assert result.returncode == 0, result.stdout + result.stderr
        result = subprocess.run(
            [
                "bash",
                str(tools / "build.sh"),
                "--platform",
                "linux",
                "--stage",
                stage,
                "--build-only",
            ],
            env=env,
            text=True,
            capture_output=True,
            timeout=30,
        )
    if result.returncode == 0:
        assert len(ctest_log.read_text().splitlines()) == 1
    elif configure_failure or work:
        assert not ctest_log.exists()
    return result, [json.loads(line) for line in log.read_text().splitlines()]


@pytest.mark.parametrize("stage", ["native", "all"])
def test_consumer_configuration_precedes_full_idle_guard(tmp_path, stage):
    result, commands = invoke(tmp_path, stage=stage)
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(commands) == 2
    assert commands[0][-1] == "-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=ON"
    assert commands[1][0] == "--build" and commands[1][-1] == "-n"
    assert "Verified full application dry-run" in result.stdout


def test_consumer_refusal_never_reaches_idle_guard_or_build(tmp_path):
    result, commands = invoke(tmp_path, configure_failure=True)
    assert result.returncode == 5
    assert "current source differs from qualified receipt" in result.stderr
    assert len(commands) == 1


def test_consumer_mode_never_waives_real_work_in_full_plan(tmp_path):
    result, commands = invoke(tmp_path, work=True)
    assert result.returncode != 0
    assert len(commands) == 2
    assert "Restored application build is not idle" in result.stderr
    assert "cc source.c -o source.o" in result.stderr


def test_normal_producer_explicitly_resets_cached_consumer_mode(tmp_path):
    result, commands = invoke(tmp_path, transition=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(commands) == 4
    assert commands[0][-1] == "-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=ON"
    assert commands[2][-1] == "-DFORESIGHT_RUNTIME_SUPPORT_CONSUMER=OFF"
    assert commands[3][0] == "--build" and "-n" not in commands[3]
