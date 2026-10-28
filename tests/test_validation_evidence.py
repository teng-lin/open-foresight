"""The evidence summary is allowlisted, versioned and can never overstate success."""

import json
import os
from pathlib import Path
import stat
import subprocess
import time

import pytest

from tools import validation_evidence as evidence

SECRETS = {
    "FORESIGHT_CI_GOOGLE_REFRESH_TOKEN": "refresh-secret",
    "FORESIGHT_SEARCH_API_KEY": "search-secret",
    "GITHUB_TOKEN": "ghs_secret",
    "AWS_SECRET_ACCESS_KEY": "aws-secret",
    "HOME": "/home/someone",
    "PATH": "/usr/bin",
}


def check(identifier, status, **extra):
    return {
        "id": identifier, "title": identifier, "kind": "command", "scope": "host",
        "platforms": ["linux", "macos"], "status": status, **extra,
    }


def summary(mode="run", checks=None, unexecuted=(), environ=None):
    return evidence.build_summary(
        mode=mode,
        source={"mode": "explicit", "identity_sha256": "0" * 64},
        invocation={"entrypoint": "tools.validate_change", "argv": []},
        selection={"conservative": False},
        checks=[check("shared-guards", "passed")] if checks is None else checks,
        unexecuted_platforms=list(unexecuted),
        reproduction=["rerun"],
        environ=environ if environ is not None else {},
    )


def test_environment_collection_is_an_allowlist_that_never_reads_secrets():
    environ = {**SECRETS, "GITHUB_REF": "refs/pull/7/merge", "TZ": "UTC", "LANG": "C.UTF-8"}
    collected = evidence.collect_environment(environ)
    assert collected == {"GITHUB_REF": "refs/pull/7/merge", "LANG": "C.UTF-8", "TZ": "UTC"}
    assert not any("FORESIGHT_CI" in name or "TOKEN" in name for name in collected)
    # FORESIGHT_ is not a prefix rule: only exact names are ever read.
    assert all(name in evidence.ENV_ALLOWLIST for name in collected)
    assert not any(name.startswith("FORESIGHT_CI_") for name in evidence.ENV_ALLOWLIST)


def test_environment_values_are_printable_and_bounded():
    collected = evidence.collect_environment({"TZ": "a\x00b\nc", "LANG": "x" * 2000})
    assert collected["TZ"] == "a?b?c"
    assert len(collected["LANG"]) == evidence.MAX_VALUE_LENGTH + 3 and collected["LANG"].endswith("...")


def test_collection_defaults_to_the_process_environment(monkeypatch):
    monkeypatch.setenv("TZ", "Asia/Tokyo")
    monkeypatch.setenv("FORESIGHT_SEARCH_API_KEY", "secret")
    assert evidence.collect_environment()["TZ"] == "Asia/Tokyo"
    assert "FORESIGHT_SEARCH_API_KEY" not in evidence.collect_environment()


def test_account_identity_records_ids_groups_and_nss_home(monkeypatch):
    record = evidence.account_identity({"HOME": "/set/by/hand"})
    assert (record["uid"], record["gid"]) == (os.getuid(), os.getgid())
    assert record["euid"] == os.geteuid() and record["egid"] == os.getegid()
    assert {item["gid"] for item in record["groups"]} == set(os.getgroups())
    assert record["home_env_set"] is True and "/set/by/hand" not in json.dumps(record)
    # Setting HOME alone does not change the NSS account.
    assert record["home_matches_nss"] == (record["nss"]["home"] == "/set/by/hand")
    assert evidence.account_identity({})["home_env_set"] is False
    assert evidence.account_identity()["uid"] == os.getuid()
    monkeypatch.setattr(evidence.pwd, "getpwuid", lambda _: (_ for _ in ()).throw(KeyError()))
    monkeypatch.setattr(evidence.grp, "getgrgid", lambda _: (_ for _ in ()).throw(KeyError()))
    unknown = evidence.account_identity({"HOME": "/x"})
    assert unknown["nss"] == {"name": None, "home": None, "shell": None}
    assert not unknown["home_matches_nss"]
    assert all(item["name"] is None for item in unknown["groups"])


def test_temp_policy_requires_private_canonical_short_owned_roots(tmp_path, monkeypatch):
    root = Path(os.path.realpath(tmp_path)) / "t"
    root.mkdir(mode=0o700)
    monkeypatch.setattr(evidence, "SHORT_TEMP_LIMIT", len(str(root)) + 20)
    good = evidence.temp_policy({"TMPDIR": str(root), "FORESIGHT_TEST_TEMP_ROOT": str(root)})
    assert good["roots"]["TMPDIR"]["compliant"] and good["compliant"]

    shared = root.parent / "shared"
    shared.mkdir(mode=0o755)
    shared.chmod(0o755)
    loose = evidence.temp_policy({"TMPDIR": str(shared)})
    assert loose["roots"]["TMPDIR"]["private"] is False and not loose["compliant"]

    link = root.parent / "link"
    link.symlink_to(root)
    assert evidence.temp_policy({"TMPDIR": str(link)})["roots"]["TMPDIR"]["canonical"] is False

    deep = root / ("d" * 30)
    deep.mkdir(mode=0o700)
    assert evidence.temp_policy({"TMPDIR": str(deep)})["roots"]["TMPDIR"]["short"] is False

    missing = evidence.temp_policy({"TMPDIR": str(root / "absent")})
    assert missing["roots"]["TMPDIR"]["error"] == "FileNotFoundError" and not missing["compliant"]
    assert evidence.temp_policy({})["roots"]["TMPDIR"] == {"set": False}
    assert not evidence.temp_policy({})["compliant"]
    assert "umask" in evidence.temp_policy()


def test_observe_tools_records_first_line_absence_and_probe_failure():
    class Result:
        stdout = "cmake version 3.31\nmore\n"
        stderr = ""
        returncode = 0

    def run(argv, **kwargs):
        assert kwargs["timeout"] == 30 and not kwargs["check"]
        if argv[0] == "/bin/ninja":
            raise subprocess.TimeoutExpired(argv, 30)
        if argv[0] == "/bin/protoc":
            return type("Empty", (), {"stdout": "", "stderr": "", "returncode": 0})()
        if argv[0] == "/bin/dart":
            return type("Broken", (), {"stdout": "", "stderr": "dart: bad flag\n", "returncode": 64})()
        return Result()

    paths = {"cmake": "/bin/cmake", "ninja": "/bin/ninja", "protoc": "/bin/protoc", "dart": "/bin/dart"}
    observed = evidence.observe_tools(("cmake", "ninja", "protoc", "dart", "git"), run=run, which=lambda name: paths.get(name))
    assert observed["cmake"] == "cmake version 3.31"
    assert observed["ninja"] == "probe failed: TimeoutExpired"
    assert observed["protoc"] == "" and observed["git"] is None
    # A failing probe is a probe failure, never a version.
    assert observed["dart"] == "probe failed: exit 64: dart: bad flag"
    assert observed["python"]
    assert "git" in evidence.observe_tools(("git",))


def test_host_identity_names_a_supported_platform_or_the_raw_one():
    assert evidence.host_identity()["platform"] in ("linux", "macos") or evidence.host_identity()["platform"]


def test_junit_counts_only_fresh_reports(tmp_path):
    report = tmp_path / "r.xml"
    assert evidence.junit_counts(report, 0) == {"path": str(report), "present": False}
    report.write_text('<testsuites><testsuite tests="5" failures="1" errors="0" skipped="2"/><testsuite tests="3" failures="0" errors="1" skipped="0"/></testsuites>')
    counts = evidence.junit_counts(report, time.time() - 5)
    assert (counts["tests"], counts["failures"], counts["errors"], counts["skipped"], counts["executed"]) == (8, 1, 1, 2, 6)
    assert evidence.junit_counts(report, time.time() + 100)["stale"] is True
    report.write_text('<testsuite tests="2" failures="0" errors="0"/>')
    assert evidence.junit_counts(report, time.time() - 5)["executed"] == 2
    report.write_text("<not-closed")
    assert evidence.junit_counts(report, time.time() - 5)["error"] == "ParseError"


def test_counts_include_only_fresh_junit_totals():
    checks = [
        check("a", "passed", junit=[{"present": True, "stale": False, "tests": 4, "failures": 0, "errors": 0, "skipped": 1, "executed": 3}]),
        check("b", "failed", junit=[{"present": True, "stale": True}, {"present": False}]),
        check("c", "unavailable"),
    ]
    counts = evidence.summarize_checks(checks)
    assert counts["selected"] == 3 and counts["executed"] == 2
    assert (counts["junit_tests"], counts["junit_skipped"], counts["junit_executed"]) == (4, 1, 3)
    assert counts["passed"] == counts["failed"] == counts["unavailable"] == 1


def test_a_plan_is_never_a_validation_result():
    plan = summary(mode="plan", checks=[check("shared-guards", "planned")])
    assert plan["status"] == "plan-only" and plan["full_validation"] is False


def test_only_a_complete_run_on_every_needed_platform_is_full_validation():
    assert summary()["status"] == "full-validation-passed"
    assert summary(checks=[check("a", "passed"), check("b", "subsumed")])["full_validation"] is True
    for status in ("unavailable", "not-run", "manual", "ci-only"):
        partial = summary(checks=[check("a", "passed"), check("b", status, reason="needs a prerequisite")])
        assert partial["status"] == "partial" and not partial["full_validation"]
        assert any("b: " + status in reason for reason in partial["not_full_validation_reasons"])
    unexecuted = summary(unexecuted=["macos"])
    assert unexecuted["status"] == "partial" and "unexecuted platforms: macos" in unexecuted["not_full_validation_reasons"]
    failed = summary(checks=[check("a", "failed"), check("b", "unavailable")])
    assert failed["status"] == "failed" and not failed["full_validation"]


def test_summary_validation_rejects_forged_success_and_foreign_environment():
    good = summary()
    for tamper in (
        lambda s: s.update(status="partial"),  # full_validation contradicts status
        lambda s: s["checks"].append(check("x", "unavailable")),
        lambda s: s.update(unexecuted_platforms=["linux"]),
        lambda s: s.update(mode="plan"),
        lambda s: s["environment"].update(GITHUB_TOKEN="x"),
        lambda s: s["checks"][0].update(status="mystery"),
        lambda s: s.update(status="bogus"),
        lambda s: s.update(schema=3),
        lambda s: s.pop("selection"),
    ):
        forged = json.loads(json.dumps(good))
        tamper(forged)
        with pytest.raises(ValueError):
            evidence.validate_summary(forged)


def test_summary_carries_conditions_but_no_secrets(tmp_path):
    result = summary(environ={**SECRETS, "GITHUB_RUN_ID": "9", "TMPDIR": str(tmp_path)})
    text = json.dumps(result)
    for secret in ("refresh-secret", "search-secret", "ghs_secret", "aws-secret", "/home/someone"):
        assert secret not in text
    assert result["environment"] == {"GITHUB_RUN_ID": "9", "TMPDIR": str(tmp_path)}
    assert result["schema"] == evidence.SCHEMA and result["kind"] == evidence.KIND
    assert {"uid", "gid", "groups", "nss"} <= result["account"].keys()
    assert "roots" in result["temp_root_policy"] and result["host"]["machine"]


def test_write_is_atomic_private_and_refuses_symlinks(tmp_path):
    destination = tmp_path / "out" / "evidence.json"
    written = evidence.write_summary(summary(), destination)
    assert written == destination and stat.S_IMODE(destination.stat().st_mode) == 0o600
    assert json.loads(destination.read_text())["status"] == "full-validation-passed"
    assert not list(destination.parent.glob(".evidence-*"))

    link = tmp_path / "out" / "link.json"
    link.symlink_to(destination)
    with pytest.raises(ValueError, match="symlink"):
        evidence.write_summary(summary(), link)

    forged = summary()
    forged["status"] = "partial"
    with pytest.raises(ValueError):
        evidence.write_summary(forged, tmp_path / "out" / "forged.json")


def test_failed_publication_leaves_no_partial_file(tmp_path, monkeypatch):
    def broken(*_):
        raise OSError("disk full")

    monkeypatch.setattr(evidence.os, "replace", broken)
    with pytest.raises(OSError, match="disk full"):
        evidence.write_summary(summary(), tmp_path / "evidence.json")
    assert list(tmp_path.iterdir()) == []


def test_incomplete_reasons_downgrade_a_run_and_cannot_be_forged_away():
    result = evidence.build_summary(
        mode="run", source={}, invocation={}, selection={}, checks=[check("a", "passed")], unexecuted_platforms=[],
        reproduction=[], environ={}, incomplete_reasons=["inventory skipped"],
    )
    assert result["status"] == "partial" and result["not_full_validation_reasons"][0] == "inventory skipped"
    forged = json.loads(json.dumps(summary()))
    forged["incomplete_reasons"] = ["something is missing"]
    with pytest.raises(ValueError):
        evidence.validate_summary(forged)


def test_junit_problems_name_every_way_a_report_can_fail_to_support_a_pass():
    good = {"path": "g", "present": True, "stale": False, "tests": 2, "failures": 0, "errors": 0, "skipped": 0, "executed": 2}
    assert evidence.junit_problems([good]) == []
    bad = [
        {"path": "a", "present": False},
        {"path": "b", "present": True, "stale": True},
        {"path": "c", "present": True, "stale": False, "error": "ParseError"},
        {**good, "path": "d", "failures": 1},
        {**good, "path": "e", "executed": 0},
    ]
    assert [problem.split(":")[0] for problem in evidence.junit_problems([good, *bad])] == list("abcde")


# ------------------------------------------------------------ schema 2 (batch 3b-1)

PINS = {"protoc": "35.1", "dart": "3.9.2", "flutter": "3.35.7", "actionlint": "1.7.7", "shellcheck": "0.9.0"}


def summary_with(tools=None, checks=None, environ=None, mode="run", unexecuted=(), pins=PINS):
    return evidence.build_summary(
        mode=mode, source={"mode": "explicit", "identity_sha256": "0" * 64, "dirty": None, "dirty_unknown": "explicit file list"},
        invocation={"entrypoint": "tools.validate_change", "argv": ["--files", "a b.md"]}, selection={},
        checks=[check("shared-guards", "passed")] if checks is None else checks,
        unexecuted_platforms=list(unexecuted), reproduction=["rerun"], environ=environ if environ is not None else {},
        tools=tools, pins=pins,
    )


def test_schema_two_adds_pins_phases_concurrency_cache_artifacts_and_gaps():
    result = summary_with(tools={"python": "3.13.0", "protoc": "libprotoc 36.2", "dart": "Dart SDK version: 3.9.2 (stable)", "cmake": "cmake 4"})
    assert result["schema"] == 2 == evidence.SCHEMA and evidence.READABLE_SCHEMAS == (1, 2)
    assert {"tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps"} <= result.keys()
    pins = result["tool_pins"]
    assert pins["protoc"] == {"pinned": "35.1", "observed": "libprotoc 36.2", "matches": False}
    assert pins["dart"]["matches"] is True
    assert pins["flutter"] == {"pinned": "3.35.7", "observed": None, "matches": None}
    codes = [gap["code"] for gap in result["reproduction_gaps"]]
    assert "pin-mismatch:protoc" in codes and "pin-mismatch:dart" not in codes and "pin-mismatch:flutter" not in codes
    assert "change-set-dirty-unknown" in codes


def test_version_matching_is_a_whole_token_and_a_failed_probe_never_matches():
    assert evidence.version_matches("35.1", "libprotoc 35.1") is True
    assert evidence.version_matches("35.1", "libprotoc 35.10") is False
    assert evidence.version_matches("3.9.2", "Dart SDK version: 13.9.2") is False
    assert evidence.version_matches("1.7.7", "probe failed: exit 1: 1.7.7") is False
    assert evidence.version_matches("1.7.7", None) is None


def test_pinned_tools_come_from_the_repository_pins_and_the_hosted_workflow_tools():
    pins = evidence.pinned_tools()
    from tools import check_local_validation

    assert pins["actionlint"] == "1.7.7" and pins["shellcheck"] == "0.9.0"
    assert {name: version for name, _arguments, version in check_local_validation.WORKFLOW_TOOLS} == {"actionlint": "1.7.7", "shellcheck": "0.9.0"}
    assert json.loads((Path(__file__).resolve().parents[1] / "tools/pins.json").read_text())["protoc"] == pins["protoc"]


def test_gaps_name_every_condition_a_reader_could_not_reproduce():
    flaky = check("native-stage", "unavailable", reason="dart is not on PATH")
    result = summary_with(checks=[check("shared-guards", "passed"), flaky], unexecuted=["linux"], tools={"protoc": "libprotoc 36.2"})
    result["account"]["home_env_set"], result["account"]["home_matches_nss"] = True, False
    result["temp_root_policy"]["compliant"] = False
    result["source"]["revision_declared"] = True
    result["artifacts"] = [{"check": "x", "path": "/p", "sha256": "0" * 64, "producer": None}]
    codes = {gap["code"] for gap in evidence.derive_gaps(result)}
    assert codes == {
        "pin-mismatch:protoc", "temp-root-noncompliant", "home-differs-from-nss", "change-set-dirty-unknown",
        "revision-declared-not-verified", "unexecuted-platform:linux", "check-not-passed:native-stage", "artifact-provenance-not-recorded",
    }
    assert evidence.derive_gaps(result)[0]["detail"]


def test_reused_outputs_and_digests_are_recorded_without_claiming_a_producer():
    reuse = [{"id": "native-library", "path": "/b", "present": True, "sha256": {"/b/lib": "a" * 64}, "at_execution": {"present": True}}]
    checks = [check("core-stage", "passed", reuse=reuse)]
    result = summary_with(checks=checks)
    assert result["cache"] == {"reused_outputs": [{"check": "core-stage", "id": "native-library", "path": "/b", "present": True, "at_execution": True}]}
    assert result["artifacts"] == [{"check": "core-stage", "path": "/b/lib", "sha256": "a" * 64, "producer": None}]
    assert any(gap["code"] == "artifact-provenance-not-recorded" for gap in result["reproduction_gaps"])


def test_concurrency_records_only_the_settings_the_runner_allowlists(monkeypatch):
    assert set(evidence.CONCURRENCY_ENV) <= set(evidence.ENV_ALLOWLIST)
    record = evidence.concurrency({"FORESIGHT_BUILD_JOBS": "8", "FORESIGHT_PYTEST_WORKERS": "2", "FORESIGHT_CI_GOOGLE_REFRESH_TOKEN": "secret", "PATH": "/x"})
    assert record["settings"] == {"FORESIGHT_BUILD_JOBS": "8", "FORESIGHT_PYTEST_WORKERS": "2"}
    assert record["cpu_count"] == os.cpu_count() and record["checks_run"] == "sequential"
    monkeypatch.setenv("FORESIGHT_PARALLEL_GATES", "1")
    assert evidence.concurrency()["settings"] == {"FORESIGHT_PARALLEL_GATES": "1"}


def test_phase_values_are_validated_and_a_forged_phase_is_rejected():
    good = summary_with(checks=[check("a", "passed", phases={"setup": "ok", "body": "passed", "teardown": "clean"})])
    evidence.validate_summary(good)
    for phase, value in (("body", "success"), ("teardown", "fine"), ("setup", "ready"), ("mystery", "ok")):
        forged = json.loads(json.dumps(good))
        forged["checks"][0]["phases"][phase] = value
        with pytest.raises(ValueError, match="phase"):
            evidence.validate_summary(forged)


def test_a_schema_two_summary_must_carry_its_new_sections_and_well_formed_gaps():
    good = summary_with()
    for key in ("tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps"):
        broken = json.loads(json.dumps(good))
        broken.pop(key)
        with pytest.raises(ValueError, match="schema 2 lacks"):
            evidence.validate_summary(broken)
    broken = json.loads(json.dumps(good))
    broken["reproduction_gaps"] = [{"code": "x"}]
    with pytest.raises(ValueError, match="code and a detail"):
        evidence.validate_summary(broken)


def test_schema_one_summaries_remain_readable():
    legacy = json.loads(json.dumps(summary_with()))
    legacy["schema"] = 1
    for key in ("tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps"):
        legacy.pop(key)
    evidence.validate_summary(legacy)


# The wider schema must not widen what leaves the machine.
SENTINELS = {
    "FORESIGHT_CI_GOOGLE_REFRESH_TOKEN": "sentinel-refresh-token",
    "FORESIGHT_SEARCH_API_KEY": "sentinel-search-key",
    "GITHUB_TOKEN": "sentinel-github-token",
    "AWS_SECRET_ACCESS_KEY": "sentinel-aws",
    "HOME": "/home/sentinel-home-user",
    "USER": "sentinel-user",
    "PATH": "/sentinel/path/bin",
    "FORESIGHT_MODEL_ASSETS": "/private/sentinel-model-assets",
}


def test_no_new_field_can_carry_a_value_from_outside_the_environment_allowlist(tmp_path):
    reuse = [{"id": "native-library", "path": str(tmp_path), "present": True, "sha256": {}, "at_execution": {"present": True}}]
    environ = {**SENTINELS, "FORESIGHT_BUILD_JOBS": "4", "GITHUB_RUN_ID": "77", "FORESIGHT_PYTEST_WORKERS": "2"}
    result = summary_with(
        environ=environ, checks=[check("core-stage", "passed", reuse=reuse, phases={"setup": "ok", "body": "passed", "teardown": "clean"})],
        tools={"python": "3.13", "protoc": "libprotoc 35.1"},
    )
    text = json.dumps(result)
    for name, value in SENTINELS.items():
        assert value not in text, name
    assert result["environment"] == {"FORESIGHT_BUILD_JOBS": "4", "GITHUB_RUN_ID": "77", "FORESIGHT_PYTEST_WORKERS": "2"}
    assert result["concurrency"]["settings"] == {"FORESIGHT_BUILD_JOBS": "4", "FORESIGHT_PYTEST_WORKERS": "2"}
    # The only free text in the new sections is tool output, paths of recorded checks, and the gap prose built here.
    assert set(result["tool_pins"]) == set(PINS)
    assert all(set(record) == {"pinned", "observed", "matches"} for record in result["tool_pins"].values())


def test_every_environment_name_a_new_section_reads_is_on_the_allowlist():
    source = (Path(__file__).resolve().parents[1] / "tools/validation_evidence.py").read_text()
    from tools import validation_replay

    assert set(evidence.CONCURRENCY_ENV) <= set(evidence.ENV_ALLOWLIST)
    assert not [name for name in evidence.ENV_ALLOWLIST if name.startswith("FORESIGHT_CI_") or "TOKEN" in name or "KEY" in name or "SECRET" in name]
    assert "os.environ[" not in source and "os.getenv" not in source  # reads go through the injected mapping
    replay = Path(validation_replay.__file__).read_text()
    assert "os.environ" not in replay and "getenv" not in replay  # the replay reads no environment at all
