"""Module entrypoints and direct-script adapters share the real CLI contract."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("mode", ["module", "direct"])
@pytest.mark.parametrize("outcome", ["found", "missing", "required-missing", "denied"])
def test_registry_entrypoint_in_git_free_export(tmp_path, mode, outcome):
    export = tmp_path / "source"
    tools = export / "tools"
    tools.mkdir(parents=True)
    for name in ("__init__.py", "ci_registry.py"):
        shutil.copy2(ROOT / "tools" / name, tools / name)
    unrelated = tmp_path / "unrelated"
    unrelated.mkdir()
    binary = tmp_path / "bin"
    binary.mkdir()
    docker = binary / "docker"
    docker.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys\n"
        "from pathlib import Path\n"
        "Path(os.environ['FIXTURE_ARGV']).write_text(json.dumps(sys.argv[1:]))\n"
        "outcome = os.environ['FIXTURE_OUTCOME']\n"
        "if outcome == 'found':\n"
        "    print(json.dumps({'digest': 'sha256:' + 'a' * 64}))\n"
        "else:\n"
        "    print('denied' if outcome == 'denied' else 'manifest unknown', file=sys.stderr)\n"
        "    sys.exit(1)\n"
    )
    docker.chmod(0o700)
    output = tmp_path / "github-output"
    output.write_text("existing\n")
    argv = tmp_path / "docker-argv.json"
    environment = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    environment.update(
        PATH=f"{binary}:{os.defpath}",
        GITHUB_OUTPUT=str(output),
        FIXTURE_ARGV=str(argv),
        FIXTURE_OUTCOME=outcome,
    )
    image = "ghcr.io/owner/component:current"
    args = [sys.executable]
    if mode == "module":
        # The primary command explicitly selects its source root, as CI does.
        args += ["-m", "tools.ci_registry"]
        cwd = export
    else:
        # Existing external direct-script callers need no cwd/PYTHONPATH setup.
        args += [str(tools / "ci_registry.py")]
        cwd = unrelated
    args += [image]
    if outcome == "required-missing":
        args += ["--require"]
    result = subprocess.run(
        args, cwd=cwd, env=environment, capture_output=True, text=True, timeout=15
    )
    assert json.loads(argv.read_text()) == [
        "buildx",
        "imagetools",
        "inspect",
        image,
        "--format",
        "{{json .Manifest}}",
    ]
    assert not (export / ".git").exists()
    if outcome == "found":
        assert result.returncode == 0, result.stdout + result.stderr
        assert output.read_text() == (
            "existing\nbuild=false\nimage=ghcr.io/owner/component@sha256:"
            + "a" * 64
            + "\n"
        )
    elif outcome == "missing":
        assert result.returncode == 0, result.stdout + result.stderr
        assert output.read_text() == "existing\nbuild=true\n"
    else:
        assert result.returncode != 0
        assert output.read_text() == "existing\n"
        assert (
            "authentication/authorization failed"
            if outcome == "denied"
            else "Producer did not publish its promised dependency image"
        ) in result.stderr


def test_registry_workflow_module_calls_select_source_root_explicitly():
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/ci-dependencies.yml").read_text()
    )
    calls = [
        step
        for job in workflow["jobs"].values()
        for step in job.get("steps", [])
        if any(
            name in step.get("run", "")
            for name in ("tools.ci_registry", "tools/ci_registry.py")
        )
    ]
    assert len(calls) == 8
    assert all(step["working-directory"] == "${{ github.workspace }}" for step in calls)
    assert not any("tools/ci_registry.py" in step["run"] for step in calls)
