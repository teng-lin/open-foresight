"""The reliability report is descriptive, bounded, and shows nothing a packet wrote."""

import copy
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import stat

import pytest

from tools import ci_stats, reliability_report as report_module, validation_evidence as evidence
from tests.test_validation_evidence import check, summary_with

ROOT = Path(__file__).resolve().parents[1]
START = datetime(2026, 10, 1, 12, 0, 0)

INVENTORY = {
    "gates": {
        "alpha-stage": {"kind": "command"},
        "beta-stage": {"kind": "command"},
        "manual-probe": {"kind": "manual"},
    },
    "boundaries": [
        {"id": "boundary-one", "gate": "alpha-stage", "also_gates": ["beta-stage"]},
        {"id": "boundary-two", "gate": "beta-stage", "also_gates": []},
    ],
}


def packet(index=0, status="passed", check_id="alpha-stage", identity=None, mode="run", platform="macos", hosted=False,
           conservative=False, reuse=None, seconds=2.0, **extra):
    result = summary_with(
        mode=mode,
        checks=[check(check_id, status if mode == "run" else "planned", seconds=seconds, **({"reuse": reuse} if reuse is not None else {}), **extra)],
        environ={"GITHUB_ACTIONS": "true"} if hosted else {},
        tools={"python": "3"} if mode == "run" else None,
    )
    result["created_utc"] = (START + timedelta(minutes=index)).strftime(report_module.TIMESTAMP)
    result["host"]["platform"] = platform
    result["selection"] = {"conservative": conservative}
    result["source"]["identity_sha256"] = identity if identity is not None else f"{index:064x}"
    return result


def write(directory, name, content):
    path = directory / name
    path.write_text(content if isinstance(content, str) else json.dumps(content))
    return path


def build(tmp_path, packets, minimum=2, inventory=INVENTORY):
    for index, item in enumerate(packets):
        write(tmp_path, f"p{index:04d}.json", item)
    return report_module.build_report(tmp_path, inventory, minimum)


def totals(result, origin="local", platform="macos"):
    [entry] = [entry for entry in result["overall"] if entry["key"] == {"origin": origin, "platform": platform}]
    return entry


def one(rows, **key):
    [row] = [row for row in rows if all(row["key"].get(name) == value for name, value in key.items())]
    return row


# ------------------------------------------------------------------ counting, denominators, minimum sample

def test_outcomes_are_counted_with_their_denominator_and_the_rate_comes_from_ci_stats(tmp_path, monkeypatch):
    calls = []
    real = ci_stats.failure_rate
    monkeypatch.setattr(ci_stats, "failure_rate", lambda values: calls.append(list(values)) or real(values))
    result = build(tmp_path, [packet(0), packet(1), packet(2, "failed"), packet(3)], minimum=4)
    row = one(result["by_check"], check="alpha-stage", attempt="first")
    assert (row["observations"], row["eligible"], row["failed"], row["excluded"]) == (4, 4, 1, 0)
    assert row["rate"] == 0.25 and row["label"] is None and row["outcomes"] == {"failure": 1, "success": 3}
    assert calls and all(set(values) <= {"success", "failure", "cancelled", "unavailable"} for values in calls)


def test_below_the_minimum_sample_no_rate_is_shown_only_counts_and_a_label(tmp_path):
    result = build(tmp_path, [packet(0), packet(1, "failed"), packet(2)], minimum=4)
    row = one(result["by_check"], check="alpha-stage")
    assert row["rate"] is None and row["label"] == "insufficient sample (3 eligible, 4 needed)"
    assert row["eligible"] == 3 and row["failed"] == 1 and row["seconds"] is None
    assert totals(result)["all_observations"]["rate"] is None
    text = report_module.render(result)
    assert "insufficient sample (3 eligible, 4 needed)" in text and "0.333" not in text


def test_at_the_minimum_the_rate_and_the_durations_appear(tmp_path):
    result = build(tmp_path, [packet(0, seconds=1.0), packet(1, "failed", seconds=3.0), packet(2, seconds=2.0)], minimum=3)
    row = one(result["by_check"], check="alpha-stage")
    assert row["rate"] == pytest.approx(1 / 3) and row["label"] is None
    assert row["seconds"] == {"n": 3, "p50": 2.0, "p90": ci_stats.percentile([1.0, 2.0, 3.0], 0.9)}


@pytest.mark.parametrize("bad", [True, False, "1.5", None, float("nan"), float("inf"), -1.0, 10**9, [1]])
def test_a_duration_that_is_not_a_plain_finite_number_is_ignored(tmp_path, bad):
    items = [packet(0, seconds=1.0), packet(1, seconds=2.0)]
    items[1]["checks"][0]["seconds"] = bad
    row = one(build(tmp_path, items, minimum=2)["by_check"], check="alpha-stage")
    assert row["seconds"] == {"n": 1, "p50": 1.0, "p90": 1.0}


def test_the_duration_of_an_excluded_check_never_enters_the_percentiles(tmp_path):
    items = [packet(0, seconds=1.0), packet(1, seconds=3.0), packet(2, "failed", interrupted=True, seconds=900.0), packet(3, "unavailable", seconds=800.0)]
    row = one(build(tmp_path, items, minimum=2)["by_check"], check="alpha-stage", attempt="first")
    assert row["seconds"] == {"n": 2, "p50": 2.0, "p90": ci_stats.percentile([1.0, 3.0], 0.9)}


def test_nothing_is_dropped_from_the_denominator_and_excluded_outcomes_are_counted(tmp_path):
    items = [
        packet(0), packet(1, "failed"),
        packet(2, "failed", interrupted=True),  # cancelled
        packet(3, "failed", phases={"setup": "failed", "body": "not-run", "teardown": "not-run"}),  # never started
        packet(4, "failed", subsumed_by="python-coverage"),
        packet(5, "unavailable"), packet(6, "not-run"), packet(7, "manual"), packet(8, "ci-only"), packet(9, "subsumed"), packet(10, "planned"),
    ]
    result = build(tmp_path, items, minimum=2)
    row = one(result["by_check"], check="alpha-stage", attempt="first")
    skipped = one(result["by_check"], check="alpha-stage", attempt="excluded")
    assert row["observations"] == 2 and row["eligible"] == 2 and row["failed"] == 1 and row["excluded"] == 0
    assert row["rate"] == 0.5  # 1 of the 2 eligible runs; the nine excluded ones neither help nor hurt
    assert skipped["observations"] == 9 and skipped["eligible"] == 0 and skipped["excluded"] == 9 and skipped["rate"] is None
    assert skipped["outcomes"] == {
        "cancelled": 1, "not-applicable": 2, "not-run": 1, "planned": 1, "setup-failure": 1, "subsumed": 1, "subsumed-failed": 1, "unavailable": 1,
    }
    everything = totals(result)["all_observations"]
    assert (everything["observations"], everything["eligible"], everything["failed"], everything["excluded"]) == (11, 2, 1, 9)


def test_local_and_hosted_runs_are_never_mixed_and_neither_are_platforms_selection_or_cache(tmp_path):
    reuse_present = [{"id": "x", "path": "p", "present": True, "at_execution": {"present": True}}]
    reuse_absent = [{"id": "x", "path": "p", "present": False, "at_execution": {"present": False}}]
    items = [
        packet(0), packet(1, hosted=True), packet(2, platform="linux"), packet(3, conservative=True),
        packet(4, reuse=reuse_present), packet(5, reuse=reuse_absent), packet(6, platform="plan9"),
    ]
    keys = {(row["key"]["platform"], row["key"]["origin"], row["key"]["selection"], row["key"]["cache"]) for row in build(tmp_path, items)["by_check"]}
    assert keys == {
        ("macos", "local", "narrowed", "none"), ("macos", "hosted", "narrowed", "none"), ("linux", "local", "narrowed", "none"),
        ("macos", "local", "conservative", "none"), ("macos", "local", "narrowed", "reused"), ("macos", "local", "narrowed", "fresh"),
        ("other", "local", "narrowed", "none"),
    }


@pytest.mark.parametrize(
    ("reuse", "expected"),
    [(None, "none"), ([], "none"), ("x", "none"), ([{"at_execution": {"present": True}}], "reused"), ([{"present": True}], "reused"),
     ([{"present": False, "at_execution": {"present": False}}], "fresh"), ([3], "fresh"), ([{"at_execution": None, "present": False}], "fresh")],
)
def test_cache_state_is_read_defensively(reuse, expected):
    assert report_module.cache_state({"reuse": reuse} if reuse is not None else {}) == expected


def test_plan_only_packets_execute_nothing_and_are_not_counted(tmp_path):
    result = build(tmp_path, [packet(0), packet(1, mode="plan-only"), packet(2, mode="plan-only")])
    assert result["inputs"]["plan_only_packets_not_counted"] == 2 and result["inputs"]["run_packets_used"] == 1
    assert totals(result)["all_observations"]["observations"] == 1


# ------------------------------------------------------------------ first runs, repeats, recurring failures

def test_a_rerun_of_the_same_change_is_a_qualification_repeat_and_never_offsets_a_failed_first_run(tmp_path):
    items = [packet(0, "failed", identity="a" * 64), packet(1, identity="a" * 64), packet(2, identity="a" * 64),
             packet(3, identity="b" * 64), packet(4, identity="c" * 64), packet(5, "failed", identity="b" * 64)]
    result = build(tmp_path, items, minimum=3)
    first = one(result["by_check"], attempt="first")
    repeat = one(result["by_check"], attempt="repeat")
    assert (first["observations"], first["failed"]) == (3, 1) and first["rate"] == pytest.approx(1 / 3)
    assert (repeat["observations"], repeat["failed"]) == (3, 1) and repeat["rate"] == pytest.approx(1 / 3) and repeat["label"] is None
    overall = totals(result)
    assert overall["first_runs_only"]["failed"] == 1 and overall["first_runs_only"]["observations"] == 3
    assert overall["qualification_repeats_only"]["observations"] == 3 and overall["all_observations"]["failed"] == 2
    assert overall["all_observations"]["observations"] == 6


def test_the_first_run_is_the_earliest_by_time_not_by_file_order(tmp_path):
    late_fail = packet(5, "failed", identity="a" * 64)
    early_pass = packet(1, identity="a" * 64)
    write(tmp_path, "a-listed-first.json", late_fail)
    write(tmp_path, "z-listed-last.json", early_pass)
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert one(result["by_check"], attempt="first")["failed"] == 0 and one(result["by_check"], attempt="repeat")["failed"] == 1


def test_a_packet_without_a_change_identity_is_labelled_unidentified_not_a_first_run(tmp_path):
    items = [packet(0), packet(1)]
    for item in items:
        item["source"]["identity_sha256"] = None
    result = build(tmp_path, items)
    assert [row["key"]["attempt"] for row in result["by_check"]] == ["unidentified"]


def test_recurring_failures_need_two_distinct_changes_and_ignore_repeats(tmp_path):
    items = [packet(0, "failed", identity="a" * 64), packet(1, "failed", identity="a" * 64), packet(2, "failed", identity="b" * 64),
             packet(3, "failed", identity="c" * 64, check_id="beta-stage"), packet(4, "failed", identity="d" * 64, hosted=True)]
    recurring = build(tmp_path, items)["recurring_first_run_failures"]
    assert recurring == [{
        "check": "alpha-stage", "platform": "macos", "origin": "local", "failed_first_runs": 2, "distinct_changes": 2,
        "first": START.strftime(report_module.TIMESTAMP), "last": (START + timedelta(minutes=2)).strftime(report_module.TIMESTAMP),
    }]


# ------------------------------------------------------------------ boundaries

def test_a_check_counts_toward_every_boundary_it_serves_and_an_unmapped_one_says_so(tmp_path):
    items = [packet(0, check_id="alpha-stage"), packet(1, check_id="beta-stage"), packet(2, check_id="beta-stage", status="failed")]
    result = build(tmp_path, items, minimum=1)
    one_row = one(result["by_boundary"], boundary="boundary-one")
    two_row = one(result["by_boundary"], boundary="boundary-two")
    assert (one_row["observations"], one_row["failed"]) == (3, 1)  # alpha as gate, beta as also_gate
    assert (two_row["observations"], two_row["failed"]) == (2, 1)
    assert any("overlap" in note for note in result["notes"])


def test_a_check_no_boundary_serves_is_unmapped_and_an_unknown_check_id_is_never_shown(tmp_path):
    secret = "evil-check-name-SENTINEL"
    items = [packet(0, check_id="manual-probe"), packet(1, check_id=secret)]
    result = build(tmp_path, items, minimum=1)
    assert one(result["by_boundary"], boundary="unmapped")["observations"] == 2
    # A gate of any kind is attributed (a manual one is excluded from rates elsewhere); a name the inventory does not know is not shown.
    assert {row["key"]["check"] for row in result["by_check"]} == {"unknown-check", "manual-probe"}
    assert secret not in json.dumps(result) and secret not in report_module.render(result)


def test_known_ids_come_from_command_gates_and_the_inventory_boundaries():
    services, boundaries = report_module.known_ids(INVENTORY)
    assert services == {"alpha-stage": ("boundary-one",), "beta-stage": ("boundary-one", "boundary-two"), "manual-probe": ()}
    assert boundaries == {"boundary-one", "boundary-two"}
    real_services, real_boundaries = report_module.known_ids(__import__("tools.boundary_inventory", fromlist=["load"]).load(ROOT))
    assert "native-stage" in real_services and real_boundaries


# ------------------------------------------------------------------ nothing a packet wrote reaches the output

SENTINELS = {
    "reason": "REASON-SENTINEL /Users/sentinel-user/secret.log",
    "log": "/var/tmp/LOG-SENTINEL/native.log",
    "revision": "REVISION-SENTINEL",
    "host": "HOST-SENTINEL",
    "run": "RUNID-SENTINEL",
    "token": "ghp_TOKEN-SENTINEL",
    "name": "NAME-SENTINEL",
}


def test_no_string_a_packet_wrote_reaches_the_json_or_the_markdown(tmp_path):
    item = packet(0, "failed", reason=SENTINELS["reason"], log=SENTINELS["log"], entrypoint=[SENTINELS["name"]])
    item["source"]["revision"] = SENTINELS["revision"]
    item["host"].update(system=SENTINELS["host"], release=SENTINELS["host"], machine=SENTINELS["host"])
    item["environment"].update(GITHUB_RUN_ID=SENTINELS["run"], GITHUB_REPOSITORY=SENTINELS["name"], GITHUB_REF_NAME=SENTINELS["token"])
    item["invocation"]["argv"] = [SENTINELS["token"]]
    item["account"]["nss"]["name"] = SENTINELS["name"]
    result = build(tmp_path, [item], minimum=1)
    text = json.dumps(result, sort_keys=True) + report_module.render(result)
    for value in SENTINELS.values():
        assert value not in text and value.split()[0] not in text, value
    assert "sentinel-user" not in text


def test_every_string_in_the_report_comes_from_a_closed_vocabulary(tmp_path):
    items = [packet(0), packet(1, "failed", check_id="beta-stage", hosted=True, platform="linux", conservative=True), packet(2, check_id="zzz")]
    result = build(tmp_path, items, minimum=1)
    allowed_keys = {"check", "platform", "origin", "selection", "cache", "attempt", "boundary"}
    values = set()

    def walk(node, path=()):
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, (*path, key))
        elif isinstance(node, list):
            for value in node:
                walk(value, path)
        elif isinstance(node, str) and "key" in path:
            values.add((path[-1], node))

    walk(result)
    assert {name for name, _value in values} <= allowed_keys
    vocabulary = {
        "check": {"alpha-stage", "beta-stage", "unknown-check"}, "platform": {"linux", "macos", "other"}, "origin": {"hosted", "local"},
        "selection": {"conservative", "narrowed", "unknown"}, "cache": {"none", "reused", "fresh"},
        "attempt": {"first", "repeat", "unidentified"}, "boundary": {"boundary-one", "boundary-two", "unmapped"},
    }
    assert all(value in vocabulary[name] for name, value in values)
    text = report_module.render(result)
    assert all(0x20 <= ord(char) <= 0x7E or char == "\n" for char in text)


def test_the_report_names_no_path_user_or_host(tmp_path):
    item = packet(0)
    item["invocation"].update(cwd="/Users/ada/src", root="/Users/ada/src", executable="/Users/ada/bin/python")
    text = json.dumps(build(tmp_path, [item])) + report_module.render(build(tmp_path, [item]))
    assert "/Users" not in text and "/src" not in text and "bin/python" not in text


# ------------------------------------------------------------------ hostile input

def count(result, reason):
    return result["inputs"]["rejected"][reason]


def test_malformed_foreign_and_invalid_files_are_counted_by_reason_not_shown(tmp_path):
    write(tmp_path, "good.json", packet(0))
    write(tmp_path, "notjson.json", "{not json")
    (tmp_path / "binary.json").write_bytes(b"\xff\xfe\x00 garbage")
    write(tmp_path, "list.json", "[1, 2]")
    write(tmp_path, "foreign.json", {"kind": "something-else", "secret": "FOREIGN-SENTINEL"})
    broken = packet(1)
    broken["checks"] = ["x"]
    write(tmp_path, "badchecks.json", broken)
    badtime = packet(2)
    badtime["created_utc"] = "yesterday"
    write(tmp_path, "badtime.json", badtime)
    wrong = packet(3)
    wrong["host"] = []
    write(tmp_path, "wronghost.json", wrong)
    write(tmp_path, "readme.txt", "ignored, not json by name")
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["inputs"]["run_packets_used"] == 1
    assert count(result, "not-json") == 2 and count(result, "not-an-evidence-summary") == 2
    assert count(result, "invalid-evidence") == 2 and count(result, "bad-timestamp") == 1
    assert "FOREIGN-SENTINEL" not in json.dumps(result) + report_module.render(result)
    assert "Rejected (counted, never shown)" in report_module.render(result)


def test_deeply_nested_json_is_a_rejection_not_a_crash(tmp_path):
    write(tmp_path, "deep.json", "[" * 200_000)
    write(tmp_path, "good.json", packet(0))
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert count(result, "not-json") == 1 and result["inputs"]["run_packets_used"] == 1


def test_identical_files_are_counted_once(tmp_path):
    item = packet(0)
    write(tmp_path, "a.json", item)
    write(tmp_path, "b.json", item)
    write(tmp_path, "c.json", json.dumps(item))
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["inputs"]["run_packets_used"] == 1 and count(result, "duplicate") == 2


def test_symlinks_fifos_and_oversized_files_are_never_followed_or_read(tmp_path, monkeypatch):
    outside = tmp_path / "outside"
    outside.mkdir()
    real = write(outside, "real.json", packet(0))
    inside = tmp_path / "in"
    inside.mkdir()
    (inside / "link.json").symlink_to(real)
    (inside / "dirlink").symlink_to(outside)
    os.mkfifo(inside / "pipe.json")
    write(inside, "big.json", packet(1))
    monkeypatch.setattr(report_module.validation_replay, "MAX_PACKET_BYTES", 100)
    result = report_module.build_report(inside, INVENTORY, 1)
    assert result["inputs"]["run_packets_used"] == 0
    assert count(result, "not-a-regular-file") == 2 and count(result, "too-large") == 1


def test_read_packet_classifies_why_a_file_was_not_read(tmp_path, monkeypatch):
    fifo = tmp_path / "pipe.json"
    os.mkfifo(fifo)
    assert report_module.read_packet(fifo) == (None, "not-a-regular-file")
    assert report_module.read_packet(tmp_path / "missing.json") == (None, "unreadable")
    big = write(tmp_path, "big.json", "x" * 50)
    monkeypatch.setattr(report_module.validation_replay, "MAX_PACKET_BYTES", 10)
    assert report_module.read_packet(big) == (None, "too-large")
    monkeypatch.setattr(report_module.validation_replay, "MAX_PACKET_BYTES", 1000)
    assert report_module.read_packet(big) == (b"x" * 50, None)


def test_the_file_cap_makes_the_report_incomplete_and_says_so(tmp_path, monkeypatch):
    monkeypatch.setattr(report_module, "MAX_FILES", 3)
    for index in range(6):
        write(tmp_path, f"p{index}.json", packet(index))
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["complete"] is False and result["inputs"]["files_considered"] == 3 and count(result, "file-cap") == 1
    assert "NO, a cap cut the read short" in report_module.render(result)


def test_the_byte_budget_makes_the_report_incomplete(tmp_path, monkeypatch):
    for index in range(5):
        write(tmp_path, f"p{index}.json", packet(index))
    size = len((tmp_path / "p0.json").read_bytes())
    monkeypatch.setattr(report_module, "MAX_TOTAL_BYTES", size * 2 + 10)
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["complete"] is False and count(result, "byte-budget") == 1 and result["inputs"]["run_packets_used"] == 2


def test_the_directory_depth_and_count_caps_are_enforced(tmp_path, monkeypatch):
    deep = tmp_path
    for level in range(report_module.MAX_DEPTH + 2):
        deep = deep / f"d{level}"
        deep.mkdir()
        write(deep, "p.json", packet(level))
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["inputs"]["run_packets_used"] == report_module.MAX_DEPTH  # d0..d2 are read; d3 and d4 lie deeper than the limit
    monkeypatch.setattr(report_module, "MAX_DIRECTORIES", 2)
    assert report_module.build_report(tmp_path, INVENTORY, 1)["complete"] is False


def test_an_unreadable_file_or_directory_is_a_rejection(tmp_path):
    if os.geteuid() != 0:
        locked = write(tmp_path, "locked.json", packet(0))
        locked.chmod(0)
        folder = tmp_path / "folder"
        folder.mkdir()
        write(folder, "inside.json", packet(1))
        folder.chmod(0)
        try:
            result = report_module.build_report(tmp_path, INVENTORY, 1)
        finally:
            locked.chmod(0o644)
            folder.chmod(0o755)
        assert count(result, "unreadable") == 2 and result["inputs"]["run_packets_used"] == 0


def test_a_packet_that_breaks_extraction_is_rejected_whatever_it_breaks(tmp_path, monkeypatch):
    write(tmp_path, "a.json", packet(0))
    monkeypatch.setattr(report_module, "observations", lambda *a: (_ for _ in ()).throw(RuntimeError("boom")))
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert count(result, "invalid-evidence") == 1 and result["overall"] == []


# ------------------------------------------------------------------ window, baseline, rendering, CLI

def test_the_window_is_the_packets_own_and_an_empty_directory_has_none(tmp_path):
    result = build(tmp_path, [packet(0), packet(30)])
    assert result["window"] == {"first": START.strftime(report_module.TIMESTAMP), "last": (START + timedelta(minutes=30)).strftime(report_module.TIMESTAMP)}
    empty = tmp_path / "empty"
    empty.mkdir()
    nothing = report_module.build_report(empty, INVENTORY, 5)
    assert nothing["window"] == {"first": None, "last": None} and nothing["by_check"] == [] and nothing["overall"] == []
    assert "Window: none to none" in report_module.render(nothing)


def test_the_report_never_reads_or_compares_a_baseline_and_hardcodes_no_window():
    source = Path(report_module.__file__).read_text()
    assert not re.search(r"20\d\d-\d\d-\d\d", source) and "October" not in source and "Oct " not in source
    assert "read_text" not in source and "open(" not in source.replace("os.fdopen", "")
    result = report_module.build_report(ROOT / "docs", INVENTORY, 1)
    assert result["baseline"].startswith("fresh: this window only") and "No improvement, regression or flakiness claim" in " ".join(result["notes"])


def test_render_is_deterministic_and_marks_what_it_withholds(tmp_path):
    items = [packet(0), packet(1, "failed"), packet(2, "failed", interrupted=True)]
    first = report_module.render(build(tmp_path, items, minimum=5))
    second = report_module.render(report_module.build_report(tmp_path, INVENTORY, 5))
    assert first == second
    assert "insufficient sample (2 eligible, 5 needed)" in first
    assert "Complete: yes" in first and first.endswith("\n")


def test_publish_writes_an_owner_only_file_and_refuses_symlinks_and_silent_replacement(tmp_path):
    source = tmp_path / "in"
    source.mkdir()
    result = build(source, [packet(0)])
    destination = tmp_path / "out" / "baseline.json"
    report_module.publish(result, destination)
    assert stat.S_IMODE(destination.stat().st_mode) == 0o600 and json.loads(destination.read_text())["kind"] == report_module.KIND
    with pytest.raises(ValueError, match="already exists"):
        report_module.publish(result, destination)
    report_module.publish(result, destination, replace=True)
    link = tmp_path / "link.json"
    link.symlink_to(destination)
    with pytest.raises(ValueError, match="symlink"):
        report_module.publish(result, link, replace=True)
    assert not [name for name in os.listdir(destination.parent) if name.startswith(".reliability-")]


def test_a_failed_publish_leaves_no_partial_file(tmp_path, monkeypatch):
    monkeypatch.setattr(report_module.os, "fsync", lambda descriptor: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError):
        report_module.publish({"kind": "x"}, tmp_path / "b.json")
    assert os.listdir(tmp_path) == []


def test_cli_prints_markdown_or_json_and_writes_a_baseline_only_from_a_complete_read(tmp_path, capsys, monkeypatch):
    directory = tmp_path / "evidence"
    directory.mkdir()
    for index in range(3):
        write(directory, f"p{index}.json", packet(index))
    baseline = tmp_path / "baseline.json"
    assert report_module.main([str(directory), "--minimum-sample", "2", "--write-baseline", str(baseline)], inventory=INVENTORY) == 0
    assert capsys.readouterr().out.startswith("# Validation reliability report") and baseline.exists()
    assert report_module.main([str(directory), "--json", "--minimum-sample", "2"], inventory=INVENTORY) == 0
    assert json.loads(capsys.readouterr().out)["kind"] == report_module.KIND
    assert report_module.main([str(directory), "--write-baseline", str(baseline)], inventory=INVENTORY) == 2  # exists: no silent replacement
    assert "already exists" in capsys.readouterr().err
    assert report_module.main([str(directory), "--write-baseline", str(baseline), "--replace"], inventory=INVENTORY) == 0
    capsys.readouterr()
    monkeypatch.setattr(report_module, "MAX_FILES", 1)
    other = tmp_path / "other.json"
    assert report_module.main([str(directory), "--write-baseline", str(other)], inventory=INVENTORY) == 3
    assert not other.exists() and "no baseline is written" in capsys.readouterr().err
    assert report_module.main([str(directory)], inventory=INVENTORY) == 3  # printed, but marked incomplete


@pytest.mark.parametrize("argv", [["{dir}/nowhere"], ["{dir}", "--minimum-sample", "0"], ["{dir}", "--minimum-sample", "-3"], ["{link}"]])
def test_cli_refuses_a_missing_or_linked_directory_and_a_nonsense_minimum(tmp_path, capsys, argv):
    real = tmp_path / "real"
    real.mkdir()
    (tmp_path / "linked").symlink_to(real)
    arguments = [item.format(dir=real, link=tmp_path / "linked") for item in argv]
    assert report_module.main(arguments, inventory=INVENTORY) == 2
    assert capsys.readouterr().err.startswith("reliability_report:")


def test_abbreviated_flags_are_refused():
    with pytest.raises(SystemExit):
        report_module.main(["somewhere", "--minimum", "3"], inventory=INVENTORY)


def test_the_real_inventory_maps_real_checks_to_boundaries(tmp_path):
    from tools import boundary_inventory

    item = packet(0, check_id="native-stage")
    result = report_module.build_report(build_dir(tmp_path, [item]), boundary_inventory.load(ROOT), 1)
    assert one(result["by_check"], check="native-stage")["observations"] == 1
    assert any(row["key"]["boundary"] != "unmapped" for row in result["by_boundary"])


def build_dir(tmp_path, packets):
    for index, item in enumerate(packets):
        write(tmp_path, f"p{index}.json", copy.deepcopy(item))
    return tmp_path


def test_evidence_summaries_written_by_the_real_builder_are_accepted(tmp_path):
    built = evidence.build_summary(
        mode="run", source={"mode": "explicit", "identity_sha256": "e" * 64, "dirty": False}, invocation={"entrypoint": "tools.validate_change", "argv": []},
        selection={"conservative": True}, checks=[check("alpha-stage", "passed", seconds=4.0)], unexecuted_platforms=[], reproduction=[],
        environ={"GITHUB_ACTIONS": "true"}, tools={"python": "3"}, pins={},
    )
    write(tmp_path, "evidence.json", built)
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    row = one(result["by_check"], check="alpha-stage")
    assert (row["key"]["origin"], row["key"]["selection"]) == ("hosted", "conservative") and row["eligible"] == 1


# ------------------------------------------------------------------ review round: first executions, silent skips, mixed totals

@pytest.mark.parametrize("before", ["not-run", "unavailable", "planned", "manual", "subsumed"])
def test_an_attempt_that_never_executed_does_not_consume_the_first_run_slot(tmp_path, before):
    same = "a" * 64
    items = [packet(0, before, identity=same), packet(1, "failed", identity=same), packet(2, identity=same)]
    result = build(tmp_path, items, minimum=1)
    assert one(result["by_check"], attempt="first")["failed"] == 1
    assert one(result["by_check"], attempt="repeat")["failed"] == 0 and one(result["by_check"], attempt="excluded")["observations"] == 1
    scoped = totals(result)
    assert scoped["first_runs_only"]["eligible"] == 1 and scoped["first_runs_only"]["failed"] == 1
    assert scoped["qualification_repeats_only"]["eligible"] == 1


def test_a_cancelled_or_never_started_first_attempt_is_excluded_and_the_next_executed_one_is_first(tmp_path):
    same = "b" * 64
    items = [packet(0, "failed", identity=same, interrupted=True), packet(1, "failed", identity=same, phases={"setup": "failed", "body": "not-run", "teardown": "not-run"}),
             packet(2, "failed", identity=same)]
    result = build(tmp_path, items, minimum=1)
    assert one(result["by_check"], attempt="first")["failed"] == 1 and one(result["by_check"], attempt="excluded")["observations"] == 2


def test_a_recurring_failure_is_found_when_each_first_execution_followed_a_skipped_attempt(tmp_path):
    items = []
    for number, identity in enumerate(("a" * 64, "b" * 64)):
        items += [packet(number * 2, "not-run", identity=identity), packet(number * 2 + 1, "failed", identity=identity)]
    recurring = build(tmp_path, items, minimum=1)["recurring_first_run_failures"]
    assert [(item["check"], item["failed_first_runs"], item["distinct_changes"]) for item in recurring] == [("alpha-stage", 2, 2)]


def test_a_failure_then_a_pass_still_counts_the_failure_as_the_first_run(tmp_path):
    same = "c" * 64
    result = build(tmp_path, [packet(0, "failed", identity=same), packet(1, identity=same)], minimum=1)
    assert one(result["by_check"], attempt="first")["failed"] == 1 and one(result["by_check"], attempt="repeat")["failed"] == 0


def gh_layout(root, failing=True):
    """What `gh run download` produces: a run directory, an artifact, a job directory, then the evidence directory."""
    write(root, "top.json", packet(0))
    nested = root / "run1" / "artifact" / "job" / "validation"
    nested.mkdir(parents=True)
    write(nested, "evidence.json", packet(1, "failed" if failing else "passed"))
    return nested


def test_a_gh_run_download_layout_is_read_to_its_depth(tmp_path):
    gh_layout(tmp_path)
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["complete"] is True and result["inputs"]["run_packets_used"] == 2 and totals(result)["all_observations"]["failed"] == 1


def test_directories_beyond_the_depth_cap_make_the_report_incomplete_and_are_counted(tmp_path, monkeypatch, capsys):
    gh_layout(tmp_path)
    monkeypatch.setattr(report_module, "MAX_DEPTH", 3)
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["complete"] is False and count(result, "depth-cap") == 1 and result["inputs"]["run_packets_used"] == 1
    assert totals(result)["all_observations"]["failed"] == 0  # the failed packet is exactly what was not read
    baseline = tmp_path.parent / "baseline.json"
    assert report_module.main([str(tmp_path), "--write-baseline", str(baseline)], inventory=INVENTORY) == 3
    assert not baseline.exists() and "no baseline is written" in capsys.readouterr().err
    assert "depth-cap 1" in report_module.render(result) and "NO, a cap cut the read short" in report_module.render(result)


def test_the_default_depth_cap_is_enforced_too(tmp_path):
    deep = tmp_path
    for level in range(report_module.MAX_DEPTH + 1):
        deep = deep / f"d{level}"
        deep.mkdir()
    write(deep, "p.json", packet(0))
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["complete"] is False and count(result, "depth-cap") == 1 and result["inputs"]["run_packets_used"] == 0


@pytest.mark.parametrize("fault", ["directory", "file", "oversize"])
def test_data_that_exists_but_was_not_read_makes_the_report_incomplete(tmp_path, monkeypatch, fault):
    if os.geteuid() == 0 and fault != "oversize":
        return  # root reads a mode-0 file; there is nothing unread to report
    write(tmp_path, "ok.json", packet(0))
    if fault == "directory":
        folder = tmp_path / "locked"
        folder.mkdir()
        write(folder, "p.json", packet(1, "failed"))
        folder.chmod(0)
        target = folder
    elif fault == "file":
        target = write(tmp_path, "locked.json", packet(1, "failed"))
        target.chmod(0)
    else:
        target = None
        monkeypatch.setattr(report_module.validation_replay, "MAX_PACKET_BYTES", (tmp_path / "ok.json").stat().st_size + 200)
        write(tmp_path, "large.json", {**packet(1, "failed"), "padding": "x" * 5000})
    try:
        result = report_module.build_report(tmp_path, INVENTORY, 1)
    finally:
        if target is not None:
            target.chmod(0o755 if target.is_dir() else 0o644)
    assert result["complete"] is False and totals(result)["all_observations"]["failed"] == 0


def test_rejections_that_lose_no_data_leave_the_report_complete(tmp_path):
    write(tmp_path, "ok.json", packet(0))
    write(tmp_path, "dup.json", packet(0))
    write(tmp_path, "junk.json", "{not json")
    write(tmp_path, "foreign.json", {"kind": "other"})
    (tmp_path / "link.json").symlink_to(tmp_path / "ok.json")
    os.mkfifo(tmp_path / "pipe.json")
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["complete"] is True and count(result, "duplicate") == 1 and count(result, "not-a-regular-file") == 2


def test_local_and_hosted_totals_are_never_mixed_into_one_rate(tmp_path):
    items = [packet(0, "failed"), packet(1, hosted=True), packet(2, platform="linux")]
    result = build(tmp_path, items, minimum=1)
    keys = [entry["key"] for entry in result["overall"]]
    assert keys == [{"origin": "hosted", "platform": "macos"}, {"origin": "local", "platform": "linux"}, {"origin": "local", "platform": "macos"}]
    assert totals(result)["all_observations"]["rate"] == 1.0
    assert totals(result, "hosted")["all_observations"]["rate"] == 0.0 and totals(result, "local", "linux")["all_observations"]["failed"] == 0
    assert not any(entry["key"]["origin"] == "mixed" for entry in result["overall"])
    text = report_module.render(result)
    assert "| local | macos | all observations |" in text and "| hosted | macos | first runs only |" in text


def test_every_gate_kind_in_the_inventory_is_attributed_and_still_excluded_from_rates(tmp_path):
    from tools import boundary_inventory

    inventory = boundary_inventory.load(ROOT)
    services, _boundaries = report_module.known_ids(inventory)
    assert {name for name, gate in inventory["gates"].items() if gate["kind"] != "command"} <= set(services)
    kinds = {gate["kind"] for gate in inventory["gates"].values()}
    assert kinds - {"command"}
    manual = next(name for name, gate in inventory["gates"].items() if gate["kind"] != "command")
    result = report_module.build_report(build_dir(tmp_path, [packet(0, "manual", check_id=manual)]), inventory, 1)
    row = one(result["by_check"], check=manual)
    assert row["key"]["attempt"] == "excluded" and row["eligible"] == 0 and row["rate"] is None


def test_packets_created_in_the_same_second_are_ordered_by_their_recorded_start_time(tmp_path):
    import hashlib

    same = "d" * 64
    early, late = packet(0, "failed", identity=same), packet(0, identity=same)
    early["invocation"]["started_epoch"] = 1000.250
    late["invocation"]["started_epoch"] = 1000.750
    # Pad the early packet until its content digest sorts after the late one's: the digest order is then the wrong order.
    for pad in range(1000):
        early["pad"] = pad
        if hashlib.sha256(json.dumps(early).encode()).hexdigest() > hashlib.sha256(json.dumps(late).encode()).hexdigest():
            break
    for name, item in (("a.json", late), ("b.json", early)):  # file order is wrong too
        write(tmp_path, name, item)
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert one(result["by_check"], attempt="first")["failed"] == 1 and one(result["by_check"], attempt="repeat")["failed"] == 0
    assert report_module.sequence({"invocation": {"started_epoch": True}}) == 0.0 and report_module.sequence({"invocation": {"started_epoch": float("nan")}}) == 0.0
    assert report_module.sequence({"invocation": None}) == 0.0 and report_module.sequence({"invocation": {"started_epoch": "9"}}) == 0.0
    assert report_module.sequence({"invocation": {"started_epoch": 12}}) == 12.0


# ------------------------------------------------------------------ review round: memory, timestamps, trust

def many_checks(count, **kwargs):
    item = packet(0, **kwargs)
    item["checks"] = [check("alpha-stage", "passed", seconds=1.0) for _ in range(count)]
    return item


def test_a_packet_with_too_many_checks_is_a_rejection_and_makes_the_report_incomplete(tmp_path, capsys):
    assert report_module.MAX_CHECKS_PER_PACKET == 256
    write(tmp_path, "ok.json", many_checks(report_module.MAX_CHECKS_PER_PACKET))
    write(tmp_path, "huge.json", {**many_checks(report_module.MAX_CHECKS_PER_PACKET + 1), "created_utc": "2026-10-02T00:00:00Z"})
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert count(result, "too-many-checks") == 1 and result["inputs"]["run_packets_used"] == 1
    assert result["complete"] is False and totals(result)["all_observations"]["observations"] == report_module.MAX_CHECKS_PER_PACKET
    baseline = tmp_path.parent / "b.json"
    assert report_module.main([str(tmp_path), "--write-baseline", str(baseline)], inventory=INVENTORY) == 3 and not baseline.exists()
    assert "too-many-checks 1" in report_module.render(result)


def test_the_total_observation_cap_stops_ingestion_and_makes_the_report_incomplete(tmp_path, monkeypatch):
    monkeypatch.setattr(report_module, "MAX_OBSERVATIONS", 25)
    for index in range(4):
        write(tmp_path, f"p{index}.json", many_checks(10) | {"created_utc": f"2026-10-0{index + 1}T00:00:00Z"})
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    assert result["complete"] is False and count(result, "observation-cap") == 1
    assert result["inputs"]["run_packets_used"] == 2 and totals(result)["all_observations"]["observations"] == 20


def test_a_parsed_packet_is_not_retained_after_its_rows_are_taken(tmp_path, monkeypatch):
    import gc
    import weakref

    class Parsed(dict):
        pass

    refs = []
    real = report_module.json.loads

    def tracking(data):
        gc.collect()
        assert all(ref() is None for ref in refs), "an earlier parsed packet is still alive while the next is read"
        parsed = Parsed(real(data))
        refs.append(weakref.ref(parsed))
        return parsed

    monkeypatch.setattr(report_module.json, "loads", tracking)
    for index in range(5):
        write(tmp_path, f"p{index}.json", packet(index))
    result = report_module.build_report(tmp_path, INVENTORY, 1)
    gc.collect()
    assert len(refs) == 5 and result["inputs"]["run_packets_used"] == 5
    assert all(ref() is None for ref in refs)


def test_a_row_is_a_slotted_record_of_closed_fields_and_nothing_else(tmp_path):
    rows = report_module.ingest(build_dir(tmp_path, [packet(0)]), {"alpha-stage": ("boundary-one",)})["rows"]
    [row] = rows
    assert isinstance(row, report_module.Row) and not hasattr(row, "__dict__")
    assert row["check"] == "alpha-stage" and row.boundaries == ("boundary-one",)
    row["attempt"] = "repeat"
    assert row.attempt == "repeat"
    with pytest.raises(AttributeError):
        row.packet = {}


@pytest.mark.parametrize("identity", ["g" * 64, "A" * 64, "a" * 63, "a" * 65, "x" * 100_000, "", "../etc/passwd", 7])
def test_an_identity_that_is_not_a_sha256_is_unidentified_and_never_kept(tmp_path, identity):
    item = packet(0)
    item["source"]["identity_sha256"] = identity
    [row] = report_module.ingest(build_dir(tmp_path, [item]), {"alpha-stage": ()})["rows"]
    assert row.identity is None and row.attempt == "unidentified"


NOW = datetime(2026, 10, 28, 12, 0, 0)


def stamped(index, stamp, **kwargs):
    item = packet(index, **kwargs)
    item["created_utc"] = stamp
    return item


@pytest.mark.parametrize(
    ("stamp", "accepted"),
    [
        ("1999-01-01T00:00:00Z", False), ("2025-12-31T23:59:59Z", False), ("2026-01-01T00:00:00Z", True), ("2026-10-28T12:00:00Z", True),
        ("2026-10-29T12:00:00Z", True), ("2026-10-29T12:00:01Z", False), ("2099-01-01T00:00:00Z", False),
    ],
)
def test_a_timestamp_outside_the_plausible_window_is_rejected(tmp_path, stamp, accepted):
    write(tmp_path, "p.json", stamped(0, stamp))
    result = report_module.build_report(tmp_path, INVENTORY, 1, now=NOW)
    assert result["inputs"]["run_packets_used"] == int(accepted) and count(result, "implausible-timestamp") == int(not accepted)
    assert result["complete"] is True  # a forged date loses nothing real


def test_a_back_dated_forgery_cannot_displace_a_real_failed_first_run(tmp_path):
    same = "f" * 64
    write(tmp_path, "real.json", stamped(0, "2026-10-01T12:00:00Z", status="failed", identity=same))
    write(tmp_path, "forged.json", stamped(1, "1999-01-01T00:00:00Z", identity=same))
    result = report_module.build_report(tmp_path, INVENTORY, 1, now=NOW)
    assert one(result["by_check"], attempt="first")["failed"] == 1 and count(result, "implausible-timestamp") == 1
    assert not [row for row in result["by_check"] if row["key"]["attempt"] == "repeat"]


def test_the_report_says_its_inputs_are_unauthenticated_and_counts_distinct_sources(tmp_path):
    items = [packet(0, hosted=True), packet(1, hosted=True), packet(2), packet(3)]
    for item in items[:2]:  # the same hosted run twice
        item["environment"].update(GITHUB_RUN_ID="100", GITHUB_RUN_ATTEMPT="1")
    result = build(tmp_path, items, minimum=1)
    assert result["sources"] == {"hosted_runs": 1, "local_origins": 1}
    assert "unauthenticated" in result["trust"] and "pull requests you did not collect yourself" in result["trust"]
    text = report_module.render(result)
    assert "Inputs are unauthenticated" in text and "1 hosted runs, 1 local origins" in text
    nowhere = tmp_path / "nowhere"
    nowhere.mkdir()
    assert report_module.build_report(nowhere, INVENTORY, 1)["sources"] == {"hosted_runs": 0, "local_origins": 0}
    assert "100" not in text  # the run id is counted, never shown


def test_a_rerun_attempt_of_a_hosted_run_is_a_distinct_source(tmp_path):
    items = [packet(0, hosted=True), packet(1, hosted=True), packet(2, hosted=True)]
    for item, (run, attempt) in zip(items, (("100", "1"), ("100", "2"), ("101", "1")), strict=True):
        item["environment"].update(GITHUB_RUN_ID=run, GITHUB_RUN_ATTEMPT=attempt)
    assert build(tmp_path, items, minimum=1)["sources"] == {"hosted_runs": 3, "local_origins": 0}
