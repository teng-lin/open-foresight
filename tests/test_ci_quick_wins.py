"""Quick CI controls preserve trust while bounding waits and reporting selection."""

import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

import pytest
import yaml

from tools import ci_artifacts as artifacts
from tools import ci_changes as changes
from tools import ci_macos_dependencies as macos

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("wait", [0, 60, 9000])
def test_artifact_miss_stops_without_a_live_same_head_producer(tmp_path, wait):
    with (
        patch.object(artifacts, "approved_original", return_value=None),
        patch.object(artifacts, "api", return_value={"artifacts": []}),
        patch.object(artifacts, "waiting_for_dependency", return_value=[]),
        patch.object(artifacts.time, "sleep") as sleep,
    ):
        assert not artifacts.pull(
            "owner/repo",
            "linux-sdk",
            "a" * 64,
            tmp_path,
            wait=wait,
            own_head="b" * 40,
            own_pr=23,
        )
    sleep.assert_not_called()


def test_artifact_wait_has_a_hard_thirty_minute_cap(tmp_path):
    now = [0]

    def advance(seconds):
        now[0] += seconds

    with (
        patch.object(artifacts, "approved_original", return_value=None),
        patch.object(artifacts, "api", return_value={"artifacts": []}),
        patch.object(artifacts, "waiting_for_dependency", return_value=[71]),
        patch.object(artifacts.time, "monotonic", side_effect=lambda: now[0]),
        patch.object(artifacts.time, "sleep", side_effect=advance),
    ):
        assert not artifacts.pull(
            "owner/repo",
            "linux-sdk",
            "a" * 64,
            tmp_path,
            wait=9000,
            own_head="b" * 40,
            own_pr=23,
        )
    assert now[0] == 1800


def test_waiting_producer_requires_current_head_repository_identity_and_active_job():
    head = "a" * 40
    base = {
        "id": 71,
        "head_sha": head,
        "head_repository": {"full_name": "owner/repo"},
        "head_branch": "feature",
        "pull_requests": [{"number": 23}],
        "event": "pull_request",
        "path": ".github/workflows/ci-dependencies.yml",
        "status": "in_progress",
        "run_attempt": 2,
    }
    runs = [
        base,
        {**base, "id": 72, "head_sha": "b" * 40},
        {**base, "id": 73, "head_repository": {"full_name": "fork/repo"}},
        {**base, "id": 74},
        {**base, "id": 75},
        {**base, "id": 76, "status": "completed"},
    ]

    def api(repository, route):
        assert repository == "owner/repo"
        assert f"head_sha={head}" in route or "branch=main" in route
        return {"workflow_runs": runs}

    def jobs(repository, run):
        return [
            {
                "name": "Assemble Linux SDK",
                "run_attempt": 2,
                "conclusion": "failure" if run == 74 else None,
            }
        ]

    with (
        patch.object(artifacts, "api", side_effect=api),
        patch.object(artifacts, "dependency_jobs", side_effect=jobs),
        patch.object(artifacts, "source_fingerprint_at", return_value="identity"),
    ):
        assert artifacts.waiting_for_dependency(
            "owner/repo", "linux-sdk", "identity", head, 23
        ) == [71, 75]
        assert (
            artifacts.waiting_for_dependency(
                "owner/repo", "linux-sdk", "other", head, 23
            )
            == []
        )
        assert (
            artifacts.waiting_for_dependency(
                "owner/repo", "linux-sdk", "identity", "", 23
            )
            == []
        )


@pytest.mark.parametrize("allow_local_build", [False, True])
def test_dependabot_missing_sdk_is_red_and_actionable(
    tmp_path, monkeypatch, capsys, allow_local_build
):
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_ACTOR", "dependabot[bot]")
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "waiting_producers", return_value=[]),
        patch.object(macos.subprocess, "run") as build,
        pytest.raises(RuntimeError, match="ci-dependencies.yml"),
    ):
        macos.ensure(
            "macos-sdk",
            tmp_path,
            "owner/repo",
            "a" * 40,
            23,
            allow_local_build=allow_local_build,
        )
    build.assert_not_called()
    assert "::error::" in capsys.readouterr().out
    assert "identity" in summary.read_text()
    assert "retry the failed consumer" in summary.read_text()


def test_macos_deadline_expires_without_duplicate_build(tmp_path):
    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "waiting_producers", return_value=[71]),
        patch.object(macos.time, "monotonic", side_effect=[0, 1800]),
        patch.object(macos.subprocess, "run") as build,
        pytest.raises(RuntimeError, match="1800-second"),
    ):
        macos.ensure("macos-sdk", tmp_path, "owner/repo", "a" * 40, 23, wait=9000)
    build.assert_not_called()


@pytest.mark.parametrize(
    "inherited_ref", ["refs/pull/999/merge", "refs/heads/main", ""]
)
def test_explain_cli_and_ci_outputs_agree_without_relying_on_github_ref(
    tmp_path, inherited_ref
):
    def git(*args):
        return subprocess.check_output(
            ["git", *args], cwd=tmp_path, text=True, timeout=30
        ).strip()

    git("init", "-q")
    (tmp_path / "README.md").write_text("base\n")
    git("add", ".")
    git(
        "-c",
        "user.name=CI",
        "-c",
        "user.email=ci@example.test",
        "commit",
        "-qm",
        "base",
    )
    base = git("rev-parse", "HEAD")
    (tmp_path / "native").mkdir()
    (tmp_path / "native/source.cpp").write_text("// change\n")
    git("add", ".")
    git(
        "-c",
        "user.name=CI",
        "-c",
        "user.email=ci@example.test",
        "commit",
        "-qm",
        "native",
    )
    output = tmp_path / "outputs"
    summary = tmp_path / "summary"
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "tools/ci_changes.py"),
            "--explain",
            f"{base}...HEAD",
        ],
        cwd=tmp_path,
        env={
            **os.environ,
            "GITHUB_REF": inherited_ref,
            "GITHUB_OUTPUT": str(output),
            "GITHUB_STEP_SUMMARY": str(summary),
        },
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    report = json.loads((tmp_path / "ci-selection.json").read_text())
    assert report["paths"] == [
        {"path": "native/source.cpp", "gates": list(changes.GATES)}
    ]
    assert all(report["selection"].values())
    assert report["range"] == f"{base}...HEAD"
    assert "native/source.cpp" in result.stdout
    assert "| linux-native | true |" in summary.read_text()
    values = dict(line.split("=", 1) for line in output.read_text().splitlines())
    assert json.loads(values["selection"]) == report["selection"]


def test_workflow_cleanup_and_deduplication_keep_the_required_gates():
    def workflow(name):
        return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())

    quality = workflow("quality.yml")["jobs"]
    assert "contracts" in quality
    contracts = json.dumps(quality["contracts"])
    assert "check_dart_bindings.py" in contracts
    assert "test_owned_descriptors.py" in contracts
    assert "dart analyze" not in contracts
    assert "operation_registry_test.dart" not in contracts
    assert not (ROOT / ".github/workflows/rpc-contracts.yml").exists()
    for name in ("macos.yml", "integration-acceptance.yml"):
        assert (
            workflow(name)["concurrency"]["cancel-in-progress"]
            == "${{ github.event_name == 'pull_request' }}"
        )
    jobs = workflow("ci-dependencies.yml")["jobs"]
    for job in jobs.values():
        if "concurrency" in job:
            assert job["concurrency"]["cancel-in-progress"] is False
    for name in ("core", "litert", "whisper", "sdk"):
        steps = jobs[name]["steps"]
        cleanup = next(
            step for step in steps if "Free hosted-runner space" in step.get("name", "")
        )
        lookup = next(step for step in steps if step.get("id") == "lookup")
        shared = next(step for step in steps if step.get("id") == "shared")
        assert steps.index(shared) < steps.index(lookup) < steps.index(cleanup)
        assert "steps.lookup.outputs.build == 'true'" in cleanup["if"]
    application = workflow("integration-acceptance.yml")["jobs"]["ubuntu-application"]
    assert not any(
        "sudo rm -rf" in step.get("run", "") for step in application["steps"]
    )
    for name in ("linux-platform-stages.yml", "macos-platform-stages.yml"):
        assert "test_native_process.py" not in json.dumps(workflow(name))
    macos_steps = json.dumps(workflow("macos.yml")["jobs"]["macos"]["steps"])
    assert "tests.test_macos_tools.CompiledMacComponentTests" in macos_steps


def test_explain_works_locally_without_github_metadata(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    for key in tuple(os.environ):
        if key.startswith("GITHUB_"):
            monkeypatch.delenv(key)
    monkeypatch.setattr(
        sys, "argv", ["ci_changes", "--explain", "main...HEAD", "--force"]
    )
    with (
        patch.object(changes.subprocess, "check_output", return_value=b"README.md\0"),
        patch.object(changes.subprocess, "run"),
    ):
        changes.main()
    report = json.loads((tmp_path / "ci-selection.json").read_text())
    assert all(report["selection"].values())
    assert report["paths"] == [{"path": "README.md", "gates": []}]
    assert "quality only" in capsys.readouterr().out


@pytest.mark.parametrize("producer_states", [[[]], [[71], []]])
def test_ordinary_missing_sdk_fails_without_local_compilation(
    tmp_path, monkeypatch, capsys, producer_states
):
    monkeypatch.setenv("GITHUB_ACTOR", "repository-owner")
    summary = tmp_path / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "fingerprint", return_value="missing-identity"),
        patch.object(macos, "waiting_producers", side_effect=producer_states),
        patch.object(macos.time, "sleep"),
        patch.object(macos.subprocess, "run") as build,
        pytest.raises(RuntimeError, match="missing-identity.*ci-dependencies.yml"),
    ):
        macos.ensure("macos-sdk", tmp_path, "owner/repo", "a" * 40, 23)
    build.assert_not_called()
    assert "::error::" in capsys.readouterr().out
    assert "retry the failed consumer" in summary.read_text()


@pytest.mark.parametrize("location", ["sdk", "runtime"])
@pytest.mark.parametrize("fork", [False, True])
def test_only_explicit_fork_metadata_enables_local_build_in_real_consumer_steps(
    tmp_path, location, fork
):
    if location == "sdk":
        steps = yaml.safe_load(
            (ROOT / ".github/actions/setup-macos-stage/action.yml").read_text()
        )["runs"]["steps"]
    else:
        steps = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())[
            "jobs"
        ]["macos"]["steps"]
    step = next(
        step for step in steps if "ci_macos_dependencies.py" in step.get("run", "")
    )
    # The GitHub expression requires actual fork event metadata, never an input
    # supplied by a PR, a branch-name convention, or an absent head repository.
    assert step["env"]["ALLOW_LOCAL_BUILD"] == (
        "${{ github.event_name == 'pull_request' && "
        "github.event.pull_request.head.repo.full_name != '' && "
        "github.event.pull_request.base.repo.full_name == github.repository && "
        "github.event.pull_request.head.repo.full_name != "
        "github.event.pull_request.base.repo.full_name }}"
    )
    executable = tmp_path / "bin/python"
    executable.parent.mkdir()
    log = tmp_path / "calls.jsonl"
    executable.write_text(
        f"#!{sys.executable}\nimport json, os, sys\n"
        "with open(os.environ['CONSUMER_ARGUMENTS'], 'a') as stream:\n"
        "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
    )
    executable.chmod(0o755)
    result = subprocess.run(
        ["bash", "-e", "-c", step["run"]],
        cwd=ROOT,
        env={
            **os.environ,
            "PATH": str(executable.parent) + os.pathsep + os.environ["PATH"],
            "ALLOW_LOCAL_BUILD": str(fork).lower(),
            "OWN_HEAD": "a" * 40,
            "OWN_PR": "23",
            "GITHUB_WORKSPACE": str(tmp_path),
            "GITHUB_PATH": str(tmp_path / "github-path"),
            "CONSUMER_ARGUMENTS": str(log),
        },
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert len(calls) == 2
    assert calls[0][0] == "tools/ci_macos_dependencies.py"
    assert ("--allow-local-build" in calls[0]) == fork
    assert calls[1][0] == "tools/ci_verify_dependency.py"
    assert "--allow-local-build" not in calls[1]


def test_missing_consumer_head_never_polls_unrelated_sdk_producers():
    with patch.object(macos, "api") as request:
        assert macos.waiting_producers("owner/repo", "macos-sdk", "", 0) == []
    request.assert_not_called()


@pytest.mark.parametrize("malformed_json", [False, True])
def test_bad_producer_identity_never_authorizes_implicit_compilation(
    tmp_path, malformed_json
):
    head = "a" * 40
    candidate = {"id": 71, "status": "in_progress", "head_sha": head}

    def request(repository, route):
        return {"workflow_runs": [candidate]}

    with (
        patch.object(macos, "pull", return_value=False),
        patch.object(macos, "api", side_effect=request),
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "trusted_run", return_value=True),
        patch.object(macos, "dependency_jobs", return_value=[]),
        patch.object(
            macos,
            "producer_identity",
            side_effect=(
                json.JSONDecodeError("invalid producer", "", 0)
                if malformed_json
                else ValueError("unsupported recipe")
            ),
        ),
        patch.object(macos.subprocess, "run") as build,
        pytest.raises(json.JSONDecodeError if malformed_json else RuntimeError),
    ):
        macos.ensure(
            "macos-sdk",
            tmp_path,
            "owner/repo",
            head,
            23,
            allow_local_build=malformed_json,
        )
    build.assert_not_called()


def test_macos_cli_advertises_explicit_fork_build_permission():
    result = subprocess.run(
        [sys.executable, str(ROOT / "tools/ci_macos_dependencies.py"), "--help"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "--allow-local-build" in result.stdout
    assert "fork validation only" in " ".join(result.stdout.split())


@pytest.mark.parametrize("prior_wait", [False, True])
def test_macos_completion_race_reuses_and_verifies_original_before_fork_fallback(
    tmp_path, prior_wait
):
    with (
        patch.object(
            macos, "pull", side_effect=[False] * (2 if prior_wait else 1) + [True]
        ) as pull,
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(
            macos, "waiting_producers", side_effect=[[71], []] if prior_wait else [[]]
        ),
        patch.object(macos.time, "sleep"),
        patch.object(macos, "verify") as verify,
        patch.object(macos.subprocess, "run") as build,
    ):
        assert (
            macos.ensure(
                "macos-sdk",
                tmp_path,
                "owner/repo",
                "a" * 40,
                23,
                allow_local_build=True,
            )
            == "artifact"
        )
        assert pull.call_count == (3 if prior_wait else 2)
        verify.assert_called_once_with("macos-sdk", tmp_path)
        build.assert_not_called()


def test_consumer_poll_queries_each_scope_once_and_keeps_older_active_pages():
    head = "a" * 40
    active = {
        "id": 71,
        "head_sha": head,
        "head_branch": "feature",
        "path": ".github/workflows/ci-dependencies.yml",
        "head_repository": {"full_name": "owner/repo"},
        "event": "pull_request",
        "pull_requests": [{"number": 23}],
        "status": "queued",
        "run_attempt": 1,
    }
    calls = []

    def request(repository, route):
        calls.append(route)
        assert "status=" not in route
        if "branch=main" in route:
            return {"workflow_runs": []}
        return {
            "workflow_runs": [
                {**active, "id": 1000 + i, "status": "completed"} for i in range(100)
            ]
            if route.endswith("&page=1")
            else [active]
        }

    with (
        patch.object(macos, "api", side_effect=request),
        patch.object(macos, "fingerprint", return_value="identity"),
        patch.object(macos, "producer_identity", return_value="identity"),
        patch.object(macos, "dependency_jobs", return_value=[]),
    ):
        assert macos.waiting_producers("owner/repo", "macos-sdk", head, 23) == [71]
    assert len(calls) == 3  # Two scopes, with a genuine second page retained.
