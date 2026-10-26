#!/usr/bin/env python3
"""Run Linux runtime gates as the existing workspace owner, never container root."""

from __future__ import annotations

import argparse
import grp
import json
import os
from pathlib import Path
import pwd
import stat
import subprocess
import tempfile

FLUTTER = Path("/opt/foresight-flutter")
FLUTTER_REVISION = "adc901062556672b4138e18a4dc62a4be8f4b3c2"


def workspace_owner(workspace: Path) -> tuple[int, int]:
    if not workspace.is_absolute() or workspace.resolve(strict=True) != workspace:
        raise ValueError("Workspace must be a physical absolute directory")
    selected = None
    for path in (*reversed(workspace.parents), workspace):
        info = path.lstat()
        print(
            json.dumps(
                {
                    "workspace_ancestor": str(path),
                    "uid": info.st_uid,
                    "gid": info.st_gid,
                    "mode": oct(stat.S_IMODE(info.st_mode)),
                }
            ),
            flush=True,
        )
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError("Workspace ancestry must contain only directories")
        if info.st_mode & 0o022 and not (
            path == Path("/var/tmp")  # noqa: S108 - Exact sticky-root permission policy.
            and info.st_uid == 0
            and info.st_gid == 0
            and stat.S_IMODE(info.st_mode) == 0o1777
        ):
            raise ValueError("Workspace ancestry has unsafe write permissions")
        if info.st_uid:
            if selected is None:
                selected = (info.st_uid, info.st_gid)
            elif info.st_uid != selected[0]:
                raise ValueError("Workspace ancestry has mixed non-root owners")
    if selected is None or selected[1] == 0:
        raise ValueError("Workspace needs a non-root owner and primary group")
    return selected


def claim_tree(path: Path, uid: int, gid: int) -> None:
    """Change ownership metadata only; never follow links or change mode/bytes."""
    if (path.lstat().st_uid, path.lstat().st_gid) != (uid, gid):
        os.lchown(path, uid, gid)
    for parent, directories, files in os.walk(path, followlinks=False):
        for name in (*directories, *files):
            entry = Path(parent) / name
            info = entry.lstat()
            if (info.st_uid, info.st_gid) != (uid, gid):
                os.lchown(entry, uid, gid)


def ensure_account(uid: int, gid: int, home: Path) -> str:
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        try:
            grp.getgrgid(gid)
        except KeyError:
            subprocess.run(
                ["groupadd", "--gid", str(gid), f"foresight-ci-{gid}"],
                check=True,
                timeout=15,
            )
        name = f"foresight-ci-{uid}"
        subprocess.run(
            [
                "useradd",
                "--no-create-home",
                "--no-log-init",
                "--uid",
                str(uid),
                "--gid",
                str(gid),
                "--home-dir",
                str(home),
                "--shell",
                "/bin/bash",
                name,
            ],
            check=True,
            timeout=15,
        )
        return name


def prepare(workspace: Path) -> tuple[int, int, dict[str, str]]:
    if os.geteuid() != 0:
        raise ValueError("The container setup must prepare the runtime gate as root")
    uid, gid = workspace_owner(workspace)
    if FLUTTER.resolve(strict=True) != FLUTTER or not FLUTTER.is_dir():
        raise ValueError("The verified Flutter working directory is required")
    revision = subprocess.run(
        [
            "git",
            "-c",
            f"safe.directory={FLUTTER}",
            "-C",
            str(FLUTTER),
            "rev-parse",
            "HEAD",
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=15,
    ).stdout.strip()
    if revision != FLUTTER_REVISION:
        raise ValueError("The restored Flutter revision differs from the pinned SDK")
    pub = Path(os.environ.get("PUB_CACHE", str(workspace / ".cache/foresight-pub")))
    if not pub.is_absolute() or ".." in pub.parts or not pub.is_relative_to(workspace):
        raise ValueError("The job pub cache must remain inside its workspace")
    parent = workspace
    for component in pub.relative_to(workspace).parts:
        parent = parent / component
        try:
            parent.mkdir(mode=0o755)
        except FileExistsError:
            pass
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise ValueError("The job pub cache must contain only physical directories")
    claim_tree(workspace, uid, gid)
    claim_tree(FLUTTER, uid, gid)
    temporary = Path(tempfile.mkdtemp(prefix="of-ci-", dir="/var/tmp"))
    os.chown(temporary, uid, gid)
    env = dict(os.environ, PUB_CACHE=str(pub))
    for variable, child in {
        "HOME": "home",
        "TMPDIR": "tmp",
        "FORESIGHT_TEST_TEMP_ROOT": "tests",
        "PYTHONPYCACHEPREFIX": "pycache",
        "XDG_RUNTIME_DIR": "run",
        "XDG_CACHE_HOME": "cache",
        "XDG_CONFIG_HOME": "config",
        "XDG_DATA_HOME": "data",
    }.items():
        path = temporary / child
        path.mkdir(mode=0o700)
        os.chown(path, uid, gid)
        env[variable] = str(path)
    name = ensure_account(uid, gid, Path(env["HOME"]))
    env.update(USER=name, LOGNAME=name)
    print(
        json.dumps(
            {
                "runtime_uid": uid,
                "runtime_gid": gid,
                "private_root": str(temporary),
                "private_mode": "0700",
            }
        ),
        flush=True,
    )
    return uid, gid, env


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workspace", type=Path, default=os.environ.get("GITHUB_WORKSPACE")
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.workspace is None or not command:
        parser.error("workspace and a runtime gate command are required")
    uid, gid, env = prepare(args.workspace)
    os.chdir(args.workspace)
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
    os.execvpe(command[0], command, env)  # noqa: S606 - Drop root/groups before the workflow command.


if __name__ == "__main__":
    main()
