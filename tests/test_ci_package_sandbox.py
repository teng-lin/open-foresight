"""CI-only namespace policy and ordinary-user preflight; no Docker or apt runs."""

import json
import os
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def fake_commands(tmp_path, names):
    binary = tmp_path / "bin"
    binary.mkdir()
    script = '#!/usr/bin/env python3\nimport json,os,sys\nname=os.path.basename(sys.argv[0])\nwith open(os.environ["SANDBOX_TEST_LOG"],"a") as stream: stream.write(json.dumps([name,*sys.argv[1:]])+"\\n")\nif name=="runuser" and os.environ.get("FAIL_SANDBOX")=="1": sys.exit(42)\n'
    for name in names:
        command = binary / name
        command.write_text(script)
        command.chmod(0o755)
    return {
        **os.environ,
        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
        "SANDBOX_TEST_LOG": str(tmp_path / "commands"),
    }


@pytest.mark.parametrize(
    "github,runner,allowed",
    [
        ("true", "github-hosted", True),
        ("false", "github-hosted", False),
        ("true", "self-hosted", False),
        ("", "", False),
    ],
)
def test_host_policy_load_is_restricted_to_disposable_hosted_ci(
    tmp_path, github, runner, allowed
):
    env = fake_commands(tmp_path, ["sudo"])
    env.update(GITHUB_ACTIONS=github, RUNNER_ENVIRONMENT=runner)
    result = subprocess.run(
        ["bash", "tools/ci_package_sandbox.sh"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    log = tmp_path / "commands"
    assert (result.returncode == 0) == allowed
    if allowed:
        assert json.loads(log.read_text()) == [
            "sudo",
            "apparmor_parser",
            "--replace",
            "packaging/ci/document-sandbox.apparmor",
        ]
    else:
        assert not log.exists()
        assert "GitHub-hosted" in result.stderr


@pytest.mark.parametrize("format", ["deb", "rpm", "arch"])
@pytest.mark.parametrize("fail", [False, True])
def test_minimal_prerequisites_then_exact_ordinary_user_sandbox_preflight(
    tmp_path, format, fail
):
    env = fake_commands(tmp_path, ["apt-get", "dnf", "pacman", "useradd", "runuser"])
    env["FAIL_SANDBOX"] = "1" if fail else "0"
    result = subprocess.run(
        ["bash", "packaging/ci/prepare-document-sandbox.sh", format, "package-test"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == (42 if fail else 0)
    commands = [
        json.loads(line) for line in (tmp_path / "commands").read_text().splitlines()
    ]
    assert commands[-2] == ["useradd", "--create-home", "package-test"]
    probe = commands[-1]
    assert probe[:5] == ["runuser", "-u", "package-test", "--", "/usr/bin/bwrap"]
    assert probe[5:10] == [
        "--unshare-all",
        "--die-with-parent",
        "--new-session",
        "--cap-drop",
        "ALL",
    ]
    assert probe[-2:] == ["--", "/usr/bin/true"]
    assert "--clearenv" in probe and "--ro-bind" in probe
    assert "--share-net" not in probe
    assert all(
        "xvfb" not in command and "python3" not in command for command in commands
    )
    if format == "deb":
        assert commands[:2] == [
            ["apt-get", "update"],
            [
                "apt-get",
                "install",
                "-y",
                "--no-install-recommends",
                "bubblewrap",
                "passwd",
            ],
        ]
    elif format == "arch":
        assert commands[0] == [
            "pacman",
            "-Syu",
            "--noconfirm",
            "--needed",
            "bubblewrap",
            "shadow",
        ]


def test_all_package_container_callers_select_the_loaded_named_policy():
    for workflow in (
        "integration-acceptance",
        "preview-packages",
        "linux-packages",
        "release-acceptance",
    ):
        jobs = yaml.safe_load((ROOT / f".github/workflows/{workflow}.yml").read_text())[
            "jobs"
        ]
        found = False
        for job in jobs.values():
            steps = job.get("steps", [])
            for index, step in enumerate(steps):
                command = step.get("run", "")
                if "docker run" not in command or "packaging/ci/" not in command:
                    continue
                found = True
                assert "apparmor=foresight-ci-document-sandbox" in command
                assert "apparmor=unconfined" not in command
                assert "--privileged" not in command
                assert any(
                    previous.get("run") == "bash tools/ci_package_sandbox.sh"
                    for previous in steps[:index]
                )
        assert found


def test_each_installer_checks_its_smoke_user_before_expensive_dependencies():
    for filename, user in (
        ("package-and-test.sh", "package-test"),
        ("test-debian.sh", "package-test"),
        ("test-release-package.sh", "acceptance"),
    ):
        source = (ROOT / "packaging/ci" / filename).read_text()
        assert source.index("prepare-document-sandbox.sh") < source.index("xvfb")
        assert f" {user}\n" in source
        assert "useradd" not in source
        assert f"runuser -u {user} -- xvfb-run" in source
