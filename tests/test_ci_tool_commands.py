"""CLI contracts preserve producer identities and never turn misses into builds."""

import json
import sys
from unittest.mock import Mock

import pytest
from tools import ci_artifacts as artifacts
from tools import ci_stage_cache as stages
from tools import ci_sanitizer_artifacts as sanitizers
from tools import ci_stage_artifacts as payloads
from tools import ci_stage_environment as environment
from tools import linux_sdk_artifacts as linux
from tools import ci_app_build_transport as transport
from tools import ci_macos_dependencies as macos
from tools import ci_changes as changes


@pytest.mark.parametrize(
    "command", ["keys", "probe", "pack", "pull", "publish-receipt"]
)
def test_artifact_commands_keep_explicit_identity_and_ci_outputs(
    tmp_path, monkeypatch, command
):
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setattr(artifacts, "fingerprint", lambda component: "a" * 64)
    calls = {}
    for name in ("probe", "pack", "pull", "publish_receipt"):
        calls[name] = Mock(return_value=True)
        monkeypatch.setattr(artifacts, name, calls[name])
    args = [
        "artifact",
        command,
        "--repository",
        "owner/repo",
        "--component",
        "linux-core",
        "--identity",
        "b" * 64,
        "--prefix",
        str(tmp_path / "prefix"),
        "--output",
        str(tmp_path / "artifact"),
        "--artifact-id",
        "123",
        "--artifact-digest",
        "sha256:" + "d" * 64,
        "--own-head",
        "c" * 40,
        "--own-pr",
        "77",
        "--run-id",
        "456",
    ]
    monkeypatch.setattr(sys, "argv", args)
    artifacts.main()
    if command == "keys":
        assert "linux-core=" + "a" * 64 in output.read_text()
    elif command == "probe":
        assert output.read_text() == "hit=true\n"
        calls["probe"].assert_called_once_with(
            "owner/repo", "linux-core", "b" * 64, "c" * 40, 77
        )
    elif command == "pull":
        assert calls["pull"].call_args.kwargs == {
            "source_run": 456,
            "artifact_id": 123,
            "artifact_digest": "sha256:" + "d" * 64,
        }
        assert calls["pull"].call_args.args[2] == "b" * 64
    elif command == "publish-receipt":
        assert calls["publish_receipt"].call_args.args[4] == 123
    else:
        assert calls["pack"].call_args.args[:2] == ("linux-core", "b" * 64)


@pytest.mark.parametrize("optional", [False, True])
def test_artifact_miss_has_distinct_exit_and_does_not_compile(
    tmp_path, monkeypatch, optional
):
    monkeypatch.setattr(artifacts, "pull", Mock(return_value=False))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "artifact",
            "pull",
            "--component",
            "linux-core",
            "--identity",
            "a" * 64,
            "--prefix",
            str(tmp_path),
            *(["--optional"] if optional else []),
        ],
    )
    with pytest.raises(SystemExit) as error:
        artifacts.main()
    assert error.value.code == (
        4 if optional else artifacts.unavailable_message("linux-core", "a" * 64)
    )


@pytest.mark.parametrize(
    "args",
    [
        ["probe"],
        ["publish-receipt"],
        ["pack"],
        [
            "pack",
            "--component",
            "linux-core",
            "--prefix",
            "/unused",
            "--identity",
            "a" * 64,
        ],
    ],
)
def test_artifact_cli_rejects_incomplete_requests(monkeypatch, args):
    monkeypatch.setattr(sys, "argv", ["artifact", *args])
    with pytest.raises(SystemExit, match="2"):
        artifacts.main()


@pytest.mark.parametrize("command", ["key", "probe", "restore", "publish"])
def test_stage_commands_keep_environment_parents_and_reuse_policy(
    tmp_path, monkeypatch, command
):
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    identity = "a" * 64
    fingerprint = Mock(return_value=identity)
    find = Mock(
        return_value={
            "identity": identity,
            "hit": True,
            "artifact_id": 42,
            "run_id": 88,
            "download_dir": str(tmp_path),
        }
    )
    publish = Mock(return_value={"identity": identity, "artifact_name": "fixture"})
    monkeypatch.setattr(stages, "fingerprint", fingerprint)
    monkeypatch.setattr(stages, "find", find)
    monkeypatch.setattr(stages, "publish", publish)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "stages",
            command,
            "--platform",
            "linux",
            "--stage",
            "native",
            "--root",
            str(tmp_path),
            "--environment-json",
            '{"compiler":"fixture"}',
            "--parents-json",
            '{"sdk":"original"}',
            "--content-json",
            '{"files":{}}',
            "--output",
            str(tmp_path / "download"),
            "--archive",
            str(tmp_path / "archive"),
            "--repository",
            "owner/repo",
            "--own-pr",
            "77",
            "--event",
            "pull_request",
            "--branch",
            "feature",
        ],
    )
    stages.main()
    assert fingerprint.call_args.args[-2:] == (
        {"compiler": "fixture"},
        {"sdk": "original"},
    )
    if command in ("probe", "restore"):
        assert "hit=true\n" in output.read_text()
        assert find.call_args.args[7:11] == (77, "pull_request", "feature", False)
        assert find.call_args.args[-1] == (
            tmp_path / "download" if command == "restore" else None
        )
    else:
        assert "identity=" + identity in output.read_text()
    if command == "publish":
        assert publish.call_args.args[-1] == {"files": {}}


@pytest.mark.parametrize("command", ["restore", "publish"])
def test_stage_commands_require_explicit_output(tmp_path, monkeypatch, command):
    monkeypatch.setattr(stages, "fingerprint", lambda *a: "a" * 64)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "stages",
            command,
            "--platform",
            "linux",
            "--stage",
            "native",
            "--environment-json",
            "{}",
        ],
    )
    with pytest.raises(SystemExit, match="2"):
        stages.main()


@pytest.mark.parametrize("command", ["verify-environment", "restore", "pack"])
def test_sanitizer_commands_forward_explicit_build_authorization(
    tmp_path, monkeypatch, command
):
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    handlers = {}
    for name in ("verify_environment_profile", "restore", "pack"):
        handlers[name] = Mock(return_value={"origin": "verified-original"})
        monkeypatch.setattr(sanitizers, name, handlers[name])
    args = [
        "sanitizers",
        command,
        "--kind",
        "address",
        "--prefix",
        str(tmp_path / "sdk"),
        "--repository",
        "owner/repo",
        "--cache-key",
        "original-key",
        "--cache-hit",
        "true",
    ]
    if command == "pack":
        args += ["--output", str(tmp_path / "archive")]
    monkeypatch.setattr(sys, "argv", args)
    sanitizers.main()
    assert output.read_text() == "origin=verified-original\n"
    if command == "restore":
        restore_args = handlers["restore"].call_args.args
        assert restore_args[5:] == ("original-key", False, "", "true")
    monkeypatch.setattr(
        sys,
        "argv",
        ["sanitizers", "pack", "--kind", "address", "--prefix", str(tmp_path)],
    )
    with pytest.raises(SystemExit, match="2"):
        sanitizers.main()


@pytest.mark.parametrize("command", ["pack", "unpack"])
def test_stage_payload_cli_reads_manifest_and_validates_arguments(
    tmp_path, monkeypatch, command
):
    manifest = tmp_path / "content.json"
    manifest.write_text('{"files":{"build/native/fixture":{}}}')
    operation = Mock()
    monkeypatch.setattr(payloads, command, operation)
    args = [
        "payload",
        command,
        "--platform",
        "linux",
        "--stage",
        "native",
        "--root",
        str(tmp_path),
    ]
    monkeypatch.setattr(sys, "argv", args)
    with pytest.raises(SystemExit, match="2"):
        payloads.main()
    monkeypatch.setattr(
        sys,
        "argv",
        [
            *args,
            "--output",
            str(tmp_path / "archive"),
            "--archive",
            str(tmp_path / "archive/payload.tar.gz"),
            "--manifest",
            str(manifest),
        ],
    )
    payloads.main()
    assert operation.call_count == 1
    if command == "unpack":
        assert operation.call_args.args[-1] == json.loads(manifest.read_text())


@pytest.mark.parametrize("command", ["describe", "produce", "resolve", "promote"])
def test_linux_sdk_cli_preserves_original_and_discards_only_requested_transport(
    tmp_path, monkeypatch, command
):
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    handlers = {}
    for name in ("describe", "produce", "resolve", "promote", "write_outputs"):
        handlers[name] = Mock(
            return_value="approved-original" if name == "produce" else "image:verified"
        )
        monkeypatch.setattr(linux, name, handlers[name])
    archive = tmp_path / "image.tar"
    archive.write_bytes(b"transport")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "sdk",
            command,
            "--component",
            "linux-core",
            "--prefix",
            str(tmp_path),
            "--output",
            str(tmp_path / "packed"),
            "--tag",
            "image:target",
            "--discard-archive",
        ],
    )
    linux.main()
    if command == "produce":
        assert output.read_text() == "original=true\n"
    elif command in ("resolve", "promote"):
        assert not archive.exists()
        handlers["write_outputs"].assert_called_once_with(
            "image:verified", application_cache=command == "resolve"
        )
    else:
        assert archive.read_bytes() == b"transport"


@pytest.mark.parametrize(
    "args", [["describe"], ["produce"], ["resolve"], ["promote", "--prefix", "/unused"]]
)
def test_linux_sdk_cli_rejects_missing_inputs(monkeypatch, args):
    monkeypatch.setattr(sys, "argv", ["sdk", *args])
    with pytest.raises(SystemExit, match="2"):
        linux.main()


@pytest.mark.parametrize(
    "flags,acceptance,ci",
    [
        ([], False, False),
        (["--acceptance"], True, False),
        (["--ci"], False, True),
    ],
    ids=["application", "acceptance", "ci"],
)
def test_application_transport_outputs_lowercase_boolean(
    tmp_path, monkeypatch, capsys, flags, acceptance, ci
):
    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    prepare = Mock(return_value={"builder": "default", "cache_available": False})
    monkeypatch.setattr(transport, "prepare", prepare)
    monkeypatch.setattr(
        sys,
        "argv",
        ["transport", "--repository", "owner/repo", *flags],
    )
    transport.main()
    prepare.assert_called_once_with("owner/repo", acceptance=acceptance, ci=ci)
    assert output.read_text() == "builder=default\ncache_available=false\n"
    assert json.loads(capsys.readouterr().out)["cache_available"] is False


def test_environment_cli_retains_collected_record(tmp_path, monkeypatch):
    destination = tmp_path / "nested/environment.json"
    collect = Mock(
        return_value={"compiler": "fixture", "sdk": {"identity": "original"}}
    )
    monkeypatch.setattr(environment, "collect", collect)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "environment",
            "--platform",
            "macos",
            "--stage",
            "native",
            "--sdk-prefix",
            str(tmp_path / "sdk"),
            "--output",
            str(destination),
        ],
    )
    environment.main()
    assert json.loads(destination.read_text()) == collect.return_value
    collect.assert_called_once_with(
        "macos", sdk_prefix=tmp_path / "sdk", stage="native"
    )


@pytest.mark.parametrize("allow_local_build", [False, True])
def test_macos_consumer_cli_keeps_running_producer_parameters(
    tmp_path, monkeypatch, capsys, allow_local_build
):
    ensure = Mock(return_value="artifact")
    monkeypatch.setattr(macos, "ensure", ensure)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "macos",
            "--component",
            "macos-sdk",
            "--prefix",
            str(tmp_path),
            "--repository",
            "owner/repo",
            "--own-head",
            "a" * 40,
            "--own-pr",
            "77",
            "--wait",
            "30",
            *(["--allow-local-build"] if allow_local_build else []),
        ],
    )
    macos.main()
    assert capsys.readouterr().out.strip() == "artifact"
    assert ensure.call_args.args[-3:] == ("a" * 40, 77, 30)
    assert ensure.call_args.kwargs == {"allow_local_build": allow_local_build}


def test_change_cli_preserves_nul_paths_and_platform_selection(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    destination = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(destination))
    calls = []

    def output(command, **kwargs):
        calls.append(command)
        return "a" * 40 if command[1] == "hash-object" else b"unknown\nfilename\0"

    monkeypatch.setattr(changes.subprocess, "check_output", output)
    monkeypatch.setattr(changes.subprocess, "run", Mock())
    monkeypatch.setattr(sys, "argv", ["changes", "--base", "0" * 40])
    changes.main()
    selected = json.loads(
        destination.read_text().splitlines()[0].removeprefix("selection=")
    )
    assert selected["packaging"] is True
    assert selected["macos"] is True
    assert selected["linux-build"] is True
    assert calls[1][-3:] == ["a" * 40, "HEAD", "--"]
