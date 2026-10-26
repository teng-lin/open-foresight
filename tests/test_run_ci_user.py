"""Linux runtime gates preserve trust boundaries while dropping container root."""

import importlib.util
import os
from pathlib import Path
import stat
import sys
from types import SimpleNamespace

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "run_ci_user", ROOT / "tools/run_ci_user.py"
)
assert spec and spec.loader
user = importlib.util.module_from_spec(spec)
spec.loader.exec_module(user)


def test_owner_is_derived_from_ancestors_even_when_checkout_is_root(
    tmp_path, monkeypatch
):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    original = Path.lstat

    def metadata(path):
        info = original(path)
        return SimpleNamespace(
            st_mode=info.st_mode,
            st_uid=1234 if path == tmp_path else 0,
            st_gid=2345 if path == tmp_path else 0,
        )

    monkeypatch.setattr(Path, "lstat", metadata)
    assert user.workspace_owner(workspace) == (1234, 2345)


@pytest.mark.parametrize("case", ["root", "group", "mixed", "writable"])
def test_unsafe_or_ambiguous_workspace_fails_before_mutation(
    tmp_path, monkeypatch, case
):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    original = Path.lstat

    def metadata(path):
        info = original(path)
        uid = 1234 if path in (tmp_path, workspace) else 0
        gid = 2345
        mode = info.st_mode
        if case == "root":
            uid = 0
        if case == "group":
            gid = 0
        if case == "mixed" and path == workspace:
            uid = 4321
        if case == "writable" and path == tmp_path:
            mode |= 0o020
        return SimpleNamespace(st_mode=mode, st_uid=uid, st_gid=gid)

    monkeypatch.setattr(Path, "lstat", metadata)
    with pytest.raises(ValueError):
        user.workspace_owner(workspace)


def test_symlink_workspace_refuses(tmp_path):
    target = tmp_path / "target"
    target.mkdir()
    link = tmp_path / "link"
    link.symlink_to(target, target_is_directory=True)
    with pytest.raises(ValueError, match="physical"):
        user.workspace_owner(link)


def test_ownership_walk_does_not_follow_symlinks_or_modify_mode_bytes(
    tmp_path, monkeypatch
):
    root = tmp_path / "workspace"
    root.mkdir()
    payload = root / "owned"
    payload.write_bytes(b"unchanged native receipt/artifact")
    payload.chmod(0o751)
    foreign = tmp_path / "foreign"
    foreign.mkdir()
    (foreign / "private").write_bytes(b"not visited")
    (root / "link").symlink_to(foreign, target_is_directory=True)
    calls = []
    monkeypatch.setattr(
        user.os, "lchown", lambda p, u, g: calls.append((Path(p), u, g))
    )
    user.claim_tree(root, 1234, 2345)
    assert {p for p, _, _ in calls} == {root, payload, root / "link"}
    assert payload.read_bytes() == b"unchanged native receipt/artifact"
    assert stat.S_IMODE(payload.stat().st_mode) == 0o751


@pytest.fixture
def prepared(tmp_path, monkeypatch):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    flutter = tmp_path / "flutter"
    flutter.mkdir()
    temporary = tmp_path / "private"
    temporary.mkdir(mode=0o700)
    monkeypatch.setattr(user.os, "geteuid", lambda: 0)
    monkeypatch.setattr(user, "workspace_owner", lambda _: (1234, 2345))
    monkeypatch.setattr(user, "FLUTTER", flutter)
    calls = []
    monkeypatch.setattr(user, "claim_tree", lambda p, u, g: calls.append(p))
    monkeypatch.setattr(user.os, "chown", lambda *_: None)
    monkeypatch.setattr(user, "ensure_account", lambda *_: "ci-owner")
    monkeypatch.setattr(user.tempfile, "mkdtemp", lambda **_: str(temporary))
    monkeypatch.setattr(
        user.subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(stdout=user.FLUTTER_REVISION),
    )
    monkeypatch.delenv("PUB_CACHE", raising=False)
    return workspace, flutter, temporary, calls


def test_cache_miss_private_environment_preserves_controls_and_umask(
    prepared, monkeypatch
):
    workspace, flutter, temporary, calls = prepared
    monkeypatch.setenv("CI", "true")
    monkeypatch.setenv("FORESIGHT_TEST_SQL_SUPPORT_LIBRARY", "/fixture/sql.so")
    previous = os.umask(0o022)
    try:
        uid, gid, env = user.prepare(workspace)
        observed = os.umask(0o022)
    finally:
        os.umask(previous)
    assert observed == 0o022
    assert (uid, gid) == (1234, 2345)
    assert calls == [workspace, flutter]
    assert env["CI"] == "true"
    assert env["FORESIGHT_TEST_SQL_SUPPORT_LIBRARY"] == "/fixture/sql.so"
    assert env["USER"] == env["LOGNAME"] == "ci-owner"
    assert env["PUB_CACHE"] == str(workspace / ".cache/foresight-pub")
    assert Path(env["PUB_CACHE"]).is_dir()
    for name in (
        "HOME",
        "TMPDIR",
        "FORESIGHT_TEST_TEMP_ROOT",
        "XDG_RUNTIME_DIR",
        "PYTHONPYCACHEPREFIX",
    ):
        path = Path(env[name])
        assert path.parent == temporary and stat.S_IMODE(path.stat().st_mode) == 0o700


@pytest.mark.parametrize("escape", ["outside", "symlink", "parent"])
def test_cache_escape_refuses_before_ownership_changes(prepared, monkeypatch, escape):
    workspace, _, _, calls = prepared
    outside = workspace.parent / "outside"
    outside.mkdir()
    cache = outside
    if escape == "symlink":
        cache = workspace / "cache"
        cache.symlink_to(outside, target_is_directory=True)
    if escape == "parent":
        cache = workspace / ".." / "outside"
    monkeypatch.setenv("PUB_CACHE", str(cache))
    with pytest.raises(ValueError):
        user.prepare(workspace)
    assert calls == []


def test_unverified_flutter_and_nonroot_setup_refuse(prepared, monkeypatch):
    workspace, _, _, calls = prepared
    monkeypatch.setattr(
        user.subprocess, "run", lambda *a, **k: SimpleNamespace(stdout="different")
    )
    with pytest.raises(ValueError, match="pinned"):
        user.prepare(workspace)
    assert calls == []
    monkeypatch.setattr(user.os, "geteuid", lambda: 1234)
    with pytest.raises(ValueError, match="as root"):
        user.prepare(workspace)


def test_root_can_repeat_verification_after_sdk_ownership_change(prepared, monkeypatch):
    workspace, flutter, _, _ = prepared
    commands = []

    def run(args, **kwargs):
        assert kwargs["timeout"] == 15
        commands.append(args)
        return SimpleNamespace(stdout=user.FLUTTER_REVISION)

    monkeypatch.setattr(user.subprocess, "run", run)
    user.prepare(workspace)
    # The private environment is new for every invocation; the workspace/SDK remain.
    next_private = workspace.parent / "second-private"
    next_private.mkdir(mode=0o700)
    monkeypatch.setattr(user.tempfile, "mkdtemp", lambda **_: str(next_private))
    user.prepare(workspace)
    assert len(commands) == 2
    assert all(
        args[:3] == ["git", "-c", f"safe.directory={flutter}"] for args in commands
    )


def test_account_creation_is_local_numeric_and_does_not_copy_credentials(
    tmp_path, monkeypatch
):
    def absent(_):
        raise KeyError

    monkeypatch.setattr(user.pwd, "getpwuid", absent)
    monkeypatch.setattr(user.grp, "getgrgid", absent)
    calls = []
    monkeypatch.setattr(
        user.subprocess, "run", lambda args, **kw: calls.append((args, kw))
    )
    assert user.ensure_account(1234, 2345, tmp_path) == "foresight-ci-1234"
    assert calls[0][0] == ["groupadd", "--gid", "2345", "foresight-ci-2345"]
    assert "--no-create-home" in calls[1][0] and "--no-log-init" in calls[1][0]
    assert all(options == {"check": True, "timeout": 15} for _, options in calls)
    monkeypatch.setattr(
        user.pwd, "getpwuid", lambda _: SimpleNamespace(pw_name="existing")
    )
    assert user.ensure_account(1234, 2345, tmp_path) == "existing"
    assert len(calls) == 2


def test_drop_all_supplementary_groups_then_gid_uid_before_exec(monkeypatch):
    calls = []
    monkeypatch.setattr(user, "prepare", lambda _: (1234, 2345, {"CI": "true"}))
    monkeypatch.setattr(user.os, "chdir", lambda p: calls.append(("cwd", p)))
    monkeypatch.setattr(user.os, "setgroups", lambda v: calls.append(("groups", v)))
    monkeypatch.setattr(user.os, "setgid", lambda v: calls.append(("gid", v)))
    monkeypatch.setattr(user.os, "setuid", lambda v: calls.append(("uid", v)))
    monkeypatch.setattr(user.os, "execvpe", lambda *v: calls.append(("exec", v)))
    monkeypatch.setattr(
        sys, "argv", ["runner", "--workspace", "/fixture", "--", "xvfb-run", "gate"]
    )
    user.main()
    assert [x[0] for x in calls] == ["cwd", "groups", "gid", "uid", "exec"]
    assert calls[1:4] == [("groups", []), ("gid", 2345), ("uid", 1234)]
    assert calls[-1][1] == ("xvfb-run", ["xvfb-run", "gate"], {"CI": "true"})


def test_all_runtime_consumers_drop_before_display_or_dbus_and_native_stays_root():
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/linux-platform-stages.yml").read_text()
    )
    for name in ("core-linux", "desktop-linux", "service-linux"):
        runs = [s.get("run", "") for s in workflow["jobs"][name]["steps"]]
        gates = [s for s in runs if "xvfb-run" in s]
        assert gates and all(
            s.index("run_ci_user.py") < s.index("xvfb-run") for s in gates
        )
    native = workflow["jobs"]["native-linux"]["steps"]
    assert not any("run_ci_user.py" in s.get("run", "") for s in native)
    action = yaml.safe_load(
        (ROOT / ".github/actions/setup-linux-stage/action.yml").read_text()
    )
    python = next(
        s
        for s in action["runs"]["steps"]
        if s.get("name") == "Install locked Python development dependencies"
    )
    assert python["env"]["UV_PYTHON_INSTALL_DIR"] == "/opt/foresight-python"


def test_wrapper_bytes_and_mode_participate_in_existing_stage_identity(tmp_path):
    import subprocess
    cache = importlib.import_module("tools.ci_native_cache")

    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, timeout=15)
    script = tmp_path / "tools/run_ci_user.py"
    script.parent.mkdir()
    script.write_text("first reviewed wrapper\n")
    subprocess.run(
        ["git", "-C", str(tmp_path), "add", "tools/run_ci_user.py"],
        check=True,
        timeout=15,
    )
    for stage in cache.STAGES:
        before = cache.source_inputs(tmp_path, stage)
        assert "tools/run_ci_user.py" in before
        script.write_text("changed wrapper\n")
        assert cache.source_inputs(tmp_path, stage) != before
        script.write_text("first reviewed wrapper\n")
        script.chmod(0o755)
        assert cache.source_inputs(tmp_path, stage) != before
        script.chmod(0o644)
