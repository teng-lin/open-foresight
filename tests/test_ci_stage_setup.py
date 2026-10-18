"""Stage setup does no compiler-SDK or language work for unrelated roles."""

import json
import os
from pathlib import Path
import subprocess
from unittest.mock import patch

import pytest
import yaml

from tools import ci_stage_environment as environment

ROOT = Path(__file__).resolve().parents[1]


def action(platform):
    return yaml.safe_load(
        (ROOT / f".github/actions/setup-{platform}-stage/action.yml").read_text()
    )["runs"]["steps"]


def step_named(platform, fragment):
    return next(step for step in action(platform) if fragment in step.get("name", ""))


@pytest.mark.parametrize("platform", ["linux", "macos"])
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
    if platform == "macos":
        job = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())[
            "jobs"
        ]["macos"]
        setup = next(
            step
            for step in job["steps"]
            if step.get("uses") == "./.github/actions/setup-macos-stage"
        )
        assert setup["with"]["stage"] == "packaging"


def test_only_mac_native_fetches_and_hashes_the_compiler_sdk():
    sdk = step_named("macos", "Fetch the qualified compiler SDK")
    assert sdk["if"] == "inputs.stage == 'native'"
    assert "ci_macos_dependencies.py --component macos-sdk" in sdk["run"]
    identity = step_named("macos", "Record the compiler")
    assert identity["if"] == "inputs.stage != 'packaging'"
    assert (
        'if [[ "$STAGE" == native ]]; then args+=(--sdk-prefix build/sdk); fi'
        in identity["run"]
    )
    for platform in ("macos", "linux"):
        verify = step_named(platform, "Verify the pinned")
        assert verify["if"] == "inputs.stage != 'native'"
        for step in action(platform):
            if step.get("id") in ("flutter", "pub"):
                assert step["if"] == "inputs.stage != 'native'"


@pytest.mark.parametrize(
    "platform,role",
    [("linux", role) for role in ("core", "desktop", "service")]
    + [("macos", role) for role in ("core", "desktop", "service", "packaging")],
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
            "STAGE": role,
            "ROLE_TEST_LOG": str(log),
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


@pytest.mark.parametrize(
    "role,packages",
    [
        ("native", ["cmake", "ninja", "icu4c"]),
        ("core", ["icu4c"]),
        ("desktop", ["cocoapods", "git-lfs", "icu4c"]),
        ("service", ["cocoapods", "git-lfs", "icu4c"]),
        ("packaging", ["icu4c"]),
    ],
)
def test_mac_brew_dependencies_match_actual_role(tmp_path, role, packages):
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
            "STAGE": role,
            "ROLE_TEST_LOG": str(log),
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert log.read_text().splitlines() == ["install", *packages]


def test_linux_fast_ui_checks_are_fresh_in_desktop_and_identity_stays_native():
    jobs = yaml.safe_load(
        (ROOT / ".github/workflows/linux-platform-stages.yml").read_text()
    )["jobs"]
    native = jobs["native-linux"]["steps"]
    desktop = jobs["desktop-linux"]["steps"]
    assert any("test_native_process.py" in step.get("run", "") for step in native)
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
