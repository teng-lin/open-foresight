"""Validation identity includes real SDK bytes and secret-safe process settings."""

from datetime import datetime, timezone
import json
import os
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from tools import ci_stage_environment as environment
from tools.ci_stage_cache import compilation_environment, fingerprint

NOW = datetime(2026, 10, 18, 12, tzinfo=timezone.utc)


def context(values):
    with patch.dict(os.environ, values, clear=True):
        return environment.validation_context(now=NOW)


def stage_identity(root, context):
    return fingerprint(
        "linux", "native", root, environment={"compiler": "fixture", **context}
    )


@pytest.fixture
def repository(tmp_path):
    import subprocess

    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, timeout=30)
    return tmp_path


@pytest.mark.parametrize(
    "key,value",
    [
        ("LANG", "C.UTF-8"),
        ("LC_ALL", "C.UTF-8"),
        ("LC_TIME", "C.UTF-8"),
        ("TZ", "Pacific/Honolulu"),
        ("CI", "true"),
        ("FORESIGHT_MACOS_UI_TEST", "1"),
        ("FORESIGHT_NEW_VALIDATION_SETTING", "enabled"),
        ("HTTP_PROXY", "http://proxy.example:8080"),
        ("https_proxy", "http://proxy.example:8080"),
        ("ALL_PROXY", "socks5://proxy.example:1080"),
        ("no_proxy", "localhost"),
    ],
)
def test_locale_timezone_flags_and_proxies_invalidate_validation(
    repository, key, value
):
    assert stage_identity(repository, context({})) != stage_identity(
        repository, context({key: value})
    )


def test_sensitive_validation_values_are_never_written_in_plaintext():
    secrets = {
        "FORESIGHT_WEB_CONTENT_API_KEY": "fixture-private-api-key",
        "FORESIGHT_GOOGLE_CLIENT_JSON": '{"client_secret":"private-oauth-value"}',
        "https_proxy": "http://private-user:private-password@example.test:8080",
    }
    record = context({**secrets, "CI": "true"})
    serialized = json.dumps(record)
    for value in secrets.values():
        assert value not in serialized
    assert "private-password" not in serialized
    for value in record["validation_environment_sha256"].values():
        assert len(value) == 64
    assert set(record["validation_environment_sha256"]) == {*secrets, "CI"}


def test_source_commit_and_volatile_github_job_variables_are_excluded():
    assert context({"GITHUB_SHA": "first", "GITHUB_JOB": "one"}) == context(
        {"GITHUB_SHA": "second", "GITHUB_JOB": "two"}
    )


@pytest.mark.parametrize("value", ["0", "1"])
def test_core_benchmark_option_does_not_discard_native_validation_or_compiler_work(
    repository, value
):
    baseline = context({})
    measured = context({"FORESIGHT_CORE_COVERAGE_BENCHMARK": value})
    assert baseline == measured
    assert stage_identity(repository, baseline) == stage_identity(repository, measured)
    assert compilation_environment(baseline) == compilation_environment(measured)
    # Normalize compatible historical receipts without rewriting their bytes.
    historical = {
        **measured,
        "validation_environment_sha256": {
            "FORESIGHT_CORE_COVERAGE_BENCHMARK": "a" * 64
        },
    }
    assert compilation_environment(historical) == compilation_environment(baseline)
    assert historical["validation_environment_sha256"] == {
        "FORESIGHT_CORE_COVERAGE_BENCHMARK": "a" * 64
    }


@pytest.mark.parametrize("key", ["CC", "CXX"])
def test_unrecorded_compiler_override_is_rejected_before_cache_use(key):
    with pytest.raises(ValueError, match="CC/CXX overrides"):
        environment.reject_compiler_overrides({key: "/another/compiler"})
    environment.reject_compiler_overrides({key: ""})


def test_effective_locale_timezone_and_daily_validation_window_are_recorded():
    first = environment.validation_context(environment={}, now=NOW)
    second = environment.validation_context(environment={}, now=NOW.replace(day=19))
    assert first["utc_validation_date"] == "2026-10-18"
    assert second["utc_validation_date"] == "2026-10-19"
    assert first != second
    assert first["locale"]["effective"]
    assert isinstance(first["timezone"]["names"], list)
    assert isinstance(first["timezone"]["current_offset_seconds"], (int, float))


@pytest.fixture
def sdk(tmp_path):
    prefix = tmp_path / "sdk"
    (prefix / "lib").mkdir(parents=True)
    (prefix / "lib/libfixture.a").write_bytes(b"original library")
    (prefix / "include").mkdir()
    (prefix / "include/fixture.h").write_bytes(b"original header")
    return prefix


def test_sdk_content_includes_file_bytes_mode_names_and_internal_links(sdk):
    first = environment.sdk_content_digest(sdk)
    library = sdk / "lib/libfixture.a"
    library.write_bytes(b"different library")
    assert environment.sdk_content_digest(sdk) != first
    library.write_bytes(b"original library")
    assert environment.sdk_content_digest(sdk) == first
    library.chmod(0o755)
    assert environment.sdk_content_digest(sdk) != first
    library.chmod(0o644)
    link = sdk / "alias"
    link.symlink_to("lib")
    linked = environment.sdk_content_digest(sdk)
    library.write_bytes(b"changed linked directory contents")
    assert environment.sdk_content_digest(sdk) != linked
    library.write_bytes(b"original library")
    link.unlink()
    link.symlink_to("include")
    assert environment.sdk_content_digest(sdk) != linked


@pytest.mark.parametrize("target", ["../outside", "/tmp/outside"])
def test_sdk_links_cannot_escape_the_consumed_sdk_tree(sdk, target):
    outside = sdk.parent / "outside"
    outside.write_bytes(b"outside content")
    if target.startswith("/"):
        target = str(outside)
    (sdk / "unsafe").symlink_to(target)
    with pytest.raises(ValueError, match="escapes"):
        environment.sdk_content_digest(sdk)


def test_sdk_dangling_links_and_special_files_fail_closed(sdk):
    broken = sdk / "broken"
    broken.symlink_to("absent")
    with pytest.raises(FileNotFoundError):
        environment.sdk_content_digest(sdk)
    broken.unlink()
    os.mkfifo(sdk / "fifo")
    with pytest.raises(ValueError, match="special file"):
        environment.sdk_content_digest(sdk)


def test_consumed_sdk_mutation_changes_environment_even_with_fixed_recipe(
    repository, sdk
):
    (repository / "tools").mkdir()
    (repository / "tools/pins.json").write_text("{}")
    with (
        patch.object(environment, "version", return_value="fixed toolchain versions"),
        patch.object(
            environment.importlib,
            "import_module",
            return_value=SimpleNamespace(fingerprint=lambda *args: "a" * 64),
        ),
    ):
        first = environment.collect("macos", root=repository, sdk_prefix=sdk)
        (sdk / "include/fixture.h").write_bytes(b"modified compile input")
        second = environment.collect("macos", root=repository, sdk_prefix=sdk)
    assert first["sdk"]["identity"] == second["sdk"]["identity"]
    assert first["sdk"]["content_sha256"] != second["sdk"]["content_sha256"]
    assert first != second
