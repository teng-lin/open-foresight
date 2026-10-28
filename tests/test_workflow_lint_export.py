"""The workflow-lint shared guard must work in a source export without Git."""

import subprocess

import pytest

from tests.source_export import export_tree
from tools import check_local_validation as validation

REQUIRED = {"actionlint": ("-version", "1.7.7"), "shellcheck": ("--version", "0.9.0")}


def hosted_tools_present():
    for name, (flag, version) in REQUIRED.items():
        try:
            output = subprocess.run([name, flag], capture_output=True, text=True, timeout=30, check=False)
        except OSError:
            return False
        if version not in output.stdout + output.stderr:
            return False
    return True


def test_workflow_files_are_named_only_when_no_git_root_exists(tmp_path, monkeypatch):
    workflows = tmp_path / "repo/.github/workflows"
    workflows.mkdir(parents=True)
    for name in ("b.yml", "a.yaml", "ignored.txt"):
        (workflows / name).write_text("name: x\n")
    monkeypatch.setattr(validation, "ROOT", tmp_path / "repo")
    assert validation.workflow_files() == [".github/workflows/a.yaml", ".github/workflows/b.yml"]
    (tmp_path / "repo/.git").mkdir()
    assert validation.workflow_files() == []


def test_a_git_ancestor_keeps_project_discovery(tmp_path, monkeypatch):
    (tmp_path / ".git").mkdir()
    nested = tmp_path / "export"
    (nested / ".github/workflows").mkdir(parents=True)
    (nested / ".github/workflows/x.yml").write_text("name: x\n")
    monkeypatch.setattr(validation, "ROOT", nested)
    assert validation.workflow_files() == []


def test_actionlint_receives_the_files_in_an_export_and_nothing_inside_a_repository(tmp_path, monkeypatch):
    calls = []

    class Done:
        returncode = 0
        stdout = b""
        stderr = b"actionlint 1.7.7 shellcheck 0.9.0"

    def run(arguments, **keywords):
        calls.append(list(arguments))
        return Done()

    (tmp_path / ".github/workflows").mkdir(parents=True)
    (tmp_path / ".github/workflows/ci.yml").write_text("name: ci\n")
    monkeypatch.setattr(validation, "ROOT", tmp_path)
    monkeypatch.setattr(validation.subprocess, "run", run)
    monkeypatch.setattr(validation.shutil, "which", lambda name: f"/bin/{name}")
    assert validation.workflow_lint() == 0
    assert calls[-1] == ["/bin/actionlint", ".github/workflows/ci.yml"]
    (tmp_path / ".git").mkdir()
    assert validation.workflow_lint() == 0
    assert calls[-1] == ["/bin/actionlint"]


def test_the_real_guard_passes_in_a_git_archive_export_without_git(tmp_path, monkeypatch):
    if not hosted_tools_present():
        pytest.skip("hosted actionlint 1.7.7 and ShellCheck 0.9.0 are required; run through the quality workflow")
    export = export_tree(tmp_path / "tree")
    monkeypatch.setattr(validation, "ROOT", export)
    assert not any((directory / ".git").exists() for directory in (export, *export.parents))
    assert validation.workflow_lint() == 0
    # The same guard still rejects a broken workflow in the export.
    (export / ".github/workflows/broken.yml").write_text("on: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ nonsense.value }}\n")
    assert validation.workflow_lint() == 1
