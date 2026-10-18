"""Installed sanitizer migration must never silently invoke a library build."""

from copy import deepcopy
import io
import json
import shutil
import subprocess
import tarfile
from unittest.mock import patch
import zipfile

import pytest
import yaml

from tools import ci_sanitizer_artifacts as sdk

REPOSITORY = "teng-lin/open-foresight"


@pytest.fixture
def source(tmp_path):
    root = tmp_path / "source"
    root.mkdir()
    for name in (
        *sdk.FILES,
        "tools/build_macos_sdk.py",
        "tools/ci_sanitizer_artifacts.py",
        sdk.WORKFLOW,
    ):
        destination = root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sdk.ROOT / name, destination)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=f@invalid",
            "commit",
            "-qm",
            "fixture",
        ],
        cwd=root,
        check=True,
    )
    return root


@pytest.fixture
def abi(tmp_path):
    return {
        "compiler": "clang version fixture\nTarget: x86_64-unknown-linux-gnu",
        "runtime": str(tmp_path / "runtime.so"),
        "runtime_sha256": "a" * 64,
        "machine": "x86_64",
        "prefix": str(tmp_path / "prefix"),
        "packages": ["openssl 3.6.4"],
        "compiler_sha256": "b" * 64,
    }


def installed(root, prefix, abi, kind="address"):
    prefix.mkdir(parents=True)
    for name in sdk.REQUIRED:
        path = prefix / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("installed SDK bytes")
    (prefix / "bin/protoc").write_text('#!/bin/sh\nprintf "libprotoc fixture\\n"\n')
    (prefix / "bin/protoc").chmod(0o755)
    (prefix / "lib/libprotobufd.so.1").write_bytes(b"library")
    (prefix / "lib/libprotobufd.so").unlink()
    (prefix / "lib/libprotobufd.so").symlink_to("libprotobufd.so.1")
    (prefix / "sanitizer-sdk.json").write_text(
        json.dumps(sdk.expected_stamp(root, kind, abi["compiler"]))
    )


def test_macos_projection_ignores_unconsumed_json_and_mac_main_flags():
    original = (sdk.ROOT / "tools/build_macos_sdk.py").read_text()
    changed = original.replace(
        "65ee68451d8eb2b5f3a30b410476ab83deb3289b", "a" * 40
    ).replace('"MACOSX_DEPLOYMENT_TARGET"', '"OTHER_MAC_SETTING"')
    assert changed != original
    assert sdk.macos_projection(changed.encode()) == sdk.macos_projection(
        original.encode()
    )
    grpc = original.replace("aae267021b1ac256f8b9038d0ef528c3798cc137", "b" * 40)
    assert sdk.macos_projection(grpc.encode()) != sdk.macos_projection(
        original.encode()
    )
    helper = original.replace("ignore_submodules=True", "ignore_submodules=False")
    assert sdk.macos_projection(helper.encode()) != sdk.macos_projection(
        original.encode()
    )


@pytest.mark.parametrize(
    "addition",
    [
        '\nDYNAMIC = subprocess.run(["false"])\n',
        "\nimport requests\n",
        '\nraise RuntimeError("side effect")\n',
        '\ndef unused(value=subprocess.run(["false"])): pass\n',
    ],
)
def test_unsupported_import_time_producer_behavior_fails_closed(addition):
    with pytest.raises((ValueError, SyntaxError)):
        sdk.macos_projection(
            (sdk.ROOT / "tools/build_macos_sdk.py").read_bytes() + addition.encode()
        )


def test_recipe_is_component_specific_and_excludes_new_receipt_helper(source):
    original = sdk.recipe(source, "address")
    assert original != sdk.recipe(source, "thread")
    (source / "tools/ci_sanitizer_artifacts.py").write_text("publication changed")
    assert sdk.recipe(source, "address") == original
    path = source / "packaging/sanitizer-grpc.cmake"
    path.write_text(path.read_text() + "\nset(CHANGED_OUTPUT_FLAG ON)\n")
    assert sdk.recipe(source, "address") != original


def test_existing_119_scoped_prefix_is_verified_and_published_without_build(
    source, abi, tmp_path
):
    prefix = tmp_path / "prefix"
    installed(source, prefix, abi)
    with (
        patch.object(sdk, "environment", return_value=abi),
        patch.object(sdk, "find") as search,
        patch.object(
            sdk,
            "cache_origin",
            return_value={
                "run_id": 39167769695,
                "source_commit": "original-compiled-source",
            },
        ),
    ):
        result = sdk.restore(
            source,
            "address",
            prefix,
            REPOSITORY,
            119,
            "unchanged-legacy-key",
            cache_hit="true",
        )
        search.assert_not_called()
        output = tmp_path / "artifact"
        publication = sdk.pack(source, "address", prefix, output)
    receipt = json.loads((output / "identity.json").read_text())
    assert receipt["qualified_from"] == {
        "kind": "existing-scoped-cache",
        "compiled_from": {
            "run_id": 39167769695,
            "source_commit": "original-compiled-source",
        },
    }
    assert receipt["identity"] == result["identity"]
    assert publication["artifact_name"].startswith("ci-sanitizer-address-")
    restored = tmp_path / "restored"
    sdk.unpack_verified(output, restored, receipt)
    assert sdk.inventory(restored) == sdk.inventory(prefix)
    assert (restored / "lib/libprotobufd.so").is_symlink()
    assert (restored / "bin/protoc").stat().st_mode & 0o111


def test_cold_miss_or_api_error_never_authorizes_a_build(source, abi, tmp_path):
    with (
        patch.object(sdk, "environment", return_value=abi),
        patch.object(sdk, "find", return_value=None),
        patch.object(sdk.subprocess, "run") as command,
    ):
        with pytest.raises(
            RuntimeError, match="No verified compatible sanitizer prefix"
        ):
            sdk.restore(source, "address", tmp_path / "missing", REPOSITORY, 119, "key")
        with pytest.raises(RuntimeError):
            sdk.restore(
                source,
                "address",
                tmp_path / "missing",
                REPOSITORY,
                119,
                "key",
                True,
                "",
            )
        with patch.object(sdk.subprocess, "check_output", return_value="a" * 40):
            result = sdk.restore(
                source,
                "address",
                tmp_path / "missing",
                REPOSITORY,
                119,
                "key",
                True,
                "Compiler ABI changed; no compatible prefix after verified search",
            )
        assert result["identity"]
        command.assert_not_called()
    for error in (
        json.JSONDecodeError("malformed API", "", 0),
        subprocess.CalledProcessError(1, ["gh", "api"]),
        OSError("network"),
    ):
        with (
            patch.object(sdk, "environment", return_value=abi),
            patch.object(sdk, "find", side_effect=error),
        ):
            with pytest.raises(type(error)):
                sdk.restore(
                    source, "address", tmp_path / "missing", REPOSITORY, 119, "key"
                )


def test_corrupt_or_incomplete_existing_prefix_stops_before_builder(
    source, abi, tmp_path
):
    prefix = tmp_path / "prefix"
    installed(source, prefix, abi)
    (prefix / "bin/grpc_cpp_plugin").unlink()
    with (
        patch.object(sdk, "environment", return_value=abi),
        patch.object(sdk, "cache_origin", return_value={"original": "verified"}),
        patch.object(sdk.subprocess, "run") as command,
    ):
        with pytest.raises(ValueError, match="Incomplete"):
            sdk.restore(
                source, "address", prefix, REPOSITORY, 119, "key", cache_hit="true"
            )
        command.assert_not_called()


def test_foreign_open_pr_and_workflow_rejected_but_reviewed_merge_can_share():
    run = {
        "path": sdk.WORKFLOW,
        "head_repository": {"full_name": REPOSITORY},
        "event": "pull_request",
        "pull_requests": [{"number": 119}],
    }
    assert sdk.trusted(REPOSITORY, run, 119)
    with patch.object(sdk.artifacts, "merged_source", return_value=False):
        assert not sdk.trusted(REPOSITORY, run, 110)
    with patch.object(sdk.artifacts, "merged_source", return_value=True):
        assert sdk.trusted(REPOSITORY, run, 110)
        assert not sdk.trusted(REPOSITORY, {**run, "path": "other.yml"}, 110)
        assert not sdk.trusted(
            REPOSITORY, {**run, "head_repository": {"full_name": "attacker/fork"}}, 110
        )


@pytest.fixture
def producer(source, abi, tmp_path):
    prefix = tmp_path / "prefix"
    installed(source, prefix, abi)
    with (
        patch.object(sdk, "environment", return_value=abi),
        patch.object(
            sdk,
            "cache_origin",
            return_value={
                "run_id": 39167769695,
                "source_commit": "original-compiled-source",
            },
        ),
    ):
        sdk.restore(
            source, "address", prefix, REPOSITORY, 119, "old-key", cache_hit="true"
        )
        sdk.pack(source, "address", prefix, tmp_path / "artifact")
    receipt = json.loads((tmp_path / "artifact/identity.json").read_text())
    run = {
        "id": 100,
        "path": sdk.WORKFLOW,
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
        "event": "push",
        "head_branch": "main",
        "head_sha": receipt["source_commit"],
    }
    artifact = {
        "id": 1,
        "name": f"ci-sanitizer-address-{receipt['identity']}-attempt-1",
        "expired": False,
        "created_at": "2026-10-18T20:01:00Z",
        "workflow_run": {"id": 100},
    }
    job = {
        "name": sdk.JOBS["address"],
        "conclusion": "success",
        "run_attempt": 1,
        "started_at": "2026-10-18T20:00:00Z",
        "completed_at": "2026-10-18T20:02:00Z",
    }
    return receipt, run, artifact, job, tmp_path / "artifact"


def find_fixture(source, abi, producer, destination, own_pr=110):
    receipt, run, artifact, job, output = producer

    def api(repository, path):
        assert repository == REPOSITORY
        return (
            {"artifacts": [artifact]} if path.startswith("actions/artifacts?") else run
        )

    def download(repository, metadata, path):
        with zipfile.ZipFile(path, "w") as stream:
            stream.writestr("identity.json", json.dumps(receipt))
            stream.writestr("payload.tar.gz", (output / "payload.tar.gz").read_bytes())

    with (
        patch.object(sdk.artifacts, "api", side_effect=api),
        patch.object(sdk.artifacts, "dependency_jobs", return_value=[job]),
        patch.object(sdk.artifacts, "download_zip", side_effect=download),
    ):
        return sdk.find(
            REPOSITORY,
            "address",
            sdk.recipe(source, "address"),
            abi,
            source,
            own_pr,
            destination,
        )


def test_verified_successful_main_artifact_crosses_pr_scope(
    source, abi, producer, tmp_path
):
    restored = tmp_path / "new-prefix"
    assert find_fixture(source, abi, producer, restored)["run_id"] == 100
    assert (restored / "bin/protoc").is_file()


@pytest.mark.parametrize(
    "change",
    [
        "failed-job",
        "attempt",
        "outside-window",
        "source-recipe",
        "receipt",
        "payload",
        "runtime",
    ],
)
def test_failed_forged_or_incompatible_producer_never_restores(
    source, abi, producer, tmp_path, change
):
    receipt, run, artifact, job, output = producer
    if change == "failed-job":
        job["conclusion"] = "failure"
    elif change == "attempt":
        receipt["source_run_attempt"] = 2
    elif change == "outside-window":
        artifact["created_at"] = "2026-10-18T20:03:00Z"
    elif change == "source-recipe":
        path = source / "tools/sanitizer_runtime.py"
        path.write_text(path.read_text() + "\n# recipe drift\n")
    elif change == "receipt":
        receipt["source_commit"] = "a" * 40
    elif change == "payload":
        (output / "payload.tar.gz").write_bytes(b"corrupt")
    elif change == "runtime":
        abi = deepcopy(abi)
        abi["runtime_sha256"] = "c" * 64
    try:
        assert find_fixture(source, abi, producer, tmp_path / "rejected") is None
    except ValueError:
        pass
    assert not (tmp_path / "rejected").exists()


def test_tampered_archive_cannot_escape_prefix(tmp_path):
    output = tmp_path / "artifact"
    output.mkdir()
    archive = output / "payload.tar.gz"
    with tarfile.open(archive, "w:gz") as stream:
        member = tarfile.TarInfo("payload/../../outside")
        member.size = 4
        stream.addfile(member, io.BytesIO(b"evil"))
    with pytest.raises((ValueError, tarfile.FilterError)):
        sdk.unpack_verified(
            output,
            tmp_path / "restore",
            {"sha256": sdk.artifacts.digest(archive), "files": {}},
        )
    assert not (tmp_path / "outside").exists()


def test_workflow_retains_legacy_keys_and_publishes_before_application_checks():
    current = yaml.safe_load((sdk.ROOT / sdk.WORKFLOW).read_text())
    old = yaml.safe_load(
        subprocess.check_output(["git", "show", "HEAD:" + sdk.WORKFLOW], cwd=sdk.ROOT)
    )
    for kind, job in sdk.JOBS.items():
        steps = current["jobs"][job]["steps"]
        old_cache = next(
            s["with"]["key"]
            for s in old["jobs"][job]["steps"]
            if s.get("uses", "").startswith("actions/cache/restore@")
        )
        assert (
            next(
                s["with"]["key"]
                for s in steps
                if s.get("uses", "").startswith("actions/cache/restore@")
            )
            == old_cache
        )
        recovery = next(
            i
            for i, s in enumerate(steps)
            if "ci_sanitizer_artifacts.py restore" in s.get("run", "")
        )
        build = next(i for i, s in enumerate(steps) if s.get("name") == sdk.BUILD[kind])
        upload = next(
            i
            for i, s in enumerate(steps)
            if s.get("name", "").startswith("Share the installed")
        )
        app = next(
            i
            for i, s in enumerate(steps)
            if s.get("name", "").startswith("Configure and build")
        )
        assert recovery < build < upload < app
    assert current["concurrency"]["cancel-in-progress"] is False
    assert current["permissions"]["actions"] == "read"


def test_actual_119_bootstrap_recipe_and_builder_bytes_are_unchanged():
    original = "2c083383ae9fad6f016a90bc9aee1cd8284f19c0"
    for kind in sdk.JOBS:
        assert sdk.recipe(sdk.ROOT, kind, original) == sdk.recipe(sdk.ROOT, kind)
    for name in (*sdk.FILES, "tools/build_macos_sdk.py"):
        assert sdk.read_source(sdk.ROOT, name, original) == sdk.read_source(
            sdk.ROOT, name
        )


def cache_origin_fixture(source, abi):
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=source, text=True
    ).strip()
    key = (
        "sanitizer-sdk-clang-23.1.3-"
        + sdk.sha((abi["compiler"] + "\n").encode())
        + "-"
        + "a" * 64
    )
    cache = {
        "id": 99,
        "key": key,
        "ref": "refs/pull/119/merge",
        "created_at": "2026-10-18T20:01:00.500679Z",
    }
    run = {
        "id": 1001,
        "path": sdk.WORKFLOW,
        "head_repository": {"full_name": REPOSITORY},
        "event": "pull_request",
        "pull_requests": [{"number": 119}],
        "head_sha": commit,
    }
    job = {
        "id": 2001,
        "name": sdk.JOBS["address"],
        "status": "completed",
        "conclusion": "failure",
        "run_attempt": 1,
        "steps": [
            {
                "name": sdk.BUILD["address"],
                "conclusion": "success",
                "completed_at": "2026-10-18T20:00:30Z",
            },
            {
                "name": "Save the validated SDK before application checks",
                "conclusion": "success",
                "started_at": "2026-10-18T20:00:31Z",
                "completed_at": "2026-10-18T20:01:00Z",
            },
        ],
    }
    return key, cache, run, job, commit


def check_cache_origin(source, abi, fixture):
    key, cache, run, job, commit = fixture

    def api(repository, route):
        assert repository == REPOSITORY
        if route.startswith("actions/caches?"):
            return {"actions_caches": [cache]}
        return {"workflow_runs": [run]}

    original = sdk.subprocess.check_output

    def request(command, **kwargs):
        if command == ["gh", "api", "--help"]:
            return "Usage: gh api"
        if command[:2] == ["gh", "api"]:
            return (
                "2026-10-18T20:00:00Z [command]/usr/bin/git log -1 --format=%H\n2026-10-18T20:00:00Z "
                + commit
                + "\n"
            )
        return original(command, **kwargs)

    with (
        patch.object(sdk.artifacts, "api", side_effect=api),
        patch.object(sdk.artifacts, "dependency_jobs", return_value=[job]),
        patch.object(sdk.subprocess, "check_output", side_effect=request),
    ):
        return sdk.cache_origin(source, "address", REPOSITORY, 119, key, abi)


def test_scoped_cache_keeps_original_source_even_if_later_application_failed(
    source, abi
):
    fixture = cache_origin_fixture(source, abi)
    origin = check_cache_origin(source, abi, fixture)
    assert origin["source_commit"] == fixture[-1]
    assert (
        origin["run_id"] == 1001
        and origin["job_id"] == 2001
        and origin["run_attempt"] == 1
    )
    assert origin["job_conclusion"] == "failure"
    assert (
        origin["sdk_build_step"]["conclusion"]
        == origin["cache_save_step"]["conclusion"]
        == "success"
    )


@pytest.mark.parametrize(
    "change",
    ["sdk-failed", "save-failed", "outside-window", "wrong-key", "wrong-workflow"],
)
def test_scoped_cache_without_original_sdk_upload_proof_is_preserved(
    source, abi, change
):
    fixture = cache_origin_fixture(source, abi)
    key, cache, run, job, _ = fixture
    if change == "sdk-failed":
        job["steps"][0]["conclusion"] = "failure"
    elif change == "save-failed":
        job["steps"][1]["conclusion"] = "failure"
    elif change == "outside-window":
        cache["created_at"] = "2026-10-18T20:05:00Z"
    elif change == "wrong-key":
        cache["key"] = key + "forged"
    else:
        run["path"] = "other.yml"
    with pytest.raises(ValueError):
        check_cache_origin(source, abi, fixture)


def test_intermediate_producer_inherits_only_equal_merged_final_recipe_and_controls(
    source,
):
    producer = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=source, text=True
    ).strip()

    def save(name, text):
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        subprocess.run(["git", "add", "."], cwd=source, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=f@invalid",
                "commit",
                "-qm",
                "change",
            ],
            cwd=source,
            check=True,
        )
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source, text=True
        ).strip()

    final = save("apps/desktop/lib/ui.dart", "Dart-only final change")
    run = {
        "head_sha": producer,
        "event": "pull_request",
        "pull_requests": [{"number": 119}],
    }

    def api(repository, route):
        if route == "pulls/119":
            return {
                "merged_at": "now",
                "head": {"sha": final, "repo": {"full_name": REPOSITORY}},
                "base": {"repo": {"full_name": REPOSITORY}},
            }
        return {"status": "ahead"}

    with (
        patch.object(sdk.artifacts, "api", side_effect=api),
        patch.object(sdk.artifacts, "merged_source", return_value=True),
    ):
        assert sdk.approved_final(REPOSITORY, run, source, "address")
        final = save("tools/new_control.py", "producer control changed")
        assert not sdk.approved_final(REPOSITORY, run, source, "address")


@pytest.mark.parametrize(
    "addition", ['\nstr = "shadow"\n', "\ndef run(*args, **kwargs): pass\n"]
)
def test_duplicate_and_builtin_shadow_imports_fail_closed(addition):
    with pytest.raises(ValueError):
        sdk.macos_projection(
            (sdk.ROOT / "tools/build_macos_sdk.py").read_bytes() + addition.encode()
        )


def test_job_environment_toolchain_override_changes_identity(source):
    original = sdk.recipe(source, "address")
    path = source / sdk.WORKFLOW
    workflow = yaml.safe_load(path.read_text())
    workflow["jobs"][sdk.JOBS["address"]]["env"] = {
        "CMAKE_TOOLCHAIN_FILE": "/tmp/other.cmake"
    }
    path.write_text(yaml.safe_dump(workflow))
    assert sdk.recipe(source, "address") != original


def test_symlinked_prefix_is_rejected_before_following_or_running_tools(
    source, abi, tmp_path
):
    physical = tmp_path / "physical"
    installed(source, physical, abi)
    link = tmp_path / "link"
    link.symlink_to(physical, target_is_directory=True)
    with patch.object(sdk, "environment") as collect:
        with pytest.raises(ValueError, match="symlinks"):
            sdk.restore(
                source, "address", link, REPOSITORY, 119, "key", cache_hit="true"
            )
        collect.assert_not_called()


def test_reviewed_main_artifact_reuses_across_110_unrelated_tool_changes(
    source, abi, producer, tmp_path
):
    (source / "tools/other_application_hardening.py").write_text(
        "unrelated consumer tool change"
    )
    assert (
        find_fixture(source, abi, producer, tmp_path / "cross-pr-reuse")[
            "compiled_from"
        ]
        == producer[0]["compiled_from"]
    )


def test_unmerged_own_pr_control_drift_cannot_forge_previous_producer(
    source, abi, producer, tmp_path
):
    producer[1].update(
        event="pull_request", head_branch="topic", pull_requests=[{"number": 119}]
    )
    (source / "tools/other_application_hardening.py").write_text(
        "unreviewed control change"
    )
    with (
        patch.object(sdk.artifacts, "merged_source", return_value=False),
        patch.object(sdk, "approved_final", return_value=False),
    ):
        assert (
            find_fixture(source, abi, producer, tmp_path / "own-rejected", own_pr=119)
            is None
        )


def test_cmake_toolchain_environment_override_rejected_before_commands(
    monkeypatch, tmp_path
):
    monkeypatch.setenv("CMAKE_TOOLCHAIN_FILE", "/tmp/output-changing.cmake")
    with patch.object(sdk.subprocess, "check_output") as command:
        with pytest.raises(ValueError, match="override"):
            sdk.environment("address", tmp_path / "prefix")
        command.assert_not_called()


@pytest.mark.parametrize("cache_hit", ["false", "true"])
def test_unqualified_existing_cache_never_executes_prefix_tools(
    source, abi, tmp_path, cache_hit
):
    prefix = tmp_path / "unqualified"
    prefix.mkdir()
    with (
        patch.object(sdk, "environment", return_value=abi),
        patch.object(sdk, "cache_origin", side_effect=ValueError("bad provenance")),
        patch.object(sdk, "verify_installed") as execute,
    ):
        with pytest.raises(ValueError):
            sdk.restore(
                source, "address", prefix, REPOSITORY, 119, "key", cache_hit=cache_hit
            )
        execute.assert_not_called()
