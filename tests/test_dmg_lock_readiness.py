"""Real inherited file locks exercise the Mac fixture's setup on POSIX hosts."""

import errno
import importlib.util
import os
from pathlib import Path
import subprocess
import shutil
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = b"synthetic image, unchanged through verification"


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
        f"expected = {PAYLOAD!r}\n"
        "image = Path(sys.argv[-1])\n"
        "if sys.argv[1] == 'create':\n"
        "    image.write_bytes(expected)\n"
        "elif sys.argv[1] == 'verify':\n"
        "    with image.open('rb') as stream:\n"
        "        try:\n"
        "            fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)\n"
        "        except BlockingIOError:\n"
        "            print('hdiutil: verify failed - Resource temporarily unavailable', file=sys.stderr)\n"
        "            sys.exit(1)\n"
        "        if stream.read() != expected:\n"
        "            print('image checksum mismatch', file=sys.stderr)\n"
        "            sys.exit(2)\n"
    )
    hdiutil.chmod(0o755)
    monkeypatch.setenv("PATH", str(bin_dir) + os.pathsep + os.environ["PATH"])
    monkeypatch.setattr(module.tempfile, "tempdir", str(tmp_path))
    return module


def hold_descriptor(monkeypatch, seconds, phase):
    """A real descendant retains a creator or target OFD after its parent closes."""
    import fcntl

    original_run = subprocess.run
    original_copy = shutil.copyfile
    children, calls, observed = [], [], {}

    def hold(image):
        with Path(image).open("r+b") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            children.append(
                subprocess.Popen(
                    [sys.executable, "-c", f"import time; time.sleep({seconds})"],
                    pass_fds=(stream.fileno(),),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            )
            # This separate open-file description never owns the child's lock.
            observed["probe_fd"] = os.open(image, os.O_RDWR)

    def run(command, **kwargs):
        calls.append(command)
        result = original_run(command, **kwargs)
        if phase == "create" and command[:2] == ["hdiutil", "create"]:
            hold(command[-1])
        return result

    def copy(source, target):
        result = original_copy(source, target)
        observed["source_identity"] = (Path(source).stat().st_dev, Path(source).stat().st_ino)
        observed["target_identity"] = (Path(target).stat().st_dev, Path(target).stat().st_ino)
        if phase == "copy":
            hold(target)
        return result

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr(shutil, "copyfile", copy)
    return children, calls, observed


def reap(children, observed):
    for child in children:
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=5)
    if "probe_fd" in observed:
        os.close(observed["probe_fd"])


def test_retained_creator_inode_does_not_block_the_unchanged_contention_case(
    fixture_module, monkeypatch
):
    import fcntl

    children, calls, observed = hold_descriptor(monkeypatch, 30, "create")
    try:
        fixture_module.DmgContractTest().test_verification_waits_for_owned_image_lock_without_changing_bytes()
        assert len(children) == 1 and children[0].poll() is None
        assert observed["source_identity"] != observed["target_identity"]
        with pytest.raises(BlockingIOError):
            fcntl.flock(observed["probe_fd"], fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert sum(command[:2] == ["hdiutil", "create"] for command in calls) == 1
        assert sum(command[:2] == ["hdiutil", "verify"] for command in calls) >= 4
    finally:
        reap(children, observed)


def test_permanent_target_lock_fails_before_starting_verification(
    fixture_module, monkeypatch
):
    children, calls, observed = hold_descriptor(monkeypatch, 30, "copy")
    try:
        with pytest.raises(BlockingIOError) as error:
            fixture_module.DmgContractTest().test_verification_waits_for_owned_image_lock_without_changing_bytes()
        assert error.value.errno in (errno.EAGAIN, errno.EWOULDBLOCK)
    finally:
        reap(children, observed)
    assert not any(command[:2] == ["hdiutil", "verify"] for command in calls)


def test_invalid_seed_still_fails_checksum_after_target_lock_release(
    fixture_module, monkeypatch
):
    original_run = subprocess.run

    def run(command, **kwargs):
        result = original_run(command, **kwargs)
        if command[:2] == ["hdiutil", "create"]:
            Path(command[-1]).write_bytes(b"invalid seed, copied without alteration")
        return result

    monkeypatch.setattr(subprocess, "run", run)
    with pytest.raises(subprocess.CalledProcessError) as error:
        fixture_module.DmgContractTest().test_verification_waits_for_owned_image_lock_without_changing_bytes()
    assert error.value.returncode == 2
    assert "image checksum mismatch" in error.value.stderr


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
