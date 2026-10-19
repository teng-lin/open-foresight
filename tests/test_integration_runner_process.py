"""Exercise the acceptance runner across a real child-process boundary.

The child implements Dart's reporter protocol, not the application. These tests
verify evidence handling without requiring Flutter, models, or a host desktop.
"""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import integration_gates as gates  # noqa: E402 - Imports follow the local tools path setup.


@pytest.fixture
def reporter(tmp_path, monkeypatch):
    root = tmp_path / "source"
    desktop = root / "apps/desktop"
    (desktop / "test").mkdir(parents=True)
    (desktop / "integration_test").mkdir()
    (desktop / "integration_test/fixture_test.dart").write_text("// fixture\n")
    (root / "packages/foresight_core").mkdir(parents=True)
    monkeypatch.setattr(gates, "ROOT", root)
    child = tmp_path / "reporter"
    child.write_text(
        f"#!{sys.executable}\n"
        "import json, os, pathlib, sys\n"
        "args = sys.argv[1:]\n"
        "pathlib.Path(os.environ['RUNNER_TRACE']).write_text(json.dumps({\n"
        "    'args': args, 'cwd': os.getcwd(),\n"
        "    'alias_exists': all(pathlib.Path(a).is_file() for a in args if a.endswith('.dart')),\n"
        "}))\n"
        "print('child diagnostic retained', flush=True)\n"
        "mode = os.environ['RUNNER_MODE']\n"
        "if mode == 'exit': sys.exit(7)\n"
        "if mode == 'no-report': sys.exit(0)\n"
        "path = pathlib.Path(next(a.split('json:', 1)[1] for a in args if a.startswith('--file-reporter=')))\n"
        "event = dict(type='testDone', hidden=False, skipped=False, result='success')\n"
        "if mode == 'skip': event['skipped'] = True\n"
        "if mode == 'hidden': event['hidden'] = True\n"
        "if mode == 'error': event['result'] = 'error'\n"
        "events = [event, dict(type='done', success=mode != 'unsuccessful')]\n"
        "if mode == 'extra': events.insert(0, event)\n"
        "if mode == 'no-done': events.pop()\n"
        "path.write_text('not json' if mode == 'malformed' else ''.join(json.dumps(e) + '\\n' for e in events))\n"
    )
    child.chmod(0o700)
    output = tmp_path / "output"
    trace = tmp_path / "trace.json"
    env = dict(os.environ, RUNNER_TRACE=str(trace), RUNNER_MODE="pass")
    return root, child, output, trace, env


def invoke(reporter, package="desktop"):
    _, child, output, _, env = reporter
    return gates.run_tests(
        package,
        ["integration_test/fixture_test.dart"] if package == "desktop" else [],
        1,
        env,
        output,
        "probe",
        flutter=str(child),
        dart=str(child),
    )


@pytest.mark.parametrize("package", ["desktop", "core"])
def test_real_reporter_process_passes_with_expected_command_and_evidence(
    reporter, package
):
    root, _, output, trace, _ = reporter
    assert invoke(reporter, package) == {"passed": 1, "skipped": 0}
    call = json.loads(trace.read_text())
    assert call["cwd"] == str(
        root / ("apps/desktop" if package == "desktop" else "packages/foresight_core")
    )
    assert call["args"][0] == "test"
    assert "--concurrency=1" in call["args"]
    assert "--reporter=expanded" in call["args"]
    assert ("--no-pub" in call["args"]) == (package == "desktop")
    assert call["alias_exists"]
    assert "child diagnostic retained" in (output / "probe.log").read_text()
    assert (output / "probe.events.jsonl").is_file()
    assert not list((root / "apps/desktop/test").iterdir())


@pytest.mark.parametrize(
    "mode",
    [
        "skip",
        "hidden",
        "error",
        "extra",
        "no-done",
        "unsuccessful",
        "malformed",
        "exit",
        "no-report",
    ],
)
def test_real_reporter_failure_rejects_stale_success_and_cleans_alias(reporter, mode):
    root, _, output, trace, env = reporter
    # A previous successful attempt must never mask missing evidence this time.
    invoke(reporter)
    env["RUNNER_MODE"] = mode
    with pytest.raises((RuntimeError, ValueError, FileNotFoundError)):
        invoke(reporter)
    assert json.loads(trace.read_text())["alias_exists"]
    assert not list((root / "apps/desktop/test").iterdir())
    assert "child diagnostic retained" in (output / "probe.log").read_text()
    if mode in {"exit", "no-report"}:
        assert not (output / "probe.events.jsonl").exists()


@pytest.mark.parametrize(
    "arguments,diagnostic",
    [
        (["--suite", "models"], "--models is required"),
        (["--suite", "models", "--models", "."], "--bundle is required"),
        (["--suite", "virtual-audio"], "--models is required"),
        (["--suite", "reference-models"], "--bundle is required"),
    ],
)
def test_cli_configuration_failure_records_failed_summary(
    tmp_path, arguments, diagnostic
):
    output = tmp_path / "reports"
    result = subprocess.run(
        [
            sys.executable,
            str(Path(gates.__file__)),
            *arguments,
            "--output",
            str(output),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 2, result.stdout + result.stderr
    assert diagnostic in result.stderr
    report = json.loads((output / "summary.json").read_text())
    assert report == {"suite": arguments[1], "status": "failed"}
