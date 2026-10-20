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


def test_main_dispatch_is_the_only_publisher_entrypoint():
    config = yaml.safe_load(
        (ROOT / ".github/workflows/linux-cache-publish.yml").read_text()
    )
    assert config.get("on", config.get(True)) == {"workflow_dispatch": None}
    assert all(value == "read" for value in config["permissions"].values())
    assert not config["concurrency"]["cancel-in-progress"]
    assert set(config["jobs"]) == {"publish-linux-caches"}
    job = config["jobs"]["publish-linux-caches"]
    assert (
        job["if"]
        == "github.ref == 'refs/heads/main' && github.event_name == 'workflow_dispatch'"
    )
    assert job["permissions"] == {
        "contents": "read",
        "actions": "read",
        "packages": "write",
    }
    steps = job["steps"]
    checkout = next(
        s for s in steps if s.get("uses", "").startswith("actions/checkout@")
    )
    assert checkout["with"] == {
        "persist-credentials": False,
        "ref": "${{ github.sha }}",
    }
    fetch = next(i for i, s in enumerate(steps) if s.get("id") == "sdk")
    assert (
        steps[fetch]["run"]
        == 'python3 tools/ci_linux_shadow_sdk.py --source "$GITHUB_SHA" --own-pr 0 --directory build/cache-sdk'
    )
    assert "--fork" not in steps[fetch]["run"]
    guards = [i for i, s in enumerate(steps) if "commits/main" in s.get("run", "")]
    publish = next(
        i
        for i, s in enumerate(steps)
        if s.get("run") == "bash tools/publish_linux_ci_caches.sh"
    )
    assert len(guards) == 2 and guards[0] < fetch < guards[1] == publish - 1
    assert (
        ".github/workflows/linux-cache-publish.yml@refs/heads/main"
        in steps[guards[0]]["run"]
    )
    assert steps[publish]["env"]["SDK_IMAGE"] == "${{ steps.sdk.outputs.image }}"
    assert not any(
        "ci_dependency_seed_provider" in str(s) or "upload-artifact" in str(s)
        for s in steps
    )


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
if row[:3]==['docker','buildx','build'] and row[row.index('--target')+1]==os.getenv('FAIL_STAGE'):
    print('cache export failed',file=sys.stderr);sys.exit(25)
"""
    for name in ["python", "docker"]:
        p = binary / name
        p.write_text(stub)
        p.chmod(0o755)
    seed = tmp_path / "verified-seed"

    def run(*, existing=False, failure=""):
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
def test_only_secret_free_dependency_targets_are_exported(publisher, existing):
    result, rows, seed = publisher(existing=existing)
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
        tag = {
            "application-dependencies": "app-deps-buildcache-v1",
            "ci": "ci-tools-buildcache-v1",
            "acceptance-dependencies": "acceptance-tools-buildcache-v1",
        }[target]
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
    tmp_path, guard_index, state
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
    for name in ["git", "gh"]:
        stub = binary / name
        stub.write_text(
            f"#!{sys.executable}\n"
            "import os,sys\n"
            "if sys.argv[0].endswith('/git'):\n"
            "    assert sys.argv[1:]==['rev-parse','HEAD'];print(os.environ['GITHUB_SHA'])\n"
            "else:\n"
            "    assert sys.argv[1:]==['api','repos/owner/repo/commits/main','--jq','.sha']\n"
            "    print(os.environ['AUTHORITATIVE_MAIN'])\n"
        )
        stub.chmod(0o755)
    source = "a" * 40
    result = subprocess.run(
        ["/bin/bash", "-e", "-c", guards[guard_index]],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": str(binary),
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
