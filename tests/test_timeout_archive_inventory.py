import shutil
import subprocess
import tarfile

import pytest

from tools import check_subprocess_timeouts as gate


def write(root, name, text):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def test_archive_checks_new_source_roots_with_real_nested_ignore_policy(
    tmp_path, capsys
):
    write(tmp_path, ".gitignore", ".venv/\nbuild/\ndist/\ncoverage/\n__pycache__/\n")
    for excluded in [".venv", "build", "dist", "coverage", "tools/__pycache__"]:
        write(
            tmp_path,
            f"{excluded}/generated.py",
            'import subprocess\nsubprocess.run(["ignored"])\n',
        )
    write(tmp_path, "tools/.gitignore", "generated/*\n!generated/real_source.py\n")
    write(
        tmp_path,
        "tools/generated/ignored.py",
        'import subprocess\nsubprocess.run(["ignored"])\n',
    )
    write(
        tmp_path,
        "tools/generated/real_source.py",
        'import subprocess\nsubprocess.run(["ok"], timeout=30)\n',
    )
    write(
        tmp_path,
        ".new source/nested\nunsafe.py",
        'import subprocess\nsubprocess.run(["must fail"])\n',
    )
    before = sorted(str(path.relative_to(tmp_path)) for path in tmp_path.rglob("*"))
    assert gate.source_files(tmp_path) == [
        ".new source/nested\nunsafe.py",
        "tools/generated/real_source.py",
    ]
    assert gate.main(tmp_path) == 1
    assert "unsafe.py:2:" in capsys.readouterr().out
    write(
        tmp_path,
        ".new source/nested\nunsafe.py",
        'import subprocess\nsubprocess.run(["now bounded"], timeout=1)\n',
    )
    assert gate.main(tmp_path) == 0
    assert before == sorted(
        str(path.relative_to(tmp_path)) for path in tmp_path.rglob("*")
    )
    assert not (tmp_path / ".git").exists()


@pytest.mark.parametrize("checkout", [False, True])
def test_inherited_git_environment_and_global_ignores_cannot_hide_source(
    tmp_path, monkeypatch, checkout
):
    if checkout:
        subprocess.run(
            ["git", "init", "--quiet", str(tmp_path)], check=True, timeout=30
        )
    write(tmp_path, "untracked.py", 'import subprocess\nsubprocess.run(["unsafe"])\n')
    config = tmp_path.parent / f"{tmp_path.name}-global-config"
    ignored = tmp_path.parent / f"{tmp_path.name}-global-ignore"
    ignored.write_text("*.py\n")
    config.write_text(f"[core]\n excludesFile = {ignored}\n")
    monkeypatch.setenv("GIT_DIR", "/missing/inherited/git")
    monkeypatch.setenv("GIT_WORK_TREE", "/missing/inherited/worktree")
    monkeypatch.setenv("GIT_INDEX_FILE", "/missing/inherited/index")
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(config))
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", str(config))
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", "core.excludesFile")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", str(ignored))
    assert gate.source_files(tmp_path) == ["untracked.py"]
    assert gate.main(tmp_path) == 1


@pytest.mark.parametrize("metadata", ["directory", "worktree-file", "broken-symlink"])
def test_broken_existing_git_metadata_never_falls_back(tmp_path, metadata):
    write(tmp_path, "source.py", 'print("finite")\n')
    if metadata == "directory":
        (tmp_path / ".git").mkdir()
    elif metadata == "worktree-file":
        (tmp_path / ".git").write_text("gitdir: /missing/worktree/git\n")
    else:
        (tmp_path / ".git").symlink_to(tmp_path / "missing-git")
    with pytest.raises(subprocess.CalledProcessError):
        gate.source_files(tmp_path)


def test_archive_git_initialization_failure_is_not_a_passing_inventory(
    tmp_path, monkeypatch
):
    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(1, args[0])

    monkeypatch.setattr(gate.subprocess, "run", fail)
    with pytest.raises(subprocess.CalledProcessError):
        gate.source_files(tmp_path)


def test_complete_git_export_preserves_source_inventory_without_local_history(tmp_path):
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    subprocess.run(["git", "init", "--quiet", str(checkout)], check=True, timeout=30)
    write(checkout, ".gitignore", "build/\n.venv/\n")
    for name in [
        "tools/check.py",
        "native/helper.py",
        "packaging/new/check.py",
        "new-source/check.py",
    ]:
        write(
            checkout, name, 'import subprocess\nsubprocess.run(["finite"], timeout=1)\n'
        )
    subprocess.run(["git", "add", "."], cwd=checkout, check=True, timeout=30)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "independent source fixture",
        ],
        cwd=checkout,
        check=True,
        timeout=30,
    )
    archive = tmp_path / "source.tar"
    subprocess.run(
        ["git", "archive", f"--output={archive}", "HEAD"],
        cwd=checkout,
        check=True,
        timeout=30,
    )
    exported = tmp_path / "export"
    exported.mkdir()
    with tarfile.open(archive) as source:
        source.extractall(exported, filter="data")
    for root in [checkout, exported]:
        write(root, "brand-new/untracked.py", 'print("new source")\n')
        write(
            root,
            "build/generated.py",
            'import subprocess\nsubprocess.run(["ignored"])\n',
        )
        write(
            root,
            ".venv/dependency.py",
            'import subprocess\nsubprocess.run(["ignored"])\n',
        )
    expected = gate.source_files(checkout)
    # The exported tree remains independently usable after its producer fixture
    # (including all local Git objects/HEAD) has been removed.
    shutil.rmtree(checkout)
    assert gate.source_files(exported) == expected
    assert gate.main(exported) == 0
    assert not (exported / ".git").exists()
