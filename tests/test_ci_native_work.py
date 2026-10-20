"""Compiler restoration is independent of successful stage-result reuse."""

import json
from pathlib import Path
from unittest.mock import Mock

import pytest

from tools import ci_native_work as work


@pytest.fixture
def resolver(monkeypatch):
    resolver = Mock(return_value={"hit": False, "reason": "verified miss"})
    monkeypatch.setattr(work.cache, "find_native_work", resolver)
    assert not hasattr(work.cache, "find")
    assert not hasattr(work.cache, "publish")
    return resolver


def test_verified_miss_records_incompatibility_without_unpacking(
    tmp_path, resolver, monkeypatch, capsys
):
    resolver.return_value = {
        "hit": False,
        "incompatible_environment_fields": ["compiler", "packages"],
    }
    unpack = Mock()
    monkeypatch.setattr(work.payloads, "unpack", unpack)
    result = work.restore(
        tmp_path,
        "linux",
        {"compiler": "current"},
        ["-G", "Ninja"],
        "owner/repo",
        event="schedule",
        branch="main",
    )
    assert result == resolver.return_value
    assert "compiler" in capsys.readouterr().out
    unpack.assert_not_called()
    args = resolver.call_args.args
    assert args[:2] == ("owner/repo", "linux")
    assert args[2]["cmake_arguments"] == ["-G", "Ninja"]
    assert args[3:8] == (tmp_path, 0, "schedule", "main", False)


@pytest.mark.parametrize(
    "error", [RuntimeError("API failure"), ValueError("unresolved search")]
)
def test_search_failure_never_becomes_permission_for_cold_build(
    tmp_path, resolver, error
):
    resolver.side_effect = error
    with pytest.raises(type(error), match=str(error)):
        work.restore(tmp_path, "linux", {}, [], "owner/repo")


@pytest.mark.parametrize("changed", [[], ["CMakeLists.txt"]])
def test_hit_preserves_original_provenance_and_configuration_invalidation(
    tmp_path, resolver, monkeypatch, changed
):
    (tmp_path / "build").mkdir()
    cache = tmp_path / "build/CMakeCache.txt"
    cache.write_text("original settings")
    receipt = {
        "content": {"files": {}},
        "source_commit": "original-head",
        "producer_run_id": 100,
    }
    resolver.return_value = {
        "hit": True,
        "receipt": receipt,
        "identity": "original",
        "run_id": 100,
        "download_dir": str(tmp_path / "download"),
        "configuration_changed": changed,
    }
    unpack = Mock()
    monkeypatch.setattr(work.payloads, "unpack", unpack)
    result = work.restore(
        tmp_path,
        "macos",
        {"sdk": {"prefix": "/exact/sdk"}},
        ["-DICU_ROOT=/exact/icu"],
        "owner/repo",
        12,
        "pull_request",
        "topic",
    )
    unpack.assert_called_once_with(
        tmp_path,
        "macos",
        "native",
        tmp_path / "download/payload.tar.gz",
        receipt["content"],
        force_changed=True,
    )
    assert cache.exists() == (not changed)
    assert result["receipt"] == receipt
    assert result["identity"] == "original"
    assert result["run_id"] == 100
    assert "download_dir" not in result


@pytest.mark.parametrize("platform,sdk", [("linux", None), ("macos", "build/sdk")])
def test_cli_collects_actual_native_environment_and_writes_evidence(
    tmp_path, resolver, monkeypatch, platform, sdk
):
    collect = Mock(return_value={"compiler": "actual", "workspace": str(tmp_path)})
    monkeypatch.setattr(work, "ROOT", tmp_path)
    monkeypatch.setattr(work.stage_environment, "collect", collect)
    monkeypatch.delenv("GITHUB_HEAD_REF", raising=False)
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "schedule")
    monkeypatch.setenv("GITHUB_REF_NAME", "main")
    output = tmp_path / "evidence/work.json"
    arguments = ["native-work", "--platform", platform, "--output", str(output)]
    if sdk:
        arguments += ["--sdk-prefix", sdk]
    arguments += ["--", "-G", "Ninja", "-DICU_ROOT=/exact/icu"]
    monkeypatch.setattr("sys.argv", arguments)
    work.main()
    collect.assert_called_once_with(
        platform, tmp_path, Path(sdk) if sdk else None, stage="native"
    )
    assert json.loads(output.read_text()) == resolver.return_value
    assert resolver.call_args.args[2]["cmake_arguments"] == [
        "-G",
        "Ninja",
        "-DICU_ROOT=/exact/icu",
    ]


def test_cli_requires_repository(monkeypatch):
    monkeypatch.delenv("GITHUB_REPOSITORY", raising=False)
    monkeypatch.setattr("sys.argv", ["native-work"])
    with pytest.raises(SystemExit, match="2"):
        work.main()


def test_cli_without_extra_arguments_or_output_uses_explicit_consumer(
    tmp_path, resolver, monkeypatch
):
    monkeypatch.setattr(work, "ROOT", tmp_path)
    monkeypatch.setattr(work.stage_environment, "collect", Mock(return_value={}))
    monkeypatch.setattr(
        "sys.argv",
        [
            "native-work",
            "--repository",
            "owner/repo",
            "--event",
            "pull_request",
            "--own-pr",
            "12",
            "--branch",
            "topic",
            "--release",
        ],
    )
    work.main()
    args = resolver.call_args.args
    assert args[2]["cmake_arguments"] == []
    assert args[4:8] == (12, "pull_request", "topic", True)
