"""The boundary inventory is reconciled against the inventories and tests it cites."""

import json

import pytest

from tests.source_export import ROOT, export_tree
from tools import boundary_inventory as inventory


@pytest.fixture(scope="module")
def export(tmp_path_factory):
    return export_tree(tmp_path_factory.mktemp("export") / "tree")


@pytest.fixture
def editable(export):
    """Mutate the exported inventory; originals are restored after each test."""
    saved = {}

    def reset():
        for path, content in saved.items():
            (export / path).write_bytes(content)

    def edit(path, change, keep=False):
        if not keep:
            reset()
        target = export / path
        saved.setdefault(path, target.read_bytes())
        data = json.loads(target.read_text())
        change(data)
        target.write_text(json.dumps(data, indent=2))

    yield edit
    reset()


def failing(export, *fragments):
    with pytest.raises(ValueError) as error:
        inventory.verify(export)
    for fragment in fragments:
        assert fragment in str(error.value)


def test_checked_in_inventory_is_reconciled_with_every_source():
    counts = inventory.verify(ROOT)
    assert counts["boundaries"] >= 10 and counts["lifecycle_cells"] >= 10
    assert counts["probes_mapped"] == len(json.loads((ROOT / "tools/integration_probes.json").read_text())["entries"])
    assert counts["exclusions_mapped"] == len(json.loads((ROOT / "pytest-exclusions.json").read_text()))


def test_the_complete_export_without_git_verifies(export):
    assert inventory.verify(export)["boundaries"] == inventory.verify(ROOT)["boundaries"]
    assert inventory.main(["--root", str(export), "--json"]) == 0


def test_every_issue_boundary_class_and_closure_class_is_present():
    data = inventory.load(ROOT)
    names = {boundary["id"] for boundary in data["boundaries"]}
    assert {"desktop-service", "mcp-service", "frontend-worker-isolate", "service-helper", "service-sqlite-read-worker", "build-installed-product", "harness-os"} <= names
    assert {rule["kind"] for rule in data["impact_rules"]} >= set(inventory.REQUIRED_RULE_KINDS)
    for boundary in data["boundaries"]:
        assert boundary["owner"] in data["owners"]
        assert {entry["kind"] for entry in boundary["evidence"]} <= set(inventory.COVERAGE_KINDS)


def test_cli_reports_success_and_failure(export, editable, capsys):
    assert inventory.main([]) == 0
    assert "consistent" in capsys.readouterr().out
    editable("tools/boundary_inventory.json", lambda data: data["boundaries"][0].update(owner="nobody"))
    assert inventory.main(["--root", str(export)]) == 1
    assert "unknown owner" in capsys.readouterr().err


def test_schema_must_match(export, editable):
    editable("tools/boundary_inventory.json", lambda data: data.update(schema=2))
    with pytest.raises(ValueError, match="Unsupported"):
        inventory.verify(export)


def test_dart_registrations_cover_multiline_adjacent_templated_and_raw_names():
    source = r"""
    test('plain name', () {});
    test(
      'wrapped '
      'across lines',
      () {},
    );
    testWidgets("double quoted \"escaped\"", (tester) async {});
    for (final value in [1]) {
      test('loop case ${value.toString()} and $value', () {});
    }
    test(r'raw $not interpolated', () {});
    test('nested ${items.map((e) => 'inner').join()} end', () {});
    test(someVariable, () {});
    isTest('ignored', () {});
    expectTest('ignored too', () {});
    test('escapes \$dollar \\ \n tab\t', () {});
    """
    names = inventory.dart_registered_tests(source)
    texts = [entry.text for entry in names]
    assert "plain name" in texts and "wrapped across lines" in texts
    assert 'double quoted "escaped"' in texts and "raw $not interpolated" in texts
    assert not any("ignored" in text for text in texts) and len(names) == 7
    templated = [entry for entry in names if entry.pattern is not None]
    assert any(entry.matches("loop case 3 and 3") for entry in templated)
    assert any(entry.matches("nested X end") for entry in templated)
    assert not any(entry.matches("loop case") for entry in templated)
    literal = next(entry for entry in names if entry.text == "plain name")
    assert literal.matches("plain name") and not literal.matches("plain")
    assert any(entry.text.startswith("escapes $dollar \\ \n tab") for entry in names)


def test_literal_parser_rejects_non_strings_and_handles_unterminated_input():
    assert inventory._literal("variable", 0) is None
    assert inventory._literal("r", 0) is None
    assert inventory.dart_registered_tests("test('unterminated") != []
    assert inventory.dart_registered_tests("test(") == []


def test_python_registrations_and_parametrized_ids():
    source = "def test_a():\n    pass\n\nclass T:\n    async def test_b(self):\n        pass\n\ndef helper():\n    pass\n"
    assert inventory.python_registered_tests(source) == {"test_a", "test_b"}


def test_registration_lookup_uses_the_file_type(export):
    assert inventory.is_registered(export, "tests/service/test_service_process.py", "test_two_headless_mcp_launchers_share_one_automatically_started_owner[x]")
    assert not inventory.is_registered(export, "tests/service/test_service_process.py", "test_missing")
    assert inventory.is_registered(export, "packages/foresight_core/test/service_lifecycle_test.dart", "two launchers converge on one owner when none is running")
    assert not inventory.is_registered(export, "tools/boundary_inventory.json", "anything")


def test_repo_files_walks_without_git_and_prunes_build_outputs(tmp_path):
    (tmp_path / "a/b").mkdir(parents=True)
    (tmp_path / "a/b/c.txt").write_text("x")
    (tmp_path / "build").mkdir()
    (tmp_path / "build/ignored.txt").write_text("x")
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git/config").write_text("x")
    assert inventory.repo_files(tmp_path) == ["a/b/c.txt"]


def test_glob_matching_crosses_directories():
    assert inventory.glob_match("a/b/c.dart", "a/**")
    assert inventory.glob_match("a/b/c_test.dart", "a/*_test.dart")
    assert not inventory.glob_match("b/c.dart", "a/**")


def test_a_cited_test_that_is_no_longer_registered_fails(export, editable):
    def rename(data):
        data["boundaries"][0]["evidence"][0]["names"] = ["a test that was renamed away"]

    editable("tools/boundary_inventory.json", rename)
    failing(export, "is not registered")


def test_missing_evidence_file_and_stale_trigger_fail(export, editable):
    def change(data):
        data["boundaries"][0]["evidence"][0]["path"] = "tests/service/gone.py"
        data["boundaries"][1]["triggers"].append("packages/nowhere/**")

    editable("tools/boundary_inventory.json", change)
    failing(export, "file does not exist", "matches no file")


def test_skip_inventory_reconciliation_is_two_way(export, editable):
    def drop_skip_gate(data):
        inventoried = {item["path"] for item in json.loads((export / "tools/integration_skips.json").read_text())["entries"]}
        entry = next(item for boundary in data["boundaries"] for item in boundary["evidence"] if item["path"] in inventoried)
        entry.pop("skip_gate")

    editable("tools/boundary_inventory.json", drop_skip_gate)
    failing(export, "must equal the skip inventory gate")

    def invent_skip_gate(data):
        entry = next(item for item in data["boundaries"][0]["evidence"] if not item.get("skip_gate") and item["path"].endswith(".dart"))
        entry["skip_gate"] = "models"

    editable("tools/boundary_inventory.json", invent_skip_gate)
    failing(export, "is not an inventory gate")

    def unknown_gate(data):
        path = data["boundaries"][0]["evidence"][1]["path"]
        skips = json.loads((export / "tools/integration_skips.json").read_text())
        skips["entries"].append({"path": path, "conditions": ["x"], "gate": "bogus-gate", "reason": "r"})
        (export / "tools/integration_skips.json").write_text(json.dumps(skips))

    editable("tools/integration_skips.json", lambda data: None)
    unknown_gate(inventory.load(export))
    failing(export, "skip inventory gate 'bogus-gate' is unknown")


def test_exclusion_reconciliation_is_two_way(export, editable):
    def drop_flag(data):
        entry = next(item for boundary in data["boundaries"] for item in boundary["evidence"] if item.get("excluded"))
        entry.pop("excluded")

    editable("tools/boundary_inventory.json", drop_flag)
    failing(export, "excluded must be true")

    def add_exclusion(data):
        data["tests/test_boundary_inventory.py"] = "Requires a build."

    editable("pytest-exclusions.json", add_exclusion)
    failing(export, "pytest exclusion tests/test_boundary_inventory.py is mapped by no boundary")


def test_probe_reconciliation_requires_mapping_and_matching_mode(export, editable):
    def unmapped(data):
        for boundary in data["boundaries"]:
            boundary["evidence"] = [item for item in boundary["evidence"] if item["path"] != "tools/test_whisper_gpu.py"]

    editable("tools/boundary_inventory.json", unmapped)
    failing(export, "probe tools/test_whisper_gpu.py is mapped by no boundary")

    def wrong_kind(data):
        for boundary in data["boundaries"]:
            for item in boundary["evidence"]:
                if item["path"] == "tools/test_whisper_gpu.py":
                    item["kind"] = "production-both-sides"

    editable("tools/boundary_inventory.json", wrong_kind)
    failing(export, "contradicts evidence kind")

    def invented_manual(data):
        data["boundaries"][0]["evidence"].append({"kind": "manual", "path": "tests/test_boundary_inventory.py"})

    editable("tools/boundary_inventory.json", invented_manual)
    failing(export, "manual evidence must be a manual probe")

    def stale_reason(data):
        data["unmapped_probes"]["tools/nowhere.py"] = "stale"
        data["unmapped_exclusions"]["tests/nowhere.py"] = "stale"

    editable("tools/boundary_inventory.json", stale_reason)
    failing(export, "unmapped_probes names tools/nowhere.py", "unmapped_exclusions names tests/nowhere.py")


def test_unmapped_sources_may_be_explained(export, editable):
    def explain(data):
        for boundary in data["boundaries"]:
            boundary["evidence"] = [item for item in boundary["evidence"] if item["path"] != "tools/test_whisper_gpu.py"]
        data["unmapped_probes"]["tools/test_whisper_gpu.py"] = "Explicitly out of scope for this fixture."

    editable("tools/boundary_inventory.json", explain)
    assert inventory.verify(export)["boundaries"]


def test_gates_must_name_real_entrypoints_and_explicit_requirements(export, editable):
    def change(data):
        data["gates"]["shared-guards"]["argv"] = ["{python}", "-m", "tools.no_such_module"]
        data["gates"]["bindings-check"]["argv"] = ["{python}", "tools/no_such_script.py"]
        data["gates"]["manual-probes"]["requirement"] = " "
        data["gates"]["hosted-packaging"]["kind"] = "unknown-kind"
        data["gates"]["python-coverage"]["subsumes"] = ["ghost"]
        data["gates"]["core-stage"]["requires"][1]["produced_by"] = ["ghost"]
        data["gates"]["native-stage"]["timeout_seconds"] = 0
        data["gates"]["desktop-stage"]["scope"] = "everywhere"
        data["gates"]["service-stage"]["long"] = "yes"
        data["gates"]["dmg-contracts"]["platforms"] = ["windows"]
        data["gates"]["dmg-contracts"]["requires"] = [{"kind": "magic"}]
        data["gates"]["document-sandbox"]["doc"] = "docs/not-there.md"
        data["gates"]["integration-fast"]["argv"] = []

    editable("tools/boundary_inventory.json", change)
    failing(
        export,
        "entrypoint tools/no_such_module.py does not exist",
        "entrypoint tools/no_such_script.py does not exist",
        "needs an explicit requirement",
        "invalid kind 'unknown-kind'",
        "unknown subsumed gate ghost",
        "unknown producer gate ghost",
        "timeout_seconds must be a positive integer",
        "scope must be host or neutral",
        "long must be a boolean",
        "platforms must be a non-empty subset",
        "invalid requirement",
        "doc docs/not-there.md does not exist",
        "argv must be a non-empty string list",
    )


def test_boundaries_must_be_complete_and_honest(export, editable):
    def change(data):
        first, second = data["boundaries"][0], data["boundaries"][1]
        second["id"] = first["id"]
        first["producer"] = ""
        first["invariants"] = []
        first["prerequisites"] = []
        first["execution_modes"] = ["quantum"]
        first["platforms"] = []
        first["gate"] = "ghost"
        first["also_gates"] = ["ghost-two"]
        first["evidence"][0]["kind"] = "wishful"
        third = data["boundaries"][2]
        third["evidence"] = [item for item in third["evidence"] if item["kind"] != "production-both-sides"] or [{"kind": "static-guard", "path": "tests/test_native_ffi_contract.py"}]
        third["evidence"] = [{"kind": "static-guard", "path": "tests/test_native_ffi_contract.py"}]
        third["gaps"] = []
        data["boundaries"][3]["evidence"] = []

    editable("tools/boundary_inventory.json", change)
    failing(
        export,
        "boundary ids must be present and unique",
        "producer is required",
        "invariants are required",
        "prerequisites are required",
        "execution_modes must be",
        "platforms must be",
        "unknown gate 'ghost'",
        "unknown gate 'ghost-two'",
        "invalid kind 'wishful'",
        "no production-both-sides evidence requires an explicit gap statement",
        "evidence is required",
    )


def test_ci_gate_map_must_match_the_ci_selection_gates(export, editable):
    def change(data):
        data["ci_gate_map"].pop("dmg")
        data["ci_gate_map"]["macos"]["platform"] = "plan9"
        data["ci_gate_map"]["linux-build"]["gates"] = ["ghost"]
        data["ci_gate_map"]["linux-test"]["gates"] = []

    editable("tools/boundary_inventory.json", change)
    failing(export, "ci_gate_map must name exactly", "invalid platform", "unknown gate ghost", "needs a local equivalent")


def test_impact_rules_cannot_lose_a_closure_class_or_reference_unknowns(export, editable):
    def change(data):
        data["impact_rules"] = [rule for rule in data["impact_rules"] if rule["kind"] != "native-abi"]
        data["impact_rules"][0]["boundaries"] = ["ghost"]
        data["impact_rules"][0]["gates"] = ["ghost"]
        data["impact_rules"][0]["globs"] = ["nothing/here/**"]
        data["impact_rules"][0]["reason"] = ""
        data["impact_rules"][1]["id"] = data["impact_rules"][0]["id"]

    editable("tools/boundary_inventory.json", change)
    failing(
        export,
        "must keep a native-abi closure rule",
        "unknown boundary ghost",
        "unknown gate ghost",
        "matches no file",
        "reason is required",
        "impact rule ids must be unique",
    )


def test_lifecycle_cells_cannot_claim_closure_without_evidence(export, editable):
    def change(data):
        cells = data["lifecycle_reconciliation"]
        closed = next(cell for cell in cells if cell["status"] == "closed-production")
        closed["evidence"] = []
        closed["missing"] = "something"
        open_cell = next(cell for cell in cells if cell["status"] == "open")
        open_cell["evidence"] = [{"path": "tests/service/test_service_process.py", "test": "test_x", "sides": "x"}]
        partial = next(cell for cell in cells if cell["status"] == "partial")
        partial["missing"] = ""
        partial["evidence"][0]["test"] = "a name that is not registered"
        partial["evidence"][0]["sides"] = ""
        partial["evidence"][-1]["path"] = "packages/foresight_core/test/gone_test.dart"
        cells.append({"boundary": "x", "transition": "y", "status": "mystery", "evidence": [], "missing": "m"})

    editable("tools/boundary_inventory.json", change)
    failing(
        export,
        "closed-production requires evidence",
        "a closed cell cannot list missing coverage",
        "an open cell cannot cite evidence",
        "partial must say what is missing",
        "is not registered in",
        "evidence must say which side is production",
        "does not exist",
        "invalid status 'mystery'",
    )


def test_a_closed_cell_with_evidence_and_nothing_missing_is_accepted(export, editable):
    def close(data):
        cell = next(item for item in data["lifecycle_reconciliation"] if item["status"] == "closed-production")
        assert cell["evidence"] and cell["missing"] is None

    editable("tools/boundary_inventory.json", close)
    assert inventory.verify(export)["lifecycle_cells"] >= 1


def test_the_service_helper_gaps_are_recorded_not_assumed_closed():
    cells = {(cell["boundary"], cell["transition"]): cell for cell in inventory.load(ROOT)["lifecycle_reconciliation"]}
    assert cells[("Service to helper", "Malformed or partial frame")]["status"] == "open"
    assert cells[("Service to helper", "Closing")]["status"] == "closed-production"
    assert cells[("Desktop to service", "Crash")]["status"] != "closed-production"


def test_copy_helper_leaves_no_git_metadata(export):
    assert not (export / ".git").exists()


def test_scanner_ignores_registrations_in_comments_and_strings():
    source = r"""
    // test('line comment', () {});
    /* testWidgets('block comment', (t) async {});
       /* nested */ test('still commented', () {}); */
    final fixtureText = 'test(\'inside a string\', () {});';
    final raw = r'''
test('inside a triple quoted string', () {});
''';
    test('the only real one', () {});
    """
    names = [entry.text for entry in inventory.dart_registered_tests(source)]
    assert names == ["the only real one"]


def test_python_scanner_uses_the_syntax_tree_not_text():
    source = (
        'def test_real():\n    """def test_in_docstring(): pass"""\n    # def test_in_comment(): pass\n'
        'TEXT = "def test_in_string(): pass"\n'
    )
    assert inventory.python_registered_tests(source) == {"test_real"}
    with pytest.raises(ValueError, match="does not parse"):
        inventory.python_registered_tests("def test_broken(:\n")


def test_skip_markers_are_detected_outside_comments_and_strings():
    dart = "test('a', () { markTestSkipped('why'); });"
    assert inventory.scan_dart(dart)[1] is True
    assert inventory.scan_dart("test('b', () {}, skip: 'later');")[1] is True
    assert inventory.scan_dart("// skip: nothing\n/* markTestSkipped */ final s = 'skip: x'; test('c', () {});")[1] is False
    assert inventory.scan_dart("@Skip('x')\nvoid main() {}")[1] is True
    source = "import pytest\n@pytest.mark.skipif(True, reason='r')\ndef test_a(): pass\ndef test_b():\n    pytest.skip('r')\ndef test_c(): pass\n"
    assert inventory._python_tests(source) == {"test_a": True, "test_b": True, "test_c": False}


def test_cited_tests_that_can_skip_must_declare_a_skip_gate(export, editable):
    def drop(data):
        entry = next(item for boundary in data["boundaries"] for item in boundary["evidence"] if item["path"] == "tests/test_linux_packages.py")
        entry.pop("skip_gate")

    editable("tools/boundary_inventory.json", drop)
    failing(export, "tests/test_linux_packages.py: carries a skip marker, so the entry must declare its skip_gate")

    def bogus(data):
        entry = next(item for boundary in data["boundaries"] for item in boundary["evidence"] if item["path"] == "tests/test_linux_packages.py")
        entry["skip_gate"] = "no-such-gate"

    editable("tools/boundary_inventory.json", bogus)
    failing(export, "skip_gate 'no-such-gate' is not an inventory gate")


def test_unparseable_cited_python_is_a_drift_error_not_a_crash(export, editable):
    (export / "tests" / "broken_cited.py").write_text("def test_x(:\n")
    try:
        editable("tools/boundary_inventory.json", lambda data: data["boundaries"][0]["evidence"].append({"kind": "static-guard", "path": "tests/broken_cited.py"}))
        failing(export, "does not parse")
    finally:
        (export / "tests" / "broken_cited.py").unlink()


def test_ci_job_map_must_cover_every_required_job_beyond_the_gates(export, editable):
    def drop(data):
        data["ci_job_map"].pop("acceptance-audio")
        data["ci_job_map"]["linux-native"]["gates"] = ["ghost"]
        data["ci_job_map"]["acceptance-cpu"]["gates"] = []

    editable("tools/boundary_inventory.json", drop)
    failing(export, "ci_job_map must name exactly", "unknown gate ghost", "needs a platform and at least one gate")
    data = inventory.load(ROOT)
    from tools import ci_selection

    assert set(data["ci_job_map"]) == set(ci_selection.ACCEPTANCE) | {"linux-native"}
    assert {"hosted-acceptance", "hosted-linux-native"} <= set(data["gates"])


def test_a_new_required_job_without_a_mapping_is_drift(export, monkeypatch):
    from tools import ci_selection

    real = ci_selection.required_jobs
    monkeypatch.setattr(ci_selection, "required_jobs", lambda *a, **k: [*real(*a, **k), "brand-new-job"])
    failing(export, "required CI job brand-new-job maps to no gate")
