"""Draft retries retain successful immutable bytes and select missing formats."""

import hashlib
import json
from pathlib import Path
from unittest.mock import patch

import pytest

from tools import release_upload as upload, release_inputs as inputs

SHA = "a" * 40


def package(tmp_path):
    path = tmp_path / "open-foresight_0.1.2-1_amd64.deb"
    path.write_bytes(b"retained native installer")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(str(path) + ".sha256").write_text(f"{digest}  {path.name}\n")
    metadata = {"revision": SHA, "version": "0.1.2", "format": "deb", "sha256": digest}
    Path(str(path) + ".build.json").write_text(json.dumps(metadata))
    return path, metadata


def draft(paths):
    return {
        "draft": True,
        "tag_name": "v0.1.2",
        "target_commitish": SHA,
        "body": "<!-- foresight-package-release: 1 -->",
        "assets": [
            {
                "id": i + 1,
                "name": path.name,
                "size": path.stat().st_size,
                "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            for i, path in enumerate(paths)
        ],
    }


def test_identical_draft_assets_are_retained_and_only_missing_files_are_uploaded(
    tmp_path,
):
    path, metadata = package(tmp_path)
    paths = sorted(tmp_path.iterdir())
    current = draft([path])
    with (
        patch.object(upload, "release_for_tag", return_value=current),
        patch.object(upload, "api", return_value={"sha": SHA}),
        patch.object(upload.subprocess, "run") as command,
    ):
        upload.upload("owner/repo", "v0.1.2", paths)
    arguments = command.call_args.args[0]
    assert arguments[:3] == ["gh", "release", "upload"]
    assert str(path) not in arguments
    assert "--clobber" not in arguments
    assert set(arguments[6:]) == {str(item) for item in paths if item != path}


@pytest.mark.parametrize("invalid", ["public", "source", "changed_bytes"])
def test_upload_never_replaces_conflicting_or_public_assets(tmp_path, invalid):
    path, metadata = package(tmp_path)
    current = draft([path])
    if invalid == "public":
        current["draft"] = False
    if invalid == "source":
        current["target_commitish"] = "b" * 40
    if invalid == "changed_bytes":
        current["assets"][0]["digest"] = "sha256:" + "0" * 64
    with (
        patch.object(upload, "release_for_tag", return_value=current),
        patch.object(upload, "api", return_value={"sha": SHA}),
        patch.object(upload.subprocess, "run") as command,
    ):
        with pytest.raises(ValueError) as failure:
            upload.upload("owner/repo", "v0.1.2", [path])
        if invalid == "changed_bytes":
            assert "reviewed recovery" in str(failure.value)
            assert "generation" not in str(failure.value)
        command.assert_not_called()


def test_package_plan_retains_verified_deb_and_selects_only_missing_formats(tmp_path):
    path, metadata = package(tmp_path)
    current = draft(sorted(tmp_path.iterdir()))
    with (
        patch.object(inputs, "release_source", return_value=SHA),
        patch.object(inputs, "release_for_tag", return_value=current),
        patch.object(
            inputs,
            "api",
            return_value={"commit": {"committer": {"date": "2026-10-18T01:00:00Z"}}},
        ),
        patch.object(
            inputs.subprocess, "check_output", return_value=json.dumps(metadata)
        ),
    ):
        result = inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "1")
        assert json.loads(result["formats"]) == ["rpm", "arch"]
        assert result["release"] == "1" and result["source"] == SHA
        assert (
            inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "1", "deb")["formats"]
            == "[]"
        )
        with pytest.raises(ValueError, match="generation"):
            inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "2")
        metadata["revision"] = "b" * 40
        with patch.object(
            inputs.subprocess, "check_output", return_value=json.dumps(metadata)
        ):
            with pytest.raises(ValueError, match="another product"):
                inputs.resolve("owner/repo", "v0.1.2", "c" * 40, "1")


@pytest.mark.parametrize(
    "kind,suffix", [("deb", ".deb"), ("rpm", ".rpm"), ("arch", ".pkg.tar.zst")]
)
def test_retry_replaces_only_failed_format_diagnostics_and_publish_uses_current_bytes(
    tmp_path, kind, suffix
):
    import os
    import subprocess
    import sys
    import yaml

    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load(
        (root / ".github/workflows/linux-packages.yml").read_text()
    )
    retention = next(
        step
        for step in workflow["jobs"]["packages"]["steps"]
        if step.get("name") == "Retain built installers before lifecycle validation"
    )
    assert (
        retention["uses"]
        == "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"
    )
    # The exact pinned action defaults overwrite=false. This controlled service
    # reports a duplicate diagnostic name to exercise explicit replacement;
    # it does not establish real cross-attempt backend collision behavior.
    store = {}

    def retain(format_name, files):
        name = retention["with"]["name"].replace("${{ matrix.format }}", format_name)
        if name in store and retention["with"].get("overwrite", False) not in (
            True,
            "true",
        ):
            raise FileExistsError(
                "Artifact already exists in this workflow run: " + name
            )
        store[name] = dict(files)

    def files(format_name, extension, content):
        name = "open-foresight-0.1.2" + extension
        checksum = hashlib.sha256(content).hexdigest()
        return {
            name: content,
            name + ".sha256": f"{checksum}  {name}\n".encode(),
            name + ".build.json": json.dumps(
                {
                    "revision": SHA,
                    "version": "0.1.2",
                    "format": format_name,
                    "sha256": checksum,
                }
            ).encode(),
        }

    siblings = {}
    for format_name, extension in (
        ("deb", ".deb"),
        ("rpm", ".rpm"),
        ("arch", ".pkg.tar.zst"),
    ):
        if format_name == kind:
            continue
        retained = files(
            format_name, extension, ("accepted sibling " + format_name).encode()
        )
        retain(format_name, retained)
        siblings.update(retained)
    before = {name: dict(data) for name, data in store.items()}
    retain(kind, files(kind, suffix, b"unqualified failed-attempt installer"))
    retry = files(kind, suffix, b"successful retry installer")
    retain(kind, retry)
    assert all(store[name] == data for name, data in before.items())
    assert store["open-foresight-" + kind + "-x86-64"] == retry

    workspace = tmp_path / "work"
    workspace.mkdir()
    (workspace / "tools").symlink_to(root / "tools", target_is_directory=True)
    artifacts = workspace / "artifacts"
    artifacts.mkdir()
    pattern = next(
        step["with"]["pattern"]
        for step in workflow["jobs"]["publish"]["steps"]
        if "pattern" in step.get("with", {})
    )
    import fnmatch

    for name, data in store.items():
        assert fnmatch.fnmatchcase(name, pattern)
        directory = artifacts / name
        directory.mkdir()
        for filename, content in data.items():
            (directory / filename).write_bytes(content)
    (artifacts / "portable-bundle").mkdir()
    remote = {
        "draft": True,
        "tag_name": "v0.1.2",
        "target_commitish": SHA,
        "assets": [
            {
                "id": index + 1,
                "name": name,
                "size": len(content),
                "digest": "sha256:" + hashlib.sha256(content).hexdigest(),
            }
            for index, (name, content) in enumerate(siblings.items())
        ],
    }
    release = workspace / "release.json"
    release.write_text(json.dumps(remote))
    binary = workspace / "bin"
    binary.mkdir()
    (binary / "python").symlink_to(sys.executable)
    gh = binary / "gh"
    gh.write_text(
        r"""#!/fixture-python
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
if args[:2]==['release','view']:
    print('true')
elif args[:1]==['api']:
    route=args[-1]
    if '/commits/' in route: print(json.dumps({'sha':'a'*40}))
    elif '/releases?' in route: print('['+Path(os.environ['UPLOAD_DRAFT']).read_text()+']')
    else: raise AssertionError(args)
elif args[:2]==['release','upload']:
    assert '--clobber' not in args
    with open(os.environ['UPLOAD_LOG'],'w') as stream:
        json.dump({Path(value).name:Path(value).read_bytes().hex() for value in args[5:]},stream)
else: raise AssertionError(args)
""".replace("/fixture-python", sys.executable, 1)
    )
    gh.chmod(0o755)
    log = workspace / "uploaded.json"
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in ("BASH_ENV", "ENV")
    }
    env.update(
        PATH=str(binary) + os.pathsep + env["PATH"],
        GITHUB_REPOSITORY="owner/repo",
        RELEASE_TAG="v0.1.2",
        GH_REPO="owner/repo",
        UPLOAD_DRAFT=str(release),
        UPLOAD_LOG=str(log),
    )
    step = next(
        step
        for step in workflow["jobs"]["publish"]["steps"]
        if step.get("name") == "Attach tested Linux packages to release"
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
    assert result.returncode == 0, result.stdout + result.stderr
    uploaded = {
        name: bytes.fromhex(content)
        for name, content in json.loads(log.read_text()).items()
    }
    assert uploaded == retry
    assert json.loads(release.read_text()) == remote


@pytest.mark.parametrize(
    "attached",
    [
        "installer",
        "checksum",
        "manifest",
        "build",
        "runtime",
        "complete",
        "clean",
        "api-error",
        "public",
        "wrong-source",
    ],
)
def test_actual_dmg_caller_holds_attached_bytes_before_builder(tmp_path, attached):
    import os
    import subprocess
    import sys
    import yaml

    root = Path(__file__).resolve().parents[1]
    (tmp_path / "tools").symlink_to(root / "tools", target_is_directory=True)
    binary = tmp_path / "bin"
    binary.mkdir()
    name = "Open-Foresight-v0.1.2-macos-arm64.dmg"
    names = {
        "installer": name,
        "checksum": name + ".sha256",
        "manifest": name + ".manifest.json",
        "build": name + ".build.json",
        "runtime": "runtime-verification.json",
    }
    assets = (
        list(names.values())
        if attached == "complete"
        else [names[attached]]
        if attached in names
        else []
    )
    remote = {
        "draft": attached != "public",
        "tag_name": "v0.1.2",
        "target_commitish": "b" * 40 if attached == "wrong-source" else SHA,
        "assets": [{"name": name} for name in assets],
    }
    (tmp_path / "draft.json").write_text(json.dumps(remote))
    for directory in ["dist", "test-results"]:
        folder = tmp_path / directory
        folder.mkdir()
        (folder / "original-evidence").write_bytes(b"untouched original attempt")
    (binary / "gh").write_text(
        (
            r"""#!/fixture-python
import json, os, sys
from pathlib import Path
if os.environ['CASE'] == 'api-error':
    print('retained API stdout diagnosis', flush=True)
    print('retained API stderr diagnosis', file=sys.stderr, flush=True)
    raise SystemExit(1)
route=sys.argv[-1]
if '/commits/' in route: print(json.dumps({'sha':'a'*40}))
elif '/releases?' in route: print('['+Path('draft.json').read_text()+']')
else: raise AssertionError(sys.argv)
"""
        ).replace("/fixture-python", sys.executable, 1)
    )
    (binary / "python3").write_text(
        (
            r"""#!/fixture-python
import os, sys
from pathlib import Path
if sys.argv[1:3] == ['-m','tools.release_upload']:
    os.execv(sys.executable,[sys.executable,*sys.argv[1:]])
if sys.argv[1] == 'tools/verify_macos_release_runtime.py': raise SystemExit(0)
assert sys.argv[1] == 'tools/create_dmg.py',sys.argv
Path('builder-invoked').write_text('actual caller reached builder')
"""
        ).replace("/fixture-python", sys.executable, 1)
    )
    for command in ["gh", "python3"]:
        (binary / command).chmod(0o755)
    for command in ["ditto", "codesign"]:
        executable = binary / command
        executable.write_text(
            (
                r"""#!/fixture-python
import json, sys
from pathlib import Path
with Path('platform-calls.jsonl').open('a') as output:
    output.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + '\n')
"""
            ).replace("/fixture-python", sys.executable, 1)
        )
        executable.chmod(0o755)
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in ("BASH_ENV", "ENV")
    }
    env.update(
        PATH=str(binary) + os.pathsep + env["PATH"],
        GITHUB_REPOSITORY="owner/repo",
        RELEASE_TAG="v0.1.2",
        CASE=attached,
    )
    workflow = yaml.safe_load(
        (root / ".github/workflows/macos-release.yml").read_text()
    )
    step = next(
        s
        for s in workflow["jobs"]["dmg"]["steps"]
        if s.get("name") == "Restore tested application and create disk image"
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
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if attached == "clean":
        assert result.returncode == 0, result.stdout + result.stderr
        assert (tmp_path / "builder-invoked").is_file()
        assert [
            json.loads(line)
            for line in (tmp_path / "platform-calls.jsonl").read_text().splitlines()
        ] == [
            ["ditto", "-x", "-k", "artifacts/Open-Foresight-macos-arm64.zip", "staging"],
            ["codesign", "--verify", "--deep", "--strict", "--verbose=2", "staging/Open Foresight.app"],
        ]
    else:
        assert not (tmp_path / "platform-calls.jsonl").exists()
        assert result.returncode != 0, result.stdout + result.stderr
        assert not (tmp_path / "builder-invoked").exists()
        if attached == "api-error":
            assert "retained API stdout diagnosis" in result.stdout + result.stderr
            assert "retained API stderr diagnosis" in result.stdout + result.stderr
        elif attached not in ("public", "wrong-source"):
            assert "reviewed recovery" in result.stderr
    assert json.loads((tmp_path / "draft.json").read_text()) == remote
    for directory in ["dist", "test-results"]:
        assert {p.name: p.read_bytes() for p in (tmp_path / directory).iterdir()} == {
            "original-evidence": b"untouched original attempt"
        }


@pytest.mark.parametrize("arguments", [[], ["--require-missing-dmg", "installer.dmg"]])
def test_dmg_preflight_cli_never_silently_accepts_upload_modes(monkeypatch, arguments):
    import sys

    monkeypatch.setattr(sys, "argv", ["upload", "--tag", "v0.1.2", *arguments])
    with (
        patch.object(upload, "require_missing_dmg") as preflight,
        patch.object(upload, "upload") as writer,
    ):
        with pytest.raises(SystemExit, match="2"):
            upload.main()
        preflight.assert_not_called()
        writer.assert_not_called()


def test_dmg_preflight_timeout_retains_subprocess_diagnostics(monkeypatch, capsys):
    import sys
    import subprocess

    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setattr(
        sys, "argv", ["upload", "--tag", "v0.1.2", "--require-missing-dmg"]
    )
    error = subprocess.TimeoutExpired(
        ["gh", "api"],
        300,
        output=b"original timeout stdout",
        stderr=b"original timeout stderr",
    )
    with patch.object(upload, "require_missing_dmg", side_effect=error):
        with pytest.raises(subprocess.TimeoutExpired):
            upload.main()
    output = capsys.readouterr().err
    assert "original timeout stdout" in output and "original timeout stderr" in output
