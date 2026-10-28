"""The failure ledger is data: owned or explicitly unassigned, closed only by a test, and generated into the document."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys

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
    assert imported <= {"__future__", "argparse", "collections", "json", "os", "pathlib", "re", "subprocess", "sys", "tempfile", "typing", "tools", "unicodedata"}, imported
    tools_imports = [node for node in ast.walk(ast.parse((ROOT / "tools/failure_ledger.py").read_text())) if isinstance(node, ast.ImportFrom) and node.module == "tools"]
    assert [alias.name for node in tools_imports for alias in node.names] == ["boundary_inventory"]  # what is on main, nothing from the evidence modules


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
        ({"test": "tests/test_controls.py::test_other"}, "is not a registered test in"),
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
        (lambda d: d["entries"][0].update(next_experiment="run\nit"), "next_experiment contains control, bidirectional or zero-width characters"),
        (lambda d: d["entries"][0].update(exit_criterion="\x1b[2J"), "exit_criterion contains control, bidirectional or zero-width characters"),
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
    assert ledger.safe("\\x1b") == "\\\\x1b" and ledger.safe("\u00e9") == "\\xe9" and ledger.safe("\u202e") == "\\u202e"
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


# ------------------------------------------------------------------ the controlling test must be a registered test

def control_ledger(path, name):
    data = base()
    entry = closed_entry(test=f"{path}::{name}")
    data["entries"][1] = entry
    return data


def with_control(tmp_path, filename, text, name):
    data = control_ledger(f"tests/{filename}", name)
    root = workspace(tmp_path, data)
    (root / "tests" / filename).write_text(text)
    return ledger.validate(data, root)


@pytest.mark.parametrize(
    ("filename", "text", "name"),
    [
        # the repros: a comment that mentions the name, and a name that occurs somewhere in the file
        ("storage_worker_session_test.dart", "// TODO: write 'cold writer drains after bootstrap' some day\n", "cold writer drains after bootstrap"),
        ("storage_worker_session_test.dart", "void main() { final owner = 1; test('something else', () {}); }\n", "owner"),
        ("a_test.dart", "void main() { /* test('the case', () {}); */ }\n", "the case"),
        ("a_test.dart", "void main() { print(\"test('the case', () {})\"); }\n", "the case"),
        ("a_test.dart", "void main() { test('the case and more', () {}); }\n", "the case"),
        ("a_test.dart", "void main() { test('the', () {}); }\n", "the case"),
        ("test_x.py", "# def test_the_case(): pass\n", "test_the_case"),
        ("test_x.py", "text = 'def test_the_case(): pass'\n", "test_the_case"),
        ("test_x.py", "def helper_test_the_case(): pass\n", "test_the_case"),
        ("test_x.py", "def test_the_case_and_more(): pass\n", "test_the_case"),
        ("test_x.py", "def test_the_case(:\n", "test_the_case"),  # does not parse: registers nothing
        ("notes.md", "test_the_case\n", "test_the_case"),
        ("notes.txt", "test('the case', () {})\n", "the case"),
    ],
)
def test_only_a_registered_test_can_be_the_controlling_test(tmp_path, filename, text, name):
    problems = with_control(tmp_path, filename, text, name)
    assert any(f"is not a registered test in tests/{filename}" in problem and problem.startswith("L2:") for problem in problems), problems


@pytest.mark.parametrize(
    ("filename", "text", "name"),
    [
        ("a_test.dart", "void main() { test('cold writer drains after bootstrap', () {}); }\n", "cold writer drains after bootstrap"),
        ("a_test.dart", "void main() {\n  testWidgets('the case', (tester) async {});\n}\n", "the case"),
        ("a_test.dart", "void main() {\n  test(\n    'wrapped across lines',\n    () {},\n  );\n}\n", "wrapped across lines"),
        ("a_test.dart", "void main() { for (final k in ['a']) { test('case $k', () {}); } }\n", "case a"),
        ("test_x.py", "def test_the_case(): pass\n", "test_the_case"),
        ("test_x.py", "import pytest\n\n@pytest.mark.parametrize('v', [1])\ndef test_the_case(v): pass\n", "test_the_case[1]"),
        ("test_x.py", "class TestX:\n    def test_inside(self): pass\n", "test_inside"),
    ],
)
def test_a_registered_dart_or_python_test_is_accepted(tmp_path, filename, text, name):
    assert with_control(tmp_path, filename, text, name) == []


# ------------------------------------------------------------------ the commit check is independent per entry and says what it is

def test_every_closed_entry_is_checked_even_after_another_one_fails(tmp_path):
    data = base()
    first = closed_entry()
    first.update(id="L1", closed_by={**first["closed_by"], "failing_before": SHA_A, "passing_after": SHA_B})
    second = closed_entry()
    second["id"] = "L9"
    data["entries"] = [first, second, data["entries"][2]]
    data["entries"][2]["causes"] = ["L1", "L9"]
    data["entries"][2]["status"] = "closed"
    root = workspace(tmp_path, data)
    git(root, "init", "-q")
    git(root, "add", "-A")
    one = git(root, "commit", "-q", "-m", "one")
    (root / "later").write_text("x")
    git(root, "add", "-A")
    two = git(root, "commit", "-q", "-m", "two")
    data["entries"][0]["closed_by"].update(failing_before=SHA_A, passing_after=two)  # L1: a commit that does not exist
    data["entries"][1]["closed_by"].update(failing_before=two, passing_after=one)  # L9: the wrong way round
    problems = ledger.verify_commits(data, root)
    assert problems == ["L1: closed_by.failing_before is not a commit in this repository", "L9: failing_before is not an ancestor of passing_after"]


def test_the_documents_and_the_module_say_the_pair_is_the_authors_claim():
    document = (ROOT / ledger.DOCUMENT).read_text()
    assert "That pair is the author's claim and nothing runs\nthe test at either commit" in document
    assert "checks only that both are commits of this repository and are in\norder" in document
    assert "nothing runs the test at either commit" in ledger.__doc__ and "author's claim" in ledger.__doc__


# ------------------------------------------------------------------ deleting an entry is not closing it

def test_an_entry_deleted_since_the_base_is_refused(tmp_path):
    data = base()
    root = workspace(tmp_path, data)
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    gone = copy.deepcopy(data)
    del gone["entries"][1]
    gone["entries"][1]["causes"] = ["L1"]
    (root / ledger.DATA).write_text(json.dumps(gone))
    (root / ledger.DOCUMENT).write_text(f"{ledger.BEGIN}\n{ledger.render_table(gone)}\n{ledger.END}\n")
    assert ledger.check(root)["problems"] == []
    problems = ledger.check(root, base="HEAD")["problems"]
    assert problems == ["L2: the entry exists at HEAD and is gone; close it with a controlling test instead of deleting it"]
    assert ledger.main(["--base", "HEAD"], root=root) == 1
    assert ledger.removed_entries(data, root, "HEAD") == []  # nothing is missing from the full ledger


@pytest.mark.parametrize("base_name", ["--exec=x", "-p", "", "a b", "x" * 300, "HEAD;rm", "no-such-revision"])
def test_a_base_that_is_not_a_revision_is_a_problem_not_a_command(tmp_path, base_name):
    root = workspace(tmp_path)
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    problems = ledger.removed_entries(base(), root, base_name)
    assert len(problems) == 1 and ("is not a revision name" in problems[0] or "cannot be read at" in problems[0])
    if base_name != "no-such-revision" and base_name != "a b" and base_name != "HEAD;rm":
        assert "is not a revision name" in problems[0], base_name  # refused before Git is asked
    assert all(0x20 <= ord(char) <= 0x7E for char in problems[0])


def test_a_base_ledger_that_cannot_be_compared_is_a_problem(tmp_path):
    root = workspace(tmp_path)
    (root / ledger.DATA).write_text('{"schema": 1, "entries": [3]}')
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "odd")
    assert ledger.removed_entries(base(), root, "HEAD") == []  # entries that are not objects name nothing, so nothing is missing
    (root / ledger.DATA).write_text("{broken")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "broken")
    assert ledger.removed_entries(base(), root, "HEAD") == ["tools/failure_ledger.json at HEAD cannot be compared"]
    (root / ledger.DATA).write_text('{"entries": [{"id": "L1"}], "x": 1, "x": 2}')
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "repeated")
    assert ledger.removed_entries(base(), root, "HEAD") == ["tools/failure_ledger.json at HEAD cannot be compared"]
    (root / ledger.DATA).write_text('{"entries": [{"id": "L1"}], "pad": "' + "x" * (ledger.MAX_DATA_BYTES + 10) + '"}')
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "huge")
    assert ledger.removed_entries(base(), root, "HEAD") == [f"tools/failure_ledger.json at HEAD is larger than {ledger.MAX_DATA_BYTES} bytes"]


# ------------------------------------------------------------------ --write is atomic and its exit codes match the check

def test_write_replaces_the_document_atomically_and_keeps_its_mode(tmp_path):
    root = workspace(tmp_path)
    document = root / ledger.DOCUMENT
    document.write_text(document.read_text().replace("it timed out", "tampered"))
    document.chmod(0o640)
    before = document.stat().st_ino
    ledger.write(root)
    assert document.stat().st_ino != before and (document.stat().st_mode & 0o777) == 0o640  # a new file was renamed into place
    assert "it timed out" in document.read_text() and not [name for name in os.listdir(document.parent) if name.startswith(".testing-")]


def test_a_failed_write_leaves_the_document_and_no_temporary_file(tmp_path, monkeypatch):
    root = workspace(tmp_path)
    document = root / ledger.DOCUMENT
    document.write_text(document.read_text().replace("it timed out", "tampered"))
    tampered = document.read_text()
    monkeypatch.setattr(ledger.os, "replace", lambda *a: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError, match="disk full"):
        ledger.write(root)
    assert document.read_text() == tampered and not [name for name in os.listdir(document.parent) if name.startswith(".testing-")]


def test_write_refuses_a_symbolic_link_at_the_document_path(tmp_path):
    root = workspace(tmp_path)
    target = tmp_path / "elsewhere.md"
    target.write_text(f"{ledger.BEGIN}\nx\n{ledger.END}\n")
    (root / ledger.DOCUMENT).unlink()
    (root / ledger.DOCUMENT).symlink_to(target)
    with pytest.raises(ValueError, match="symbolic link"):
        ledger.write(root)
    assert target.read_text() == f"{ledger.BEGIN}\nx\n{ledger.END}\n"


def test_write_with_rule_violations_exits_one_like_the_check_and_prints_them(tmp_path, capsys):
    data = base()
    data["entries"][0]["owner_status"] = "assigned"
    root = workspace(tmp_path, data)
    assert ledger.main(["--write"], root=root) == 1
    err = capsys.readouterr().err
    assert "L1: an assigned owner must be a name" in err and "Traceback" not in err
    assert ledger.main([], root=root) == 1
    (root / ledger.DATA).write_text("{broken")
    assert ledger.main(["--write"], root=root) == 2  # only an unreadable input is 2


def test_the_commit_check_without_git_is_a_problem_not_a_pass(tmp_path, monkeypatch):
    data = base()
    data["entries"][1] = closed_entry()
    root = workspace(tmp_path, data)
    assert ledger.main(["--verify-commits"], root=root) == 1
    monkeypatch.setattr(ledger.subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError("git")))
    assert ledger.verify_commits(data, root) == ["git could not be run to verify commits"]
    assert ledger.removed_entries(data, root, "HEAD") == ["git could not be run to compare with the base"]


# ------------------------------------------------------------------ hostile data: encoding, markers, NUL, git, keys, pipes

def run_main_in_c_locale(root, *arguments):
    script = "import sys; from pathlib import Path; from tools import failure_ledger as l; sys.exit(l.main(sys.argv[2:], root=Path(sys.argv[1])))"
    environment = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C", "LANG": "C", "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0", "PYTHONPATH": str(ROOT)}
    return subprocess.run([sys.executable, "-c", script, str(root), *arguments], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=120)


def test_write_in_a_non_utf8_locale_keeps_the_document_and_writes_utf8(tmp_path):
    data = base()
    data["entries"][0]["error"] = "boom caf\u00e9 failure \u2014 na\u00efve"
    root = workspace(tmp_path, data)
    document = root / ledger.DOCUMENT
    (root / ledger.DATA).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    document.write_text(document.read_bytes().decode().replace("it timed out", "tampered"), encoding="utf-8")
    before = document.stat().st_size
    result = run_main_in_c_locale(root, "--write")
    assert result.returncode == 0, result.stderr
    raw = document.read_bytes()
    assert len(raw) > 0 and abs(len(raw) - before) < 200 and "caf\u00e9 failure \u2014 na\u00efve".encode() in raw
    assert run_main_in_c_locale(root).returncode == 0  # the next check reads it back
    assert b"\r" not in raw


def test_write_keeps_the_newlines_the_document_already_has(tmp_path):
    root = workspace(tmp_path)
    document = root / ledger.DOCUMENT
    document.write_bytes(document.read_bytes().replace(b"\n", b"\r\n").replace(b"it timed out", b"tampered"))
    original = document.read_bytes()
    assert b"\r\n" in original
    # the generated block is joined with \n; the lines around it keep their endings
    ledger.write(root)
    assert document.read_bytes().startswith(b"# Testing\r\n\r\nintro\r\n\r\n") and document.read_bytes().endswith(b"\r\n\r\ntail\r\n")


def test_write_checks_that_the_new_document_holds_exactly_the_generated_table(tmp_path, monkeypatch):
    root = workspace(tmp_path)
    document = root / ledger.DOCUMENT
    document.write_text(document.read_text().replace("it timed out", "tampered"))
    tampered = document.read_text()
    monkeypatch.setattr(ledger, "replace_table", lambda text, table: f"{ledger.BEGIN}\nnot the table\n{ledger.END}\n{ledger.END}\n")
    with pytest.raises(ValueError, match="nothing was written"):
        ledger.write(root)
    assert document.read_text() == tampered and not [name for name in os.listdir(document.parent) if name.startswith(".testing-")]


@pytest.mark.parametrize("field", ["first_job", "error", "next_experiment", "exit_criterion", "status_note"])
@pytest.mark.parametrize("hostile", ["x <!-- failure-ledger:end --> y", "x <!-- y", "x --> y", "failure-ledger:begin", "<!-- failure-ledger:begin (x) -->"])
def test_no_rendered_field_may_carry_a_comment_marker(tmp_path, field, hostile):
    data = base()
    data["entries"][0][field] = hostile
    assert any(problem.startswith("L1:") and field in problem and "comment marker" in problem for problem in problems_for(tmp_path, data)), (field, hostile)


@pytest.mark.parametrize("field", ["class_note", "owner"])
def test_the_class_note_and_the_owner_cannot_carry_a_marker_either(tmp_path, field):
    data = base()
    entry = data["entries"][1]
    if field == "owner":
        entry.update(owner_status="assigned", owner="Ada <!-- failure-ledger:end -->")
    else:
        entry["class_note"] = "x --> y"
    assert any("comment marker" in problem for problem in problems_for(tmp_path, data))


def test_a_marker_in_class_evidence_is_refused_too(tmp_path):
    data = base()
    data["entries"][1]["class_evidence"] = ["see <!-- run"]
    assert any("class_evidence contains control characters or a comment marker" in problem for problem in problems_for(tmp_path, data))


@pytest.mark.parametrize("char", [chr(code) for code in (0x202E, 0x200B, 0x2066, 0xFEFF, 0x2028, 0x2029, 0xD800, 0xE000, 0x00, 0x1B, 0x7F, 0x85, 0x9B, 0x0A, 0x09)])
def test_bidirectional_zero_width_and_separator_characters_are_refused_like_control_characters(tmp_path, char):
    for field in ("error", "owner"):
        data = base()
        if field == "owner":
            data["entries"][0].update(owner_status="assigned", owner=f"Ada{char}Lovelace")
        else:
            data["entries"][0]["error"] = f"it{char}timed out"
        assert any("L1:" in problem and ("control" in problem) for problem in problems_for(tmp_path / field, data)), (field, char)


@pytest.mark.parametrize("test", ["tests/x\x00.py::name", "tests/test_controls.py::na\x00me", "tests/test_controls.py::name\n", "t" * 4001 + "::n", "tests/\u202e.py::n"])
def test_a_hostile_controlling_test_name_is_a_problem_line_not_a_crash(tmp_path, test):
    data = base()
    data["entries"][1] = closed_entry(test=test)
    problems = problems_for(tmp_path, data)
    assert any("closed_by.test must be 'path/to/test_file::test name'" in problem for problem in problems), problems
    assert all(0x20 <= ord(char) <= 0x7E for problem in problems for char in problem)


def test_a_path_that_cannot_be_resolved_is_a_problem_not_an_exception(tmp_path, monkeypatch):
    data = base()
    data["entries"][1] = closed_entry()
    root = workspace(tmp_path, data)
    monkeypatch.setattr(Path, "resolve", lambda self, strict=False: (_ for _ in ()).throw(ValueError("embedded null character")))
    assert any("must name a file inside the repository" in problem for problem in ledger.validate(data, root))


def test_replacement_refs_cannot_rewrite_the_ancestry_the_check_sees(tmp_path):
    data = base()
    data["entries"][1] = closed_entry()
    root = workspace(tmp_path, data)
    environment = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}

    def run(*arguments):
        return subprocess.run(["git", "-C", str(root), *arguments], check=True, capture_output=True, text=True, env=environment, timeout=60).stdout.strip()

    run("init", "-q")
    run("add", "-A")
    run("commit", "-q", "-m", "first")
    first = run("rev-parse", "HEAD")
    run("checkout", "-q", "--orphan", "other")
    run("commit", "-q", "--allow-empty", "-m", "unrelated")
    unrelated = run("rev-parse", "HEAD")
    tree = run("rev-parse", "HEAD^{tree}")
    child = run("commit-tree", tree, "-p", first, "-m", "pretend child")
    run("replace", unrelated, child)  # now `unrelated` looks like a child of `first`
    data["entries"][1]["closed_by"].update(failing_before=first, passing_after=unrelated)
    probe = subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", first, unrelated], capture_output=True, timeout=30)
    assert probe.returncode == 0  # with replacement objects honoured, the lie works
    assert ledger.verify_commits(data, root) == ["L2: failing_before is not an ancestor of passing_after"]


def test_the_ancestry_check_survives_git_failing_midway(tmp_path, monkeypatch):
    data = base()
    data["entries"][1] = closed_entry()
    root = workspace(tmp_path, data)
    git(root, "init", "-q")
    git(root, "add", "-A")
    first = git(root, "commit", "-q", "-m", "first")
    (root / "later").write_text("x")
    git(root, "add", "-A")
    second = git(root, "commit", "-q", "-m", "second")
    data["entries"][1]["closed_by"].update(failing_before=first, passing_after=second)
    real = ledger.subprocess.run

    def flaky(command, *arguments, **keywords):
        if "merge-base" in command:
            raise subprocess.TimeoutExpired(command, 30)
        return real(command, *arguments, **keywords)

    monkeypatch.setattr(ledger.subprocess, "run", flaky)
    assert ledger.verify_commits(data, root) == ["git could not be run to verify commits"]


def test_git_is_always_called_without_replacement_objects():
    source = Path(ledger.__file__).read_text()
    assert source.count('"git", "--no-replace-objects"') == 2


def test_repeated_keys_are_found_in_one_pass_not_by_recounting(tmp_path, monkeypatch):
    import time

    seen = []
    real = ledger.Counter
    monkeypatch.setattr(ledger, "Counter", lambda keys: seen.append(1) or real(keys))
    started = time.monotonic()
    ledger._no_duplicates([(f"k{index}", index) for index in range(30_000)])
    assert seen == [1] and time.monotonic() - started < 2
    with pytest.raises(ValueError, match="repeats the key k1"):
        ledger._no_duplicates([("k1", 1), ("k2", 2), ("k1", 3)])


def cells(row):
    """Split a Markdown table row on pipes that are not escaped, the way a table reads it."""
    import re

    return [cell.strip() for cell in re.split(r"(?<!\\)\|", row.strip()[1:-1])]


@pytest.mark.parametrize(
    "text",
    ["a|b", "a\\|b", "a\\\\|b", "a\\\\\\|b", "|", "\\", "x\\", "a \\| b", "`x\\|y`", "||", "ends with \\"],
)
def test_no_cell_text_can_split_or_shift_a_row(text):
    data = base()
    data["entries"][0]["error"] = text
    row = ledger.render_table(data).splitlines()[2]
    assert len(cells(row)) == 8, (text, row)
    assert "\\\\|" not in row  # a doubled backslash before a pipe is what a table reads as a split


def test_a_backslash_before_a_pipe_is_a_character_reference_and_other_backslashes_stay():
    assert ledger.render_cell("a\\|b") == "a&#92;\\|b"
    assert ledger.render_cell("a\\\\|b") == "a&#92;&#92;\\|b"
    assert ledger.render_cell("path\\to") == "path\\to" and ledger.render_cell("x|y") == "x\\|y"


def test_the_drift_check_notices_a_cell_with_a_backslash_and_a_pipe(tmp_path):
    data = base()
    data["entries"][0]["error"] = "left\\|right"
    root = workspace(tmp_path, data)
    assert ledger.check(root)["problems"] == []
    document = root / ledger.DOCUMENT
    document.write_text(document.read_text().replace("left&#92;\\|right", "left\\\\|right"))
    assert any("differs from" in problem for problem in ledger.check(root)["problems"])
