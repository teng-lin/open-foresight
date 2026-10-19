"""Upgrade deferrals and rollback errors preserve the installed application."""

import json
from pathlib import Path
import shutil
import subprocess
from unittest.mock import Mock

import pytest
from test_macos_tools import installer, bundle, portable_swap, SIGNATURE
from test_macos_binary_contracts import bundle as macho_tools


@pytest.fixture
def applications(tmp_path, monkeypatch):
    source = bundle(tmp_path / "Source.app", "new")
    target = bundle(tmp_path / "Installed.app", "old")
    monkeypatch.setattr(
        installer, "copy_application", lambda s, d: shutil.copytree(s, d, symlinks=True)
    )
    monkeypatch.setattr(
        installer, "installation_lock_path", lambda app: tmp_path / "private/lock"
    )
    return source, target


@pytest.mark.parametrize(
    "failure",
    ["symlink", "suffix", "nested", "adhoc", "staged-signature", "launch-race"],
)
def test_invalid_install_never_modifies_existing_app(applications, failure):
    source, target = applications
    verify = Mock(return_value=SIGNATURE)
    options = {"verify": verify, "active": lambda app: {}, "swap": portable_swap}
    if failure == "symlink":
        link = source.with_name("Link.app")
        link.symlink_to(source)
        source = link
    elif failure == "suffix":
        source = source.rename(source.with_suffix(".bundle"))
    elif failure == "nested":
        source = bundle(target / "Nested.app", "new")
    elif failure == "adhoc":
        verify.return_value = {"team": None, "adhoc": True}
    elif failure == "staged-signature":
        verify.side_effect = [SIGNATURE, SIGNATURE, {"team": "other", "adhoc": False}]
    else:
        options["active"] = Mock(side_effect=[{}, {42: "service"}])
    with pytest.raises((ValueError, installer.Deferred)):
        installer.install(source, target, **options)
    assert (target / "version").read_text() == "old"
    assert not list(target.parent.glob(".open-foresight-install-*"))


@pytest.mark.parametrize("rollback", [False, True])
def test_first_install_can_roll_back_failed_post_install_signature(
    applications, rollback
):
    source, target = applications
    shutil.rmtree(target)

    def verify(path):
        return (
            {"team": "unexpected", "adhoc": False}
            if rollback and path == target
            else SIGNATURE
        )

    if rollback:
        with pytest.raises(ValueError, match="Installed signature"):
            installer.install(source, target, verify=verify, active=lambda _: {})
        assert not target.exists()
    else:
        installer.install(source, target, verify=verify, active=lambda _: {})
        assert (target / "version").read_text() == "new"
    assert (source / "version").read_text() == "new"


@pytest.mark.parametrize(
    "failure", ["profiles", "status", "incomplete", "identity", "still-running"]
)
def test_shutdown_defers_when_owner_cannot_be_completely_verified(
    applications, monkeypatch, failure
):
    _, target = applications
    executable = (target / installer.SERVICE).resolve()
    calls = []

    def run(args, **kw):
        calls.append(args)
        value = (
            {"pid": 42}
            if args[-1] == "--status"
            else {"stopped": True, "shutdown_verified": True}
        )
        return subprocess.CompletedProcess(
            args, int(failure == "status"), json.dumps(value), "diagnostic"
        )

    monkeypatch.setattr(installer.subprocess, "run", run)
    monkeypatch.setattr(installer.subprocess, "check_output", lambda *a, **kw: "42 1\n")
    path = (
        Mock(side_effect=[executable, None])
        if failure == "identity"
        else Mock(return_value=executable)
    )
    monkeypatch.setattr(installer, "process_path", path)
    monkeypatch.setattr(installer.time, "monotonic", Mock(side_effect=[0, 16]))
    active = {
        42: str(executable),
        **({43: str(executable)} if failure == "incomplete" else {}),
    }
    with pytest.raises(installer.Deferred):
        installer.stop_owned_services(
            target, active, [] if failure == "profiles" else [target.parent / "profile"]
        )
    assert (target / "version").read_text() == "old"
    assert len(calls) == (
        0 if failure == "profiles" else 2 if failure == "still-running" else 1
    )


def test_installation_lock_rejects_public_file_and_atomic_swap_propagates_errno(
    tmp_path, monkeypatch
):
    path = tmp_path / "private/lock"
    path.parent.mkdir(mode=0o700)
    path.write_text("")
    path.chmod(0o644)
    monkeypatch.setattr(installer, "installation_lock_path", lambda app: path)
    with pytest.raises(ValueError, match="private user-owned"):
        with installer.installation_lock(tmp_path / "app"):
            pytest.fail("unsafe lock acquired")
    operation = Mock(return_value=1)
    library = Mock(renamex_np=operation)
    monkeypatch.setattr(installer.ctypes, "CDLL", lambda *a, **kw: library)
    monkeypatch.setattr(installer.ctypes, "get_errno", lambda: 5)
    with pytest.raises(OSError) as error:
        installer.atomic_swap(tmp_path / "first", tmp_path / "second")
    assert error.value.errno == 5


def test_executable_relative_loads_require_context_and_system_cache_probe_fails_closed(
    tmp_path, monkeypatch
):
    app = tmp_path / "Fixture.app"
    owner = app / "Contents/Resources/lib/library.dylib"
    owner.parent.mkdir(parents=True)
    owner.write_bytes(b"library")
    with pytest.raises(ValueError, match="Executable context"):
        macho_tools.resolve_dependency(
            "@executable_path/../lib/private.dylib", owner, app
        )
    monkeypatch.setattr(macho_tools, "rpaths", lambda _: ["@executable_path/../lib"])
    with pytest.raises(ValueError, match="Unresolved"):
        macho_tools.resolve_dependency("@rpath/private.dylib", owner, app)
    binary = app / "Contents/lib/private.dylib"
    binary.parent.mkdir()
    binary.write_bytes(b"private")
    (app / "Contents/MacOS").mkdir()
    assert (
        macho_tools.resolve_dependency(
            "@executable_path/../lib/private.dylib",
            owner,
            app,
            app / "Contents/MacOS/desktop",
        )
        == binary.resolve()
    )
    monkeypatch.setattr(macho_tools, "run", lambda *a: "DYLIB")
    assert macho_tools.executable_context(owner, app) is None
    macho_tools.shared_cache_library.cache_clear()
    monkeypatch.setattr(macho_tools.sys, "platform", "darwin")
    monkeypatch.setattr(
        macho_tools.ctypes, "CDLL", Mock(side_effect=OSError("unavailable"))
    )
    assert (
        macho_tools.shared_cache_library(Path("/usr/lib/not-a-library.dylib")) is False
    )
    macho_tools.shared_cache_library.cache_clear()
