"""Replay reads a packet, reproduces nothing, and lists every gap it can see."""

import json
import shlex

import pytest

from tools import validation_evidence as evidence, validation_replay as replay
from tests.test_validation_evidence import SENTINELS, check, summary_with

HERE = {
    "host": {"system": "Darwin", "release": "25.0", "machine": "arm64", "platform": "macos", "python": "3.13.15"},
    "tools": {"python": "3.13.15", "protoc": "libprotoc 35.1", "git": "git version 2"},
    "uid": 501,
    "nss_name": "builder",
    "temp_compliant": True,
}


def packet(**overrides):
    result = summary_with(
        tools={"python": "3.13.15", "protoc": "libprotoc 35.1", "git": "git version 2"},
        checks=[check("shared-guards", "passed"), check("native-stage", "failed", reason="exit status 1", log="/var/tmp/x/native.log", entrypoint=["bash", "tools/build.sh", "--stage", "native"], phases={"setup": "ok", "body": "failed", "teardown": "clean"})],
    )
    result["host"] = dict(HERE["host"])
    result["account"].update(uid=501, nss={"name": "builder", "home": "/h", "shell": "/bin/sh"}, home_env_set=False)
    result["temp_root_policy"]["compliant"] = True
    result["unexecuted_platforms"] = []
    result["reproduction_gaps"] = [gap for gap in evidence.derive_gaps(result) if not gap["code"].startswith("check-not-passed")] + [
        {"code": "check-not-passed:native-stage", "detail": "status failed"}
    ]
    result.update(overrides)
    return result


def test_the_replay_prints_the_exact_invocation_and_each_failed_checks_entrypoint():
    report = replay.analyze(packet(), HERE)
    assert report["command"] == shlex.join([".venv/bin/python", "-m", "tools.validate_change", "--files", "a b.md"])
    assert "'a b.md'" in report["command"]
    [failed] = report["failing_checks"]
    assert failed["id"] == "native-stage" and failed["command"] == "bash tools/build.sh --stage native"
    assert failed["log"] == "/var/tmp/x/native.log" and failed["phases"]["body"] == "failed"
    text = replay.render(report)
    assert "Check native-stage: failed (exit status 1)" in text and "retained log: /var/tmp/x/native.log" in text
    assert "runs nothing" in text


def test_a_replay_on_the_recorded_host_reports_only_the_packets_own_gaps():
    report = replay.analyze(packet(), HERE)
    assert report["host_mismatches"] == []
    assert {gap["code"] for gap in report["recorded_gaps"]} == {"change-set-dirty-unknown", "check-not-passed:native-stage"}
    assert report["gap_count"] == 2


@pytest.mark.parametrize(
    ("change", "code"),
    [
        (lambda here: here["host"].update(platform="linux"), "host-differs:platform"),
        (lambda here: here["host"].update(machine="x86_64"), "host-differs:machine"),
        (lambda here: here["host"].update(system="Linux"), "host-differs:system"),
        (lambda here: here["host"].update(release="26.0"), "host-differs:release"),
        (lambda here: here["host"].update(python="3.12.1"), "host-differs:python"),
        (lambda here: here["tools"].update(protoc="libprotoc 36.2"), "tool-differs:protoc"),
        (lambda here: here["tools"].update(git=None), "tool-missing:git"),
        (lambda here: here.update(uid=0), "account-differs:root"),
        (lambda here: here.update(nss_name="runner"), "account-differs:nss-name"),
        (lambda here: here.update(temp_compliant=False), "temp-root-differs"),
    ],
)
def test_each_difference_between_the_recorded_host_and_this_one_is_a_named_gap(change, code):
    here = json.loads(json.dumps(HERE))
    change(here)
    codes = [gap["code"] for gap in replay.host_mismatches(packet(), here)]
    assert codes == [code]


def test_tool_python_and_unrecorded_tools_never_count_as_differences():
    here = json.loads(json.dumps(HERE))
    here["tools"]["python"] = "3.13.99"
    here["tools"]["cmake"] = "cmake 4"
    assert replay.host_mismatches(packet(), here) == []
    assert replay.host_mismatches(packet(tools=None), HERE) == []


def test_the_replay_lists_unexecuted_platforms_and_pin_mismatches_from_the_packet():
    stale = packet()
    stale["tool_pins"]["protoc"]["matches"] = False
    stale["unexecuted_platforms"] = ["linux"]
    stale["reproduction_gaps"] = evidence.derive_gaps(stale)
    codes = {gap["code"] for gap in replay.analyze(stale, HERE)["recorded_gaps"]}
    assert {"pin-mismatch:protoc", "unexecuted-platform:linux"} <= codes


def test_schema_one_packets_have_their_gaps_derived():
    legacy = packet()
    legacy["schema"] = 1
    for key in ("tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps"):
        legacy.pop(key)
    legacy["tool_pins"] = {}
    report = replay.analyze(legacy, HERE)
    assert report["schema"] == 1
    assert {gap["code"] for gap in report["recorded_gaps"]} >= {"change-set-dirty-unknown", "check-not-passed:native-stage"}


def write(tmp_path, content, name="evidence.json"):
    path = tmp_path / name
    path.write_text(content if isinstance(content, str) else json.dumps(content))
    return path


def test_cli_exit_status_follows_the_gaps_and_the_packet(tmp_path, capsys):
    path = write(tmp_path, packet())
    assert replay.main([str(path)], observe=lambda: HERE) == 0
    assert replay.main([str(path), "--check"], observe=lambda: HERE) == 1
    clean = packet(reproduction_gaps=[])
    clean["source"]["dirty"] = False
    clean["checks"] = [check("shared-guards", "passed")]
    assert replay.main([str(write(tmp_path, clean, "clean.json")), "--check"], observe=lambda: HERE) == 0
    capsys.readouterr()
    assert replay.main([str(path), "--json"], observe=lambda: HERE) == 0
    assert json.loads(capsys.readouterr().out)["failing_checks"][0]["id"] == "native-stage"


@pytest.mark.parametrize("content", ["{not json", "[]", json.dumps({"schema": 9, "kind": evidence.KIND})])
def test_an_unreadable_or_foreign_packet_exits_two(tmp_path, content, capsys):
    assert replay.main([str(write(tmp_path, content))], observe=lambda: HERE) == 2
    assert "validation_replay:" in capsys.readouterr().err
    assert replay.main([str(tmp_path / "missing.json")], observe=lambda: HERE) == 2


def test_the_replay_never_prints_a_value_from_outside_the_packet_allowlist(tmp_path, capsys):
    secret = summary_with(environ={**SENTINELS, "GITHUB_RUN_ID": "9"}, tools={"python": "3.13.15"})
    replay.main([str(write(tmp_path, secret)), "--json"], observe=lambda: HERE)
    output = capsys.readouterr().out
    for name, value in SENTINELS.items():
        assert value not in output, name


def test_observe_host_reads_this_host():
    here = replay.observe_host()
    assert {"host", "tools", "uid", "nss_name", "temp_compliant"} <= here.keys()
    assert here["host"]["platform"] in ("linux", "macos")
