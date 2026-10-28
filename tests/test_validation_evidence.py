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
    assert observed["dart"] == "probe failed: exit 64"
    assert "bad flag" not in json.dumps(observed)  # a failed probe's output is not kept
    assert observed["python"]
    assert "git" in evidence.observe_tools(("git",))


def test_the_version_bearing_line_is_recorded_not_the_banner():
    shellcheck = "ShellCheck - shell script analysis tool\nversion: 0.9.0\nlicense: GNU General Public License, version 3\n"
    flutter = "Flutter 3.35.7 • channel stable • https://github.com/flutter/flutter.git\nFramework • revision abc\n"

    def run(argv, **kwargs):
        text = {"/bin/shellcheck": shellcheck, "/bin/flutter": flutter, "/bin/odd": "no digits here\nnone either\n"}[argv[0]]
        return type("R", (), {"stdout": text, "stderr": "", "returncode": 0})()

    paths = {"shellcheck": "/bin/shellcheck", "flutter": "/bin/flutter", "actionlint": "/bin/odd"}
    observed = evidence.observe_tools(("shellcheck", "flutter", "actionlint"), run=run, which=paths.get)
    assert observed["shellcheck"] == "version: 0.9.0"
    assert evidence.version_matches("0.9.0", observed["shellcheck"]) is True
    assert observed["flutter"].startswith("Flutter 3.35.7")
    assert observed["actionlint"] == "no digits here"  # no version line: the first line, which will not match a pin
    assert evidence.version_line([]) == ""
    assert evidence.TOOL_PROBES["flutter"] == ["flutter", "--version", "--suppress-analytics"]
    assert set(evidence.pinned_tools()) <= set(evidence.TOOL_PROBES)  # every pin can be observed


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
        "pin-mismatch:protoc", "revision-unrecorded", "pin-unobserved:dart", "pin-unobserved:flutter", "pin-unobserved:actionlint", "pin-unobserved:shellcheck", "temp-root-noncompliant", "home-differs-from-nss", "change-set-dirty-unknown",
        "revision-declared-not-verified", "unexecuted-platform:linux", "check-not-passed:native-stage", "artifact-provenance-not-recorded",
    }
    assert evidence.derive_gaps(result)[0]["detail"]


def test_an_unobserved_pin_is_a_gap_only_for_a_run_that_probed_tools():
    probed = summary_with(tools={"python": "3.13.0", "protoc": "libprotoc 35.1", "dart": "Dart SDK version: 3.9.2", "flutter": "Flutter 3.35.7",
                                 "actionlint": "1.7.7", "shellcheck": "version: 0.9.0"})
    assert not [gap for gap in probed["reproduction_gaps"] if gap["code"].startswith("pin-")]
    missing = summary_with(tools={"protoc": "libprotoc 35.1", "flutter": None})
    codes = {gap["code"] for gap in missing["reproduction_gaps"]}
    assert {"pin-unobserved:flutter", "pin-unobserved:dart"} <= codes and "pin-unobserved:protoc" not in codes
    assert "pin-unobserved:flutter" in {gap["code"] for gap in evidence.derive_gaps(missing)}
    # A plan probes nothing, so it makes no pin claim either way; its gap is that nothing ran.
    plan = summary_with(mode="plan-only", tools=None, checks=[check("shared-guards", "planned")])
    codes = {gap["code"] for gap in plan["reproduction_gaps"]}
    assert "not-executed" in codes and not [code for code in codes if code.startswith("pin-")]


def test_a_dirty_tree_is_a_gap_and_gap_prose_never_carries_a_path():
    dirty = summary_with(tools={"python": "3"})
    dirty["source"]["dirty"] = True
    assert "dirty-at-recording" in {gap["code"] for gap in evidence.derive_gaps(dirty)}
    leaky = summary_with(
        checks=[check("native-stage", "failed", reason="cannot open /home/sentinel-user/.cache/log (see '/var/tmp/x/y.log')")],
    )
    leaky["source"]["dirty_unknown"] = "git failed: fatal: not a git repository: /Users/sentinel-user/src/app"
    text = json.dumps(evidence.derive_gaps(leaky))
    assert "sentinel-user" not in text and "/var/tmp" not in text and "<path>" in text
    assert evidence.redact("a/b and /abs/path, then x") == "a/b and <path>, then x"
    assert evidence.redact("CI/CD 1/2 https://example.org/x") == "CI/CD 1/2 https://example.org/x"


def test_the_image_is_recorded_from_the_runner_variables_and_os_release():
    release = 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04"\n'
    image = evidence.image_identity({"ImageOS": "ubuntu24", "ImageVersion": "20260101.1", "PATH": "/sentinel/path"}, lambda: release, system="linux")
    assert image == {"runner_image": {"ImageOS": "ubuntu24", "ImageVersion": "20260101.1"}, "os_id": "ubuntu", "os_version_id": "24.04"}
    assert evidence.image_identity({}, lambda: None, system="linux") == {"runner_image": {}, "os_id": None, "os_version_id": None}
    assert evidence.os_release_fields("ID=\"debian\"\n# comment\nVERSION_ID=12\nOTHER=1")  == {"ID": "debian", "VERSION_ID": "12"}
    mac = evidence.image_identity({}, lambda: release, system="darwin", mac_version=lambda: "15.1")
    assert (mac["os_id"], mac["os_version_id"]) == ("macos", "15.1")
    assert evidence.image_identity({}, lambda: release, system="darwin", mac_version=lambda: "")["os_version_id"] is None
    assert "ImageOS" in evidence.ENV_ALLOWLIST and "ImageVersion" in evidence.ENV_ALLOWLIST


def test_the_summary_carries_the_image_and_a_schema_two_summary_requires_it():
    result = summary_with(environ={"ImageOS": "ubuntu24", "ImageVersion": "7"})
    assert result["image"]["runner_image"] == {"ImageOS": "ubuntu24", "ImageVersion": "7"}
    assert set(result["image"]) == {"runner_image", "os_id", "os_version_id"}
    broken = json.loads(json.dumps(result))
    broken.pop("image")
    with pytest.raises(ValueError, match="schema 2 lacks: image"):
        evidence.validate_summary(broken)


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
    for key in ("tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps", "image"):
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
    for key in ("tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps", "image"):
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


# ------------------------------------------------ review round 2

def test_parallelism_settings_are_integers_or_the_word_invalid():
    result = evidence.concurrency({"FORESIGHT_BUILD_JOBS": "8", "FORESIGHT_PYTEST_WORKERS": "auto; rm -rf ~\n", "FORESIGHT_PARALLEL_GATES": "9" * 7})
    assert result["settings"] == {"FORESIGHT_BUILD_JOBS": "8", "FORESIGHT_PARALLEL_GATES": "invalid", "FORESIGHT_PYTEST_WORKERS": "invalid"}
    forged = json.loads(json.dumps(summary_with()))
    forged["concurrency"]["settings"] = {"FORESIGHT_BUILD_JOBS": "4; curl evil"}
    with pytest.raises(ValueError, match="integers or `invalid`"):
        evidence.validate_summary(forged)
    forged["concurrency"]["settings"] = ["4"]
    with pytest.raises(ValueError, match="integers or `invalid`"):
        evidence.validate_summary(forged)


def test_paths_under_the_account_home_are_recorded_with_a_tilde(tmp_path):
    assert evidence.tilde("/Users/ada/build/x", "/Users/ada") == "~/build/x"
    assert evidence.tilde("/Users/ada", "/Users/ada/") == "~"
    assert evidence.tilde("/Users/adam/x", "/Users/ada") == "/Users/adam/x"  # a prefix of the name is not the home
    assert evidence.tilde("/var/tmp/x", "/") == "/var/tmp/x" and evidence.tilde("/x", None) == "/x" and evidence.tilde("/x", "") == "/x"
    digest = "0" * 64
    reuse = [{"id": "lib", "path": "/Users/ada/build/native", "present": True, "sha256": {"/Users/ada/build/native/lib.dylib": digest}, "at_execution": {"present": True}}]
    cache, artifacts = evidence.cache_and_artifacts([{"id": "native-stage", "reuse": reuse}], home="/Users/ada")
    assert cache["reused_outputs"][0]["path"] == "~/build/native" and artifacts[0]["path"] == "~/build/native/lib.dylib"
    home = evidence.account_identity({})["nss"]["home"]
    built = summary_with(checks=[check("native-stage", "passed", reuse=[{**reuse[0], "path": f"{home}/b", "sha256": {}}])])
    if home and home.rstrip("/"):
        assert built["cache"]["reused_outputs"][0]["path"] == "~/b"
        assert home not in json.dumps(built["cache"])


def test_a_subsumed_check_is_a_gap_because_its_own_entrypoint_did_not_run():
    result = summary_with(checks=[check("python-coverage", "passed"), check("core-tests", "subsumed", subsumed_by="python-coverage")])
    gaps = {gap["code"]: gap["detail"] for gap in result["reproduction_gaps"]}
    assert "python-coverage" in gaps["subsumed-not-verified:core-tests"] and "did not run" in gaps["subsumed-not-verified:core-tests"]
    assert "subsumed-not-verified:python-coverage" not in gaps


@pytest.mark.parametrize(
    ("damage", "message"),
    [
        (lambda s: s.update(checks=["x"]), "text id and status"),
        (lambda s: s.update(checks="abc"), "checks must be a list"),
        (lambda s: s.update(reproduction_gaps="abc"), "reproduction_gaps must be a list"),
        (lambda s: s.update(reproduction_gaps=["abc"]), "code and a detail"),
        (lambda s: s.update(tool_pins={"x": 1}), "tool pin"),
        (lambda s: s.update(artifacts=[1]), "artifact"),
        (lambda s: s.update(unexecuted_platforms=[1]), "list text"),
        (lambda s: s.update(reproduction=[None]), "list text"),
        (lambda s: s["environment"].update(CI=1), "must be text"),
        (lambda s: s["host"].update(python=3), "must be text"),
        (lambda s: s["checks"][0].update(reason=3), "field reason must be text"),
        (lambda s: s["checks"][0].update(log=[]), "field log must be text"),
        (lambda s: s["checks"][0].update(entrypoint="bash x"), "entrypoint must list text"),
        (lambda s: s["checks"][0].update(entrypoint=[1]), "entrypoint must list text"),
        (lambda s: s["checks"][0].update(phases=["ok"]), "phases must be a mapping"),
        (lambda s: s.update(full_validation="yes"), "full_validation must be a bool"),
        (lambda s: s.update(image=[]), "image must be a dict"),
    ],
)
def test_wrongly_typed_fields_are_refused_with_a_value_error(damage, message):
    broken = json.loads(json.dumps(summary_with()))
    damage(broken)
    with pytest.raises(ValueError, match=message):
        evidence.validate_summary(broken)


def test_observe_tools_passes_its_timeout_to_every_probe():
    seen = []

    def run(argv, **kwargs):
        seen.append(kwargs["timeout"])
        return type("R", (), {"stdout": "git version 2.1\n", "stderr": "", "returncode": 0})()

    evidence.observe_tools(("git",), run=run, which=lambda name: "/bin/git", timeout=7)
    evidence.observe_tools(("git",), run=run, which=lambda name: "/bin/git")
    assert seen == [7, 30]


def test_the_summary_records_the_policy_it_is_given_not_a_recomputed_one():
    policy = {"roots": {}, "umask": "0o77", "compliant": False, "source": "child"}
    result = evidence.build_summary(
        mode="run", source={"mode": "explicit", "identity_sha256": "0" * 64, "dirty": False}, invocation={"entrypoint": "tools.validate_change", "argv": []},
        selection={}, checks=[check("shared-guards", "passed")], unexecuted_platforms=[], reproduction=[], environ={}, tools={"python": "3"}, pins={},
        temp_root_policy=policy,
    )
    assert result["temp_root_policy"] == policy and "temp-root-noncompliant" in {gap["code"] for gap in result["reproduction_gaps"]}


# ------------------------------------------------ review round 3

def test_a_packet_without_a_revision_has_a_gap_and_one_with_it_does_not():
    bare = summary_with()
    assert "revision-unrecorded" in {gap["code"] for gap in bare["reproduction_gaps"]}
    named = json.loads(json.dumps(bare))
    named["source"]["revision"] = "a" * 40
    assert "revision-unrecorded" not in {gap["code"] for gap in evidence.derive_gaps(named)}


def test_redaction_handles_quoted_paths_with_spaces_and_account_directories():
    assert evidence.redact("cannot open '/Users/John Smith/My Project/x.log' now") == "cannot open '<path>' now"
    assert evidence.redact('cannot open "/var/tmp/a b/log"') == 'cannot open "<path>"'
    assert evidence.redact("failed in /Users/John Smith/src/app/build.log, retry") == "failed in <path>, retry"
    assert evidence.redact("see /home/ada/.cache/x and /opt/tool/bin") == "see <path> and <path>"
    assert evidence.redact("no path here, a/b, 1/2, https://x.org/p") == "no path here, a/b, 1/2, https://x.org/p"
    assert "Smith" not in evidence.redact("/Users/John Smith/x")


def test_a_checks_recorded_reason_is_redacted_but_its_status_and_log_are_kept():
    failing = check("native-stage", "failed", reason="cannot start the entrypoint: FileNotFoundError: '/Users/John Smith/repo/tools/x.sh'", log="/var/tmp/x/native.log")
    result = summary_with(checks=[failing])
    [recorded] = result["checks"]
    assert "Smith" not in recorded["reason"] and recorded["reason"].endswith("'<path>'") and recorded["log"] == "/var/tmp/x/native.log"
    assert failing["reason"].startswith("cannot start") and "Smith" in failing["reason"]  # the caller's own record is untouched
    assert summary_with(checks=[check("shared-guards", "passed")])["checks"][0].get("reason") is None


# ------------------------------------------------ review round 4

def test_redaction_reaches_paths_after_a_colon_but_leaves_urls_alone():
    assert evidence.redact("FileNotFoundError:/Users/ada/repo/x.sh missing") == "FileNotFoundError:<path> missing"
    assert evidence.redact("error: /opt/tool/bin failed") == "error: <path> failed"
    assert evidence.redact("OSError:/opt/tool/bin failed") == "OSError:<path> failed"
    assert evidence.redact("see https://example.org/a/b and http://x/y") == "see https://example.org/a/b and http://x/y"
    assert evidence.redact("cwd=/var/tmp/x/y") == "cwd=<path>"


def test_a_packet_without_an_identified_image_has_a_gap():
    result = summary_with()
    result["image"] = {"runner_image": {}, "os_id": None, "os_version_id": None}
    assert "image-unrecorded" in {gap["code"] for gap in evidence.derive_gaps(result)}
    result["image"]["os_id"] = "ubuntu"
    assert "image-unrecorded" not in {gap["code"] for gap in evidence.derive_gaps(result)}
    result.pop("image")
    assert "image-unrecorded" in {gap["code"] for gap in evidence.derive_gaps(result)}
