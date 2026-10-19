"""Release CLI contracts preserve explicit source/version and private outputs."""

import hashlib
import json
from pathlib import Path
import sys
from unittest.mock import Mock

import pytest
from tools import (
    app_version,
    build_sequence,
    candidate_identity,
    package_contract_candidate,
)
from tools import preview_packages as preview
from tools import (
    release_inputs,
    release_latest,
    release_upload,
    reuse_release_acceptance,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import reference_distribution_config as config


@pytest.mark.parametrize(
    "option", [[], ["--build-number"], ["--check"], ["--set", "1.2.3", "--build", "42"]]
)
def test_version_cli_prints_requested_identity_and_checks_drift(
    monkeypatch, capsys, option
):
    monkeypatch.setattr(app_version, "read_version", lambda: ("1.2.3", 41))
    monkeypatch.setattr(app_version, "stale", lambda: [])
    setter = Mock(return_value=("1.2.3", 42))
    monkeypatch.setattr(app_version, "set_version", setter)
    monkeypatch.setattr(sys, "argv", ["version", *option])
    app_version.main()
    assert capsys.readouterr().out.strip() == (
        ""
        if "--check" in option
        else "41"
        if "--build-number" in option
        else "1.2.3+42"
        if "--set" in option
        else "1.2.3"
    )
    if "--set" in option:
        setter.assert_called_once_with("1.2.3", 42)
    monkeypatch.setattr(sys, "argv", ["version", "--build", "42"])
    with pytest.raises(SystemExit, match="2"):
        app_version.main()
    monkeypatch.setattr(app_version, "stale", lambda: ["version.dart"])
    monkeypatch.setattr(sys, "argv", ["version", "--check"])
    with pytest.raises(SystemExit, match="version.dart"):
        app_version.main()


@pytest.mark.parametrize(
    "status,stdout,stderr,optional,expected",
    [
        (0, '{"sha":"fixture"}', "", False, {"sha": "fixture"}),
        (0, "", "", False, None),
        (1, "", "HTTP 404", True, None),
        (1, "", "HTTP 500", True, RuntimeError),
    ],
)
def test_sequence_request_distinguishes_missing_state_from_failed_transport(
    monkeypatch, status, stdout, stderr, optional, expected
):
    import subprocess

    run = Mock(return_value=subprocess.CompletedProcess([], status, stdout, stderr))
    monkeypatch.setattr(build_sequence.subprocess, "run", run)
    if expected is RuntimeError:
        with pytest.raises(RuntimeError, match="HTTP 500"):
            build_sequence.request(
                "owner/repo", "route", "POST", {"build": 42}, optional
            )
    else:
        assert (
            build_sequence.request(
                "owner/repo", "route", "POST", {"build": 42}, optional
            )
            == expected
        )
    assert run.call_args.args[0][-2:] == ["--input", "-"]
    assert json.loads(run.call_args.kwargs["input"]) == {"build": 42}


def test_sequence_cli_does_not_rewrite_allocated_number(monkeypatch, capsys):
    allocate = Mock(return_value=123)
    monkeypatch.setattr(build_sequence, "allocate", allocate)
    monkeypatch.setattr(
        sys, "argv", ["sequence", "--repository", "owner/repo", "--minimum", "100"]
    )
    build_sequence.main()
    assert capsys.readouterr().out.strip() == "123"
    allocate.assert_called_once_with("owner/repo", 100)


@pytest.mark.parametrize("command", ["plan", "receipt", "manifest", "stamp"])
def test_preview_commands_keep_original_distribution_identity(
    tmp_path, monkeypatch, capsys, command
):
    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    operation = Mock(return_value={"source": "a" * 40, "build_number": "42"})
    monkeypatch.setattr(preview, command, operation)
    args = ["preview", command]
    if command == "plan":
        args += [
            "--repository",
            "owner/repo",
            "--validation",
            "full",
            "--candidate-run",
            "99",
        ]
    elif command == "receipt":
        args += ["--directory", str(tmp_path), "--format", "dmg", "--source", "a" * 40]
    else:
        args += [
            "--version",
            "1.2.3",
            "--build-number",
            "42",
            "--source",
            "a" * 40,
            "--label",
            "nightly.20261019.42",
        ]
        if command == "manifest":
            args += ["--directory", str(tmp_path), "--validation", "full"]
    monkeypatch.setattr(sys, "argv", args)
    preview.main()
    assert json.loads(capsys.readouterr().out)["source"] == "a" * 40
    if command == "plan":
        assert output.read_text() == "source=" + "a" * 40 + "\nbuild_number=42\n"
        assert operation.call_args.args[-1] == 99
    elif command == "receipt":
        assert operation.call_args.args == (tmp_path, "dmg", "a" * 40)
    else:
        assert (
            operation.call_args.args[2 if command == "stamp" else 3]
            == "nightly.20261019.42"
        )


@pytest.mark.parametrize(
    "command", ["candidate", "contract", "inputs", "latest", "upload", "reuse"]
)
def test_release_commands_preserve_immutable_source_and_existing_evidence(
    tmp_path, monkeypatch, capsys, command
):
    output = tmp_path / "outputs"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setenv("GPU_EVIDENCE", "fixture-evidence")
    source = "a" * 40
    if command == "candidate":
        monkeypatch.setattr(candidate_identity, "number", lambda *a: 42)
        monkeypatch.setattr(
            candidate_identity, "source_version", lambda source: ("1.2.3", 1)
        )
        monkeypatch.setattr(
            sys, "argv", ["candidate", "--source", source, "--platforms", "macos"]
        )
        candidate_identity.main()
        assert output.read_text() == "version=1.2.3\nbuild_number=42\n"
    elif command == "contract":
        retrieve = Mock(return_value={"source": source, "producer_run": "99"})
        monkeypatch.setattr(package_contract_candidate, "retrieve", retrieve)
        monkeypatch.setattr(
            sys,
            "argv",
            [
                "contract",
                "--base",
                source,
                "--directory",
                str(tmp_path),
                "--run-id",
                "99",
            ],
        )
        package_contract_candidate.main()
        retrieve.assert_called_once_with("owner/repo", source, tmp_path, 99)
        assert "producer_run=99" in output.read_text()
    elif command == "inputs":
        monkeypatch.setattr(
            release_inputs.subprocess, "check_output", lambda *a, **kw: source
        )
        resolve = Mock(return_value={"source": source})
        monkeypatch.setattr(release_inputs, "resolve", resolve)
        monkeypatch.setattr(
            sys,
            "argv",
            ["inputs", "--tag", "v1.2.3", "--generation", "42", "--formats", "dmg"],
        )
        release_inputs.main()
        resolve.assert_called_once_with("owner/repo", "v1.2.3", source, "42", "dmg")
        monkeypatch.setenv("GITHUB_REF", "refs/heads/topic")
        with pytest.raises(ValueError, match="reviewed main"):
            release_inputs.main()
    elif command == "latest":
        pages = tmp_path / "releases.json"
        pages.write_text(
            '[[{"tag_name":"v1.2.2"}],[{"tag_name":"v1.2.4","draft":true}]]'
        )
        monkeypatch.setattr(
            sys, "argv", ["latest", "--tag", "v1.2.3", "--releases", str(pages)]
        )
        release_latest.main()
        assert capsys.readouterr().out.strip() == "true"
    elif command == "upload":
        upload = Mock()
        monkeypatch.setattr(release_upload, "upload", upload)
        monkeypatch.setattr(
            sys, "argv", ["upload", "--tag", "v1.2.3", str(tmp_path / "installer")]
        )
        release_upload.main()
        upload.assert_called_once_with("owner/repo", "v1.2.3", [tmp_path / "installer"])
    else:
        restore = Mock(
            return_value={
                "source_commit": source,
                "reused_validation_from": {"run": 99},
            }
        )
        monkeypatch.setattr(reuse_release_acceptance, "restore", restore)
        monkeypatch.setattr(
            sys,
            "argv",
            ["reuse", "--tag", "v1.2.3", "--run", "99", "--output", str(output)],
        )
        reuse_release_acceptance.main()
        restore.assert_called_once_with("owner/repo", "v1.2.3", 99, "fixture-evidence")
        assert json.loads(output.read_text())["reused_validation_from"]["run"] == 99


@pytest.mark.parametrize("mode", ["output", "google-output", "github", "google-only"])
def test_distribution_config_cli_suppresses_values_and_writes_only_explicit_destination(
    tmp_path, monkeypatch, capsys, mode
):
    keys = {"SETTING": "private fixture value"}
    registration = {"installed": {"client_id": "private registration"}}
    monkeypatch.setattr(config, "read_configuration", lambda app: dict(keys))
    monkeypatch.setattr(config, "read_google_configuration", lambda app: registration)
    store = Mock()
    monkeypatch.setattr(config, "store_github", store)
    destination = tmp_path / "private/config.json"
    args = ["config", "--app", str(tmp_path / "Synthetic.app")]
    if mode in ("output", "google-output"):
        args += ["--" + mode, str(destination)]
    else:
        args += ["--github-repository", "owner/repo"]
        if mode == "google-only":
            args += ["--google-only"]
    monkeypatch.setattr(sys, "argv", args)
    config.main()
    report = json.loads(capsys.readouterr().out)
    assert report["values"] == "suppressed"
    assert "private" not in json.dumps(report)
    if mode in ("output", "google-output"):
        assert json.loads(destination.read_text()) == (
            keys if mode == "output" else registration
        )
        assert destination.stat().st_mode & 0o777 == 0o600
        store.assert_not_called()
    else:
        values = store.call_args.args[0]
        assert values == (
            keys if mode == "github" else {config.SECRET_NAME: json.dumps(registration)}
        )


def test_reference_settings_require_exact_bytes_and_expected_representation(
    tmp_path, monkeypatch
):
    data = b"AIza" + b"x" * 35
    binary = tmp_path / "Synthetic.app/Contents/MacOS/Foresight"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(data)
    monkeypatch.setattr(config, "REFERENCE_SHA256", hashlib.sha256(data).hexdigest())
    monkeypatch.setattr(config, "SETTINGS", {"SETTING": (1, 0)})
    assert config.read_configuration(tmp_path / "Synthetic.app") == {
        "SETTING": data.decode()
    }
    monkeypatch.setattr(config, "SETTINGS", {"SETTING": (1, 1)})
    with pytest.raises(ValueError, match="representation"):
        config.read_configuration(tmp_path / "Synthetic.app")
    monkeypatch.setattr(config, "GOOGLE_CLIENT_ID_OFFSET", 0)
    with pytest.raises(ValueError, match="registration"):
        config.read_google_configuration(tmp_path / "Synthetic.app")
    monkeypatch.setattr(
        sys, "argv", ["config", "--output", str(tmp_path / "unused"), "--google-only"]
    )
    with pytest.raises(SystemExit, match="2"):
        config.main()
