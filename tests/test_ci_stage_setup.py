"""Linux roles stay narrow; macOS warms the complete application prerequisites."""

import json
import os
from pathlib import Path
import subprocess
from unittest.mock import patch

import pytest
import yaml

from tools import ci_build_environment as environment

ROOT = Path(__file__).resolve().parents[1]


def action(platform):
    return yaml.safe_load(
        (ROOT / f".github/actions/setup-{platform}-stage/action.yml").read_text()
    )["runs"]["steps"]


def step_named(platform, fragment):
    return next(step for step in action(platform) if fragment in step.get("name", ""))


@pytest.mark.parametrize("platform", ["linux"])
def test_every_caller_declares_its_role(platform):
    path = ROOT / f".github/workflows/{platform}-platform-stages.yml"
    jobs = yaml.safe_load(path.read_text())["jobs"]
    for role in ("native", "core", "desktop", "service"):
        setup = next(
            step
            for step in jobs[f"{role}-{platform}"]["steps"]
            if step.get("uses") == f"./.github/actions/setup-{platform}-stage"
        )
        assert setup["with"]["stage"] == role


def test_macos_setup_fetches_one_verified_sdk_without_stage_roles():
    config = yaml.safe_load(
        (ROOT / ".github/actions/setup-macos-stage/action.yml").read_text()
    )
    assert "stage" not in config["inputs"]
    sdk = step_named("macos", "Fetch the qualified compiler SDK")
    assert "if" not in sdk
    assert "ci_macos_dependencies.py --component macos-sdk" in sdk["run"]
    assert "--allow-local-build" in sdk["run"]
    assert "github.event_name == 'pull_request'" in sdk["env"]["ALLOW_LOCAL_BUILD"]
    assert not any(
        "ci_stage_environment" in step.get("run", "") for step in action("macos")
    )
    for step in action("linux"):
        if step.get("id") in ("flutter", "pub"):
            assert step["if"] == "inputs.stage != 'native'"


@pytest.mark.parametrize(
    "platform,role",
    [("linux", role) for role in ("core", "desktop", "service")],
)
def test_pub_resolution_runs_only_the_packages_needed_by_the_role(
    tmp_path, platform, role
):
    step = step_named(platform, "Resolve locked language prerequisites")
    assert step["if"] == "inputs.stage != 'native'"
    for package in ("packages/foresight_core", "apps/desktop"):
        (tmp_path / package).mkdir(parents=True)
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.jsonl"
    script = '#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["ROLE_TEST_LOG"],"a") as stream: stream.write(json.dumps([os.path.basename(sys.argv[0]),os.getcwd(),sys.argv[1:]])+"\\n")\n'
    for name in ("dart", "flutter"):
        tool = binary / name
        tool.write_text(script)
        tool.chmod(0o755)
    subprocess.run(
        ["bash", "-euo", "pipefail", "-c", step["run"]],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "ROLE_TEST_LOG": str(log),
            "STAGE": role,
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    commands = [json.loads(line) for line in log.read_text().splitlines()]
    expected = [
        [
            "dart",
            str(tmp_path / "packages/foresight_core"),
            ["pub", "get", "--enforce-lockfile"],
        ]
    ]
    if role in ("desktop", "service"):
        expected.append(
            [
                "flutter",
                str(tmp_path / "apps/desktop"),
                ["pub", "get", "--enforce-lockfile"],
            ]
        )
    assert commands == expected


def test_mac_brew_dependencies_match_complete_application(tmp_path):
    step = step_named("macos", "Install build tools")
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "brew.args"
    brew = binary / "brew"
    brew.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ROLE_TEST_LOG"\n')
    brew.chmod(0o755)
    subprocess.run(
        ["bash", "-euo", "pipefail", "-c", step["run"]],
        env={
            **os.environ,
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "ROLE_TEST_LOG": str(log),
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert log.read_text().splitlines() == [
        "install",
        "cmake",
        "ninja",
        "cocoapods",
        "git-lfs",
        "icu4c",
    ]


def test_linux_fast_ui_checks_are_fresh_in_desktop_and_identity_stays_native():
    jobs = yaml.safe_load(
        (ROOT / ".github/workflows/linux-platform-stages.yml").read_text()
    )["jobs"]
    native = jobs["native-linux"]["steps"]
    desktop = jobs["desktop-linux"]["steps"]
    assert not any("test_native_process.py" in step.get("run", "") for step in native)
    assert not any("--suite fast" in step.get("run", "") for step in native)
    fast = next(
        i for i, step in enumerate(desktop) if "--suite fast" in step.get("run", "")
    )
    stage = next(i for i, step in enumerate(desktop) if step.get("id") == "stage")
    upload = next(
        i
        for i, step in enumerate(desktop)
        if step.get("name") == "Retain the independently qualified desktop stage"
    )
    assert stage < fast < upload
    assert "if" not in desktop[fast]  # Runs after a restored stage as well as a build.
    assert "xvfb-run -a dbus-run-session --" in desktop[fast]["run"]
    assert "--native build/native/libforesight_native.so" in desktop[fast]["run"]


@pytest.mark.parametrize("role", ["native", "core", "desktop", "service"])
def test_environment_does_not_require_unconsumed_tools(tmp_path, role):
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/pins.json").write_text("{}")
    with patch.object(environment, "version", return_value="pinned") as version:
        environment.collect("macos", root=tmp_path, stage=role)
    calls = {
        call.args[0][0]: call.kwargs.get("required", False)
        for call in version.call_args_list
    }
    assert calls["cmake"] == (role == "native")
    assert calls["ninja"] == (role == "native")
    assert ("dart" in calls) == (role != "native")
    assert ("flutter" in calls) == (role not in ("native", "core"))


@pytest.mark.parametrize("platform", ["linux"])
def test_language_caches_separate_roles_and_restore_compatible_legacy_entries(platform):
    steps = action(platform)
    select = step_named(platform, "Select the language cache role")
    assert select["if"] == "inputs.stage != 'native'"
    for cache in ("flutter", "pub"):
        restore = next(step for step in steps if step.get("id") == cache)
        save = next(
            step
            for step in steps
            if "/save@" in step.get("uses", "")
            and step["with"]["path"] == restore["with"]["path"]
        )
        assert restore["with"]["key"] == save["with"]["key"]
        assert "${{ steps.language-cache.outputs.kind }}" in restore["with"]["key"]
        assert "-v2" in restore["with"]["key"]
        assert restore["if"] == "inputs.stage != 'native'"
        assert "cache-hit != 'true'" in save["if"]
    sdk = next(step for step in steps if step.get("id") == "flutter")
    architecture = "x64" if platform == "linux" else "arm64"
    assert f"flutter-{platform}-{architecture}-3.35.7-v1" in sdk["with"]["restore-keys"]
    assert "3.35.7" in sdk["with"]["key"]
    pub = next(step for step in steps if step.get("id") == "pub")
    assert (
        "hashFiles('packages/foresight_core/pubspec.lock', 'apps/desktop/pubspec.lock')"
        in pub["with"]["key"]
    )
    assert "|| hashFiles('packages/foresight_core/pubspec.lock')" in pub["with"]["key"]
    assert pub["with"]["path"] == "${{ github.workspace }}/.cache/foresight-pub"


@pytest.mark.parametrize(
    "platform,role",
    [("linux", role) for role in ("core", "desktop", "service")],
)
def test_actual_engine_and_pub_commands_finish_before_their_caches_are_saved(
    tmp_path, platform, role
):
    for package in ("packages/foresight_core", "apps/desktop"):
        (tmp_path / package).mkdir(parents=True)
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.jsonl"
    script = '#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["ROLE_TEST_LOG"],"a") as stream: stream.write(json.dumps([os.path.basename(sys.argv[0]),os.getcwd(),sys.argv[1:],os.environ.get("PUB_CACHE")])+"\\n")\n'
    for name in ("dart", "flutter"):
        executable = binary / name
        executable.write_text(script)
        executable.chmod(0o755)
    output = tmp_path / "output"
    exported = tmp_path / "environment"
    env = {
        **os.environ,
        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
        "ROLE_TEST_LOG": str(log),
        "STAGE": role,
        "GITHUB_WORKSPACE": str(tmp_path),
        "GITHUB_OUTPUT": str(output),
        "GITHUB_ENV": str(exported),
    }
    steps = action(platform)
    select = step_named(platform, "Select the language cache role")
    subprocess.run(
        ["bash", "-euo", "pipefail", "-c", select["run"]],
        cwd=tmp_path,
        env=env,
        check=True,
        timeout=10,
    )
    kind = "ui" if role in ("desktop", "service") else "dart"
    assert output.read_text() == f"kind={kind}\n"
    if platform == "linux":
        assert exported.read_text() == f"PUB_CACHE={tmp_path}/.cache/foresight-pub\n"
        assert (tmp_path / ".cache/foresight-pub").is_dir()
        env["PUB_CACHE"] = str(tmp_path / ".cache/foresight-pub")
    warm = step_named(platform, "Warm the pinned desktop engine cache")
    assert warm["if"] == "inputs.stage == 'desktop' || inputs.stage == 'service'"
    assert warm["run"] == f"flutter precache --{platform}"
    verify = step_named(platform, "Verify the pinned")
    assert "adc901062556672b4138e18a4dc62a4be8f4b3c2" in verify["run"]
    assert steps.index(verify) < steps.index(warm)
    saved = []
    for step in steps[steps.index(warm) :]:
        if (
            step == warm
            and kind == "ui"
            or "Resolve locked language prerequisites" in step.get("name", "")
        ):
            subprocess.run(
                ["bash", "-euo", "pipefail", "-c", step["run"]],
                cwd=tmp_path,
                env=env,
                check=True,
                timeout=10,
            )
        if "/save@" not in step.get("uses", ""):
            continue
        commands = [json.loads(line) for line in log.read_text().splitlines()]
        assert [command[0] for command in commands] == (
            ["flutter", "dart", "flutter"] if kind == "ui" else ["dart"]
        )
        if kind == "ui":
            assert commands[0][2] == ["precache", f"--{platform}"]
            assert commands[-1][1] == str(tmp_path / "apps/desktop")
        if platform == "linux":
            assert all(command[3] == env["PUB_CACHE"] for command in commands)
        saved.append(step["with"]["path"])
    assert len(saved) == 2


def test_consolidated_mac_fetches_verified_sdk_once_and_linux_keeps_stage_roles():
    sdk = step_named("macos", "Fetch the qualified compiler SDK")
    assert "if" not in sdk
    assert "ci_macos_dependencies.py --component macos-sdk" in sdk["run"]
    assert "ci_verify_dependency.py --component macos-sdk" in sdk["run"]
    assert (
        sum(
            "ci_macos_dependencies.py --component macos-sdk" in step.get("run", "")
            for step in action("macos")
        )
        == 1
    )
    verify = step_named("linux", "Verify the pinned")
    assert verify["if"] == "inputs.stage != 'native'"
    for step in action("linux"):
        if step.get("id") in ("flutter", "pub"):
            assert step["if"] == "inputs.stage != 'native'"


def test_consolidated_mac_brew_dependencies_are_installed_once(tmp_path):
    packages = ["cmake", "ninja", "cocoapods", "git-lfs", "icu4c"]
    step = step_named("macos", "Install build tools")
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "brew.args"
    brew = binary / "brew"
    brew.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ROLE_TEST_LOG"\n')
    brew.chmod(0o755)
    subprocess.run(
        ["bash", "-euo", "pipefail", "-c", step["run"]],
        env={
            **os.environ,
            "PATH": str(binary) + os.pathsep + os.environ["PATH"],
            "ROLE_TEST_LOG": str(log),
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert log.read_text().splitlines() == ["install", *packages]
