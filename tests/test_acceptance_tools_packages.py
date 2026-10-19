"""Exercise the actual Docker RUN retry boundary without changing host apt state."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "update_failures,install_failures,success,updates,installs",
    [
        (0, 0, True, 1, 1),
        (1, 0, True, 2, 1),
        (0, 1, True, 2, 2),
        (3, 0, False, 3, 0),
        (0, 3, False, 3, 3),
    ],
)
def test_snapshot_setup_retries_without_using_partial_indexes_or_erasing_work(
    tmp_path,
    update_failures,
    install_failures,
    success,
    updates,
    installs,
):
    lists = tmp_path / "lists"
    lists.mkdir()
    marker = lists / "downloaded-index"
    marker.write_text("retain until successful setup")
    packages = tmp_path / "downloaded-packages"
    packages.write_text("retain between attempts and after installation")
    binary = tmp_path / "bin"
    binary.mkdir()
    apt = binary / "apt-get"
    apt.write_text(
        "#!"
        + sys.executable
        + "\n"
        + """import json,os,sys
from pathlib import Path
state_file=Path(os.environ['APT_TEST_STATE'])
state=json.loads(state_file.read_text()) if state_file.exists() else {'update':0,'install':0,'commands':[]}
command='update' if 'update' in sys.argv else 'install'
state[command]+=1
state['commands'].append(sys.argv[1:])
state_file.write_text(json.dumps(state))
assert Path(os.environ['APT_TEST_MARKER']).exists(), 'discarded verified index between attempts'
assert Path(os.environ['APT_TEST_PACKAGES']).exists(), 'discarded packages between attempts'
limit=int(os.environ['APT_TEST_'+command.upper()+'_FAILURES'])
if state[command]<=limit:
 print('503 Service Unavailable',file=sys.stderr)
 # apt's ordinary update can return success with missing indexes.
 sys.exit(100 if command=='install' or 'APT::Update::Error-Mode=any' in sys.argv else 0)
"""
    )
    apt.chmod(0o755)
    sleep = binary / "sleep"
    sleep.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$APT_TEST_SLEEPS"\n')
    sleep.chmod(0o755)
    source = (ROOT / "packaging/acceptance.Dockerfile").read_text()
    command = (
        source.split("RUN ", 1)[1].split("\n# The cached SDK", 1)[0].replace("\\\n", "")
    )
    # Keep the real shell/control flow, redirecting only its image cleanup path.
    command = command.replace("/var/lib/apt/lists/*", shlex.quote(str(lists)) + "/*")
    state = tmp_path / "state.json"
    sleeps = tmp_path / "sleeps"
    result = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", command],
        env={
            **os.environ,
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "UBUNTU_SNAPSHOT": "20261001T000000Z",
            "APT_TEST_STATE": str(state),
            "APT_TEST_MARKER": str(marker),
            "APT_TEST_PACKAGES": str(packages),
            "APT_TEST_SLEEPS": str(sleeps),
            "APT_TEST_UPDATE_FAILURES": str(update_failures),
            "APT_TEST_INSTALL_FAILURES": str(install_failures),
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    calls = json.loads(state.read_text())
    assert calls["update"] == updates and calls["install"] == installs
    for arguments in calls["commands"]:
        assert "Acquire::Retries=3" in arguments
        assert arguments[arguments.index("--snapshot") + 1] == "20261001T000000Z"
    assert marker.exists() != success
    assert packages.read_text() == "retain between attempts and after installation"
    assert (sleeps.read_text().splitlines() if sleeps.exists() else []) == ["10"] * (
        updates - 1
    )
    if not success:
        assert "503 Service Unavailable" in result.stderr
        assert "failed after three attempts" in result.stderr
