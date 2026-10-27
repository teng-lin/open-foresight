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
    assert temp.parent == real.resolve()
    assert record["test_root"] == str(temp)
    assert record["mode"] == 0o700 and record["uid"] == record["self_uid"]
    argv = record["argv"]
    assert argv[argv.index("--basetemp") + 1] == str(temp)
    assert argv[:2] == ["-m", "pytest"]
    assert argv[2] == str(gate.parents[1] / "tests/service")
    assert not temp.exists(), "The gate must release its own temp root"
    assert Path(env["CALLS"]).read_text() == "native\nworker\n"


def test_default_temp_root_is_private_disk_backed_and_canonical(tmp_path):
    gate, build, python, env = fixture_gate(tmp_path, "linux")
    env.pop("FORESIGHT_TEST_TEMP_ROOT", None)
    env.pop("TMPDIR", None)
    result = run_gate(gate, build, python, "linux", env)
    assert result.returncode == 0, result.stderr
    record = observe(env)
    temp = Path(record["tmp"])
    assert temp.parent == Path("/var/tmp").resolve()
    assert record["canonical"] and record["mode"] == 0o700
    assert record["test_root"] == str(temp)
    assert not temp.exists()


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
    assert not Path(record["tmp"]).exists()
    assert sentinel.read_text() == "not the gate's directory"
