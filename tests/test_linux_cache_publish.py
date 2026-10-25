"""Dedicated main cache writes retain verified SDK/seed consumption boundaries."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest
import yaml

from tools import ci_linux_shadow_sdk as shadow

ROOT = Path(__file__).resolve().parents[1]


def test_maintenance_is_independent_main_only_and_preserves_original_upload_proof():
    config = yaml.safe_load(
        (ROOT / ".github/workflows/linux-cache-publish.yml").read_text()
    )
    triggers = config.get("on", config.get(True))
    assert set(triggers) == {"push", "workflow_dispatch", "schedule"}
    assert triggers["push"] == {"branches": ["main"]}
    # One fallback poll; its bounded cadence is owned by tests/test_ci_cadence.py.
    assert [set(row) for row in triggers["schedule"]] == [{"cron"}]
    assert all(value == "read" for value in config["permissions"].values())
    assert "concurrency" not in config
    jobs = config["jobs"]
    assert "needs" not in jobs["reconcile"]
    assert "concurrency" not in jobs["reconcile"]
    for name, job in jobs.items():
        assert "github.ref == 'refs/heads/main'" in job["if"]
        assert "github.event_name" in job["if"]
        assert "pull_request" not in str(job["if"])
        if name == "dispatch-refresh":
            assert job["needs"] == "reconcile"
            assert "concurrency" not in job
            assert job["permissions"] == {"contents": "read", "actions": "write"}
            assert '"push","schedule"' in job["if"]
        elif name == "qualification-consumers":
            assert job["needs"] == ["reconcile", "publish-linux-caches"]
            assert "inputs.qualify_consumers" in job["if"]
            assert "concurrency" not in job
        elif name != "reconcile":
            assert job["needs"] == "reconcile"
            if "uses" in job:
                assert job["uses"] == "./.github/workflows/macos-cache-publish.yml"
            else:
                assert not job["concurrency"]["cancel-in-progress"]
    job = jobs["publish-linux-caches"]
    assert job["permissions"] == {
        "contents": "read",
        "actions": "read",
        "packages": "write",
    }
    steps = job["steps"]
    fetch = next(i for i, step in enumerate(steps) if step.get("id") == "sdk")
    assert "--fork" not in steps[fetch]["run"]
    assert "ci_linux_shadow_sdk.py" in steps[fetch]["run"]
    guards = [
        i for i, step in enumerate(steps) if "commits/main" in step.get("run", "")
    ]
    tooling = next(i for i, step in enumerate(steps) if step.get("id") == "tooling")
    assert guards[0] < fetch < guards[1] < tooling
    receipt = next(
        step
        for step in steps
        if step.get("uses", "").startswith("actions/upload-artifact@")
        and "ci-tooling-" in step["with"]["name"]
    )
    assert receipt["with"]["path"] == "build/cache-tooling/tooling.json"
    assert receipt["with"]["if-no-files-found"] == "error"
    assert receipt["with"]["overwrite"] is True
    assert "tooling_reused" in receipt["if"]
    publish = next(
        step
        for step in steps
        if step.get("run") == "bash tools/publish_linux_ci_caches.sh"
    )
    assert publish["env"]["CI_CACHE_NAMESPACE"] == "isolated-v2"
    assert "steps.tooling.outputs.tooling_image" in publish["env"]["TOOLING_IMAGE"]
    assert (
        ".github/workflows/linux-cache-publish.yml@refs/heads/main"
        in steps[guards[0]]["run"]
    )


def test_only_dispatched_jobs_publish_shared_bytes_and_schedule_only_dispatches():
    config = yaml.safe_load((ROOT / ".github/workflows/linux-cache-publish.yml").read_text())
    jobs = config["jobs"]
    assert '"push","workflow_dispatch","schedule"' in jobs["reconcile"]["if"]
    assert "registry_needed" in jobs["reconcile"]["outputs"]
    assert "QUALIFY_CONSUMERS" in next(
        step["env"] for step in jobs["reconcile"]["steps"] if step.get("id") == "source"
    )
    for name in ("publish-linux-caches", "publish-common-caches", "publish-arch-caches", "publish-macos-models"):
        assert "github.event_name == 'workflow_dispatch'" in jobs[name]["if"]
    assert "needs.reconcile.outputs.registry_needed == 'true'" in jobs["publish-linux-caches"]["if"]
    dispatcher = jobs["dispatch-refresh"]
    assert "registry_needed" in dispatcher["if"] and "common" in dispatcher["if"]
    script = dispatcher["steps"][0]["run"]
    assert 'test "$GITHUB_REF" = refs/heads/main' in script
    assert "commits/main" in script and "--field ref=main" in script
    assert "docker" not in script and "cache/save" not in script


def test_linux_acceptance_restores_legacy_models_until_new_writer_is_qualified():
    jobs = yaml.safe_load((ROOT / ".github/workflows/macos.yml").read_text())["jobs"]
    for name in ("acceptance-cpu", "acceptance-audio"):
        restore = next(
            step for step in jobs[name]["steps"]
            if step.get("uses", "").startswith("actions/cache/restore@")
            and step["with"]["path"] == "build/acceptance-models"
        )["with"]
        assert restore["key"].startswith("main-integration-models-${{ runner.os }}-")
        assert restore["restore-keys"].startswith("integration-models-v1-")
        assert restore["key"].split("hashFiles(", 1)[1] == restore["restore-keys"].split("hashFiles(", 1)[1]


def test_main_sdk_miss_never_falls_back_to_sdk_compilation(monkeypatch, tmp_path):
    monkeypatch.setattr(shadow.waiter, "fetch", lambda *a, **kw: False)
    monkeypatch.setattr(
        shadow.artifacts, "fingerprint", lambda c: "verified-input-identity"
    )
    monkeypatch.setattr(
        shadow.sdk,
        "produce",
        lambda *a, **kw: pytest.fail("SDK compilation is forbidden"),
    )
    with pytest.raises(RuntimeError, match="unavailable"):
        shadow.prepare("owner/repo", "a" * 40, 0, False, tmp_path / "sdk")


@pytest.mark.parametrize(
    "ref,event",
    [
        ("refs/pull/123/merge", "pull_request"),
        ("refs/heads/main", "pull_request"),
        ("refs/heads/feature", "workflow_dispatch"),
    ],
)
def test_publisher_rejects_prs_before_any_tool(ref, event, tmp_path):
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "tools/publish_linux_ci_caches.sh")],
        cwd=tmp_path,
        env={
            **os.environ,
            "GITHUB_REF": ref,
            "GITHUB_EVENT_NAME": event,
            "PATH": "/nonexistent",
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 1
    assert "Cache publication requires" in result.stderr


@pytest.fixture
def publisher(tmp_path):
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools/pins.json").write_text('{"ubuntu_snapshot":"20261001T000000Z"}')
    binary = tmp_path / "bin"
    binary.mkdir()
    log = tmp_path / "commands.jsonl"
    stub = f"""#!{sys.executable}
import json, os, sys
from pathlib import Path
row=[Path(sys.argv[0]).name,*sys.argv[1:]]
with open(os.environ['COMMAND_LOG'],'a') as stream:stream.write(json.dumps(row)+'\\n')
if row[0]=='docker' and row[1:]==['context','show']:print('verified-builder')
if row[0]=='python' and 'tools/ci_app_dependency_seed.py' in row:
    if os.getenv('FAIL_STAGE')=='seed':print('seed verification failed',file=sys.stderr);sys.exit(23)
    seed=Path(row[row.index('--output')+1]);seed.mkdir(exist_ok=True)
    if '--verify-existing' in row:assert (seed/'original-provenance').read_bytes()==b'original producer receipt'
if row[0]=='python' and '--ci' in row and os.getenv('FAIL_STAGE')=='transport':
    print('transport lookup failed',file=sys.stderr);sys.exit(24)
if row[0]=='python' and 'tools/ci_tooling_image.py' in row:
    output=Path(row[row.index('--output')+1]);output.mkdir(parents=True,exist_ok=True)
    (output/'inputs.json').write_text(json.dumps({{'image':'fixture-tooling@sha256:'+'b'*64}}))
if row[0]=='python' and len(row)>1 and row[1]=='-c':
    os.execv({sys.executable!r},[{sys.executable!r},*sys.argv[1:]])
if row[:3]==['docker','buildx','build'] and row[row.index('--target')+1]==os.getenv('FAIL_STAGE'):
    print('cache export failed',file=sys.stderr);sys.exit(25)
"""
    for name in ["python", "docker"]:
        p = binary / name
        p.write_text(stub)
        p.chmod(0o755)
    seed = tmp_path / "verified-seed"

    def run(*, existing=False, failure="", namespace="legacy"):
        if existing:
            seed.mkdir()
            (seed / "original-provenance").write_bytes(b"original producer receipt")
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "tools/publish_linux_ci_caches.sh")],
            cwd=tmp_path,
            env={
                **os.environ,
                "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                "COMMAND_LOG": str(log),
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REPOSITORY": "Owner/Repo",
                "APP_DEPENDENCY_SEED": str(seed),
                "SDK_IMAGE": "sha256:" + "a" * 64,
                "CI_CACHE_NAMESPACE": namespace,
                "FAIL_STAGE": failure,
                "GOOGLE_CLIENT_ID": "secret-must-not-be-forwarded",
            },
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result, [json.loads(line) for line in log.read_text().splitlines()], seed

    return run


@pytest.mark.parametrize("existing", [False, True])
@pytest.mark.parametrize("namespace", ["legacy", "isolated-v2"])
def test_only_secret_free_dependency_targets_are_exported(publisher, existing, namespace):
    result, rows, seed = publisher(existing=existing, namespace=namespace)
    assert result.returncode == 0, result.stdout + result.stderr
    probes = [r for r in rows if "tools/ci_app_build_transport.py" in r]
    assert [r[-1] if r[-1].startswith("--") else "" for r in probes] == [
        "",
        "--ci",
        "--acceptance",
    ]
    seed_command = next(r for r in rows if "tools/ci_app_dependency_seed.py" in r)
    assert ("--verify-existing" in seed_command) == existing
    builds = [r for r in rows if r[:3] == ["docker", "buildx", "build"]]
    assert [r[r.index("--target") + 1] for r in builds] == [
        "application-dependencies",
        "ci",
        "acceptance-dependencies",
    ]
    for row in builds:
        target = row[row.index("--target") + 1]
        assert row[row.index("--builder") + 1] == "verified-builder"
        assert "--secret" not in row and not any(
            "secret-must-not" in x or "GOOGLE" in x for x in row
        )
        assert "--push" not in row and "--load" not in row
        assert ("REQUIRE_DEPENDENCY_REUSE=1" in row) == (
            target != "acceptance-dependencies"
        )
        if target != "acceptance-dependencies":
            assert row[row.index("--build-context") + 1] == "appdeps_seed=" + str(seed)
            assert "TOOLING_IMAGE=fixture-tooling@sha256:" + "b" * 64 in row
        else:
            assert not any(value.startswith("TOOLING_IMAGE=") for value in row)
        tag = {
            "application-dependencies": "app-deps-buildcache-v1",
            "ci": "ci-tools-buildcache-v1",
            "acceptance-dependencies": "acceptance-tools-buildcache-v1",
        }[target]
        if namespace == "isolated-v2":
            tag = "qualified-v2-" + tag
        assert (
            row[row.index("--cache-to") + 1]
            == "type=registry,ref=ghcr.io/owner/repo/linux-sdk:"
            + tag
            + ",mode=max,image-manifest=true"
        )
        assert any("app-buildcache-x86-64" in x for x in row)
        assert not any(
            "sdk.Dockerfile" in x or "linux_container_test" in x for x in row
        )
    if existing:
        assert (
            seed / "original-provenance"
        ).read_bytes() == b"original producer receipt"


@pytest.mark.parametrize(
    "failure,exit_code,diagnostic",
    [
        ("transport", 24, "transport lookup failed"),
        ("seed", 23, "seed verification failed"),
        ("ci", 25, "cache export failed"),
    ],
)
def test_publisher_stops_on_the_original_command_failure(
    publisher, failure, exit_code, diagnostic
):
    result, rows, _ = publisher(existing=True, failure=failure)
    assert result.returncode == exit_code
    assert diagnostic in result.stderr
    builds = [r for r in rows if r[:3] == ["docker", "buildx", "build"]]
    if failure in ("transport", "seed"):
        assert not builds
    else:
        assert [r[r.index("--target") + 1] for r in builds] == [
            "application-dependencies",
            "ci",
        ]


@pytest.mark.parametrize("guard_index", [0, 1])
@pytest.mark.parametrize("state", ["current", "stale", "pr", "wrong-ref"])
def test_actual_workflow_guards_reject_stale_or_unreviewed_source(
    tmp_path, monkeypatch, guard_index, state
):
    config = yaml.safe_load(
        (ROOT / ".github/workflows/linux-cache-publish.yml").read_text()
    )
    guards = [
        step["run"]
        for step in config["jobs"]["publish-linux-caches"]["steps"]
        if "commits/main" in step.get("run", "")
    ]
    binary = tmp_path / "bin"
    binary.mkdir()
    commands = tmp_path / "guard-commands.jsonl"
    for name in ["git", "gh"]:
        stub = binary / name
        stub.write_text(
            f"#!{sys.executable}\n"
            "import json,os,sys\n"
            "from pathlib import Path\n"
            "with open(os.environ['GUARD_COMMAND_LOG'], 'a') as stream:\n"
            "    stream.write(json.dumps([Path(sys.argv[0]).name,*sys.argv[1:]])+'\\n')\n"
            "if sys.argv[0].endswith('/git'):\n"
            "    assert sys.argv[1:]==['rev-parse','HEAD'];print(os.environ['GITHUB_SHA'])\n"
            "else:\n"
            "    assert sys.argv[1:]==['api','repos/owner/repo/commits/main','--jq','.sha']\n"
            "    print(os.environ['AUTHORITATIVE_MAIN'])\n"
        )
        stub.chmod(0o755)
    # Remote Mac Bash can source ~/.bashrc for inherited SSH_CLIENT and reset
    # PATH even with -c. Run exact guard text without host startup/environment.
    poison = tmp_path / "ambient-bash-env"
    poison.write_text("echo unexpected-host-startup >&2; exit 99\n")
    monkeypatch.setenv("BASH_ENV", str(poison))
    monkeypatch.setenv("SSH_CLIENT", "fixture remote connection")
    source = "a" * 40
    result = subprocess.run(
        ["/bin/bash", "--noprofile", "--norc", "-e", "-c", guards[guard_index]],
        cwd=tmp_path,
        env={
            "PATH": str(binary),
            "HOME": str(tmp_path),
            "GUARD_COMMAND_LOG": str(commands),
            "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_REF": "refs/heads/feature"
            if state == "wrong-ref"
            else "refs/heads/main",
            "GITHUB_EVENT_NAME": "pull_request"
            if state == "pr"
            else "workflow_dispatch",
            "GITHUB_WORKFLOW_REF": "owner/repo/.github/workflows/linux-cache-publish.yml@refs/heads/main",
            "GITHUB_SHA": source,
            "AUTHORITATIVE_MAIN": "b" * 40 if state == "stale" else source,
        },
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert (result.returncode == 0) == (state == "current"), (
        result.stdout + result.stderr
    )

    rows = (
        [json.loads(line) for line in commands.read_text().splitlines()]
        if commands.exists()
        else []
    )
    assert rows == (
        [
            ["git", "rev-parse", "HEAD"],
            ["gh", "api", "repos/owner/repo/commits/main", "--jq", ".sha"],
        ]
        if state in ("current", "stale")
        else []
    )
    assert "unexpected-host-startup" not in result.stderr
