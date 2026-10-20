"""Tooling receipts preserve source, original upload attempt and input identity."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile

import pytest

from tools import ci_tooling_image as tooling
from tools import ci_linux_handoff as handoff

REPO = "owner/repo"
SOURCE = "a" * 40
SDK = "sha256:" + "b" * 64
DIGEST = "sha256:" + "c" * 64
SNAPSHOT = "20261001T000000Z"


@pytest.fixture
def evidence(tmp_path, monkeypatch):
    # Hosted metadata is explicit and deliberately unrelated to the fixture's
    # producer. Consumer ref/event never grant publication or change provenance.
    monkeypatch.setenv("GITHUB_REF", "refs/pull/999/merge")
    monkeypatch.setenv("GITHUB_EVENT_NAME", "pull_request")
    monkeypatch.setenv("GITHUB_REPOSITORY", "unrelated/consumer")
    root = tmp_path / "source"
    recipe = root / tooling.RECIPE
    recipe.parent.mkdir(parents=True)
    recipe.write_text("FROM exact-sdk\nRUN install-pinned-tools\n")
    recipe.chmod(0o644)
    expected = tooling.identity(SDK, SNAPSHOT, root)
    run = {
        "id": 41,
        "path": ".github/workflows/linux-cache-publish.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": SOURCE,
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
        # A later sibling rerun cannot relabel original tooling bytes.
        "run_attempt": 2,
        "status": "completed",
        "conclusion": "failure",
    }
    job = {
        "id": 51,
        "run_id": 41,
        "name": "publish-linux-caches",
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "started_at": "2026-10-20T01:00:00Z",
        "completed_at": "2026-10-20T01:10:00Z",
    }
    receipt = {
        "schema": 1,
        "component": tooling.CONSUMER,
        "repository": REPO,
        "inputs": expected,
        "tier": "tooling",
        "label": "",
        "source_commit": SOURCE,
        "source_run_id": 41,
        "source_run_attempt": 1,
        "source_job_id": 51,
        "image_digest": DIGEST,
    }
    artifact = {
        "id": 61,
        "name": "ci-tooling-" + expected["identity"],
        "expired": False,
        "workflow_run": {"id": 41},
        "created_at": "2026-10-20T01:05:00Z",
    }
    return {
        "expected": expected,
        "receipt": receipt,
        "artifact": artifact,
        "run": run,
        "job": job,
        "root": root,
    }


def verify(e, fetch=None):
    return tooling.verify_receipt(
        REPO,
        e["expected"],
        e["receipt"],
        e["artifact"],
        e["run"],
        [e["job"]],
        fetch=fetch or (lambda *args: {"status": "ahead"}),
    )


@pytest.mark.parametrize("ref", ["refs/pull/999/merge", "refs/heads/main", None])
def test_original_successful_attempt_survives_sibling_reruns(
    evidence, monkeypatch, ref
):
    if ref is None:
        monkeypatch.delenv("GITHUB_REF")
    else:
        monkeypatch.setenv("GITHUB_REF", ref)
    assert verify(evidence) == f"ghcr.io/{REPO}/linux-sdk@{DIGEST}"
    assert evidence["receipt"]["source_run_attempt"] == 1


@pytest.mark.parametrize(
    "part,key,value",
    [
        ("receipt", "schema", True),
        ("receipt", "component", "linux-sdk"),
        ("receipt", "repository", "attacker/repo"),
        ("receipt", "tier", "preview"),
        ("receipt", "label", "preview"),
        ("receipt", "source_commit", "d" * 40),
        ("receipt", "source_run_id", True),
        ("receipt", "source_run_attempt", 2),
        ("receipt", "source_run_attempt", 0),
        ("receipt", "source_job_id", 52),
        ("receipt", "source_job_id", False),
        ("receipt", "image_digest", "mutable-tag"),
        ("run", "head_branch", "feature"),
        ("run", "event", "pull_request"),
        ("run", "path", ".github/workflows/macos.yml"),
        ("run", "id", 42),
        ("run", "repository", {"full_name": "attacker/repo"}),
        ("run", "head_repository", {"full_name": "attacker/repo"}),
        ("run", "head_sha", "not-a-commit"),
        ("job", "run_attempt", 2),
        ("job", "conclusion", "failure"),
        ("job", "conclusion", "cancelled"),
        ("job", "name", "linux-build"),
        ("job", "run_id", 42),
        ("job", "completed_at", "2026-10-20T01:04:00Z"),
        ("job", "started_at", "2026-10-20T01:06:00Z"),
        ("job", "started_at", "invalid"),
        ("artifact", "expired", True),
        ("artifact", "expired", None),
        ("artifact", "name", "unrelated"),
        ("artifact", "workflow_run", {"id": 42}),
    ],
)
def test_receipt_cannot_launder_wrong_source_bytes_or_attempt(
    evidence, part, key, value
):
    evidence[part][key] = value
    with pytest.raises(ValueError):
        verify(evidence)


def test_incompatible_sdk_or_recipe_and_unreachable_source_fail_closed(evidence):
    evidence["receipt"] = copy.deepcopy(evidence["receipt"])
    evidence["receipt"]["inputs"]["sdk_image_id"] = "sha256:" + "d" * 64
    with pytest.raises(ValueError, match="contract"):
        verify(evidence)
    evidence["receipt"]["inputs"] = evidence["expected"]
    with pytest.raises(ValueError, match="ancestry"):
        verify(evidence, lambda *args: {"status": "diverged"})


def test_only_real_tooling_inputs_change_key(evidence):
    root = evidence["root"]
    first = tooling.identity(SDK, SNAPSHOT, root)
    (root / "application.cpp").write_text("new app source")
    (root / "qualification.json").write_text("new dependency seed receipt")
    assert tooling.identity(SDK, SNAPSHOT, root) == first
    assert tooling.identity("sha256:" + "d" * 64, SNAPSHOT, root) != first
    assert tooling.identity(SDK, "20260901T000000Z", root) != first
    (root / tooling.RECIPE).chmod(0o755)
    assert tooling.identity(SDK, SNAPSHOT, root) != first
    (root / tooling.RECIPE).chmod(0o644)
    (root / tooling.RECIPE).write_text("FROM exact-sdk\nRUN other-tools\n")
    assert tooling.identity(SDK, SNAPSHOT, root) != first


@pytest.mark.parametrize("sdk,snapshot", [("tag", SNAPSHOT), (SDK, "latest")])
def test_identity_rejects_mutable_inputs(sdk, snapshot):
    with pytest.raises(ValueError):
        tooling.identity(sdk, snapshot)


def test_identity_rejects_symlink_recipe(evidence):
    recipe = evidence["root"] / tooling.RECIPE
    real = recipe.with_suffix(".real")
    recipe.rename(real)
    recipe.symlink_to(real)
    with pytest.raises(ValueError, match="regular"):
        tooling.identity(SDK, SNAPSHOT, evidence["root"])


def test_identity_uses_git_executable_mode_not_checkout_umask(evidence):
    recipe = evidence["root"] / tooling.RECIPE
    original = tooling.identity(SDK, SNAPSHOT, evidence["root"])
    recipe.chmod(0o664)
    assert tooling.identity(SDK, SNAPSHOT, evidence["root"]) == original
    recipe.chmod(0o775)
    executable = tooling.identity(SDK, SNAPSHOT, evidence["root"])
    assert executable["identity"] != original["identity"]
    assert executable["recipe"]["mode"] == 0o755
    recipe.chmod(0o755)
    assert tooling.identity(SDK, SNAPSHOT, evidence["root"]) == executable


def test_lookup_checks_paginated_zip_checksum_and_preserves_original_receipt(
    evidence, tmp_path
):
    e = evidence
    archive = tmp_path / "original.zip"
    with zipfile.ZipFile(archive, "w") as stream:
        stream.writestr("tooling.json", json.dumps(e["receipt"]))
    e["artifact"]["digest"] = (
        "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
    )
    calls = []

    def fetch(repo, route):
        assert repo == REPO
        calls.append(route)
        if route.startswith("actions/artifacts?"):
            if route.endswith("page=1"):
                return {
                    "artifacts": [
                        {**e["artifact"], "id": i, "expired": True} for i in range(100)
                    ]
                }
            return {"artifacts": [e["artifact"]]}
        if route == "actions/runs/41":
            return e["run"]
        assert route == f"compare/{SOURCE}...main"
        return {"status": "ahead"}

    def download(repo, artifact, dest):
        assert (
            artifact["digest"]
            == "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
        )
        dest.write_bytes(archive.read_bytes())

    output = tmp_path / "resolved"
    assert tooling.lookup(
        REPO,
        e["expected"],
        output,
        fetch=fetch,
        download=download,
        jobs=lambda *args: [e["job"]],
    ).endswith("@" + DIGEST)
    assert any(route.endswith("page=2") for route in calls)
    saved = json.loads((output / "producer.json").read_text())
    assert saved["receipt"] == e["receipt"]


@pytest.mark.parametrize(
    "members",
    [["../tooling.json"], ["tooling.json", "extra"], ["tooling.json", "tooling.json"]],
)
def test_lookup_rejects_unexpected_zip_members(evidence, tmp_path, members):
    def download(repo, artifact, dest):
        with zipfile.ZipFile(dest, "w") as stream:
            for name in members:
                stream.writestr(name, json.dumps(evidence["receipt"]))

    def fetch(repo, route):
        return (
            {"artifacts": [evidence["artifact"]]}
            if "artifacts?" in route
            else evidence["run"]
        )

    with pytest.raises(ValueError, match="ZIP"):
        tooling.lookup(
            REPO,
            evidence["expected"],
            tmp_path / "out",
            fetch=fetch,
            download=download,
            jobs=lambda *args: [evidence["job"]],
        )


def test_confirmed_expiry_is_miss_but_api_failure_is_not(evidence, tmp_path):
    def fetch(*args):
        return {"artifacts": [{**evidence["artifact"], "expired": True}]}

    assert (
        tooling.lookup(REPO, evidence["expected"], tmp_path / "out", fetch=fetch)
        is None
    )

    def broken(*args):
        raise RuntimeError("API unavailable; retry lookup")

    with pytest.raises(RuntimeError, match="API unavailable"):
        tooling.lookup(REPO, evidence["expected"], tmp_path / "out", fetch=broken)


def publisher_env():
    return {
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_REPOSITORY": REPO,
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_JOB": "publish-linux-caches",
        "GITHUB_WORKFLOW_REF": REPO
        + "/.github/workflows/linux-cache-publish.yml@refs/heads/main",
        "GITHUB_SHA": SOURCE,
    }


@pytest.mark.parametrize(
    "key,value",
    [
        ("GITHUB_REF", "refs/pull/7/merge"),
        ("GITHUB_EVENT_NAME", "pull_request"),
        ("GITHUB_JOB", "linux-build"),
        ("GITHUB_REPOSITORY", "other/repo"),
        ("GITHUB_WORKFLOW_REF", "other"),
        ("GITHUB_SHA", "bad"),
    ],
)
def test_only_dedicated_main_job_may_publish(key, value):
    env = publisher_env()
    env[key] = value
    with pytest.raises(ValueError, match="dedicated"):
        tooling.require_publisher(REPO, environment=env, head=SOURCE)


def test_publisher_rechecks_main_and_checkout():
    env = publisher_env()

    def fetch(*args):
        return {"sha": SOURCE}

    assert (
        tooling.require_publisher(REPO, environment=env, head=SOURCE, fetch=fetch)
        == SOURCE
    )
    with pytest.raises(ValueError, match="advanced"):
        tooling.require_publisher(REPO, environment=env, head="d" * 40, fetch=fetch)
    with pytest.raises(ValueError, match="advanced"):
        tooling.require_publisher(
            REPO, environment=env, head=SOURCE, fetch=lambda *args: {"sha": "d" * 40}
        )


def test_build_handoff_binds_tooling_inputs_to_actual_sdk(
    evidence, tmp_path, monkeypatch
):
    monkeypatch.setattr(handoff.subprocess, "check_output", lambda *a, **kw: SDK)
    monkeypatch.setattr(tooling, "ROOT", evidence["root"])
    # Supply the explicit fixture root; never make fixtures depend on local HEAD.
    real_identity = tooling.identity
    monkeypatch.setattr(
        tooling,
        "identity",
        lambda sdk, snapshot: real_identity(sdk, snapshot, evidence["root"]),
    )
    seed = tmp_path / "seed.json"
    seed.write_text('{"original_run":1}')
    metadata = tmp_path / "tooling.json"
    metadata.write_text(json.dumps({"inputs": evidence["expected"]}))
    first = handoff.input_identity(
        "verified-sdk", seed, evidence["root"] / tooling.RECIPE, SNAPSHOT, metadata
    )
    assert first["tooling_identity"] == evidence["expected"]["identity"]
    wrong = copy.deepcopy(evidence["expected"])
    wrong["sdk_image_id"] = "sha256:" + "d" * 64
    metadata.write_text(json.dumps({"inputs": wrong}))
    with pytest.raises(ValueError, match="actual consumed"):
        handoff.input_identity(
            "verified-sdk", seed, evidence["root"] / tooling.RECIPE, SNAPSHOT, metadata
        )


def test_tool_installation_must_preserve_actual_compiler_and_header_bytes():
    seen = []

    def profile(image):
        seen.append(image)
        return {
            "compiler": "exact",
            "headers": {"stdio.h": "digest"},
            "image_id": image,
            "requested_image": image,
        }

    assert tooling.verify_abi("sdk", "tooling", profile=profile)
    assert seen == ["sdk", "tooling"]

    def incompatible(image):
        return {
            "compiler": "exact",
            "headers": {"stdio.h": "changed" if image == "tooling" else "digest"},
        }

    with pytest.raises(ValueError, match="compiler ABI"):
        tooling.verify_abi("sdk", "tooling", profile=incompatible)


@pytest.fixture
def docker_fixture(evidence, tmp_path, monkeypatch):
    e = evidence
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.setattr(tooling, "identity", lambda *args: e["expected"])
    monkeypatch.setattr(tooling, "verify_abi", lambda *args: "d" * 64)
    output = tmp_path / "tooling"
    rows = []
    image = {
        "Id": "sha256:" + "e" * 64,
        "Architecture": "amd64",
        "Os": "linux",
        "Config": {
            "Labels": {
                "org.openforesight.ci-tooling": e["expected"]["identity"],
                "org.openforesight.sdk-image-id": SDK,
                "org.openforesight.ubuntu-snapshot": SNAPSHOT,
            }
        },
    }

    def request(args, **kwargs):
        assert kwargs["timeout"] > 0
        rows.append(args)
        if args == [
            "docker",
            "image",
            "inspect",
            "--format",
            "{{.Id}}",
            "verified-sdk",
        ]:
            return SDK
        if args == ["docker", "context", "show"]:
            return "same-daemon"
        assert args[:3] == ["docker", "image", "inspect"], args
        return json.dumps([image])

    def run(args, **kwargs):
        assert kwargs["timeout"] > 0 and kwargs["check"] is True
        rows.append(args)
        if "--metadata-file" in args:
            Path(args[args.index("--metadata-file") + 1]).write_text(
                json.dumps({"containerimage.digest": DIGEST})
            )

    monkeypatch.setattr(tooling.subprocess, "check_output", request)
    monkeypatch.setattr(tooling.subprocess, "run", run)
    return e, output, rows, image


@pytest.mark.parametrize("ref", ["refs/pull/555/merge", "refs/heads/main", None])
def test_real_miss_prepares_only_tooling_in_sdk_daemon_without_shared_writes(
    docker_fixture, monkeypatch, ref
):
    e, output, rows, image = docker_fixture
    if ref is None:
        monkeypatch.delenv("GITHUB_REF", raising=False)
    else:
        monkeypatch.setenv("GITHUB_REF", ref)
    result = tooling.prepare(REPO, "verified-sdk", SNAPSHOT, output)
    builds = [r for r in rows if r[:3] == ["docker", "buildx", "build"]]
    assert len(builds) == 1
    cmd = builds[0]
    assert cmd[cmd.index("--builder") + 1] == "same-daemon"
    assert "--load" in cmd and "--push" not in cmd and "--cache-to" not in cmd
    assert cmd[cmd.index("--file") + 1] == tooling.RECIPE
    assert cmd[cmd.index("--target") + 1] == "ci-tooling"
    assert not any("appdeps" in arg or "sdk.Dockerfile" in arg for arg in cmd)
    assert result["reused"] is False and result["image_id"] == image["Id"]
    assert json.loads((output / "inputs.json").read_text()) == result


def test_warm_immutable_tooling_reuses_original_provenance_without_build(
    docker_fixture, monkeypatch
):
    e, output, rows, _ = docker_fixture
    monkeypatch.setenv("GH_TOKEN", "fixture-not-a-token")
    expected_image = f"ghcr.io/{REPO}/linux-sdk@{DIGEST}"
    monkeypatch.setattr(tooling, "lookup", lambda *args: expected_image)
    result = tooling.prepare(REPO, "verified-sdk", SNAPSHOT, output)
    assert ["docker", "pull", expected_image] in rows
    assert not any(r[:3] == ["docker", "buildx", "build"] for r in rows)
    assert result["reused"] is True and result["image"] == expected_image


@pytest.mark.parametrize(
    "field,value", [("Architecture", "arm64"), ("Os", "darwin"), ("Config", {})]
)
def test_actual_consumed_image_platform_and_labels_are_checked(
    docker_fixture, field, value
):
    _, output, _, image = docker_fixture
    image[field] = value
    with pytest.raises(ValueError, match="labels/platform"):
        tooling.prepare(REPO, "verified-sdk", SNAPSHOT, output)
    assert not (output / "inputs.json").exists()


def test_publisher_receipt_binds_exact_original_running_job_before_upload(
    docker_fixture, monkeypatch
):
    e, output, rows, _ = docker_fixture
    calls = []

    def guard(repo):
        calls.append(repo)
        return SOURCE

    monkeypatch.setattr(tooling, "require_publisher", guard)
    monkeypatch.setenv("GITHUB_RUN_ID", "41")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    monkeypatch.setattr(
        tooling.artifacts,
        "dependency_jobs",
        lambda *args: [
            {
                "id": 51,
                "name": "publish-linux-caches",
                "run_attempt": 1,
                "status": "in_progress",
            }
        ],
    )
    tooling.prepare(REPO, "verified-sdk", SNAPSHOT, output, publish=True)
    assert len(calls) == 3
    assert any("--push" in row for row in rows)
    receipt = json.loads((output / "tooling.json").read_text())
    assert receipt["source_commit"] == SOURCE
    assert receipt["source_run_attempt"] == 1 and receipt["source_job_id"] == 51
    assert receipt["image_digest"] == DIGEST
    assert receipt["tier"] == "tooling" and receipt["label"] == ""


def test_missing_original_publisher_job_never_creates_an_eligible_receipt(
    docker_fixture, monkeypatch
):
    _, output, _, _ = docker_fixture
    monkeypatch.setattr(tooling, "require_publisher", lambda *args: SOURCE)
    monkeypatch.setenv("GITHUB_RUN_ID", "41")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    monkeypatch.setattr(tooling.artifacts, "dependency_jobs", lambda *args: [])
    with pytest.raises(ValueError, match="original publisher"):
        tooling.prepare(REPO, "verified-sdk", SNAPSHOT, output, publish=True)
    assert not (output / "tooling.json").exists()


def test_metadata_read_failure_never_authorizes_rebuild(docker_fixture, monkeypatch):
    _, output, rows, _ = docker_fixture
    monkeypatch.setenv("GH_TOKEN", "fixture-not-a-token")

    def unavailable(*args):
        raise RuntimeError("metadata unavailable")

    monkeypatch.setattr(tooling, "lookup", unavailable)
    with pytest.raises(RuntimeError, match="metadata unavailable"):
        tooling.prepare(REPO, "verified-sdk", SNAPSHOT, output)
    assert not any(r[:3] == ["docker", "buildx", "build"] for r in rows)


@pytest.mark.parametrize(
    "state", ["pull-request", "wrong-repository", "pending", "failed"]
)
def test_unqualified_maintenance_is_never_consumed_or_allowed_to_cancel_app_validation(
    evidence, tmp_path, state
):
    e = evidence
    run = copy.deepcopy(e["run"])
    job = copy.deepcopy(e["job"])
    if state == "pull-request":
        run["event"] = "pull_request"
    elif state == "wrong-repository":
        run["repository"]["full_name"] = "foreign/repo"
    else:
        job["conclusion"] = None if state == "pending" else "failure"
        job["status"] = "in_progress" if state == "pending" else "completed"

    def fetch(repo, route):
        return {"artifacts": [e["artifact"]]} if "artifacts?" in route else run

    def forbidden(*args):
        pytest.fail("Unqualified bytes must not be downloaded")

    assert (
        tooling.lookup(
            REPO,
            e["expected"],
            tmp_path / "out",
            fetch=fetch,
            download=forbidden,
            jobs=lambda *args: [job],
        )
        is None
    )


def test_cli_records_reuse_without_claiming_fresh_compilation(
    tmp_path, monkeypatch, capsys
):
    output = tmp_path / "github-output"
    result = {
        "image": f"ghcr.io/{REPO}/linux-sdk@{DIGEST}",
        "inputs": {"identity": "f" * 64},
        "reused": True,
    }
    calls = []

    def prepare(*args, **kwargs):
        calls.append((args, kwargs))
        return result

    monkeypatch.setattr(tooling, "prepare", prepare)
    monkeypatch.setattr(
        tooling.sys,
        "argv",
        [
            "ci_tooling_image.py",
            "--repository",
            REPO,
            "--sdk-image",
            "verified-sdk",
            "--snapshot",
            SNAPSHOT,
            "--output",
            str(tmp_path / "image"),
            "--publish",
        ],
    )
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    tooling.main()
    assert calls[0][1] == {"publish": True}
    assert json.loads(capsys.readouterr().out) == result
    assert "tooling_reused=true" in output.read_text()
    assert "compiled" not in output.read_text()
    monkeypatch.delenv("GITHUB_OUTPUT")
    tooling.main()
    assert json.loads(capsys.readouterr().out) == result


def test_publisher_guard_reads_actual_checkout_without_history_dependency(monkeypatch):
    monkeypatch.setattr(
        tooling.subprocess, "check_output", lambda *args, **kwargs: SOURCE + "\n"
    )
    assert (
        tooling.require_publisher(
            REPO, environment=publisher_env(), fetch=lambda *args: {"sha": SOURCE}
        )
        == SOURCE
    )


def test_reviewed_cmake_runtime_migration_retains_qualified_abi_identity():
    original = {
        "compiler_package": "13.3.0-6ubuntu2~24.04.1",
        "platform": "linux/amd64",
        "ubuntu": "24.04",
        "glibc": "2.39",
        "cmake": "3.28",
        "proof_sha256": "a" * 64,
        "matched_files": 489,
    }
    migrated = {
        **original,
        "matched_files": 486,
        "compatibility_proof_sha256": "b" * 64,
        "compatible_cmake_runtime_files": {
            "/usr/lib/x86_64-linux-gnu/libcurl.so.4": {
                "original_sha256": "c" * 64,
                "consumer_sha256": "d" * 64,
            }
        },
    }
    result = tooling.verify_abi(
        "original",
        "migrated",
        profile=lambda image: original if image == "original" else migrated,
    )
    assert result == tooling.verify_abi(
        "original", "original", profile=lambda image: original
    )
    incompatible = {**migrated, "compiler_package": "other"}
    with pytest.raises(ValueError, match="compiler ABI"):
        tooling.verify_abi(
            "original",
            "changed",
            profile=lambda image: original if image == "original" else incompatible,
        )
    incompatible = {**migrated, "proof_sha256": "e" * 64}
    with pytest.raises(ValueError, match="compiler ABI"):
        tooling.verify_abi(
            "original",
            "changed",
            profile=lambda image: original if image == "original" else incompatible,
        )


def test_actual_identity_cli_bootstraps_imports_without_pythonpath_or_git(tmp_path):
    binary = tmp_path / "bin"
    binary.mkdir()
    docker = binary / "docker"
    docker.write_text(
        f"#!{sys.executable}\nimport sys\nassert sys.argv[1:]==['image','inspect','--format','{{{{.Id}}}}','verified-sdk']\nprint({SDK!r})\n"
    )
    docker.chmod(0o755)
    seed = tmp_path / "qualification.json"
    seed.write_text('{"original_producer":41}')
    recipe = tmp_path / "build.Dockerfile"
    recipe.write_text("FROM fixture-tooling AS application-base\n")
    metadata = tmp_path / "tooling.json"
    metadata.write_text(json.dumps({"inputs": tooling.identity(SDK, SNAPSHOT)}))
    output = tmp_path / "identity.json"
    env = {
        **os.environ,
        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
        "GITHUB_REF": "refs/pull/999/merge",
        "GITHUB_EVENT_NAME": "pull_request",
    }
    env.pop("PYTHONPATH", None)
    result = subprocess.run(
        [
            sys.executable,
            str(Path(handoff.__file__)),
            "identity",
            "--sdk-image",
            "verified-sdk",
            "--qualification",
            str(seed),
            "--recipe",
            str(recipe),
            "--snapshot",
            SNAPSHOT,
            "--tooling",
            str(metadata),
            "--output",
            str(output),
        ],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    record = json.loads(output.read_text())
    assert record["tooling_identity"] == tooling.identity(SDK, SNAPSHOT)["identity"]
    assert (
        record["dependency_seed_sha256"]
        == hashlib.sha256(seed.read_bytes()).hexdigest()
    )
