"""Workflow literals and build readers must agree with reviewed shared pins."""

import json
from pathlib import Path
import re
import runpy

from test_pull_request_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / "tools/pins.json").read_text())


def test_workflow_flutter_dart_and_protoc_literals_match_shared_pins():
    paths = [
        *(ROOT / ".github/workflows").glob("*.yml"),
        *(ROOT / ".github/actions").glob("*/action.yml"),
    ]
    for path in paths:
        source = path.read_text()
        for version in re.findall(
            r"--branch (\d+\.\d+\.\d+) https://github.com/flutter/flutter.git", source
        ):
            assert version == PINS["flutter"]["version"], path.name
        for commit in re.findall(r"rev-parse HEAD\).*?= ([0-9a-f]{40})", source):
            assert commit == PINS["flutter"]["commit"], path.name
        for version in re.findall(r"protoc-(\d+\.\d+)-", source):
            assert version == PINS["protoc"], path.name
        for version in re.findall(r"sdk: ['\"]?(\d+\.\d+\.\d+)", source):
            assert version == PINS["dart"], path.name


def test_tools_read_litert_version_from_the_shared_pin_file(tmp_path):
    tools = ROOT / "tools"
    for name in (
        "prepare_litert.py",
        "package.py",
        "package_macos.py",
        "litert_extensions.py",
        "build_litert_extensions.py",
    ):
        assert 'Path(__file__).with_name("pins.json")' in (tools / name).read_text()
    (tmp_path / "prepare_litert.py").write_text(
        (tools / "prepare_litert.py").read_text()
    )
    (tmp_path / "pins.json").write_text(json.dumps({**PINS, "litert_lm": "0.99.0"}))
    assert runpy.run_path(str(tmp_path / "prepare_litert.py"))["VERSION"] == "0.99.0"


def test_python_locks_target_313_and_protobuf_stubs_match_runtime_major():
    for name in ("dev", "format", "litert"):
        text = (ROOT / f"requirements-{name}.lock").read_text()
        assert "--python-version 3.13" in text
        assert "requirements-litert-macos.lock" not in text
    requirements = (ROOT / "requirements-dev.txt").read_text()
    runtime = re.search(r"^protobuf==(\d+)", requirements, re.M)[1]
    stubs = re.search(r"^types-protobuf==(\d+)", requirements, re.M)[1]
    assert runtime == stubs
    assert 'python_version = "3.13"' in (ROOT / "pyproject.toml").read_text()


def test_litert_transport_pin_matches_the_shared_version():
    wheel = PINS["litert_linux_wheel"]
    assert f"litert_lm_api-{PINS['litert_lm']}-" in wheel["url"]
    assert len(wheel["sha256"]) == len(wheel["library_sha256"]) == 64


def test_litert_sdk_copied_context_resolves_module_file_dependencies(tmp_path):
    import os
    import shutil
    import subprocess
    import sys

    dockerfile = (ROOT / "packaging/sdk-litert.Dockerfile").read_text()
    context = tmp_path / "isolated-context"
    for source, target in re.findall(
        r"^COPY (\S+) /opt/foresight-extension/(\S+)$", dockerfile, re.M
    ):
        destination = context / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / source, destination)
    result = subprocess.run(
        [sys.executable, str(context / "tools/build_litert_extensions.py"), "--help"],
        cwd=tmp_path,
        env={"PATH": os.environ["PATH"]},
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert "--output" in result.stdout


def test_minimal_ubuntu_bootstraps_verified_ca_before_snapshot_https():
    text = (ROOT / "packaging/sdk-core.Dockerfile").read_text()
    ca = PINS["ubuntu_bootstrap_ca"]
    instruction = f"ADD --chmod=0644 --checksum=sha256:{ca['sha256']} {ca['url']} /etc/ssl/certs/ca-certificates.crt"
    assert instruction in text
    assert text.index(instruction) < text.index("RUN apt-get --snapshot")
    assert "Verify-Peer=false" not in text


def test_macos_offline_contracts_run_after_the_pinned_sdk_protoc_is_available():
    setup = parse_workflow(
        (ROOT / ".github/actions/setup-macos-stage/action.yml").read_text()
    )
    steps = setup["runs"]["steps"]
    sdk = next(step for step in steps if "--component macos-sdk" in step.get("run", ""))
    assert sdk["run"].index("ci_verify_dependency.py") < sdk["run"].index(
        'echo "$GITHUB_WORKSPACE/build/sdk/bin" >> "$GITHUB_PATH"'
    )
    workflow = parse_workflow((ROOT / ".github/workflows/macos.yml").read_text())
    native = workflow["jobs"]["macos-checks"]["steps"]
    setup_index = next(
        i
        for i, step in enumerate(native)
        if step.get("uses") == "./.github/actions/setup-macos-stage"
    )
    tests_index = next(
        i
        for i, step in enumerate(native)
        if "tools/platform_python_tests.py --platform macos" in step.get("run", "")
    )
    assert setup_index < tests_index
    assert native[tests_index]["if"] == "matrix.stage == 'contracts'"
    assert (
        "contracts" in workflow["jobs"]["macos-checks"]["strategy"]["matrix"]["stage"]
    )
    install = next(step for step in steps if step.get("name") == "Install build tools")
    assert "protobuf" not in install["run"]
