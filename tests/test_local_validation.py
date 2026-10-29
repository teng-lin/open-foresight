"""Shared local guards catch cross-language drift and retain every failure."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from tools import check_local_validation as validation


@pytest.fixture(autouse=True)
def owned_temp_parent(tmp_path, monkeypatch):
    monkeypatch.setattr(validation, "TEMP_PARENT", tmp_path)


def test_shared_guards_include_inventory_without_language_selection():
    tasks = dict(validation.shared_tasks(sys.executable))
    assert tasks["skip-inventory"] == [sys.executable, "tools/check_integration_inventory.py"]
    assert tasks["boundary-inventory"] == [sys.executable, "-m", "tools.boundary_inventory"]
    assert tasks["entrypoint-parity"] == [sys.executable, "-m", "tools.check_entrypoint_parity"]
    assert {"workflow-lint", "mypy", "ruff", "document-links", "subprocess-timeouts"} <= tasks.keys()


def test_real_failed_guards_all_run_and_keep_raw_output(tmp_path, monkeypatch):
    output = validation.private_output(tmp_path / "evidence")
    marker = tmp_path / "later-ran"
    first = [sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'failure\\xff\\n');sys.exit(7)"]
    later = [sys.executable, "-c", f"from pathlib import Path;Path({str(marker)!r}).touch();print('later')"]
    monkeypatch.setattr(validation, "ROOT", tmp_path)
    monkeypatch.setattr(validation, "shared_tasks", lambda _: [("failed", first), ("later", later)])
    previous = os.environ.get("TMPDIR")
    assert validation.validate(output, full_python=True) == 1
    assert marker.exists()
    assert (output / "guards/failed.log").read_bytes() == b"failure\xff\n"
    report = json.loads((output / "result.json").read_text())
    assert report == {"shared_guards": 1, "full_python": None, "status": "failed"}
    assert not (output / "python").exists()
    assert os.environ.get("TMPDIR") == previous


def test_full_python_runs_only_after_clean_shared_guards(tmp_path, monkeypatch):
    output = validation.private_output(tmp_path / "evidence")
    calls = []

    def gates(tasks, directory):
        calls.append((tasks, directory))
        return 0 if len(calls) < 3 else 1

    monkeypatch.setattr(validation.parallel_build_gates, "run_gates", gates)
    assert validation.validate(output, full_python=True) == 1
    assert len(calls) == 3
    assert calls[2][0][0][1][:2] == ["bash", "tools/coverage.sh"]
    assert json.loads((output / "result.json").read_text())["full_python"] == 1


def test_guard_exception_is_failed_evidence_and_restores_environment(tmp_path, monkeypatch):
    output = validation.private_output(tmp_path / "evidence")
    original = Path.cwd()
    monkeypatch.setenv("FORESIGHT_TEST_TEMP_ROOT", "original")
    monkeypatch.setattr(validation, "ROOT", tmp_path)

    def fail(*_):
        raise OSError("fixture launch failure")

    monkeypatch.setattr(validation.parallel_build_gates, "run_gates", fail)
    with pytest.raises(OSError, match="fixture launch"):
        validation.validate(output, full_python=False)
    assert Path.cwd() == original
    assert os.environ["FORESIGHT_TEST_TEMP_ROOT"] == "original"
    report = json.loads((output / "result.json").read_text())
    assert report["status"] == "failed" and report["error_type"] == "OSError"


@pytest.mark.parametrize("mode", [0o755, 0o777])
def test_output_refuses_public_directory(tmp_path, mode):
    directory = tmp_path / "output"
    directory.mkdir(mode=mode)
    directory.chmod(mode)
    with pytest.raises(ValueError, match="private"):
        validation.private_output(directory)


def test_output_refuses_symlink(tmp_path):
    target = tmp_path / "target"
    target.mkdir()
    link = tmp_path / "link"
    link.symlink_to(target, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        validation.private_output(link)


def test_output_refuses_existing_evidence_without_overwriting(tmp_path):
    output = tmp_path / "evidence"
    output.mkdir(mode=0o700)
    old = output / "result.json"
    old.write_bytes(b"previous failure\xff")
    with pytest.raises(ValueError, match="empty"):
        validation.private_output(output)
    assert old.read_bytes() == b"previous failure\xff"


def test_output_refuses_outside_or_shared_parent(tmp_path):
    for output in (tmp_path, tmp_path.parent / "outside-validation-root"):
        with pytest.raises(ValueError, match="below canonical"):
            validation.private_output(output)


def test_default_output_is_fresh_owned_and_canonical(tmp_path):
    output = validation.private_output(None)
    assert output.parent == tmp_path
    assert output.stat().st_mode & 0o777 == 0o700
    assert not list(output.iterdir())


def test_workflow_lint_requires_shellcheck_before_actionlint(tmp_path, monkeypatch, capsys):
    invocations = []
    monkeypatch.setattr(validation.shutil, "which", lambda name: str(tmp_path / name) if name == "actionlint" else None)

    def run(command, **_):
        invocations.append(command)
        return subprocess.CompletedProcess(command, 0, b"1.7.7\n", b"")

    monkeypatch.setattr(validation.subprocess, "run", run)
    assert validation.workflow_lint() == 1
    assert len(invocations) == 1 and invocations[0][-1] == "-version"
    assert "Missing required workflow tool: shellcheck" in capsys.readouterr().out


@pytest.mark.parametrize("action_version", ["1.7.7", "1.7.70"])
def test_workflow_versions_match_exact_hosted_tools(tmp_path, monkeypatch, action_version):
    invocations = []
    monkeypatch.setattr(validation.shutil, "which", lambda name: str(tmp_path / name))

    def run(command, **_):
        invocations.append(command)
        text = action_version if Path(command[0]).name == "actionlint" else "version: 0.9.0"
        return subprocess.CompletedProcess(command, 0, text.encode(), b"")

    monkeypatch.setattr(validation.subprocess, "run", run)
    assert validation.workflow_lint() == (0 if action_version == "1.7.7" else 1)
    assert any(len(command) == 1 for command in invocations) == (action_version == "1.7.7")


@pytest.mark.parametrize("protoc_exit", [0, 1])
def test_python_tools_fail_before_tests_on_unconfigured_shim(monkeypatch, capsys, protoc_exit):
    monkeypatch.setattr(validation.shutil, "which", lambda name: "/tools/" + name)
    for key in ("CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"):
        monkeypatch.delenv(key, raising=False)

    def run(command, **_):
        text = b"libprotoc 35.1" if command[0].endswith("protoc") else b"qualified tool"
        return subprocess.CompletedProcess(command, protoc_exit, text, b"")

    monkeypatch.setattr(validation.subprocess, "run", run)
    assert validation.python_prerequisites() == protoc_exit
    assert json.loads(capsys.readouterr().out)["protoc"]["path"] == "/tools/protoc"


def test_python_tools_report_all_missing_and_compiler_overrides(monkeypatch, capsys):
    monkeypatch.setattr(validation.shutil, "which", lambda _: None)
    monkeypatch.setenv("CC", "fixture compiler")
    assert validation.python_prerequisites() == 1
    report = json.loads(capsys.readouterr().out)
    assert all(report[name]["error"] for name in ("cmake", "ninja", "protoc"))
    assert "CC" in report["inherited_compiler_overrides"]


def test_failed_tool_preflight_never_starts_coverage(tmp_path, monkeypatch):
    output = validation.private_output(tmp_path / "evidence")
    calls = []

    def gates(tasks, _):
        calls.append(tasks)
        return 0 if len(calls) == 1 else 1

    monkeypatch.setattr(validation.parallel_build_gates, "run_gates", gates)
    assert validation.validate(output, full_python=True) == 1
    assert len(calls) == 2
    report = json.loads((output / "result.json").read_text())
    assert report["python_prerequisites"] == 1 and report["full_python"] is None


def test_report_storage_failure_still_restores_process_state(tmp_path, monkeypatch):
    output = validation.private_output(tmp_path / "evidence")
    previous_directory = Path.cwd()
    previous_timeout = validation.parallel_build_gates.WAIT_TIMEOUT_SECONDS
    monkeypatch.setenv("TMPDIR", "original")
    monkeypatch.setattr(validation, "ROOT", tmp_path)
    monkeypatch.setattr(validation.parallel_build_gates, "run_gates", lambda *_: 0)
    original_write = Path.write_text

    def write(path, *args, **kwargs):
        if path == output / "result.json":
            raise OSError("fixture storage failure")
        return original_write(path, *args, **kwargs)

    monkeypatch.setattr(Path, "write_text", write)
    with pytest.raises(OSError, match="storage"):
        validation.validate(output, full_python=False)
    assert Path.cwd() == previous_directory
    assert os.environ["TMPDIR"] == "original"
    assert validation.parallel_build_gates.WAIT_TIMEOUT_SECONDS == previous_timeout
