"""Incremental stage reuse retains compiler products while validating current work."""

import json
import sys
from unittest.mock import Mock
import zipfile

import pytest
from tools import ci_stage_cache as cache
from tools import ci_stage_artifacts as payloads
from tools import run_ci_stage as runner
import test_ci_stage_cache as fixtures


@pytest.fixture
def producer():
    case = fixtures.ProducerTests()
    case.setUp()
    try:
        yield case
    finally:
        case.doCleanups()


@pytest.mark.parametrize("changed", [False, True])
def test_runner_restores_compilation_and_only_refreshes_changed_configuration(
    producer, tmp_path, monkeypatch, changed, capsys
):
    case = producer
    case.write(".gitignore", "build/\n")
    case.save()
    objects = {
        "build/_deps/vendor/object.o": b"retained expensive object",
        "build/native/libforesight_native.so": b"native",
        "build/CMakeCache.txt": b"old configuration",
    }
    for name, data in objects.items():
        case.write(name, data.decode())
    # Keep the archive outside the tracked source tree.
    packed = tmp_path / "payload"
    manifest = payloads.pack(case.root, "linux", "native", packed)
    monkeypatch.setattr(cache, "find", lambda *a: {"hit": False})
    monkeypatch.setattr(
        cache,
        "find_native_work",
        lambda *a: {
            "hit": True,
            "run_id": 100,
            "download_dir": str(packed),
            "receipt": {"content": manifest},
            "configuration_changed": ["CMakeLists.txt"] if changed else [],
        },
    )

    def execute(root, platform, stage, hit, cmake_args):
        assert hit is False  # Reusing objects never reuses a green test result.
        assert (root / "build/_deps/vendor/object.o").read_bytes() == objects[
            "build/_deps/vendor/object.o"
        ]
        assert (root / "build/CMakeCache.txt").exists() is not changed

    monkeypatch.setattr(runner, "execute", execute)
    monkeypatch.setenv("GITHUB_OUTPUT", str(case.root / "build/github-output"))
    result = runner.run(
        case.root,
        "linux",
        "native",
        fixtures.ENVIRONMENT,
        {},
        {},
        fixtures.REPOSITORY,
        110,
        "pull_request",
        False,
        [],
    )
    assert result["compilation_cache_hit"] is True and result["cache_hit"] is False
    assert (
        "compilation_cache_hit=true" in (case.root / "build/github-output").read_text()
    )
    assert ("Refresh CMake configuration" in capsys.readouterr().out) is changed


def test_service_stage_hit_restores_verified_results_without_executing_builder(
    producer, tmp_path, monkeypatch
):
    case = producer
    case.write(".gitignore", "build/\ntest-results/\n")
    case.save()
    case.write("test-results/service/fixture.json", '{"passed":true}')
    packed = tmp_path / "service"
    manifest = payloads.pack(case.root, "linux", "service", packed)
    monkeypatch.setattr(
        cache,
        "find",
        lambda *a: {
            "hit": True,
            "download_dir": str(packed),
            "run_id": 100,
            "receipt": {"content": manifest},
        },
    )
    restore = Mock()
    execute = Mock()
    monkeypatch.setattr(runner, "restore_input", restore)
    monkeypatch.setattr(runner, "execute", execute)
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    parents = {"native": "a" * 64}
    inputs = {"native": tmp_path / "native"}
    result = runner.run(
        case.root,
        "linux",
        "service",
        fixtures.ENVIRONMENT,
        parents,
        inputs,
        fixtures.REPOSITORY,
        110,
        "pull_request",
        False,
        [],
    )
    restore.assert_called_once()
    assert restore.call_args.args[2] == "native"
    assert result["cache_hit"] is True and result["compilation_cache_hit"] is False
    assert execute.call_args.args[2:4] == ("service", True)
    assert (
        case.root / "test-results/service/fixture.json"
    ).read_text() == '{"passed":true}'


def test_native_work_restores_real_zip_and_receipt_to_requested_directory(producer):
    destination = producer.root / "restored"
    result = producer.find_work(output=destination)
    assert result["hit"] is True
    assert (destination / "payload.tar.gz").read_bytes() == producer.payload
    assert json.loads((destination / "identity.json").read_text()) == producer.receipt


@pytest.mark.parametrize("failure", ["members", "size"])
def test_malformed_small_metadata_cannot_authorize_cold_build(
    producer, monkeypatch, failure
):
    case = producer
    metadata = case.add_metadata(case.artifact, case.receipt)
    if failure == "members":
        case.members["unexpected"] = b"untrusted"
    else:
        metadata["size_in_bytes"] = 1
        monkeypatch.setattr(cache.retained, "MAX_STAGE_RECEIPT_BYTES", 1)
    result = case.find_work()
    assert result["hit"] is False and result["rejected_payloads"] == 1
    assert case.downloaded_ids == [metadata["id"]]


@pytest.mark.parametrize("failure", ["json", "size"])
def test_bad_cached_receipt_keeps_destination_absent(tmp_path, monkeypatch, failure):
    archive = tmp_path / "cached.zip"
    with zipfile.ZipFile(archive, "w") as stream:
        stream.writestr("identity.json", b"not JSON")
        stream.writestr("payload.tar.gz", b"verified payload")
    if failure == "size":
        monkeypatch.setattr(cache.retained, "MAX_STAGE_RECEIPT_BYTES", 1)
    destination = tmp_path / "restored"
    with pytest.raises(ValueError):
        cache.read_zip(archive, destination)
    assert not destination.exists()


def test_identity_rejects_mutable_refs_platforms_and_payload_kinds(producer):
    with pytest.raises(ValueError, match="full commit"):
        cache.source_inputs(producer.root, "native", "main")
    with pytest.raises(ValueError, match="platform or stage"):
        cache.fingerprint("other", "native", producer.root)
    with pytest.raises(ValueError, match="artifact identity"):
        cache.name("linux", "native", "mutable")
    with pytest.raises(ValueError, match="payload kind"):
        cache.publish(
            "linux", "core", producer.root, {}, {}, None, None, payload_kind="native"
        )
    producer.receipt["sha256"] = "not-a-checksum"
    with pytest.raises(ValueError, match="payload checksum"):
        cache.validate_receipt(
            producer.receipt,
            "linux",
            "native",
            producer.identity,
            producer.run,
            fixtures.ENVIRONMENT,
            {},
            producer.root,
        )


@pytest.mark.parametrize("failure", ["unexpected-input", "wrong-parents"])
def test_runner_rejects_prerequisite_mismatch_before_cache_lookup(
    tmp_path, monkeypatch, failure
):
    monkeypatch.setattr(cache, "git", lambda *a: b"a" * 40)
    find = Mock(side_effect=AssertionError("must not look up cache"))
    monkeypatch.setattr(cache, "find", find)
    with pytest.raises(ValueError):
        runner.run(
            tmp_path,
            "linux",
            "core",
            {"compiler": "verified"},
            {},
            {"unexpected": tmp_path} if failure == "unexpected-input" else {},
            "repo",
            1,
            "pull_request",
            False,
            [],
        )
    find.assert_not_called()


def test_stage_cli_accepts_current_environment_without_prerequisites(
    tmp_path, monkeypatch, capsys
):
    env = tmp_path / "environment.json"
    env.write_text('{"compiler":"verified"}')
    monkeypatch.setenv("FORESIGHT_STAGE_ENVIRONMENT", str(env))
    monkeypatch.setattr(
        sys,
        "argv",
        ["run", "--platform", "linux", "--stage", "native", "--event", "pull_request"],
    )
    run = Mock(return_value={"cache_hit": True})
    monkeypatch.setattr(runner, "run", run)
    runner.main()
    assert json.loads(capsys.readouterr().out) == {"cache_hit": True}
    assert run.call_args.args[5] == {}
