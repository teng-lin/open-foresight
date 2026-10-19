"""Corrupt sanitizer transports preserve prior work and fail qualification."""

import copy
import io
import json
import os
import tarfile
import zipfile
from unittest.mock import Mock

import pytest
import yaml
from test_ci_sanitizer_artifacts import (
    abi as abi,
    source as source,
    producer as producer,
    sdk,
    REPOSITORY,
    cache_origin_fixture,
    installed,
    find_fixture,
)


@pytest.fixture(autouse=True, params=[None, "refs/heads/main", "refs/pull/987/merge"])
def ci_context(request, monkeypatch):
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_RUN_ID", "1234")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    if request.param:
        monkeypatch.setenv("GITHUB_REF", request.param)
    else:
        monkeypatch.delenv("GITHUB_REF", raising=False)


@pytest.mark.parametrize(
    "body,message",
    [
        ("@decorator\ndef extra(): pass\n", "decorator"),
        ("def extra(value: str): pass\n", "annotations"),
        ("ROOT = 'other'\n", "root"),
        ("def imported(): return missing_global\n", "global"),
        ("def imported():\n def nested(): pass\n return nested\n", "nested"),
        ("def imported(): return globals()\n", "Opaque"),
    ],
)
def test_recipe_projection_rejects_opaque_imported_control(body, message, monkeypatch):
    monkeypatch.setattr(sdk, "IMPORTED", ("imported",))
    with pytest.raises(ValueError, match=message):
        sdk.macos_projection(body.encode())


def test_missing_build_step_and_unknown_profile_fail_before_sdk_tools(
    source, abi, monkeypatch, tmp_path
):
    path = source / sdk.WORKFLOW
    workflow = yaml.safe_load(path.read_text())
    workflow["jobs"][sdk.JOBS["address"]]["steps"] = []
    path.write_text(yaml.safe_dump(workflow))
    with pytest.raises(ValueError, match="recipe steps"):
        sdk.recipe(source, "address")
    profile = source / "tools/sanitizer_toolchain_profiles.json"
    profile.write_text('{"schema":2}')
    with pytest.raises(ValueError, match="toolchain profile"):
        sdk.verify_environment_profile(source, "address", tmp_path / "sdk")


@pytest.mark.parametrize("failure", ["outside-link", "fifo", "absent", "stamp"])
def test_unqualified_installed_prefix_never_executes_its_tools(
    source, abi, tmp_path, monkeypatch, failure
):
    prefix = tmp_path / "sdk"
    installed(source, prefix, abi)
    if failure == "outside-link":
        (prefix / "outside").symlink_to(tmp_path)
    elif failure == "fifo":
        os.mkfifo(prefix / "pipe")
    elif failure == "stamp":
        (prefix / "sanitizer-sdk.json").write_text("{}")
    command = Mock(side_effect=AssertionError("unqualified SDK executed"))
    monkeypatch.setattr(sdk.subprocess, "check_output", command)
    with pytest.raises(ValueError):
        sdk.verify_installed(
            source,
            "address",
            tmp_path / "absent" if failure == "absent" else prefix,
            abi,
        )
    command.assert_not_called()


@pytest.mark.parametrize("failure", ["existing", "budget", "root", "inventory"])
def test_archive_restore_rejects_corruption_without_installing(
    source, abi, producer, tmp_path, monkeypatch, failure
):
    receipt, _, _, _, directory = producer
    receipt = copy.deepcopy(receipt)
    destination = tmp_path / "destination"
    if failure == "existing":
        destination.mkdir()
        (destination / "keep").write_bytes(b"successful work")
    elif failure == "budget":
        monkeypatch.setattr(sdk, "MAX_BYTES", 1)
    elif failure == "root":
        with tarfile.open(directory / "payload.tar.gz", "w:gz") as archive:
            entry = tarfile.TarInfo("other/file")
            entry.size = 1
            archive.addfile(entry, io.BytesIO(b"x"))
        receipt["sha256"] = sdk.artifacts.digest(directory / "payload.tar.gz")
    else:
        receipt["files"] = {}
    with pytest.raises(ValueError):
        sdk.unpack_verified(directory, destination, receipt)
    if failure == "existing":
        assert (destination / "keep").read_bytes() == b"successful work"
    else:
        assert not destination.exists()


@pytest.mark.parametrize(
    "failure", ["fork", "recipe", "members", "digest", "payload-budget"]
)
def test_artifact_failures_do_not_replace_current_prefix(
    source, abi, producer, tmp_path, monkeypatch, failure
):
    receipt, run, artifact, job, output = producer
    if failure == "fork":
        run["repository"]["full_name"] = "fork/repo"
    elif failure == "recipe":
        (source / "packaging/sanitizer-grpc.cmake").write_text("different recipe")
    elif failure == "digest":
        receipt["sha256"] = "not-a-digest"
    elif failure == "payload-budget":
        monkeypatch.setattr(sdk, "MAX_BYTES", 1)
    destination = tmp_path / "restored"
    if failure == "members":

        def download(repository, metadata, path):
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("unexpected", b"bad")

        monkeypatch.setattr(
            sdk.artifacts,
            "api",
            lambda repo, route: (
                {"artifacts": [artifact]} if "actions/artifacts?" in route else run
            ),
        )
        monkeypatch.setattr(sdk.artifacts, "dependency_jobs", lambda *a: [job])
        monkeypatch.setattr(sdk.artifacts, "download_zip", download)
        with pytest.raises(ValueError, match="artifact members"):
            sdk.find(
                REPOSITORY,
                "address",
                sdk.recipe(source, "address"),
                abi,
                source,
                110,
                destination,
            )
    elif failure in ("fork", "recipe"):
        assert find_fixture(source, abi, producer, destination) is None
    else:
        with pytest.raises(ValueError):
            find_fixture(source, abi, producer, destination)
    assert not destination.exists()
    assert (tmp_path / "prefix/lib/libprotobufd.so").is_symlink()


def test_recovered_artifact_is_verified_before_publication(
    source, abi, producer, monkeypatch, tmp_path
):
    prefix = tmp_path / "restored"
    monkeypatch.setattr(sdk, "environment", lambda *a: abi)
    result = find_fixture(
        source,
        abi,
        producer,
        prefix,
        operation=lambda: sdk.restore(
            source, "address", prefix, REPOSITORY, 110, "unused"
        ),
    )
    assert sdk.inventory(prefix) == sdk.inventory(tmp_path / "prefix")
    assert (
        json.loads(open(result["qualification"]).read())["origin"]["kind"]
        == "verified-artifact"
    )
    output = tmp_path / "new-artifact"
    output.mkdir()
    with pytest.raises(ValueError, match="absent sanitizer artifact"):
        sdk.pack(source, "address", prefix, output)
    monkeypatch.setattr(sdk, "environment", lambda *a: {**abi, "compiler": "changed"})
    with pytest.raises(ValueError, match="inputs changed"):
        sdk.pack(source, "address", prefix, tmp_path / "other")


@pytest.mark.parametrize(
    "failure",
    ["key", "foreign-pr", "main-event", "job", "recipe", "controls", "log", "checkout"],
)
def test_cache_origin_requires_original_build_save_and_checkout(
    source, abi, monkeypatch, tmp_path, failure
):
    reference = "refs/heads/main" if failure == "main-event" else "refs/pull/119/merge"
    key, cache, run, job, commit = cache_origin_fixture(source, abi, reference)
    monkeypatch.setenv("GITHUB_REF", reference)
    if failure == "foreign-pr":
        run["pull_requests"] = [{"number": 120}]
    elif failure == "main-event":
        run["event"] = "pull_request"
    elif failure == "job":
        job["status"] = "in_progress"
    elif failure == "key":
        key = "wrong-compiler-key"
    original_recipe = sdk.recipe
    if failure == "recipe":
        monkeypatch.setattr(
            sdk, "recipe", lambda root, kind, source=None: {"source": source}
        )
    if failure == "controls":
        monkeypatch.setattr(
            sdk, "control_closure", lambda root, source=None: {"source": source}
        )
        monkeypatch.setattr(sdk.artifacts, "merged_source", lambda *a: False)
        monkeypatch.setattr(sdk, "approved_final", lambda *a: False)
    checkout = "0" * 40 if failure == "checkout" else commit
    log = (
        "no checkout proof"
        if failure == "log"
        else f"git log -1 --format=%H\nTIMESTAMP {checkout}\n"
    )
    previous = sdk.subprocess.check_output

    def request(command, **kw):
        if command[:2] == ["gh", "api"]:
            return "Usage: gh api" if command[-1] == "--help" else log
        return previous(command, **kw)

    monkeypatch.setattr(sdk.subprocess, "check_output", request)
    monkeypatch.setattr(
        sdk.artifacts,
        "api",
        lambda repo, route: (
            {"actions_caches": [cache]}
            if route.startswith("actions/caches?")
            else {"workflow_runs": [run]}
        ),
    )
    monkeypatch.setattr(sdk.artifacts, "dependency_jobs", lambda *a: [job])
    if failure == "checkout":
        monkeypatch.setattr(sdk, "ensure_commit", lambda *a: None)
        monkeypatch.setattr(
            sdk,
            "recipe",
            lambda root, kind, source=None: (
                {"changed": True}
                if source == checkout
                else original_recipe(root, kind, source)
            ),
        )
    with pytest.raises((ValueError, sdk.CacheProducerNotFound)):
        sdk.cache_origin(source, "address", REPOSITORY, 119, key, abi)
    assert (tmp_path / "source").is_dir()
