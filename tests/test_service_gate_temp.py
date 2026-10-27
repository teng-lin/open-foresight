"""Compiled service tests give native capture a canonical, owned temp root."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

GATE = Path(__file__).resolve().parents[1] / "tools/build_service_gate.sh"


def fixture_gate(
    tmp_path: Path, platform: str
) -> tuple[Path, Path, Path, dict[str, str]]:
    root = tmp_path / "repository"
    tools = root / "tools"
    tools.mkdir(parents=True)
    gate = tools / GATE.name
    gate.write_bytes(GATE.read_bytes())
    (tools / "ci_timing.sh").write_text('ci_timed() { shift; "$@"; }\n')
    (tools / "runtime_support_gate.sh").write_text(
        'foresight_verify_runtime_support() { printf "native\\n" >> "$CALLS"; }\n'
        'foresight_diagnostic_worker() { printf "worker\\n" >> "$CALLS"; }\n'
    )
    build = root / "build"
    for name in (
        "application/foresight-service",
        "application/foresight-mcp",
        "services/helper/ForesightHelper",
        "services/helper/model_worker_fixture",
    ):
        target = build / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("controlled prerequisite\n")
        target.chmod(0o755)
    suffix = "dylib" if platform == "macos" else "so"
    native = build / f"native/libforesight_native.{suffix}"
    native.parent.mkdir()
    native.touch()
    if platform == "macos":
        sqlite = build / "macos/libforesight_sqlite3.dylib"
        sqlite.parent.mkdir()
        sqlite.touch()
    python = root / "observe-python"
    python.write_text(
        f"#!{sys.executable}\n"
        "import json,os,pathlib,stat,sys\n"
        "temp=os.environ.get('TMPDIR')\n"
        "record={'argv':sys.argv[1:], 'tmp':temp, "
        "'test_root':os.environ.get('FORESIGHT_TEST_TEMP_ROOT'), "
        "'canonical':bool(temp) and os.path.realpath(temp)==temp, "
        "'mode':stat.S_IMODE(os.stat(temp).st_mode) if temp else None, "
        "'uid':os.stat(temp).st_uid if temp else None, 'self_uid':os.getuid()}\n"
        "base=sys.argv[sys.argv.index('--basetemp')+1]\n"
        "record['basetemp_mode']=stat.S_IMODE(os.stat(base).st_mode)\n"
        "record['basetemp_canonical']=os.path.realpath(base)==base\n"
        "pathlib.Path(os.environ['OBSERVATION']).write_text(json.dumps(record))\n"
        "print('controlled service stdout', flush=True)\n"
        "print('controlled service stderr',file=sys.stderr,flush=True)\n"
        "sys.exit(int(os.environ.get('SERVICE_EXIT','0')))\n"
    )
    python.chmod(0o755)
    env = dict(
        os.environ,
        OBSERVATION=str(root / "observation.json"),
        CALLS=str(root / "calls"),
    )
    return gate, build, python, env


def run_gate(gate: Path, build: Path, python: Path, platform: str, env: dict[str, str]):
    return subprocess.run(
        ["bash", str(gate), platform, str(build), str(python)],
        env=env,
        capture_output=True,
        timeout=30,
        check=False,
    )


def observe(env: dict[str, str]) -> dict:
    return json.loads(Path(env["OBSERVATION"]).read_text())


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_alias_temp_root_is_canonical_and_shared_with_all_test_children(
    tmp_path, platform
):
    gate, build, python, env = fixture_gate(tmp_path, platform)
    real = tmp_path / "owned-temp"
    real.mkdir(mode=0o700)
    alias = tmp_path / "temp-alias"
    alias.symlink_to(real, target_is_directory=True)
    env.update(TMPDIR=str(alias), FORESIGHT_TEST_TEMP_ROOT=str(alias))
    result = run_gate(gate, build, python, platform, env)
    assert result.returncode == 0, result.stderr
    record = observe(env)
    temp = Path(record["tmp"])
    assert record["canonical"]
    assert temp.name == "tmp" and temp.parent.parent == real.resolve()
    assert record["test_root"] == str(temp)
    assert record["mode"] == 0o700 and record["uid"] == record["self_uid"]
    argv = record["argv"]
    assert argv[argv.index("--basetemp") + 1] == str(temp.parent / "pytest")
    assert record["basetemp_mode"] == 0o700 and record["basetemp_canonical"]
    assert argv[:2] == ["-m", "pytest"]
    assert argv[2] == str(gate.parents[1] / "tests/service")
    assert not temp.parent.exists(), "The gate must release its entire owned root"
    assert Path(env["CALLS"]).read_text() == "native\nworker\n"


def test_default_temp_root_is_private_disk_backed_and_canonical(tmp_path):
    gate, build, python, env = fixture_gate(tmp_path, "linux")
    env.pop("FORESIGHT_TEST_TEMP_ROOT", None)
    env.pop("TMPDIR", None)
    result = run_gate(gate, build, python, "linux", env)
    assert result.returncode == 0, result.stderr
    record = observe(env)
    temp = Path(record["tmp"])
    assert temp.parent.parent == Path("/var/tmp").resolve()
    assert record["canonical"] and record["mode"] == 0o700
    assert record["test_root"] == str(temp)
    assert not temp.parent.exists()


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_test_failure_keeps_raw_output_and_cleans_only_owned_temp(tmp_path, platform):
    gate, build, python, env = fixture_gate(tmp_path, platform)
    real = tmp_path / "owned-temp"
    real.mkdir(mode=0o700)
    sentinel = real / "retain-this"
    sentinel.write_text("not the gate's directory")
    alias = tmp_path / "temp-alias"
    alias.symlink_to(real, target_is_directory=True)
    env.update(TMPDIR=str(alias), FORESIGHT_TEST_TEMP_ROOT=str(alias), SERVICE_EXIT="7")
    result = run_gate(gate, build, python, platform, env)
    assert result.returncode == 7
    assert result.stdout == b"controlled service stdout\n"
    assert result.stderr == b"controlled service stderr\n"
    record = observe(env)
    assert record["canonical"]
    assert record["tmp"] == record["test_root"]
    assert not Path(record["tmp"]).parent.exists()
    assert sentinel.read_text() == "not the gate's directory"


def test_real_pytest_basetemp_does_not_delete_earlier_tempfile(tmp_path):
    gate, build, _python, env = fixture_gate(tmp_path, "linux")
    root = gate.parents[1]
    (root / "pytest.ini").write_text("[pytest]\n")
    service = root / "tests/service"
    service.mkdir(parents=True)
    (service / "conftest.py").write_text(
        "import os,pathlib\n"
        "def pytest_configure(config):\n"
        " pathlib.Path(os.environ['TMPDIR'],'session-sentinel').write_text('preserved')\n"
    )
    (service / "test_lifetime.py").write_text(
        "import os,pathlib\n"
        "def test_first_tmp_path_keeps_earlier_session_files(tmp_path):\n"
        " assert pathlib.Path(os.environ['TMPDIR'],'session-sentinel').read_text()=='preserved'\n"
        " assert tmp_path.exists()\n"
    )
    parent = tmp_path / "owned-temp"
    parent.mkdir(mode=0o700)
    env.update(
        FORESIGHT_TEST_TEMP_ROOT=str(parent), TMPDIR=str(parent), PYTEST_ADDOPTS=""
    )
    result = run_gate(gate, build, Path(sys.executable), "linux", env)
    (tmp_path / "real-pytest-stdout.log").write_bytes(result.stdout)
    (tmp_path / "real-pytest-stderr.log").write_bytes(result.stderr)
    assert result.returncode == 0, result.stdout + result.stderr
    assert b"1 passed" in result.stdout
    assert not list(parent.iterdir()), "The gate must release its entire owned tree"


def test_failed_canonicalization_retains_original_cleanup_owner(tmp_path):
    gate, build, python, env = fixture_gate(tmp_path, "linux")
    parent = tmp_path / "owned-temp"
    parent.mkdir(mode=0o700)
    record = tmp_path / "created-root"
    startup = tmp_path / "controlled-shell-startup"
    startup.write_text(
        'pwd() { case "$PWD" in */of-svc.*) '
        'printf "%s" "$PWD" > "$CREATED_ROOT"; return 17;; '
        'esac; builtin pwd "$@"; }\n'
    )
    env.update(
        FORESIGHT_TEST_TEMP_ROOT=str(parent),
        BASH_ENV=str(startup),
        CREATED_ROOT=str(record),
    )
    result = run_gate(gate, build, python, "linux", env)
    assert result.returncode == 17
    assert record.is_file(), "The controlled failure must occur after root creation"
    assert not Path(record.read_text()).exists()
    assert not Path(env["OBSERVATION"]).exists(), (
        "Tests must not start after setup fails"
    )
