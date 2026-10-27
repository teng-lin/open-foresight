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

    def run(argv, **kwargs):
        assert kwargs["timeout"] == 30 and not kwargs["check"]
        if argv[0] == "/bin/ninja":
            raise subprocess.TimeoutExpired(argv, 30)
        if argv[0] == "/bin/protoc":
            return type("Empty", (), {"stdout": "", "stderr": ""})()
        return Result()

    paths = {"cmake": "/bin/cmake", "ninja": "/bin/ninja", "protoc": "/bin/protoc"}
    observed = evidence.observe_tools(("cmake", "ninja", "protoc", "dart"), run=run, which=paths.get)
    assert observed["cmake"] == "cmake version 3.31"
    assert observed["ninja"] == "probe failed: TimeoutExpired"
    assert observed["protoc"] == "" and observed["dart"] is None
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
        lambda s: s.update(schema=2),
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
