"""The stage runner must validate prerequisites before trusting cached work."""

import hashlib
import json
import subprocess
from unittest.mock import patch

import pytest

from tools import run_ci_stage as runner


def input_artifact(directory, source="a" * 40, identity="b" * 64):
    directory.mkdir()
    (directory / "payload.tar.gz").write_bytes(b"payload")
    receipt = {
        "platform": "linux",
        "stage": "native",
        "payload_kind": "native-runtime",
        "source_commit": source,
        "identity": identity,
        "sha256": hashlib.sha256(b"payload").hexdigest(),
        "content": {"files": {"fixture": {}}},
    }
    (directory / "identity.json").write_text(json.dumps(receipt))
    return receipt


@pytest.mark.parametrize(
    "field,value",
    [
        ("source_commit", "c" * 40),
        ("identity", "d" * 64),
        ("stage", "desktop"),
        ("platform", "macos"),
        ("payload_kind", "native"),
        ("sha256", "0" * 64),
    ],
)
def test_same_run_wrong_or_corrupt_parent_is_rejected_before_unpack(
    tmp_path, field, value
):
    directory = tmp_path / "input"
    receipt = input_artifact(directory)
    receipt[field] = value
    (directory / "identity.json").write_text(json.dumps(receipt))
    with patch.object(runner.payloads, "unpack") as unpack:
        with pytest.raises(ValueError):
            runner.restore_input(
                tmp_path, "linux", "native", directory, "b" * 64, "a" * 40
            )
    unpack.assert_not_called()


def test_same_run_valid_parent_is_unpacked_only_after_receipt_check(tmp_path):
    directory = tmp_path / "input"
    receipt = input_artifact(directory)
    with patch.object(runner.payloads, "unpack") as unpack:
        runner.restore_input(tmp_path, "linux", "native", directory, "b" * 64, "a" * 40)
    unpack.assert_called_once_with(
        tmp_path,
        "linux",
        "native-runtime",
        directory / "payload.tar.gz",
        receipt["content"],
    )


def test_native_hit_relinks_revision_and_checks_actual_compiled_identity(tmp_path):
    with (
        patch.object(runner.subprocess, "run") as command,
        patch.object(
            runner.subprocess,
            "check_output",
            return_value="open-foresight-0.1.1-aaaaaaaaaaaa\n",
        ) as identity,
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch("tools.app_version.read_version", return_value=("0.1.1", 1)),
    ):
        runner.execute(tmp_path, "linux", "native", True, ["-G", "Ninja"])
    assert command.call_count == 2
    assert command.call_args_list[0].args[0][0] == "cmake"
    assert command.call_args_list[1].args[0][:2] == ["cmake", "--build"]
    identity.assert_called_once()
    assert identity.call_args.args[0][-1] == "--build-id"


def test_native_hit_cannot_republish_stale_compiled_revision(tmp_path):
    with (
        patch.object(runner.subprocess, "run"),
        patch.object(
            runner.subprocess,
            "check_output",
            return_value="open-foresight-0.1.1-bbbbbbbbbbbb\n",
        ),
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch("tools.app_version.read_version", return_value=("0.1.1", 1)),
    ):
        with pytest.raises(ValueError, match="helper identity mismatch"):
            runner.execute(tmp_path, "linux", "native", True, [])


@pytest.mark.parametrize("stage", ["core", "desktop", "service"])
def test_verified_language_stage_hit_does_not_rerun_tests_or_compile(tmp_path, stage):
    with patch.object(runner.subprocess, "run") as command:
        runner.execute(tmp_path, "linux", stage, True, [])
    command.assert_not_called()


@pytest.mark.parametrize("stage", ["core", "desktop", "service"])
def test_language_miss_runs_its_selected_stage_only(tmp_path, stage):
    with patch.object(runner.subprocess, "run") as command:
        runner.execute(tmp_path, "linux", stage, False, [])
    assert command.call_args.args[0][-2:] == ["--stage", stage]


def test_missing_parent_never_looks_up_cached_green_result(tmp_path):
    with (
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(runner.cache, "find") as find,
    ):
        with pytest.raises(ValueError, match="requires input artifacts"):
            runner.run(
                tmp_path,
                "linux",
                "core",
                {"compiler": "fixture"},
                {"native": "b" * 64},
                {},
                "repo",
                1,
                "pull_request",
                False,
                [],
            )
    find.assert_not_called()


def test_runner_does_not_expose_validation_environment_in_receipt(
    tmp_path, monkeypatch
):
    secret = "private-build-setting"
    monkeypatch.setenv("FORESIGHT_COVERAGE", secret)
    monkeypatch.setenv("CFLAGS", secret)
    with (
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(
            runner.cache, "fingerprint", side_effect=RuntimeError("captured")
        ) as fingerprint,
    ):
        with pytest.raises(RuntimeError, match="captured"):
            runner.run(
                tmp_path,
                "linux",
                "native",
                {},
                {},
                {},
                "repo",
                1,
                "pull_request",
                False,
                [],
            )
    environment = fingerprint.call_args.kwargs["environment"]
    assert secret not in json.dumps(environment)
    digest = hashlib.sha256(secret.encode()).hexdigest()
    assert environment["validation_flags"]["FORESIGHT_COVERAGE"] == digest
    assert environment["validation_flags"]["CFLAGS"] == digest


@pytest.mark.parametrize(
    "stage,enabled",
    [("native", False), ("native", True), ("core", False), ("core", True)],
)
def test_benchmark_flag_binds_only_enabled_core_validation(
    tmp_path, monkeypatch, stage, enabled
):
    monkeypatch.setenv("FORESIGHT_CORE_COVERAGE_BENCHMARK", "1" if enabled else "0")
    collected = runner.stage_environment.validation_context()
    with (
        patch.object(runner, "restore_input"),
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(
            runner.cache, "fingerprint", side_effect=RuntimeError("captured")
        ) as fingerprint,
    ):
        with pytest.raises(RuntimeError, match="captured"):
            runner.run(
                tmp_path,
                "linux",
                stage,
                collected,
                {"native": "b" * 64} if stage == "core" else {},
                {"native": tmp_path} if stage == "core" else {},
                "repo",
                1,
                "pull_request",
                False,
                [],
            )
    flags = fingerprint.call_args.kwargs["environment"]["validation_flags"]
    assert ("FORESIGHT_CORE_COVERAGE_BENCHMARK" in flags) == (
        stage == "core" and enabled
    )


@pytest.mark.parametrize(
    "event,own_pr,branch,release",
    [("pull_request", 1, "topic", False), ("push", 0, "main", True)],
)
def test_native_runner_publishes_distinct_runtime_and_compilation_archives(
    tmp_path, monkeypatch, event, own_pr, branch, release
):
    monkeypatch.setenv("GITHUB_HEAD_REF", branch if own_pr else "")
    monkeypatch.setenv("GITHUB_REF_NAME", "unused-merge-ref" if own_pr else branch)
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, timeout=30)
    (tmp_path / ".gitignore").write_text("build/\n")
    (tmp_path / "native.cpp").write_text("implementation")
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True, timeout=30)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.test",
            "commit",
            "-qm",
            "fixture",
        ],
        cwd=tmp_path,
        check=True,
        timeout=30,
    )

    def build(*args):
        for name in (
            "build/services/helper/ForesightHelper",
            "build/services/helper/ForesightHelperTest",
            "build/native/libforesight_native.so",
            "build/native/libforesight_sql_support.so",
            "build/native/libforesight_sql_support.dylib",
            "build/native/libforesight_diagnostic_support.so",
            "build/native/libforesight_diagnostic_support.dylib",
            "build/native/foresight-diagnostic-launcher",
            "build/native/diagnostic-native-inputs.json",
            "build/native/diagnostic-toolchain-metadata.json",
            "build/native/diagnostic-products.json",
            "build/native/diagnostic-sql-inputs.json",
            "build/native/runtime-support-build.json",
            "build/_deps/compiler/object.o",
        ):
            target = tmp_path / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(name.encode())

    with (
        patch.object(runner.cache, "find", return_value={"hit": False}),
        patch.object(
            runner.cache, "find_native_work", return_value={"hit": False}
        ) as work,
        patch.object(runner, "execute", side_effect=build) as execute,
    ):
        result = runner.run(
            tmp_path,
            "linux",
            "native",
            {"compiler": "fixture"},
            {},
            {},
            "repo",
            own_pr,
            event,
            release,
            [],
        )
    assert work.call_args.args[4:8] == (own_pr, event, branch, release)
    assert execute.call_args.args[3] is False
    assert result["runtime_artifact_name"] == result["artifact_name"] + "-runtime"
    full = json.loads(
        (tmp_path / "build/ci-stage/linux-native/identity.json").read_text()
    )
    runtime_path = tmp_path / "build/ci-stage/linux-native-runtime"
    runtime = json.loads((runtime_path / "identity.json").read_text())
    assert full["identity"] == runtime["identity"] == result["identity"]
    assert (
        full["payload_kind"] == "native" and runtime["payload_kind"] == "native-runtime"
    )
    assert "build/_deps/compiler/object.o" in full["content"]["files"]
    assert "build/_deps/compiler/object.o" not in runtime["content"]["files"]
    target = tmp_path / "consumer"
    runner.restore_input(
        target,
        "linux",
        "native",
        runtime_path,
        result["identity"],
        runtime["source_commit"],
    )
    assert (target / "build/services/helper/ForesightHelper").is_file()
    assert (target / "build/services/helper/ForesightHelperTest").read_bytes() == (
        tmp_path / "build/services/helper/ForesightHelperTest"
    ).read_bytes()
    for relative in (
        "build/native/libforesight_sql_support.so",
        "build/native/libforesight_sql_support.dylib",
        "build/native/libforesight_diagnostic_support.so",
        "build/native/libforesight_diagnostic_support.dylib",
        "build/native/foresight-diagnostic-launcher",
        "build/native/diagnostic-native-inputs.json",
        "build/native/diagnostic-toolchain-metadata.json",
        "build/native/diagnostic-products.json",
        "build/native/diagnostic-sql-inputs.json",
        "build/native/runtime-support-build.json",
    ):
        assert (target / relative).read_bytes() == (tmp_path / relative).read_bytes()
    assert not (target / "build/_deps").exists()


def test_service_miss_builds_own_current_products_before_tests(tmp_path):
    with patch.object(runner.subprocess, "run") as command:
        runner.execute(tmp_path, "linux", "service", False, [])
    assert len(command.call_args_list) == 2
    first, second = [c.args[0] for c in command.call_args_list]
    assert first == [
        "bash",
        str(tmp_path / "tools/build.sh"),
        "--platform",
        "linux",
        "--stage",
        "core",
        "--build-only",
    ]
    assert second == [
        "bash",
        str(tmp_path / "tools/build.sh"),
        "--platform",
        "linux",
        "--stage",
        "service",
    ]
    assert all(
        c.kwargs["check"] is True and c.kwargs["timeout"] == 3600
        for c in command.call_args_list
    )


def test_failed_service_product_build_never_starts_service_tests(tmp_path):
    with patch.object(
        runner.subprocess,
        "run",
        side_effect=subprocess.CalledProcessError(7, ["controlled-build"]),
    ) as command:
        with pytest.raises(subprocess.CalledProcessError):
            runner.execute(tmp_path, "linux", "service", False, [])
    assert command.call_count == 1
    assert command.call_args.args[0][-3:] == ["--stage", "core", "--build-only"]


@pytest.mark.parametrize(
    "parents,inputs",
    [
        (
            {"native": "b" * 64, "core": "c" * 64, "desktop": "d" * 64},
            {"native": "native", "core": "old-core"},
        ),
        ({"native": "b" * 64}, {"native": "native", "core": "old-core"}),
        ({}, {}),
    ],
)
def test_service_refuses_old_test_parent_recipe_before_restore_or_cache(
    tmp_path, parents, inputs
):
    with (
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(runner, "restore_input") as restore,
        patch.object(runner.cache, "find") as find,
    ):
        with pytest.raises(ValueError, match="requires"):
            runner.run(
                tmp_path,
                "linux",
                "service",
                {"compiler": "fixture"},
                parents,
                {k: tmp_path / v for k, v in inputs.items()},
                "repo",
                1,
                "pull_request",
                False,
                [],
            )
    restore.assert_not_called()
    find.assert_not_called()


def test_service_native_only_recipe_binds_current_source_and_native_before_lookup(
    tmp_path,
):
    with (
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(runner, "restore_input") as restore,
        patch.object(
            runner.cache, "fingerprint", side_effect=RuntimeError("captured")
        ) as fingerprint,
        patch.object(runner.cache, "find") as find,
    ):
        with pytest.raises(RuntimeError, match="captured"):
            runner.run(
                tmp_path,
                "linux",
                "service",
                {"compiler": "fixture"},
                {"native": "b" * 64},
                {"native": tmp_path / "native"},
                "repo",
                1,
                "pull_request",
                False,
                [],
            )
    restore.assert_called_once_with(
        tmp_path, "linux", "native", tmp_path / "native", "b" * 64, "a" * 40
    )
    assert fingerprint.call_args.kwargs["parents"] == {"native": "b" * 64}
    find.assert_not_called()


def test_old_service_test_parent_identity_cannot_equal_native_only_source_build(
    tmp_path,
):
    from tools import ci_native_cache

    with patch.object(
        ci_native_cache,
        "source_inputs",
        return_value={"public-source": ["100644", "blob", "a" * 40]},
    ):
        common = {"environment": {"compiler": "controlled"}, "root": tmp_path}
        old = runner.cache.fingerprint(
            "linux",
            "service",
            parents={"native": "b" * 64, "core": "c" * 64, "desktop": "d" * 64},
            **common,
        )
        current = runner.cache.fingerprint(
            "linux", "service", parents={"native": "b" * 64}, **common
        )
    assert current != old


def test_service_cache_hit_reuses_verified_result_without_claiming_fresh_products(
    tmp_path, monkeypatch
):
    native = tmp_path / "native-input"
    input_artifact(native)
    cached = tmp_path / "cached"
    cached.mkdir()
    manifest = {
        "files": {"test-results/service/results.xml": {"fixture": "verified result"}}
    }
    output = tmp_path / "build/ci-stage/linux-service"

    def pack(*args):
        output.mkdir(parents=True)
        (output / "content.json").write_text("{}")
        return manifest

    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "outputs"))
    with (
        patch.object(runner.cache, "git", return_value=b"a" * 40),
        patch.object(runner.cache, "fingerprint", return_value="d" * 64),
        patch.object(
            runner.cache,
            "find",
            return_value={
                "hit": True,
                "download_dir": str(cached),
                "run_id": 123,
                "receipt": {"content": manifest},
            },
        ) as find,
        patch.object(runner.payloads, "unpack") as unpack,
        patch.object(runner.payloads, "pack", side_effect=pack),
        patch.object(
            runner.cache,
            "publish",
            return_value={
                "identity": "d" * 64,
                "artifact_name": "verified-service-result",
            },
        ) as publish,
        patch.object(
            runner.cache, "source_inputs", return_value={"controlled": "same source"}
        ),
        patch.object(runner.subprocess, "run") as command,
    ):
        result = runner.run(
            tmp_path,
            "linux",
            "service",
            {"compiler": "controlled"},
            {"native": "b" * 64},
            {"native": native},
            "repo",
            1,
            "pull_request",
            False,
            [],
        )
    assert result["cache_hit"] is True
    assert result["compilation_cache_hit"] is False
    assert not (tmp_path / "build/application").exists()
    command.assert_not_called()
    assert find.call_args.args[3] == "d" * 64
    assert find.call_args.args[5] == {"native": "b" * 64}
    assert find.call_args.args[6] == tmp_path
    assert unpack.call_args_list[-1].args == (
        tmp_path,
        "linux",
        "service",
        cached / "payload.tar.gz",
        manifest,
    )
    assert publish.call_args.args[4] == {"native": "b" * 64}
    assert publish.call_args.args[7] == manifest
