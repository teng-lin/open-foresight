"""Real process boundaries preserve every Linux gate and serialize Flutter work."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

import pytest

from tools import linux_test_schedule as schedule
from tools import parallel_build_gates

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def runner(tmp_path):
    root = tmp_path / "source with spaces"
    tools = root / "tools"
    tools.mkdir(parents=True)
    for name in ("linux_test_schedule.py", "parallel_build_gates.py"):
        shutil.copy2(ROOT / "tools" / name, tools / name)
    binary = tmp_path / "bin"
    binary.mkdir()
    for name, strip in (("xvfb-run", 1), ("dbus-run-session", 1)):
        tool = binary / name
        tool.write_text(
            f"#!{sys.executable}\nimport os,sys\n"
            f"args=sys.argv[{strip + 1}:]\nos.execvpe(args[0],args,os.environ)\n"
        )
        tool.chmod(0o755)
    (tools / "build.sh").write_text(
        '#!/bin/bash\nexec "$FORESIGHT_PYTHON" "$(dirname "$0")/fake.py" "$@"\n'
    )
    (tools / "fake.py").write_text("""import json,os,subprocess,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
args=sys.argv[1:]
if os.getenv('REQUIRE_RESTORE')=='1':assert (root/'restore.done').exists()
if args==['--test-only']:
    name='application'
elif '--stage' in args:
    assert args[:3]==['--platform','linux','--test-only'],args
    name=args[args.index('--stage')+1]
else:
    name='host' if '--platform' in args else 'fast'
    if name=='host' and '--basetemp' in args:assert args==['--platform','linux','--basetemp',os.environ['TMPDIR']+'/pytest','--cache-dir',os.environ['TMPDIR']+'/pytest-cache'],args
    if name=='fast':
        native='build/native/libforesight_native.so' if args[args.index('--native')+1].startswith('build/') else str(root/'build/native/libforesight_native.so')
        assert args==['--suite','fast','--native',native,'--output','test-results/fast-integration'],args
if os.getenv('REQUIRE_RESTORE')!='1':assert os.environ['FORESIGHT_BUILD_MODE']=='test-only'
(root/(name+'.started')).touch()
with open(root/(name+'.env.json'),'w') as f:
    json.dump({k:os.environ[k] for k in ['TMPDIR','FORESIGHT_TEST_TEMP_ROOT','PYTHONPYCACHEPREFIX']},f)
print(name+' diagnostics',flush=True)
if name not in ['native','application'] and os.getenv('REQUIRE_RESTORE')!='1':assert (root/'native.done').exists()
def wait(marker):
    end=time.monotonic()+5
    while not (root/marker).exists():
        if time.monotonic()>end:raise RuntimeError('gate did not overlap: '+marker)
        time.sleep(.01)
if os.getenv('CANCEL_MODE')=='1' and name=='core':
    child="import signal,sys,time; from pathlib import Path; p=Path(sys.argv[1]); signal.signal(signal.SIGTERM,lambda *a:(p.write_text('stopped'),sys.exit(0))); p.with_suffix('.ready').touch(); time.sleep(60)"
    subprocess.Popen([sys.executable,'-c',child,str(root/'descendant.stopped')])
    wait('descendant.ready')
    time.sleep(60)
if os.getenv('FAIL_STAGE')==name:raise SystemExit(7)
if not os.getenv('FAIL_STAGE') and os.getenv('REQUIRE_RESTORE')!='1':
    if name=='core':wait('fast.done')
    if name=='host':
        wait('core.started');wait('desktop.started')
if name=='fast' and os.getenv('REQUIRE_RESTORE')!='1':assert (root/'desktop.done').exists()
if name=='service':
    for other in ['core','desktop','fast','host']:assert (root/(other+'.done')).exists()
if name in ['service','application']:
    xml=root/'test-results/service/results.xml';xml.parent.mkdir(parents=True,exist_ok=True)
    xml.write_text('<testsuite><testcase>'+('<skipped/>' if os.getenv('FORGE_SKIP')=='1' else '')+'</testcase></testsuite>')
(root/(name+'.done')).touch()
report=root/'test-results'/name/'report.json';report.parent.mkdir(parents=True,exist_ok=True);report.write_text('{}')
""")
    for name in ("platform_python_tests.py", "integration_gates.py"):
        (tools / name).write_text((tools / "fake.py").read_text())
    env = {
        **os.environ,
        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
        "FORESIGHT_PYTHON": sys.executable,
    }
    return root, env


def run(runner, failure=""):
    root, env = runner
    result = subprocess.run(
        [sys.executable, str(root / "tools/linux_test_schedule.py")],
        env={**env, "FAIL_STAGE": failure},
        capture_output=True,
        text=True,
        timeout=15,
    )
    return root, result


def test_core_desktop_fast_and_host_overlap_without_flutter_collision(runner):
    root, result = run(runner)
    assert result.returncode == 0, result.stdout + result.stderr
    for name in ("native", "core", "desktop", "fast", "host", "service"):
        assert (root / "test-results" / name / "report.json").exists()
    envs = [
        json.loads((root / (n + ".env.json")).read_text())
        for n in ("core", "desktop", "host")
    ]
    assert len({e["TMPDIR"] for e in envs}) == 3
    for e in envs:
        assert e["FORESIGHT_TEST_TEMP_ROOT"] == e["TMPDIR"]
        assert e["PYTHONPYCACHEPREFIX"].startswith(e["TMPDIR"])
    logs = root / "test-results/linux-test-schedule"
    assert "desktop diagnostics" in (logs / "desktop.log").read_text()
    assert "fast diagnostics" in (logs / "desktop.log").read_text()
    assert "core diagnostics" in (logs / "core.log").read_text()


@pytest.mark.parametrize(
    "failure", ["native", "core", "desktop", "fast", "host", "service"]
)
def test_failed_stage_cannot_be_hidden_by_a_later_success(runner, failure):
    root, result = run(runner, failure)
    assert result.returncode != 0
    assert not (root / "service.done").exists()
    if failure == "native":
        assert not (root / "core.started").exists()
        assert not (root / "host.started").exists()
    elif failure == "desktop":
        assert not (root / "fast.started").exists()
    logs = root / "test-results/linux-test-schedule"
    owner = "desktop" if failure == "fast" else failure
    assert failure + " diagnostics" in (logs / (owner + ".log")).read_text()
    if failure in ("core", "desktop", "fast", "host"):
        for name in ("core", "desktop", "host"):
            assert (logs / (name + ".log")).exists()


def test_partial_launch_reaps_previously_started_branches(runner, monkeypatch):
    root, env = runner
    original = parallel_build_gates.subprocess.Popen
    processes = []

    def launch(command, **kwargs):
        if "--branch" in command and command[command.index("--branch") + 1] == "host":
            raise OSError("host launch failed")
        process = original(command, env=env, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(parallel_build_gates.subprocess, "Popen", launch)
    with pytest.raises(OSError, match="host launch failed"):
        schedule.schedule(root, sys.executable)
    assert all(p.poll() is not None for p in processes)
    assert (root / "test-results/linux-test-schedule/core.log").exists()
    assert not (root / "service.started").exists()


def test_cancellation_reaps_owned_branch_and_descendant(runner):
    root, env = runner
    log = root / "scheduler-parent.log"
    with log.open("wb") as output:
        process = subprocess.Popen(
            [sys.executable, str(root / "tools/linux_test_schedule.py")],
            env={**env, "CANCEL_MODE": "1"},
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 8
            while not (root / "descendant.ready").exists():
                assert process.poll() is None, log.read_text()
                assert time.monotonic() < deadline, log.read_text()
                time.sleep(0.01)
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=8) == 143, log.read_text()
            deadline = time.monotonic() + 3
            while not (root / "descendant.stopped").exists():
                assert time.monotonic() < deadline, log.read_text()
                time.sleep(0.01)
            assert not (root / "service.started").exists()
            assert (root / "test-results/linux-test-schedule/core.log").exists()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=8)


@pytest.mark.parametrize("mode", [None, "0", "1", "bad"])
@pytest.mark.parametrize("forge_skip", [False, True])
def test_container_entrypoint_restores_first_and_honors_schedule_switch(
    runner, mode, tmp_path, forge_skip
):
    root, env = runner
    workspace = tmp_path / "workspace"
    (workspace / "tools").mkdir(parents=True)
    # Dependency/version failures are covered by the bootstrap unit and real
    # two-container tests; this fixture owns restore/scheduling order.
    (workspace / "tools/linux_tooling_python.sh").write_text(
        "foresight_select_tooling_python() {\n"
        ' test -n "$FORESIGHT_PYTHON"\n'
        f" touch '{root}/tooling.ready'\n"
        "}\n"
    )
    (workspace / "tools/ci_linux_handoff.py").write_text(
        "from pathlib import Path; import sys\n"
        "assert sys.argv[1]=='restore' and '--inputs' in sys.argv\n"
        f"assert Path({str(root)!r},'tooling.ready').exists()\n"
        "Path(sys.argv[sys.argv.index('--root')+1],'restore.done').touch()\n"
    )
    output = tmp_path / "out"
    mounted_source = tmp_path / "container-src"
    mounted_source.symlink_to(root, target_is_directory=True)
    script = (ROOT / "tools/linux_container_test.sh").read_text()
    # Substitute mount tokens in two passes, never resubstitute inserted paths.
    for source, token in (
        ("/workspace", "@WORKSPACE@"),
        ("/src", "@SRC@"),
        ("/out", "@OUT@"),
        ("/handoff", "@HANDOFF@"),
    ):
        script = script.replace(source, token)
    for token, value in (
        ("@WORKSPACE@", workspace),
        ("@SRC@", mounted_source),
        ("@OUT@", output),
        ("@HANDOFF@", tmp_path / "handoff"),
    ):
        script = script.replace(token, str(value))
    entrypoint = tmp_path / "container-entrypoint.sh"
    entrypoint.write_text(script)
    scoped = {
        **env,
        "REQUIRE_RESTORE": "1",
        "FORGE_SKIP": "1" if forge_skip else "0",
        "SOURCE_REVISION": "a" * 40,
        "OUT_UID": str(os.getuid()),
        "OUT_GID": str(os.getgid()),
        "FORESIGHT_BUILD_MODE": "test-only",
        "TMPDIR": str(tmp_path),
        "FORESIGHT_TEST_TEMP_ROOT": str(tmp_path),
        "PYTHONPYCACHEPREFIX": str(tmp_path / "pycache"),
    }
    scoped.pop("FORESIGHT_LINUX_TEST_SCHEDULE", None)
    if mode is not None:
        scoped["FORESIGHT_LINUX_TEST_SCHEDULE"] = mode
    result = subprocess.run(
        ["bash", str(entrypoint)],
        env=scoped,
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert (root / "tooling.ready").exists()
    assert (root / "restore.done").exists()
    assert (result.returncode == 0) == (mode != "bad" and not forge_skip), (
        result.stdout + result.stderr
    )
    if mode == "0":
        assert (root / "application.done").exists()
        assert not (root / "native.started").exists()
    elif mode != "bad":
        assert (root / "native.done").exists()
        assert not (root / "application.started").exists()
    if mode != "bad":
        report = output / "test-results/service/results.xml"
        assert report.exists()
        if forge_skip:
            assert "must have zero skips" in result.stderr
            assert "<skipped/>" in report.read_text()
