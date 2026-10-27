"""Explicit media prerequisite orchestration; codec validation stays in its owner."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

import pytest
import yaml

from tools import platform_python_tests, run_media_test_gate as gate

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def producer(monkeypatch):
    calls = []
    binary = b"controlled orchestration bytes, not a compiled codec"
    prepared = SimpleNamespace(
        build_id="a" * 64,
        binary=binary,
        source_receipt_sha256="b" * 64,
        assembly_protocol=1,
    )
    monkeypatch.setattr(gate.platform, "system", lambda: "Linux")
    monkeypatch.setattr(gate.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(gate.os, "geteuid", lambda: 1000)

    def build(cache, output, *, fetch, jobs):
        calls.append(("build", cache, output, fetch, jobs))
        output.mkdir(mode=0o700)
        (output / "foresight-media-worker").write_bytes(binary)

    def prepare(root, output, target):
        calls.append(("verify", root, output, target))
        return prepared

    monkeypatch.setattr(gate.build_media_worker, "build", build)
    monkeypatch.setattr(gate.media_worker_package, "prepare", prepare)
    return calls, prepared


def test_selects_only_verified_current_worker_and_preserves_other_inputs(
    tmp_path, producer
):
    calls, prepared = producer
    cache, output = tmp_path / "cache", tmp_path / "product"
    inherited = {
        "PATH": "/usr/bin:/bin",
        "FORESIGHT_TEST_MEDIA_WORKER": "/stale/worker",
        "FORESIGHT_TEST_MEDIA_BUILD_ID": "stale",
        "FORESIGHT_TEST_MEDIA_SHA256": "stale",
        "FORESIGHT_TEST_MEDIA_CDHASH": "stale-mac-identity",
        "FORESIGHT_NATIVE_LIBRARY": "/selected/current/native.so",
    }
    selected = gate.prepare_environment(
        cache, output, fetch=True, jobs=2, environment=inherited
    )
    assert calls == [
        ("build", cache, output, True, 2),
        ("verify", gate.ROOT, output.resolve(), "linux-x86_64"),
    ]
    assert selected["FORESIGHT_TEST_MEDIA_WORKER"] == str(
        output / "foresight-media-worker"
    )
    assert selected["FORESIGHT_TEST_MEDIA_BUILD_ID"] == prepared.build_id
    assert (
        selected["FORESIGHT_TEST_MEDIA_SHA256"]
        == hashlib.sha256(prepared.binary).hexdigest()
    )
    assert selected["FORESIGHT_TEST_MEDIA_CDHASH"] == ""
    assert selected["FORESIGHT_NATIVE_LIBRARY"] == inherited["FORESIGHT_NATIVE_LIBRARY"]
    assert inherited["FORESIGHT_TEST_MEDIA_BUILD_ID"] == "stale"
    receipt = json.loads((output / "media-test-selection.json").read_text())
    assert receipt["uid"] == 1000
    assert receipt["source_receipt_sha256"] == prepared.source_receipt_sha256


@pytest.mark.parametrize("jobs", [0, 33])
def test_invalid_build_budget_fails_before_compilation(tmp_path, producer, jobs):
    calls, _ = producer
    with pytest.raises(ValueError, match="jobs"):
        gate.prepare_environment(
            tmp_path / "cache",
            tmp_path / "product",
            fetch=False,
            jobs=jobs,
            environment={},
        )
    assert calls == []


def test_macos_uses_verified_loaded_code_identity(tmp_path, monkeypatch, producer):
    calls, _ = producer
    monkeypatch.setattr(gate.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(gate.platform, "machine", lambda: "arm64")
    signed = []
    monkeypatch.setattr(
        gate.media_worker_package,
        "_cdhash",
        lambda path: signed.append(path) or "c" * 40,
    )
    output = tmp_path / "mac-product"
    selected = gate.prepare_environment(
        tmp_path / "cache", output, fetch=False, jobs=2, environment={}
    )
    assert calls[-1] == ("verify", gate.ROOT, output.resolve(), "darwin-arm64")
    assert signed == [output / "foresight-media-worker"]
    assert selected["FORESIGHT_TEST_MEDIA_CDHASH"] == "c" * 40


def test_macos_refuses_signature_failure_before_selection(
    tmp_path, monkeypatch, producer
):
    monkeypatch.setattr(gate.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(gate.platform, "machine", lambda: "arm64")

    def refuse(path):
        raise ValueError("media_codesign_failed")

    monkeypatch.setattr(gate.media_worker_package, "_cdhash", refuse)
    output = tmp_path / "product"
    with pytest.raises(ValueError, match="codesign_failed"):
        gate.prepare_environment(
            tmp_path / "cache", output, fetch=False, jobs=2, environment={}
        )
    assert not (output / "media-test-selection.json").exists()


def test_failed_compilation_retains_full_raw_log_without_masking_failure(
    tmp_path, monkeypatch, producer
):
    raw = b"COMMAND actual compiler\nretained failure\xff\n"

    def failed(cache, output, **kwargs):
        output.mkdir(mode=0o700)
        log = cache / "media-owned" / "build.log"
        log.parent.mkdir(parents=True, mode=0o700)
        log.write_bytes(raw)
        raise RuntimeError("original compiler failure")

    monkeypatch.setattr(gate.build_media_worker, "build", failed)
    output = tmp_path / "product"
    with pytest.raises(RuntimeError, match="original compiler failure"):
        gate.prepare_environment(
            tmp_path / "cache", output, fetch=False, jobs=2, environment={}
        )
    assert (output / "test-build-logs/media-owned/build.log").read_bytes() == raw
    assert not (output / "media-test-selection.json").exists()


def test_same_verified_selection_is_reused_without_another_build(tmp_path, producer):
    calls, _ = producer
    selected = gate.prepare_environment(
        tmp_path / "cache", tmp_path / "first", fetch=False, jobs=2, environment={}
    )
    calls.clear()
    output = tmp_path / "second"
    again = gate.prepare_environment(
        tmp_path / "cache",
        output,
        fetch=False,
        jobs=2,
        environment=selected,
        reuse_selected=True,
    )
    assert calls == [("verify", gate.ROOT, tmp_path / "first", "linux-x86_64")]
    assert again == selected
    assert (
        json.loads((output / "media-test-selection.json").read_text())[
            "reused_verified_selection"
        ]
        is True
    )


def test_stale_selected_identity_is_refused_not_rebuilt(tmp_path, producer):
    calls, _ = producer
    selected = gate.prepare_environment(
        tmp_path / "cache", tmp_path / "first", fetch=False, jobs=2, environment={}
    )
    selected["FORESIGHT_TEST_MEDIA_SHA256"] = "0" * 64
    calls.clear()
    with pytest.raises(ValueError, match="identity does not match"):
        gate.prepare_environment(
            tmp_path / "cache",
            tmp_path / "second",
            fetch=False,
            jobs=2,
            environment=selected,
            reuse_selected=True,
        )
    assert len(calls) == 1 and calls[0][0] == "verify"


def test_selection_only_writes_exact_fixed_nul_fields(tmp_path, monkeypatch, producer):
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "gate",
            "--cache",
            str(tmp_path / "cache"),
            "--output",
            str(tmp_path / "product"),
            "--environment-output",
            str(tmp_path / "environment"),
        ],
    )
    gate.main()
    fields = (tmp_path / "environment").read_bytes().split(b"\0")
    assert fields[-1] == b""
    assert fields[0:-1:2] == [key.encode() for key in gate.SELECTION_KEYS]
    assert fields[1] == str(tmp_path / "product/foresight-media-worker").encode()
    assert fields[-2] == b""
    assert (tmp_path / "environment").stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("refusal", ["root", "platform"])
def test_wrong_principal_or_platform_cannot_build(
    tmp_path, monkeypatch, producer, refusal
):
    calls, _ = producer
    if refusal == "root":
        monkeypatch.setattr(gate.os, "geteuid", lambda: 0)
    else:
        monkeypatch.setattr(gate.platform, "system", lambda: "Darwin")
    with pytest.raises(ValueError):
        gate.prepare_environment(
            tmp_path / "cache",
            tmp_path / "product",
            fetch=False,
            jobs=2,
            environment={},
        )
    assert calls == []


def test_failed_receipt_does_not_publish_selection(tmp_path, monkeypatch, producer):
    def refuse(*args):
        raise ValueError("media_application_source_mismatch")

    monkeypatch.setattr(gate.media_worker_package, "prepare", refuse)
    output = tmp_path / "product"
    with pytest.raises(ValueError, match="source_mismatch"):
        gate.prepare_environment(
            tmp_path / "cache", output, fetch=False, jobs=2, environment={}
        )
    assert not (output / "media-test-selection.json").exists()


def test_old_assembly_protocol_cannot_admit_gate(tmp_path, producer):
    _, prepared = producer
    prepared.assembly_protocol = 0
    output = tmp_path / "product"
    with pytest.raises(ValueError, match="assembly protocol"):
        gate.prepare_environment(
            tmp_path / "cache", output, fetch=False, jobs=2, environment={}
        )
    assert not (output / "media-test-selection.json").exists()


def test_missing_command_refuses_before_any_producer(tmp_path, monkeypatch):
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "run_media_test_gate.py",
            "--cache",
            str(tmp_path / "cache"),
            "--output",
            str(tmp_path / "product"),
        ],
    )
    with pytest.raises(SystemExit) as error:
        gate.main()
    assert error.value.code == 2
    assert not (tmp_path / "product").exists()


def test_gate_exec_keeps_principal_pid_and_failure_status(tmp_path):
    # Test the real exec boundary, not codec compilation (qualified separately).
    child = (
        "import json,os,sys;print(json.dumps({'pid':os.getpid(),"
        "'uid':os.geteuid(),'selection':os.environ['selected']}),flush=True);"
        "sys.exit(7)"
    )
    script = (
        "import os,sys\nfrom tools import run_media_test_gate as gate\n"
        "def prepared(*a,**k):\n"
        " print('buffered producer receipt')\n"
        " sys.stderr.write('buffered producer diagnostic')\n"
        " return dict(os.environ,selected='verified')\n"
        "gate.prepare_environment=prepared\n"
        f"sys.argv=['gate','--cache',{str(tmp_path / 'c')!r},"
        f"'--output',{str(tmp_path / 'o')!r},'--',sys.executable,'-c',{child!r}]\n"
        "gate.main()\n"
    )
    environment = dict(os.environ)
    environment.pop("PYTHONUNBUFFERED", None)
    process = subprocess.Popen(
        [sys.executable, "-c", script],
        env=environment,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=5)
        raise
    assert process.returncode == 7, stderr
    lines = stdout.splitlines()
    assert len(lines) == 2, stdout
    assert lines[0] == "buffered producer receipt"
    assert stderr == "buffered producer diagnostic"
    assert json.loads(lines[1]) == {
        "pid": process.pid,
        "uid": os.geteuid(),
        "selection": "verified",
    }


def test_arch_prerequisite_is_inside_nonroot_boundary_and_retains_failed_builds():
    workflow = yaml.safe_load((ROOT / ".github/workflows/arch-drift.yml").read_text())
    steps = workflow["jobs"]["arch"]["steps"]
    command = next(
        s["run"]
        for s in steps
        if s.get("name") == "Build and test with the current Arch toolchain"
    )
    assert command.index("run_ci_user.py") < command.index("run_media_test_gate.py")
    assert command.index("run_media_test_gate.py") < command.index("xvfb-run")
    assert "--fetch -- xvfb-run -a dbus-run-session -- bash tools/build.sh" in command
    assert "--output test-results/arch/media-worker" in command
    retained = next(
        s["with"]["path"]
        for s in steps
        if s.get("name") == "Retain drift diagnostics and suite evidence"
    )
    assert "test-results/" in retained
    assert "build/media-test-cache/**/build.log" in retained


def test_real_exec_boundary_is_selected_on_both_platform_hosts():
    assert platform_python_tests.owner_gates("tests/test_run_media_test_gate.py") == (
        "macos",
        "linux-build",
    )
