"""Build classification and recipe validation must fail closed before reuse."""

import json
import locale
import os
import sys
from unittest.mock import Mock

import pytest

from tools import ci_artifacts as artifacts
from tools import ci_changes as changes
from tools import ci_stage_environment as environment
from tools import sdk_workflow_recipe as workflow


@pytest.mark.parametrize(
    "old,new,message",
    [
        ("jobs:\n", "jobs: {}\n", "job layout"),
        ("  plan:\n", "  plan: {}\n", "job layout"),
        ("  plan:\n", "  plan:\n    name: Build Linux core\n", "alias"),
        ("  core:\n", "  core:\n    strategy:\n      matrix: {}\n", "Unexpected"),
        ("    steps:\n", "    actions:\n", "Missing SDK build steps"),
    ],
)
def test_malformed_producer_layout_cannot_authorize_cached_sdk(old, new, message):
    text = (artifacts.ROOT / artifacts.WORKFLOW).read_text()
    assert old in text
    lines = text.replace(old, new).splitlines(keepends=True)
    # These guards are independent of which delimited recipe owns each line.
    owners = set().union(*workflow.JOBS.values())
    with pytest.raises(ValueError, match=message):
        workflow.validate(lines, [owners] * len(lines))


@pytest.mark.parametrize("setting", ["env", "defaults", "container", "services"])
def test_unmarked_ambient_producer_settings_cannot_hide_compiler_changes(setting):
    text = (artifacts.ROOT / artifacts.WORKFLOW).read_text()
    injected = f"    {setting}: {{injected: changed}}\n"
    lines = text.replace("  macos:\n", "  macos:\n" + injected).splitlines(
        keepends=True
    )
    owners = set().union(*workflow.JOBS.values())
    coverage = [owners if line != injected else set() for line in lines]
    with pytest.raises(ValueError, match="Unaccounted SDK build environment: macos"):
        workflow.validate(lines, coverage)


def test_unsupported_requested_locale_is_recorded_and_original_restored(monkeypatch):
    calls = []

    def setlocale(category, value=None):
        assert category == locale.LC_ALL
        calls.append(value)
        if value == "":
            raise locale.Error("unsupported requested locale")
        return "C"

    monkeypatch.setattr(environment.locale, "setlocale", setlocale)
    record = environment.validation_context(
        {"LANG": "unavailable", "FORESIGHT_SECRET": "never publish this"}
    )
    assert record["locale"] == {
        "effective": "C",
        "requested_supported": False,
        "environment": {"LANG": "unavailable"},
    }
    assert calls == [None, "", None, "C"]
    assert "never publish this" not in json.dumps(record)


def test_sdk_prefix_cannot_be_a_regular_file(tmp_path):
    prefix = tmp_path / "sdk"
    prefix.write_bytes(b"not an extracted SDK")
    with pytest.raises(ValueError, match="must be a directory"):
        environment.sdk_content_digest(prefix)


def test_internal_sdk_link_cannot_resolve_to_a_fifo(tmp_path):
    os.mkfifo(tmp_path / "pipe")
    (tmp_path / "a-link").symlink_to("pipe")
    with pytest.raises(ValueError, match="symlink targets a special file"):
        environment.sdk_content_digest(tmp_path)


@pytest.mark.parametrize(
    "path,expected",
    [
        ("packaging/notices/dependency.md", set(changes.GATES[1:])),
        ("apps/desktop/macos/Runner/Info.plist", {"macos"}),
        ("apps/desktop/linux/runner/main.cc", set(changes.GATES[1:])),
        ("tools/new_unknown_build_tool.py", set(changes.GATES)),
    ],
)
def test_output_affecting_paths_select_all_required_platform_gates(path, expected):
    assert {
        key for key, value in changes.select_gates([path]).items() if value
    } == expected


@pytest.mark.parametrize("platform", ["linux", "macos"])
def test_initial_commit_classification_uses_empty_tree_and_limits_platform(
    tmp_path, monkeypatch, platform
):
    monkeypatch.chdir(tmp_path)
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setattr(
        sys, "argv", ["ci_changes", "--base", "0" * 40, "--platforms", platform]
    )
    commands = []

    def check_output(args, **kwargs):
        commands.append(args)
        return "empty-tree\n" if kwargs.get("text") else b"tools/new-build.py\0"

    monkeypatch.setattr(changes.subprocess, "check_output", check_output)
    check = Mock()
    monkeypatch.setattr(changes.subprocess, "run", check)
    changes.main()
    assert commands == [
        ["git", "hash-object", "-t", "tree", "/dev/null"],
        [
            "git",
            "diff",
            "--name-only",
            "--no-renames",
            "-z",
            "empty-tree",
            "HEAD",
            "--",
        ],
    ]
    check.assert_called_once_with(
        ["git", "diff", "--check", "empty-tree", "HEAD", "--"], check=True, timeout=300
    )
    fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
    selected = json.loads(fields["selection"])
    assert selected["packaging"]
    assert selected["macos"] == (platform == "macos")
    assert selected["linux-native"] == (platform == "linux")
    assert fields["linux_bundle"] == str(platform == "linux").lower()


def test_classifier_requires_base_before_running_git(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["ci_changes"])
    run = Mock()
    monkeypatch.setattr(changes.subprocess, "check_output", run)
    with pytest.raises(SystemExit) as error:
        changes.main()
    assert error.value.code == 2
    run.assert_not_called()


def test_cli_checks_selected_gates_including_macos_stage_summary(monkeypatch, capsys):
    selected = changes.select_gates(["tools/smoke_macos_bundle.py"])
    jobs = {
        gate: {"result": "success" if needed else "skipped"}
        for gate, needed in selected.items()
    }
    jobs.update(
        {"changes": {"result": "success"}, "macos-stages": {"result": "success"}}
    )
    monkeypatch.setenv("NEEDS", json.dumps(jobs))
    monkeypatch.setenv("SELECTION", json.dumps(selected))
    monkeypatch.setenv("MAIN", "false")
    monkeypatch.setattr(sys, "argv", ["ci_changes", "--check-gates"])
    changes.main()
    assert "All selected platform gates passed" in capsys.readouterr().out
    jobs["macos-stages"]["result"] = "skipped"
    monkeypatch.setenv("NEEDS", json.dumps(jobs))
    with pytest.raises(ValueError, match="macos-stages: expected success"):
        changes.main()
