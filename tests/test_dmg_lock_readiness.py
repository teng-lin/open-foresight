"""Real inherited file locks exercise the Mac fixture's setup on POSIX hosts."""

import errno
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def fixture_module(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location(
        "dmg_contract_readiness", ROOT / "tests/test_dmg_contract.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    hdiutil = bin_dir / "hdiutil"
    hdiutil.write_text(
        f"#!{sys.executable}\n"
        "import fcntl, sys\n"
        "from pathlib import Path\n"
        "image = Path(sys.argv[-1])\n"
        "if sys.argv[1] == 'create':\n"
        "    image.write_bytes(b'synthetic image, unchanged through verification')\n"
        "elif sys.argv[1] == 'verify':\n"
        "    with image.open('rb') as stream:\n"
        "        try:\n"
        "            fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)\n"
        "        except BlockingIOError:\n"
        "            print('hdiutil: verify failed - Resource temporarily unavailable', file=sys.stderr)\n"
        "            sys.exit(1)\n"
    )
    hdiutil.chmod(0o755)
    monkeypatch.setenv("PATH", str(bin_dir) + os.pathsep + os.environ["PATH"])
    monkeypatch.setattr(module.tempfile, "tempdir", str(tmp_path))
    return module


def hold_creator_descriptor(monkeypatch, seconds):
    """The completed create process's descendant retains the same locked OFD."""
    import fcntl

    original_run = subprocess.run
    original_flock = fcntl.flock
    children = []
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        result = original_run(command, **kwargs)
        if command[:2] == ["hdiutil", "create"]:
            with Path(command[-1]).open("r+b") as stream:
                original_flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                children.append(
                    subprocess.Popen(
                        [sys.executable, "-c", f"import time; time.sleep({seconds})"],
                        pass_fds=(stream.fileno(),),
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                )
            # Parent descriptor closes before the original create call returns.
        return result

    monkeypatch.setattr(subprocess, "run", run)
    return children, calls


def reap(children):
    for child in children:
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=5)


def test_create_child_lock_must_settle_before_the_unchanged_contention_case(
    fixture_module, monkeypatch
):
    children, calls = hold_creator_descriptor(monkeypatch, 0.2)
    try:
        fixture_module.DmgContractTest().test_verification_waits_for_owned_image_lock_without_changing_bytes()
    finally:
        reap(children)
    assert len(children) == 1
    assert sum(command[:2] == ["hdiutil", "create"] for command in calls) == 1
    assert sum(command[:2] == ["hdiutil", "verify"] for command in calls) >= 4


def test_permanent_creator_lock_fails_before_starting_verification(
    fixture_module, monkeypatch
):
    children, calls = hold_creator_descriptor(monkeypatch, 30)
    try:
        with pytest.raises(BlockingIOError) as error:
            fixture_module.DmgContractTest().test_verification_waits_for_owned_image_lock_without_changing_bytes()
        assert error.value.errno in (errno.EAGAIN, errno.EWOULDBLOCK)
    finally:
        reap(children)
    assert not any(command[:2] == ["hdiutil", "verify"] for command in calls)


def test_other_lock_error_is_not_retried(fixture_module, monkeypatch):
    import fcntl

    attempts = []

    def invalid_descriptor(*args):
        attempts.append(args)
        raise OSError(errno.EBADF, "closed fixture descriptor")

    monkeypatch.setattr(fcntl, "flock", invalid_descriptor)
    with pytest.raises(OSError) as error:
        fixture_module.DmgContractTest().test_verification_waits_for_owned_image_lock_without_changing_bytes()
    assert error.value.errno == errno.EBADF
    assert len(attempts) == 1
