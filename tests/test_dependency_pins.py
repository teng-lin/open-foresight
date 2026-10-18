"""Workflow literals and build readers must agree with reviewed shared pins."""

import json
from pathlib import Path
import re
import runpy

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / "tools/pins.json").read_text())


def test_workflow_flutter_dart_and_protoc_literals_match_shared_pins():
    for path in (ROOT / ".github/workflows").glob("*.yml"):
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
