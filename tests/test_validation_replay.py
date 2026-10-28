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
    "image": {"runner_image": {}, "os_id": "macos", "os_version_id": "15.1"},
    "revision": "a" * 40,
    "dirty": False,
}


def packet(**overrides):
    result = summary_with(
        tools={"python": "3.13.15", "protoc": "libprotoc 35.1", "git": "git version 2"}, pins={"protoc": "35.1"},
        checks=[check("shared-guards", "passed"), check("native-stage", "failed", reason="exit status 1", log="/var/tmp/x/native.log", entrypoint=["bash", "tools/build.sh", "--stage", "native"], phases={"setup": "ok", "body": "failed", "teardown": "clean"})],
    )
    result["host"] = dict(HERE["host"])
    result["account"].update(uid=501, nss={"name": "builder", "home": "/h", "shell": "/bin/sh"}, home_env_set=False)
    result["temp_root_policy"]["compliant"] = True
    result["image"] = dict(HERE["image"])
    result["source"].update(revision="a" * 40, dirty=False)
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
    assert {gap["code"] for gap in report["recorded_gaps"]} == {"check-not-passed:native-stage"}
    assert report["gap_count"] == 1


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
        (lambda here: here["image"].update(os_version_id="14.7"), "image-differs:os_version_id"),
        (lambda here: here["image"].update(os_id="ubuntu"), "image-differs:os_id"),
        (lambda here: here.update(revision="b" * 40), "revision-differs"),
        (lambda here: here.update(revision=None), "revision-unobserved-here"),
        (lambda here: here.update(dirty=True), "dirty-here"),
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
    legacy["source"]["dirty"] = None
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
    assert {"host", "tools", "uid", "nss_name", "temp_compliant", "image", "revision", "dirty"} <= here.keys()
    assert here["host"]["platform"] in ("linux", "macos")


# ------------------------------------------------------------ review round: gaps a reader must not miss

def test_a_plan_only_or_dirty_packet_keeps_its_gaps_even_when_the_packet_records_none():
    plan = packet(mode="plan-only", status="plan-only", full_validation=False, reproduction_gaps=[])
    plan["checks"] = [check("shared-guards", "planned")]
    codes = {gap["code"] for gap in replay.analyze(plan, HERE)["recorded_gaps"]}
    assert "not-executed" in codes
    dirty = packet(reproduction_gaps=[])
    dirty["checks"] = [check("shared-guards", "passed")]
    dirty["source"]["dirty"] = True
    assert "dirty-at-recording" in {gap["code"] for gap in replay.analyze(dirty, HERE)["recorded_gaps"]}


def test_a_packet_that_omits_a_gap_it_implies_cannot_pass_the_check(tmp_path):
    stale = packet()
    stale["reproduction_gaps"] = [{"code": "check-not-passed:native-stage", "detail": "status failed"}]
    stale["unexecuted_platforms"] = ["linux"]
    stale["source"]["dirty"] = True
    report = replay.analyze(stale, HERE)
    assert {gap["code"] for gap in report["recorded_gaps"]} == {"check-not-passed:native-stage", "unexecuted-platform:linux", "dirty-at-recording"}
    assert [gap["code"] for gap in report["recorded_gaps"]][0] == "check-not-passed:native-stage"  # the packet's own entries stay first
    assert replay.main([str(write(tmp_path, stale)), "--check"], observe=lambda: HERE) == 1


def test_observe_git_reads_revision_and_dirtiness_and_never_guesses(tmp_path):
    assert replay.observe_git(tmp_path) == {"revision": None, "dirty": None}  # no .git: not observed
    (tmp_path / ".git").mkdir()
    calls = []

    def answer(stdout, code=0):
        def run(argv, **kwargs):
            calls.append(argv)
            return type("R", (), {"stdout": stdout[argv[3]], "returncode": code})()
        return run

    out = {"rev-parse": f"{'c' * 40}\n", "status": " M tools/x.py\n"}
    assert replay.observe_git(tmp_path, run=answer(out)) == {"revision": "c" * 40, "dirty": True}
    assert calls[0][:3] == ["git", "-C", str(tmp_path)] and calls[1][3] == "status"
    assert replay.observe_git(tmp_path, run=answer({"rev-parse": "d" * 40, "status": ""})) == {"revision": "d" * 40, "dirty": False}
    assert replay.observe_git(tmp_path, run=answer(out, code=128)) == {"revision": None, "dirty": None}

    def broken(argv, **kwargs):
        raise FileNotFoundError

    assert replay.observe_git(tmp_path, run=broken) == {"revision": None, "dirty": None}


def test_a_declared_revision_is_not_compared_and_an_unrecorded_one_is_ignored():
    declared = packet()
    declared["source"]["revision_declared"] = True
    here = json.loads(json.dumps(HERE))
    here["revision"] = "b" * 40
    assert replay.host_mismatches(declared, here) == []
    unrecorded = packet()
    unrecorded["source"]["revision"] = None
    assert replay.host_mismatches(unrecorded, here) == []


@pytest.mark.parametrize(
    "damage",
    [
        lambda p: p.update(checks=3),
        lambda p: p.update(source="main"),
        lambda p: p["checks"].append("not-a-check"),
        lambda p: p["checks"][0].pop("status"),
        lambda p: p["host"].update(python=None),
        lambda p: p.update(invocation=[]),
        lambda p: p.update(account=None),
        lambda p: p.update(temp_root_policy=7),
    ],
)
def test_a_corrupt_packet_exits_two_without_a_traceback(tmp_path, damage, capsys):
    broken = packet()
    damage(broken)
    code = replay.main([str(write(tmp_path, broken)), "--check"], observe=lambda: HERE)
    assert code == 2
    err = capsys.readouterr().err
    assert err.startswith("validation_replay:") and "Traceback" not in err


def test_load_packet_names_the_failure_class_not_the_parser_message(tmp_path):
    with pytest.raises(ValueError) as caught:
        replay.load_packet(write(tmp_path, '{"secret": "/home/sentinel-user/x"'))
    assert "sentinel-user" not in str(caught.value) and "JSONDecodeError" in str(caught.value)
    with pytest.raises(ValueError, match="malformed"):
        replay.load_packet(write(tmp_path, {**packet(), "checks": 3}, "bad.json"))
    binary = tmp_path / "binary.json"
    binary.write_bytes(b"\xff\xfe\x00")
    with pytest.raises(ValueError, match="Cannot read packet"):
        replay.load_packet(binary)
