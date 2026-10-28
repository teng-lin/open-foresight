"""The failure ledger is data: owned or explicitly unassigned, closed only by a test, and generated into the document."""

import copy
import json
import os
from pathlib import Path
import subprocess

import pytest

from tools import failure_ledger as ledger

ROOT = Path(__file__).resolve().parents[1]
SHA_A = "a" * 40
SHA_B = "b" * 40


def base():
    return {
        "schema": 1,
        "source": "nightly run 1 at abc, tracked by #1",
        "entries": [
            {
                "id": "L1", "kind": "failure", "first_job": "`job-a`", "class": "UNKNOWN", "error": "it timed out",
                "owner": None, "owner_status": "unassigned", "next_experiment": "run it 200 times", "exit_criterion": "name the phase",
                "status": "open", "status_note": "evidence added", "reruns": [],
            },
            {
                "id": "L2", "kind": "failure", "first_job": "`job-b`", "class": "dependency", "class_note": "transient, per triage",
                "class_evidence": ["triage of run 1"], "error": "mirror out of sync", "owner": None, "owner_status": "unassigned",
                "next_experiment": "fixture mirror", "exit_criterion": "reported as dependency", "status": "open", "status_note": "", "reruns": [],
            },
            {
                "id": "L3", "kind": "consequence", "first_job": "`aggregate`", "error": "aggregate of L1 and L2", "owner": None,
                "owner_status": "not-applicable", "causes": ["L1", "L2"], "next_experiment": "none", "exit_criterion": "green when L1 and L2 close",
                "status": "consequence-only", "status_note": "",
            },
        ],
    }


def workspace(tmp_path, data=None, document=True, control="def test_the_control(): pass\n"):
    root = tmp_path / "repo"
    (root / "tools").mkdir(parents=True)
    (root / "docs").mkdir()
    (root / "tests").mkdir()
    data = base() if data is None else data
    (root / ledger.DATA).write_text(json.dumps(data) if not isinstance(data, str) else data)
    (root / "tests/test_controls.py").write_text(control)
    if document:
        table = ledger.render_table(data) if isinstance(data, dict) and not ledger.validate(data, root) else "| x |"
        (root / ledger.DOCUMENT).write_text(f"# Testing\n\nintro\n\n{ledger.BEGIN}\n{table}\n{ledger.END}\n\ntail\n")
    return root


def closed_entry(**closed_by):
    entry = base()["entries"][1]
    entry.update(status="closed", status_note="", closed_by={"test": "tests/test_controls.py::test_the_control", "failing_before": SHA_A, "passing_after": SHA_B, **closed_by})
    return entry


def problems_for(tmp_path, data):
    root = workspace(tmp_path, data)
    return ledger.validate(data, root)


# ------------------------------------------------------------------ the real ledger

def test_the_real_ledger_is_consistent_and_the_document_table_is_generated_from_it():
    report = ledger.check(ROOT)
    assert report["problems"] == [] and report["unreadable"] is False and report["entries"] == 5
    document = (ROOT / ledger.DOCUMENT).read_text()
    assert ledger.extract_table(document) == ledger.render_table(ledger.load(ROOT))
    assert "tools/failure_ledger.json" in document and "tests/test_failure_ledger.py" in document


def test_no_owner_has_been_invented_and_no_rerun_or_aggregate_has_closed_anything():
    entries = {entry["id"]: entry for entry in ledger.load(ROOT)["entries"]}
    assert set(entries) == {"L1", "L2", "L3", "L4", "L5"}
    for name in ("L1", "L2", "L3", "L4"):
        assert entries[name]["owner"] is None and entries[name]["owner_status"] == "unassigned", name
        assert entries[name]["status"] in ("open", "mitigated") and "closed_by" not in entries[name]
    assert [entries[name]["class"] for name in ("L1", "L2", "L3")] == ["UNKNOWN"] * 3  # no evidence has been cited for a class
    assert entries["L4"]["class"] == "dependency" and entries["L4"]["class_evidence"]
    assert entries["L5"]["kind"] == "consequence" and entries["L5"]["causes"] == ["L1", "L2", "L3", "L4"] and entries["L5"]["status"] == "consequence-only"
    rendered = ledger.render_table(ledger.load(ROOT))
    assert rendered.count(ledger.UNASSIGNED) == 4


def test_the_guard_depends_on_nothing_but_the_standard_library():
    import ast

    imported = set()
    for node in ast.walk(ast.parse((ROOT / "tools/failure_ledger.py").read_text())):
        if isinstance(node, ast.Import):
            imported |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom):
            imported.add((node.module or "").split(".")[0])
    assert imported <= {"__future__", "argparse", "collections", "json", "pathlib", "re", "subprocess", "sys", "typing"}, imported


# ------------------------------------------------------------------ owners

@pytest.mark.parametrize(
    ("damage", "fragment"),
    [
        (lambda e: e.pop("owner_status"), "an entry with no owner must say unassigned"),
        (lambda e: e.update(owner_status=None), "an entry with no owner must say unassigned"),
        (lambda e: e.update(owner_status="nobody"), "owner_status must be assigned, unassigned or not-applicable"),
        (lambda e: e.update(owner="Someone"), "owner must be null when owner_status is unassigned"),
        (lambda e: e.update(owner_status="assigned"), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="assigned", owner="  "), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="assigned", owner=""), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="assigned", owner="Unassigned: needs named owner"), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="assigned", owner="unassigned"), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="assigned", owner="x" * 201), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="assigned", owner="Name\x1b[31m"), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="assigned", owner=7), "an assigned owner must be a name"),
        (lambda e: e.update(owner_status="not-applicable"), "only a consequence can have owner_status not-applicable"),
    ],
)
def test_an_entry_needs_a_named_owner_or_the_explicit_unassigned_marker(tmp_path, damage, fragment):
    data = base()
    damage(data["entries"][0])
    assert any(fragment in problem and problem.startswith("L1:") for problem in problems_for(tmp_path, data)), fragment


def test_a_named_owner_is_accepted_and_rendered_as_given(tmp_path):
    data = base()
    data["entries"][0].update(owner_status="assigned", owner="Ada Lovelace")
    root = workspace(tmp_path, data)
    assert ledger.validate(data, root) == []
    assert "| Ada Lovelace |" in ledger.render_table(data) and ledger.render_table(data).count(ledger.UNASSIGNED) == 1


def test_a_consequence_has_no_owner(tmp_path):
    data = base()
    data["entries"][2].update(owner_status="unassigned")
    assert any("a consequence has no owner" in problem for problem in problems_for(tmp_path, data))
    data = base()
    data["entries"][2].update(owner="Someone")
    assert any("a consequence has no owner" in problem for problem in problems_for(tmp_path / "b", data))


# ------------------------------------------------------------------ classes stay UNKNOWN until evidence is cited

@pytest.mark.parametrize(
    ("damage", "fragment"),
    [
        (lambda e: e.update({"class": "flaky"}), "class must be one of"),
        (lambda e: e.update({"class": "product"}), "class product needs class_evidence"),
        (lambda e: e.update({"class": "environment", "class_evidence": []}), "class environment needs class_evidence"),
        (lambda e: e.update({"class_evidence": ["a run"]}), "class_evidence is cited but the class is UNKNOWN"),
        (lambda e: e.pop("class"), "class must be one of"),
    ],
)
def test_a_class_is_unknown_until_evidence_supports_it(tmp_path, damage, fragment):
    data = base()
    damage(data["entries"][0])
    assert any(fragment in problem for problem in problems_for(tmp_path, data)), fragment


def test_a_class_with_cited_evidence_is_accepted(tmp_path):
    data = base()
    data["entries"][0].update({"class": "fixture", "class_evidence": ["run 7 shows the fixture lease"]})
    assert problems_for(tmp_path, data) == []


@pytest.mark.parametrize("evidence", ["a string", [1], [""], ["x"] * 51, ["x" * 4001]])
def test_class_evidence_is_a_short_list_of_text(tmp_path, evidence):
    data = base()
    data["entries"][1]["class_evidence"] = evidence
    assert any("class_evidence must be a short list of non-empty text" in problem for problem in problems_for(tmp_path, data))


# ------------------------------------------------------------------ status, reruns and closing

def test_a_successful_rerun_never_closes_an_entry_and_is_only_recorded(tmp_path):
    data = base()
    data["entries"][0]["reruns"] = [{"result": "passed", "ref": "run 9"}] * 5
    assert problems_for(tmp_path, data) == []
    assert data["entries"][0]["status"] == "open"
    assert "open: evidence added" in ledger.render_table(data)
    data["entries"][0]["status"] = "closed"  # the rerun is not a closing record
    problems = problems_for(tmp_path / "b", data)
    assert any(problem.startswith("L1: a closed entry needs closed_by") and "a rerun closes nothing" in problem for problem in problems)


@pytest.mark.parametrize(
    "reruns",
    [[{"result": "fixed", "ref": "run 9"}], [{"result": "passed"}], [{"result": "passed", "ref": ""}], [{"result": "passed", "ref": "r", "extra": 1}], ["passed"], "passed", [{"result": "passed", "ref": "r"}] * 51],
)
def test_reruns_are_recorded_in_a_fixed_shape(tmp_path, reruns):
    data = base()
    data["entries"][0]["reruns"] = reruns
    assert any("rerun" in problem for problem in problems_for(tmp_path, data))


def test_a_closed_entry_needs_a_controlling_test_and_two_commits(tmp_path):
    data = base()
    data["entries"][1] = closed_entry()
    data["entries"][2].update(status="consequence-only")
    root = workspace(tmp_path, data)
    # L2 is closed and L1 is not: the consequence is still consequence-only and valid.
    assert ledger.validate(data, root) == []
    assert "| closed |" in ledger.render_table(data)


@pytest.mark.parametrize(
    ("closed_by", "fragment"),
    [
        ({"test": "tests/test_controls.py"}, "closed_by.test must be 'path/to/test_file::test name'"),
        ({"test": "tests/test_controls.py::"}, "closed_by.test must be 'path/to/test_file::test name'"),
        ({"test": "::test_the_control"}, "closed_by.test must be 'path/to/test_file::test name'"),
        ({"test": 7}, "closed_by.test must be"),
        ({"test": "tests/missing.py::test_the_control"}, "does not exist or cannot be read"),
        ({"test": "tests/test_controls.py::test_other"}, "does not appear in"),
        ({"test": "../outside.py::test_the_control"}, "must name a file inside the repository"),
        ({"test": "tests/../tests/test_controls.py::test_the_control"}, "must name a file inside the repository"),
        ({"test": "/etc/hosts::root"}, "must name a file inside the repository"),
        ({"test": "tests/../../x.py::test_the_control"}, "must name a file inside the repository"),
        ({"failing_before": "abc"}, "closed_by.failing_before must be a full lowercase commit hash"),
        ({"failing_before": "A" * 40}, "closed_by.failing_before must be a full lowercase commit hash"),
        ({"passing_after": 7}, "closed_by.passing_after must be a full lowercase commit hash"),
        ({"passing_after": SHA_A}, "must be different commits"),
    ],
)
def test_the_closing_record_is_checked(tmp_path, closed_by, fragment):
    data = base()
    data["entries"][1] = closed_entry(**closed_by)
    assert any(fragment in problem and problem.startswith("L2:") for problem in problems_for(tmp_path, data)), fragment


@pytest.mark.parametrize("record", [None, {}, {"test": "tests/test_controls.py::test_the_control"}, {"test": "t::n", "failing_before": SHA_A, "passing_after": SHA_B, "rerun": "run 9"}, "run 9", []])
def test_a_closing_record_has_exactly_the_three_fields(tmp_path, record):
    data = base()
    entry = closed_entry()
    entry.pop("closed_by")
    if record is not None:
        entry["closed_by"] = record
    data["entries"][1] = entry
    assert any("a closed entry needs closed_by" in problem for problem in problems_for(tmp_path, data))


def test_a_closing_record_on_an_entry_that_is_not_closed_is_refused(tmp_path):
    data = base()
    data["entries"][1]["closed_by"] = closed_entry()["closed_by"]
    assert any("closed_by is only for a closed entry" in problem for problem in problems_for(tmp_path, data))


def test_a_closed_entry_cannot_be_unknown(tmp_path):
    data = base()
    entry = closed_entry()
    entry.update({"class": "UNKNOWN"})
    entry.pop("class_evidence")
    data["entries"][1] = entry
    assert any("a closed entry cannot be UNKNOWN" in problem for problem in problems_for(tmp_path, data))


def test_a_controlling_test_that_is_a_symlink_or_huge_is_not_trusted(tmp_path):
    data = base()
    data["entries"][1] = closed_entry()
    root = workspace(tmp_path, data)
    outside = tmp_path / "outside.py"
    outside.write_text("def test_the_control(): pass\n")
    (root / "tests/test_controls.py").unlink()
    (root / "tests/test_controls.py").symlink_to(outside)
    assert any("must name a file inside the repository" in problem for problem in ledger.validate(data, root))
    inside = root / "tests/real.py"
    inside.write_text("def test_the_control(): pass\n")
    (root / "tests/test_controls.py").unlink()
    (root / "tests/test_controls.py").symlink_to(inside)
    assert any("does not exist or cannot be read" in problem for problem in ledger.validate(data, root))
    (root / "tests/test_controls.py").unlink()
    (root / "tests/test_controls.py").write_text("x" * (ledger.MAX_DOCUMENT_BYTES + 1))
    assert any("does not exist or cannot be read" in problem for problem in ledger.validate(data, root))


def test_a_mitigated_entry_says_what_was_mitigated(tmp_path):
    data = base()
    data["entries"][0].update(status="mitigated", status_note="")
    assert any("a mitigated entry must say in status_note" in problem for problem in problems_for(tmp_path, data))
    data["entries"][0]["status_note"] = "a fixture bound was added; the cause is not explained"
    assert problems_for(tmp_path / "b", data) == []
    del data["entries"][0]["status_note"]
    assert any("a mitigated entry must say" in problem for problem in problems_for(tmp_path / "c", data))


@pytest.mark.parametrize("status", ["resolved", "fixed", "", None, "Open", "consequence-only"])
def test_a_failure_has_one_of_the_failure_statuses(tmp_path, status):
    data = base()
    data["entries"][0]["status"] = status
    assert any("status must be one of" in problem or "not consequence-only" in problem for problem in problems_for(tmp_path, data))


# ------------------------------------------------------------------ consequences

@pytest.mark.parametrize(
    ("damage", "fragment"),
    [
        (lambda e: e.pop("causes"), "a consequence needs causes"),
        (lambda e: e.update(causes=[]), "a consequence needs causes"),
        (lambda e: e.update(causes="L1"), "a consequence needs causes"),
        (lambda e: e.update(causes=[1]), "a consequence needs causes"),
        (lambda e: e.update(causes=["L9"]), "cause L9 is not an entry"),
        (lambda e: e.update(causes=["L3"]), "cause L3 is not a failure entry"),
        (lambda e: e.update(causes=["L1\x1b"]), "is not an entry"),
        (lambda e: e.update(status="open"), "a consequence is consequence-only or closed"),
    ],
)
def test_a_consequence_names_existing_failure_entries(tmp_path, damage, fragment):
    data = base()
    damage(data["entries"][2])
    problems = problems_for(tmp_path, data)
    assert any(fragment in problem and problem.startswith("L3:") for problem in problems), (fragment, problems)
    assert not any("\x1b" in problem for problem in problems)


def test_a_consequence_is_stale_when_every_cause_is_closed_and_cannot_close_early(tmp_path):
    data = base()
    data["entries"][0] = closed_entry()
    data["entries"][0]["id"] = "L1"
    data["entries"][1] = closed_entry()
    assert any("every cause is closed, so this consequence is stale" in problem for problem in problems_for(tmp_path, data))
    data["entries"][2].update(status="closed")
    assert problems_for(tmp_path / "b", data) == []
    early = base()
    early["entries"][2].update(status="closed")
    problems = problems_for(tmp_path / "c", early)
    assert any("closed while L1 is not closed; a green aggregate closes nothing" in problem for problem in problems)


def test_a_consequence_with_one_open_cause_stays_consequence_only(tmp_path):
    data = base()
    data["entries"][1] = closed_entry()
    assert problems_for(tmp_path, data) == []


def test_a_failure_has_no_causes(tmp_path):
    data = base()
    data["entries"][0]["causes"] = ["L2"]
    assert any("unknown fields causes" in problem for problem in problems_for(tmp_path, data))


# ------------------------------------------------------------------ the data file's own shape

@pytest.mark.parametrize(
    ("damage", "fragment"),
    [
        (lambda d: d.update(schema=2), "schema must be 1"),
        (lambda d: d.pop("schema"), "schema must be 1"),
        (lambda d: d.update(extra=1), "unknown top-level fields extra"),
        (lambda d: d.update(source=""), "source must name the run or issue"),
        (lambda d: d.pop("source"), "source must name the run or issue"),
        (lambda d: d.update(entries=[]), "entries must be a non-empty list"),
        (lambda d: d.update(entries="L1"), "entries must be a non-empty list"),
        (lambda d: d.update(entries=[{"id": "L1"}] * 101), "more than 100 entries"),
        (lambda d: d["entries"].append(copy.deepcopy(d["entries"][0])), "the id is used twice"),
        (lambda d: d["entries"].append("L9"), "entry 3: id must look like L1"),
        (lambda d: d["entries"].append({"id": "l9"}), "id must look like L1"),
        (lambda d: d["entries"].append({"id": "L9\x1b[31m"}), "id must look like L1"),
        (lambda d: d["entries"].append({"id": "L" + "9" * 40}), "id must look like L1"),
        (lambda d: d["entries"][0].update(kind="aggregate"), "kind must be failure or consequence"),
        (lambda d: d["entries"][0].update(surprise=1), "unknown fields surprise"),
        (lambda d: d["entries"][0].update({"x\x1b[31m": 1}), "unknown fields x\\x1b[31m"),
        (lambda d: d["entries"][0].update(error=""), "error must be non-empty text"),
        (lambda d: d["entries"][0].update(error=3), "error must be non-empty text"),
        (lambda d: d["entries"][0].update(error="x" * 4001), "error is longer than 4000 characters"),
        (lambda d: d["entries"][0].update(next_experiment="run\nit"), "next_experiment contains control characters"),
        (lambda d: d["entries"][0].update(exit_criterion="\x1b[2J"), "exit_criterion contains control characters"),
        (lambda d: d["entries"][0].pop("first_job"), "first_job must be non-empty text"),
        (lambda d: d["entries"][0].update(status_note=4), "status_note must be non-empty text"),
    ],
)
def test_the_data_files_shape_is_refused_when_wrong(tmp_path, damage, fragment):
    data = base()
    damage(data)
    problems = problems_for(tmp_path, data)
    assert any(fragment in problem for problem in problems), (fragment, problems)
    assert all(all(0x20 <= ord(char) <= 0x7E for char in problem) for problem in problems), "a message echoed a raw control character"


def test_a_failure_entry_needs_its_bounded_experiment_and_exit_criterion(tmp_path):
    for field in ("next_experiment", "exit_criterion", "error", "first_job"):
        data = base()
        data["entries"][0].pop(field)
        assert any(f"{field} must be non-empty text" in problem for problem in problems_for(tmp_path / field, data)), field


# ------------------------------------------------------------------ loading an untrusted file

def test_load_refuses_unreadable_oversized_nested_or_repeating_files(tmp_path):
    root = workspace(tmp_path, document=False)
    path = root / ledger.DATA
    path.write_text('{"schema": 1, "schema": 2}')
    with pytest.raises(ValueError, match="repeats the key schema"):
        ledger.load(root)
    path.write_text("[" * 100_000)
    with pytest.raises(ValueError, match="nested too deeply|not valid JSON"):
        ledger.load(root)
    path.write_text("[1, 2]")
    with pytest.raises(ValueError, match="not a JSON object"):
        ledger.load(root)
    path.write_text("x" * (ledger.MAX_DATA_BYTES + 1))
    with pytest.raises(ValueError, match="larger than"):
        ledger.load(root)
    path.write_bytes(b"\xff\xfe{")
    with pytest.raises(ValueError, match="not UTF-8"):
        ledger.load(root)
    path.unlink()
    with pytest.raises(ValueError, match="is not a regular file"):
        ledger.load(root)
    path.symlink_to(root / "tests/test_controls.py")
    with pytest.raises(ValueError, match="is not a regular file"):
        ledger.load(root)


def test_a_repeated_key_inside_an_entry_is_refused_too(tmp_path):
    data = json.dumps(base()).replace('"status": "open"', '"status": "open", "status": "closed"', 1)
    root = workspace(tmp_path, data, document=False)
    with pytest.raises(ValueError, match="repeats the key status"):
        ledger.load(root)


def test_check_reports_an_unreadable_file_as_unreadable_not_as_a_traceback(tmp_path):
    root = workspace(tmp_path, "{not json", document=False)
    report = ledger.check(root)
    assert report["unreadable"] is True and "not valid JSON" in report["problems"][0]


def test_safe_escapes_and_bounds_whatever_it_is_given():
    assert ledger.safe("a\x1b[31mb\n") == "a\\x1b[31mb\\x0a"
    assert ledger.safe("\\x1b") == "\\\\x1b" and ledger.safe("é") == "\\xe9" and ledger.safe("‮") == "\\u202e"
    assert len(ledger.safe("x" * 1000)) == 83 and ledger.safe("x" * 1000).endswith("...")
    assert ledger.safe(["a", "\x1b"]) == "['a', '\\\\x1b']"


# ------------------------------------------------------------------ the generated table

def test_cells_are_single_line_and_a_pipe_cannot_split_them():
    assert ledger.render_cell("a | b\n  c\t d") == "a \\| b c d"
    assert ledger.render_cell("`x|y`") == "`x\\|y`"
    data = base()
    data["entries"][0]["error"] = "left | right\nnext"
    rows = ledger.render_table(data).splitlines()
    assert len(rows) == 5 and rows[2].count(" | ") == 7 and "left \\| right next" in rows[2]


def test_the_table_has_the_documented_columns_and_labels():
    table = ledger.render_table(base()).splitlines()
    assert table[0] == "| ID | First job | Class | Exact error | Owner | Next bounded experiment | Exit criterion (controlling test) | Status |"
    assert table[3].startswith("| L2 | `job-b` | dependency (transient, per triage) |") or "| dependency (transient, per triage) |" in table[3]
    assert table[2].endswith("| open: evidence added |") and table[3].endswith("| open |")
    assert table[4].startswith("| L3 | `aggregate` | consequence |") and "| not applicable |" in table[4] and table[4].endswith("| consequence only |")
    assert ledger.UNASSIGNED in table[2]


def test_the_check_fails_when_the_table_and_the_data_differ(tmp_path):
    root = workspace(tmp_path)
    assert ledger.check(root)["problems"] == []
    document = root / ledger.DOCUMENT
    document.write_text(document.read_text().replace("it timed out", "it passed"))
    assert ledger.check(root)["problems"] == [f"{ledger.DOCUMENT}: the ledger table differs from {ledger.DATA}; run python -m tools.failure_ledger --write"]
    data = json.loads((root / ledger.DATA).read_text())
    data["entries"][0]["owner_status"] = "assigned"
    data["entries"][0]["owner"] = "Ada"
    (root / ledger.DATA).write_text(json.dumps(data))
    assert any("differs from" in problem for problem in ledger.check(root)["problems"])


@pytest.mark.parametrize(
    "document",
    ["no markers\n", "{b}\n| t |\n", "| t |\n{e}\n", "{b}\n{e}\n{b}\n{e}\n", "{e}\n{b}\n", "{b}\n{b}\n{e}\n", "{b}\n{e}\n{e}\n"],
)
def test_exactly_one_well_formed_pair_of_markers_is_required(tmp_path, document):
    root = workspace(tmp_path)
    (root / ledger.DOCUMENT).write_text(document.format(b=ledger.BEGIN, e=ledger.END))
    assert ledger.extract_table((root / ledger.DOCUMENT).read_text()) is None
    assert any("needs exactly one begin and one end marker" in problem for problem in ledger.check(root)["problems"])
    with pytest.raises(ValueError, match="needs exactly one begin and one end marker"):
        ledger.replace_table(document.format(b=ledger.BEGIN, e=ledger.END), "| t |")


def test_write_regenerates_the_table_and_keeps_every_other_byte(tmp_path):
    root = workspace(tmp_path)
    document = root / ledger.DOCUMENT
    original = document.read_text()
    document.write_text(original.replace("it timed out", "tampered"))
    assert ledger.check(root)["problems"]
    assert ledger.write(root) == document
    assert document.read_text() == original and ledger.check(root)["problems"] == []
    assert ledger.write(root) == document and document.read_text() == original  # idempotent


def test_write_refuses_while_the_data_has_problems(tmp_path):
    data = base()
    data["entries"][0]["owner_status"] = "assigned"
    root = workspace(tmp_path, data)
    before = (root / ledger.DOCUMENT).read_text()
    with pytest.raises(ValueError, match="an assigned owner must be a name"):
        ledger.write(root)
    assert (root / ledger.DOCUMENT).read_text() == before


def test_the_document_is_read_with_a_size_cap_and_a_missing_one_is_unreadable(tmp_path):
    root = workspace(tmp_path)
    (root / ledger.DOCUMENT).write_text("x" * (ledger.MAX_DOCUMENT_BYTES + 1))
    report = ledger.check(root)
    assert report["unreadable"] is True and "larger than" in report["problems"][0]
    (root / ledger.DOCUMENT).unlink()
    assert ledger.check(root)["unreadable"] is True


# ------------------------------------------------------------------ closing commits in Git

def git(root, *arguments):
    environment = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    subprocess.run(["git", "-C", str(root), *arguments], check=True, capture_output=True, text=True, env=environment, timeout=60)
    if arguments[0] != "commit":
        return ""
    return subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True, timeout=60).stdout.strip()


def test_closing_commits_must_exist_and_be_in_order(tmp_path):
    data = base()
    data["entries"][1] = closed_entry()
    root = workspace(tmp_path, data)
    git(root, "init", "-q")
    git(root, "add", "-A")
    first = git(root, "commit", "-q", "-m", "first")
    (root / "extra.txt").write_text("x")
    git(root, "add", "-A")
    second = git(root, "commit", "-q", "-m", "second")
    for sha_before, sha_after, expected in ((first, second, []), (second, first, ["L2: failing_before is not an ancestor of passing_after"]), (SHA_A, second, ["L2: closed_by.failing_before is not a commit in this repository"])):
        data["entries"][1]["closed_by"].update(failing_before=sha_before, passing_after=sha_after)
        assert ledger.verify_commits(data, root) == expected
    open_ledger = base()
    assert ledger.verify_commits(open_ledger, root) == []


def test_verify_commits_flag_is_off_by_default(tmp_path):
    data = base()
    data["entries"][1] = closed_entry()
    root = workspace(tmp_path, data)
    assert ledger.check(root)["problems"] == []  # no repository here: the commits are not looked up unless asked
    assert ledger.check(root, commits=True)["problems"]


# ------------------------------------------------------------------ command line

def test_main_exit_codes_and_messages(tmp_path, capsys):
    root = workspace(tmp_path)
    assert ledger.main([], root=root) == 0 and "Failure ledger is consistent: 3 entries." in capsys.readouterr().out
    document = root / ledger.DOCUMENT
    document.write_text(document.read_text().replace("it timed out", "tampered"))
    assert ledger.main([], root=root) == 1 and "differs from" in capsys.readouterr().err
    assert ledger.main(["--write"], root=root) == 0 and "wrote docs/testing.md" in capsys.readouterr().out
    (root / ledger.DATA).write_text("{broken")
    assert ledger.main([], root=root) == 2 and "not valid JSON" in capsys.readouterr().err
    assert ledger.main(["--write"], root=root) == 2
    with pytest.raises(SystemExit):
        ledger.main(["--writ"], root=root)  # no abbreviations


def test_main_never_prints_a_raw_control_character_from_the_data(tmp_path, capsys):
    data = base()
    data["entries"][0].update({"hostile\x1b[31m": 1, "error": "ok"})
    root = workspace(tmp_path, data)
    assert ledger.main([], root=root) == 1
    err = capsys.readouterr().err
    assert "\x1b" not in err and "hostile\\x1b[31m" in err
