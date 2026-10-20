"""Upgrade selection and verified installer bytes fail before package execution."""

from argparse import Namespace
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

import pytest

from tools import release_upgrade as upgrade

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import test_release_dmg as dmg  # noqa: E402


def release(tag, kind="deb", **kwargs):
    name = (
        "app"
        + {"deb": ".deb", "rpm": ".rpm", "arch": ".pkg.tar.zst", "dmg": ".dmg"}[kind]
    )
    return {
        "tag_name": tag,
        "draft": False,
        "prerelease": False,
        "assets": [
            {"name": name},
            {"name": name + ".sha256"},
            {"name": name + ".build.json"},
        ],
        **kwargs,
    }


def test_previous_release_selection_is_semantic_and_fully_paginated(monkeypatch):
    pages = [
        [release("v0.9.0")] * 100,
        [
            release("v1.2.2"),
            release("v1.2.3"),
            release("v1.3.0"),
            release("v1.2.9", draft=True),
            release("v1.2.8", prerelease=True),
            release("bad"),
        ],
    ]
    routes = []

    def api(repo, route):
        assert repo == "owner/repo"
        routes.append(route)
        return pages[int(route.rsplit("=", 1)[-1]) - 1]

    monkeypatch.setattr(upgrade, "api", api)
    assert upgrade.previous("owner/repo", "v1.2.3", "deb") == "v1.2.2"
    assert len(routes) == 2


@pytest.mark.parametrize(
    "problem", ["none", "ambiguous", "broken-latest", "invalid-target"]
)
def test_missing_or_broken_previous_never_silently_uses_older_release(
    monkeypatch, problem
):
    releases = [release("v1.2.1"), release("v1.2.2")]
    if problem == "none":
        releases = []
    if problem == "ambiguous":
        releases.append(release("v1.2.2"))
    if problem == "broken-latest":
        releases[-1]["assets"] = []
    monkeypatch.setattr(upgrade, "api", lambda *args: releases)
    with pytest.raises(ValueError):
        upgrade.previous(
            "owner/repo", "preview" if problem == "invalid-target" else "v1.2.3", "deb"
        )


def local_installer(directory, tag, suffix=".dmg"):
    directory.mkdir(parents=True, exist_ok=True)
    installer = directory / (tag + suffix)
    installer.write_bytes(("immutable " + tag).encode())
    checksum = hashlib.sha256(installer.read_bytes()).hexdigest()
    Path(str(installer) + ".sha256").write_text(checksum + "  " + installer.name + "\n")
    identity = {
        "asset": installer.name,
        "tag": tag,
        "sha256": checksum,
        "status": "verified_download",
        "source_commit": "a" * 40,
    }
    (directory / "installer.json").write_text(json.dumps(identity))
    return installer, identity


@pytest.mark.parametrize("suffix", [".deb", ".rpm", ".pkg.tar.zst", ".dmg"])
def test_upgrade_pair_rechecks_both_actual_installer_bytes(tmp_path, suffix):
    previous, old = local_installer(tmp_path / "old", "v1.2.2", suffix)
    current, new = local_installer(tmp_path / "new", "v1.2.3", suffix)
    assert upgrade.verified_pair(previous.parent, current.parent) == (old, new)
    current.write_bytes(b"changed after download")
    with pytest.raises(ValueError):
        upgrade.verified_pair(previous.parent, current.parent)


@pytest.mark.parametrize(
    "problem",
    [
        "asset-path",
        "unverified",
        "tag",
        "digest",
        "symlink",
        "same-version",
        "different-format",
        "unknown-format",
    ],
)
def test_bad_previous_identity_cannot_execute_an_installer(tmp_path, problem):
    previous, old = local_installer(tmp_path / "old", "v1.2.2")
    current, new = local_installer(tmp_path / "new", "v1.2.3")
    if problem == "asset-path":
        old["asset"] = "../elsewhere.dmg"
    if problem == "unverified":
        old["status"] = "failed"
    if problem == "tag":
        old["tag"] = "nightly.20261019.1"
    if problem == "digest":
        old["sha256"] = "f" * 64
    if problem == "symlink":
        saved = tmp_path / "outside.dmg"
        previous.rename(saved)
        previous.symlink_to(saved)
    if problem == "same-version":
        old["tag"] = new["tag"]
    if problem == "different-format":
        current, new = local_installer(current.parent, "v1.2.3", ".deb")
    if problem == "unknown-format":
        previous, old = local_installer(previous.parent, "v1.2.2", ".exe")
        current, new = local_installer(current.parent, "v1.2.3", ".exe")
    (previous.parent / "installer.json").write_text(json.dumps(old))
    with pytest.raises(ValueError):
        upgrade.verified_pair(previous.parent, current.parent)


@pytest.mark.parametrize("valid", [False, True])
def test_previous_download_uses_existing_checksum_and_source_verifier(
    tmp_path, monkeypatch, valid
):
    monkeypatch.setattr(upgrade, "previous", lambda *args: "v1.2.2")
    commands = []

    def run(args, **kwargs):
        commands.append(args)
        (tmp_path / "installer.json").write_text(
            json.dumps(
                {"tag": "v1.2.2", "status": "verified_download" if valid else "failed"}
            )
        )

    monkeypatch.setattr(upgrade.subprocess, "run", run)
    if valid:
        assert (
            upgrade.prepare("owner/repo", "v1.2.3", "deb", tmp_path)["tag"] == "v1.2.2"
        )
    else:
        with pytest.raises(ValueError):
            upgrade.prepare("owner/repo", "v1.2.3", "deb", tmp_path)
    assert commands[0][1].endswith("release_asset_acceptance.py")
    assert "--allow-draft" not in commands[0]
    assert "--format" in commands[0] and "deb" in commands[0]


def test_upgrade_cli_forwards_explicit_verified_download_inputs(
    tmp_path, monkeypatch, capsys
):
    from unittest.mock import Mock

    prepare = Mock(return_value={"status": "verified_download"})
    monkeypatch.setattr(upgrade, "prepare", prepare)
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "release_upgrade",
            "--tag",
            "v1.2.3",
            "--format",
            "dmg",
            "--directory",
            str(tmp_path),
        ],
    )
    upgrade.main()
    prepare.assert_called_once_with("owner/repo", "v1.2.3", "dmg", tmp_path)
    assert json.loads(capsys.readouterr().out)["status"] == "verified_download"


def test_previous_dmg_resolves_aliased_temporary_root_and_always_detaches(
    tmp_path, monkeypatch
):
    previous, identity = local_installer(tmp_path / "old", "v1.2.2")
    current, _ = local_installer(tmp_path / "new", "v1.2.3")
    actual = tmp_path / "actual-tmp"
    actual.mkdir()
    alias = tmp_path / "tmp-alias"
    alias.symlink_to(actual, target_is_directory=True)
    destination, output = tmp_path / "owned.app", tmp_path / "reports"
    destination.mkdir()
    output.mkdir()
    commands = []

    def run(args, **kwargs):
        commands.append(args)
        if args[:2] == ["hdiutil", "attach"]:
            source = (
                Path(args[args.index("-mountpoint") + 1])
                / "Open Foresight.app/Contents"
            )
            source.mkdir(parents=True)
            (source / "Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "io.openforesight.App"})
            )
        if args[0] == "ditto":
            shutil.copytree(args[1], args[2], dirs_exist_ok=True)
        return subprocess.CompletedProcess(args, 0)

    monkeypatch.setattr(dmg.subprocess, "run", run)
    monkeypatch.setattr(dmg, "verify_signature", lambda *args: {"adhoc": True})
    monkeypatch.setattr(dmg, "persistence_probe", lambda *args: None)
    assert (
        dmg.previous_installation(previous, destination, alias, output, current)
        == identity
    )
    assert commands[-1][:2] == ["hdiutil", "detach"]
    assert Path(commands[-1][-1]).is_relative_to(actual)


@pytest.mark.parametrize("failure", ["escape", "persistence"])
def test_previous_dmg_failure_detaches_original_volume(tmp_path, monkeypatch, failure):
    previous, _ = local_installer(tmp_path / "old", "v1.2.2")
    current, _ = local_installer(tmp_path / "new", "v1.2.3")
    destination, output = tmp_path / "owned.app", tmp_path / "reports"
    destination.mkdir()
    output.mkdir()
    commands = []

    def run(args, **kwargs):
        commands.append(args)
        if args[:2] == ["hdiutil", "attach"]:
            mount = Path(args[args.index("-mountpoint") + 1])
            source = mount / "Open Foresight.app"
            if failure == "escape":
                source.symlink_to(tmp_path)
            else:
                source.mkdir()
                (source / "Contents").mkdir()
                (source / "Contents/Info.plist").write_bytes(
                    plistlib.dumps({"CFBundleIdentifier": "io.openforesight.App"})
                )
        return subprocess.CompletedProcess(args, 0)

    def fail(*args):
        raise RuntimeError("persistence failed")

    monkeypatch.setattr(dmg.subprocess, "run", run)
    monkeypatch.setattr(dmg, "verify_signature", lambda *args: {})
    monkeypatch.setattr(dmg, "persistence_probe", fail)
    with pytest.raises((ValueError, RuntimeError)):
        dmg.previous_installation(previous, destination, tmp_path, output, current)
    assert commands[-1][:2] == ["hdiutil", "detach"]


@pytest.mark.parametrize("lose_data", [False, True])
def test_dmg_upgrade_runs_previous_then_current_and_verifies_persistent_bytes(
    tmp_path, monkeypatch, lose_data
):
    import sqlite3

    previous, _ = local_installer(tmp_path / "old", "v1.2.2")
    current, _ = local_installer(tmp_path / "new", "v1.2.3")
    destination = tmp_path / "Applications/Open Foresight.app"
    output = tmp_path / "reports"
    history = []
    commands = []

    def run(args, **kwargs):
        commands.append(args)
        if args[:2] == ["hdiutil", "attach"]:
            mount = Path(args[args.index("-mountpoint") + 1])
            source = mount / "Open Foresight.app/Contents"
            source.mkdir(parents=True)
            version = "v1.2.2" if Path(args[-1]) == previous else "v1.2.3"
            (source / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": "io.openforesight.App",
                        "CFBundleShortVersionString": version,
                    }
                )
            )
        if args[0] == "ditto":
            shutil.copytree(args[1], args[2], dirs_exist_ok=True)
        return subprocess.CompletedProcess(args, 0, "", "")

    def install(source, target, **kwargs):
        assert plistlib.loads((target / "Contents/Info.plist").read_bytes())[
            "CFBundleShortVersionString"
        ] in ("v1.2.2", "v1.2.3")
        shutil.copytree(source, target, dirs_exist_ok=True)

    def persistence(bundle, profile, state, phase):
        version = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())[
            "CFBundleShortVersionString"
        ]
        history.append((version, phase))
        profile.mkdir(parents=True, exist_ok=True)
        database = profile / "application.db"
        with sqlite3.connect(database) as connection:
            if phase == "create":
                connection.execute("CREATE TABLE notes(body TEXT)")
                connection.execute(
                    "INSERT INTO notes VALUES (?)", ("owned upgrade data",)
                )
            else:
                if lose_data:
                    connection.execute("DELETE FROM notes")
                assert connection.execute("SELECT body FROM notes").fetchall() == [
                    ("owned upgrade data",)
                ]
        state.write_text(
            json.dumps(
                {
                    "status": "created"
                    if phase == "create"
                    else "verified_after_reinstall",
                    "database": str(database),
                }
            )
        )

    monkeypatch.setattr(dmg.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(dmg.subprocess, "run", run)
    monkeypatch.setattr(dmg, "install", install)
    monkeypatch.setattr(dmg, "verify_signature", lambda *args: {"adhoc": True})
    monkeypatch.setattr(dmg, "persistence_probe", persistence)
    args = Namespace(
        dmg=current,
        previous_dmg=previous,
        destination=destination,
        models=tmp_path / "models",
        output=output,
        validation="full",
    )
    if lose_data:
        with pytest.raises(AssertionError):
            dmg.run(args)
        assert not (output / "upgrade.json").exists()
        assert (
            json.loads((output / "installation.json").read_text())["status"] == "failed"
        )
    else:
        report = dmg.run(args)
        assert report["previous_release_upgrade"] == "passed"
        assert (
            json.loads((output / "upgrade.json").read_text())["previous_tag"]
            == "v1.2.2"
        )
        assert history == [
            ("v1.2.2", "create"),
            ("v1.2.3", "verify"),
            ("v1.2.3", "create"),
            ("v1.2.3", "verify"),
        ]
        assert any(
            "test_installed_release.py" in " ".join(map(str, command))
            for command in commands
        )
    assert not destination.exists()
    assert sum(command[:2] == ["hdiutil", "detach"] for command in commands) == 2
    assert previous.read_bytes() == b"immutable v1.2.2"


@pytest.mark.parametrize(
    "kind,suffix", [("deb", ".deb"), ("rpm", ".rpm"), ("arch", ".pkg.tar.zst")]
)
@pytest.mark.parametrize(
    "caller,failure",
    [
        ("release", None),
        ("release", "corrupt-previous"),
        ("release", "missing-previous"),
        ("release", "lost-data"),
        ("preview", None),
        ("preview", "corrupt-current"),
    ],
)
def test_real_linux_callers_keep_preview_lifecycle_and_require_release_upgrade(
    tmp_path, kind, suffix, caller, failure
):
    import os
    import yaml

    from tools import preview_packages

    root = Path(__file__).resolve().parents[1]
    workspace = tmp_path / "src/out/caller"
    workspace.mkdir(parents=True)
    (workspace / "tools").symlink_to(root / "tools", target_is_directory=True)
    (workspace / "packaging").symlink_to(root / "packaging", target_is_directory=True)
    assets = workspace / ("assets" if caller == "release" else "dist/packages")
    current, _ = local_installer(assets, "v1.2.3", suffix)
    if caller == "preview":
        metadata = {
            "revision": "a" * 40,
            "format": kind,
            "sha256": hashlib.sha256(current.read_bytes()).hexdigest(),
            "version": "1.2.3~nightly.20261020.12",
            "build_number": 12,
        }
        Path(str(current) + ".build.json").write_text(json.dumps(metadata))
        # This is the actual nightly receipt shape: it is not a stable-release
        # download identity, and no previous stable installer is mounted.
        preview_packages.receipt(assets, kind, "a" * 40)
    previous = workspace / "previous-assets" / ("v1.2.2" + suffix)
    if caller == "release" and failure != "missing-previous":
        previous, _ = local_installer(previous.parent, "v1.2.2", suffix)
    if failure == "corrupt-previous":
        previous.write_bytes(b"changed previous installer")
    if failure == "corrupt-current":
        current.write_bytes(b"changed current installer")
    output = workspace / "reports"
    output.mkdir()
    binary = workspace / "bin"
    binary.mkdir()
    sandbox = workspace / "sandbox"
    sandbox.mkdir()
    (sandbox / ".dockerenv").touch()
    (sandbox / "os-release").write_text("ID=fixture\n")
    installed = workspace / "installed-version"
    log = workspace / "commands.jsonl"
    tool = binary / "tool"
    tool.write_text(
        r"""#!/fixture-python
import json, os, re, shutil, sqlite3, subprocess, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['UPGRADE_LOG'], 'a') as stream:
    stream.write(json.dumps([name, *args]) + '\n')
installed = Path(os.environ['UPGRADE_INSTALLED'])
paths = json.loads(os.environ['UPGRADE_PATH_MAP'])
if name == 'docker':
    mounts = {}
    env = dict(os.environ)
    for i, arg in enumerate(args):
        if arg == '-v':
            parts = args[i + 1].split(':')
            host, virtual = parts[:2]
            mode = parts[2] if len(parts) == 3 else 'rw'
            assert mode == ('rw' if virtual == '/reports' else 'ro')
            mounts[virtual] = host
        elif arg == '-e':
            key, value = args[i + 1].split('=', 1)
            env[key] = value
    for virtual in ('/assets', '/reports', '/models', '/work'):
        paths[virtual] = mounts[virtual]
    if '/previous-assets' in mounts:
        paths['/previous-assets'] = mounts['/previous-assets']
    i = args.index('bash')
    assert args[i + 1] == '/work/packaging/ci/test-release-package.sh'
    source = Path(os.environ['UPGRADE_SCRIPT']).read_text()
    pattern = '|'.join(re.escape(key) for key in sorted(paths, key=len, reverse=True))
    source = re.sub(pattern, lambda match: paths[match[0]], source)
    target = Path(os.environ['UPGRADE_INNER'])
    target.write_text(source)
    env['UPGRADE_PATH_MAP'] = json.dumps(paths)
    result = subprocess.run(['/bin/bash', str(target), *args[i + 2:]], env=env, timeout=20)
    sys.exit(result.returncode)
elif name == 'id':
    assert args == ['-u']
    print('0')
elif name == 'bash':
    assert args[0].endswith('/packaging/ci/prepare-document-sandbox.sh')
    assert args[1:] == [os.environ['FORMAT'], 'acceptance']
elif name == 'python':
    assert args[0] == 'tools/test_installed_release.py' and '--prepare-models-only' in args
elif name in ('apt-get', 'dnf', 'pacman'):
    if os.environ['UPGRADE_PREVIOUS'] in args:
        installed.write_text('previous')
    elif os.environ['UPGRADE_CURRENT'] in args:
        if os.environ['UPGRADE_FAILURE'] == 'lost-data':
            for database in Path(paths['/home/acceptance']).rglob('application.db'):
                database.unlink()
        installed.write_text('current')
    elif any(arg in args for arg in ('remove', '-R')):
        for virtual in ('/opt/open-foresight', '/usr/bin/open-foresight', '/usr/share/applications'):
            path = Path(paths[virtual])
            if path.is_dir(): shutil.rmtree(path)
            else: path.unlink(missing_ok=True)
        sys.exit(0)
    else:
        # System prerequisites are mocked; package installation is tracked.
        sys.exit(0)
    Path(paths['/opt/open-foresight']).mkdir(parents=True, exist_ok=True)
    command = Path(paths['/usr/bin/open-foresight'])
    command.parent.mkdir(parents=True, exist_ok=True)
    command.touch()
    desktop = Path(paths['/usr/share/applications']) / 'io.openforesight.App.desktop'
    desktop.parent.mkdir(parents=True, exist_ok=True)
    desktop.touch()
elif name == 'install':
    Path(args[-1]).mkdir(parents=True, exist_ok=True)
elif name == 'chown':
    pass
elif name == 'desktop-file-validate':
    assert Path(args[0]).is_file()
elif name == 'runuser':
    if '--phase' not in args:
        assert installed.read_text() == 'current' and 'xvfb-run' in args
        sys.exit(0)
    profile = Path(args[args.index('--profile') + 1])
    profile.mkdir(parents=True, exist_ok=True)
    database = profile / 'application.db'
    phase = args[args.index('--phase') + 1]
    with sqlite3.connect(database) as connection:
        if phase == 'create':
            assert installed.read_text() == ('previous' if profile.name == 'upgrade' else 'current')
            connection.execute('CREATE TABLE notes(body TEXT)')
            connection.execute('INSERT INTO notes VALUES (?)', ('preserved note and source',))
        else:
            assert installed.read_text() == 'current'
            assert connection.execute('SELECT body FROM notes').fetchall() == [('preserved note and source',)]
    Path(args[args.index('--state') + 1]).write_text(json.dumps({
        'status': 'created' if phase == 'create' else 'verified_after_reinstall',
        'database': str(database),
    }))
else:
    raise AssertionError((name, args))
""".replace("/fixture-python", sys.executable, 1)
    )
    tool.chmod(0o755)
    for name in (
        "docker",
        "id",
        "bash",
        "python",
        "apt-get",
        "dnf",
        "pacman",
        "install",
        "chown",
        "desktop-file-validate",
        "runuser",
    ):
        (binary / name).symlink_to(tool)
    (binary / "python3").symlink_to(sys.executable)
    workflow = (
        "release-acceptance.yml" if caller == "release" else "preview-packages.yml"
    )
    job = yaml.safe_load((root / ".github/workflows" / workflow).read_text())["jobs"][
        "linux"
    ]
    step = next(
        step
        for step in job["steps"]
        if "bash /work/packaging/ci/test-release-package.sh" in step.get("run", "")
    )
    image = next(
        row["image"]
        for row in job["strategy"]["matrix"]["include"]
        if row["format"] == kind
    )
    paths = {
        "/previous-assets": str(workspace / "unmounted-previous"),
        "/home/acceptance": str(sandbox / "home"),
        "/opt/open-foresight": str(sandbox / "bundle"),
        "/usr/bin/open-foresight": str(sandbox / "owned-bin/open-foresight"),
        "/usr/share/applications": str(sandbox / "applications"),
        "/etc/os-release": str(sandbox / "os-release"),
        "/.dockerenv": str(sandbox / ".dockerenv"),
    }
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in {"BASH_ENV", "ENV"}
    }
    env.update(
        PATH=str(binary) + os.pathsep + env["PATH"],
        FORMAT=kind,
        IMAGE=image,
        UPGRADE_LOG=str(log),
        UPGRADE_INSTALLED=str(installed),
        UPGRADE_PREVIOUS=str(previous),
        UPGRADE_CURRENT=str(current),
        UPGRADE_FAILURE=failure or "",
        UPGRADE_SCRIPT=str(root / "packaging/ci/test-release-package.sh"),
        UPGRADE_INNER=str(sandbox / "inner.sh"),
        UPGRADE_PATH_MAP=json.dumps(paths),
    )
    result = subprocess.run(
        [
            "/bin/bash",
            "--noprofile",
            "--norc",
            "-e",
            "-o",
            "pipefail",
            "-c",
            step["run"],
        ],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert (result.returncode == 0) == (failure is None), result.stdout + result.stderr
    rows = [json.loads(line) for line in log.read_text().splitlines()]
    docker = next(row for row in rows if row[0] == "docker")
    script_index = docker.index("/work/packaging/ci/test-release-package.sh")
    expected_arguments = [kind, "--require-upgrade"] if caller == "release" else [kind]
    assert docker[script_index + 1 :] == expected_arguments
    package_calls = [
        row
        for row in rows
        if row[0] in ("apt-get", "dnf", "pacman")
        and any(path in row for path in (str(previous), str(current)))
    ]
    if failure in ("corrupt-previous", "corrupt-current", "missing-previous"):
        assert package_calls == [] and not installed.exists()
    elif failure == "lost-data":
        assert len(package_calls) == 2
    else:
        expected = (
            [str(previous), str(current), str(current)]
            if caller == "release"
            else [str(current), str(current)]
        )
        assert len(package_calls) == len(expected)
        assert all(
            path in command
            for path, command in zip(expected, package_calls, strict=True)
        )
        report = json.loads((output / "installation.json").read_text())
        assert report["status"] == "passed" and report["user_data_preserved"]
    if failure is None and caller == "release":
        report = json.loads((output / "upgrade.json").read_text())
        assert report["status"] == "passed" and report["previous_tag"] == "v1.2.2"
        assert (
            report["current_sha256"] == hashlib.sha256(current.read_bytes()).hexdigest()
        )
    else:
        assert not (output / "upgrade.json").exists()
