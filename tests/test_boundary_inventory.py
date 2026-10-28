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
    data = inventory.load(ROOT)
    assert counts["boundaries"] == len(data["boundaries"]) == 12 and counts["lifecycle_cells"] == len(data["lifecycle_reconciliation"]) == 14
    assert counts["gates"] == len(data["gates"]) and counts["impact_rules"] == len(data["impact_rules"])
    assert counts["probes_mapped"] == len(json.loads((ROOT / "tools/integration_probes.json").read_text())["entries"])
    assert counts["exclusions_mapped"] == len(json.loads((ROOT / "pytest-exclusions.json").read_text()))


def test_the_complete_export_without_git_verifies(export):
    assert inventory.verify(export)["boundaries"] == inventory.verify(ROOT)["boundaries"]
    assert inventory.main(["--root", str(export), "--json"]) == 0


def test_every_issue_boundary_class_and_closure_class_is_present():
    data = inventory.load(ROOT)
    names = {boundary["id"] for boundary in data["boundaries"]}
    assert names == {
        "desktop-service", "mcp-service", "frontend-worker-isolate", "service-helper", "service-sqlite-read-worker",
        "launcher-service-handoff", "dart-native-ffi", "schema-bindings", "build-installed-product", "harness-os",
        "document-import-sandbox", "model-runtime-acceptance",
    }
    assert {rule["kind"] for rule in data["impact_rules"]} == set(inventory.REQUIRED_RULE_KINDS) | {"test-file"}
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
        closed = next(cell for cell in cells if (cell["boundary"], cell["transition"]) == ("Service to helper", "Closing"))
        closed["status"] = "closed-production"
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


def cell(data, boundary, transition):
    return next(item for item in data["lifecycle_reconciliation"] if (item["boundary"], item["transition"]) == (boundary, transition))


def test_a_closed_cell_needs_evidence_that_says_production_on_both_sides(export, editable):
    def close(data, sides):
        target = cell(data, "Service to helper", "Closing")
        target.update(status="closed-production", missing=None)
        target["evidence"][1]["sides"] = sides
        for item in target["evidence"][:1] + target["evidence"][2:]:
            item["sides"] = "stand-in helper"

    editable("tools/boundary_inventory.json", lambda data: close(data, "production client, fixture service"))
    failing(export, "a closed cell needs evidence whose sides say production both")
    editable("tools/boundary_inventory.json", lambda data: close(data, "production both; adopted helper"))
    assert inventory.verify(export)["lifecycle_cells"] == 14


EXPECTED_VERDICTS = {
    ("Desktop to service", "Crash"): "fixture-only",
    ("Desktop to service", "EOF before reply"): "fixture-only",
    ("Desktop to service", "Slow reply (non-attach)"): "fixture-only",
    ("Desktop to service", "Duplicate launch"): "partial",
    ("Desktop to service", "Reconnect"): "partial",
    ("MCP/CLI to service", "Slow reply"): "fixture-only",
    ("Frontend isolate to worker isolate", "Slow reply"): "open",
    ("Service to helper", "Closing"): "partial",
    ("Service to helper", "Reconnect"): "partial",
    ("Service to helper", "EOF before reply"): "fixture-only",
    ("Service to helper", "Slow reply"): "fixture-only",
    ("Service to helper", "Malformed or partial frame"): "open",
    ("Service to helper", "Duplicate launch"): "partial",
    ("Lock and record handoff", "Duplicate launch"): "partial",
}


def test_every_lifecycle_verdict_is_pinned_and_none_is_closed():
    cells = {(item["boundary"], item["transition"]): item["status"] for item in inventory.load(ROOT)["lifecycle_reconciliation"]}
    # A verdict changes only together with the test that justifies it.
    assert cells == EXPECTED_VERDICTS


def test_downgraded_cells_say_why_and_cite_what_the_tests_prove():
    data = inventory.load(ROOT)
    eof = cell(data, "Desktop to service", "EOF before reply")
    assert [(e["path"].rsplit("/", 1)[1], e["test"]) for e in eof["evidence"][:2]] == [
        ("remote_domain_test.dart", "abrupt service loss reconnects and refreshes snapshots without replaying a write"),
        ("remote_domain_test.dart", "a command whose outcome is unknown is never resent"),
    ]
    assert "already closed" in eof["missing"] and "no reply pending" in eof["missing"]
    reconnect = cell(data, "Desktop to service", "Reconnect")
    assert "literal true" in reconnect["evidence"][1]["sides"] and "fixture service" in reconnect["missing"]
    closing = cell(data, "Service to helper", "Closing")
    assert closing["status"] == "partial" and "SIGKILL fallback passes" in closing["missing"]
    assert any("helper.released" in item["sides"] for item in closing["evidence"])
    eof_helper = cell(data, "Service to helper", "EOF before reply")
    assert [e["test"] for e in eof_helper["evidence"]] == ["peer EOF before a queued request reports failure without escaping"]
    assert "no RPC in flight" in eof_helper["missing"]
    assert "no RPC in flight" in cell(data, "Service to helper", "Reconnect")["evidence"][0]["sides"]
    slow = cell(data, "Frontend isolate to worker isolate", "Slow reply")
    assert slow["evidence"] == [] and "not an assertion about the frontend/worker bridge" in slow["missing"]


def test_boundary_citations_do_not_overclaim():
    boundaries = {item["id"]: item for item in inventory.load(ROOT)["boundaries"]}
    launcher = next(e for e in boundaries["launcher-service-handoff"]["evidence"] if e["path"] == "tests/service/test_service_process.py")
    assert launcher["names"] == ["test_unexpected_service_death_interrupts_capture_and_reuses_profile"]
    closing = next(e for e in boundaries["mcp-service"]["evidence"] if e["path"].endswith("service_closing_protocol_test.dart"))
    assert closing["kind"] == "fixture" and "MCP process and protocol layer are replaced" in closing["note"]
    facade = next(e for e in boundaries["desktop-service"]["evidence"] if e["path"] == "tests/service/test_service_process.py")
    assert "does not prove that an uncertain mutation is never replayed" in facade["note"]
    assert any("literal true" in gap for gap in boundaries["desktop-service"]["gaps"])


def test_class_and_module_level_skips_in_cited_files_must_declare_a_skip_gate(export, editable):
    for path in ("tests/integration/test_file_parser.py", "tests/test_macos_bundle.py", "tests/test_dmg_contract.py"):
        def drop(data, path=path):
            next(item for boundary in data["boundaries"] for item in boundary["evidence"] if item["path"] == path).pop("skip_gate")

        editable("tools/boundary_inventory.json", drop)
        failing(export, f"{path}: carries a skip marker, so the entry must declare its skip_gate")
    declared = {
        item["path"]: item["skip_gate"]
        for boundary in inventory.load(ROOT)["boundaries"]
        for item in boundary["evidence"]
        if item["path"] in ("tests/integration/test_file_parser.py", "tests/test_macos_bundle.py", "tests/test_dmg_contract.py")
    }
    assert declared == {
        "tests/integration/test_file_parser.py": "native-stage",
        "tests/test_macos_bundle.py": "platform-contracts",
        "tests/test_dmg_contract.py": "dmg-contracts",
    }


def test_local_only_must_carry_a_reason(export, editable):
    def blank(data):
        data["gates"]["shared-guards"]["local_only"] = "  "

    editable("tools/boundary_inventory.json", blank)
    failing(export, "gate shared-guards: local_only needs a reason")
    assert inventory.load(ROOT)["gates"]["python-coverage"]["local_only"].strip()


def test_wiring_unverified_must_carry_a_reason(export, editable):
    def blank(data):
        data["gates"]["integration-virtual-audio"]["wiring_unverified_reason"] = " "

    editable("tools/boundary_inventory.json", blank)
    failing(export, "gate integration-virtual-audio: wiring_unverified_reason needs a reason")
    assert inventory.load(ROOT)["gates"]["integration-virtual-audio"]["wiring_unverified_reason"].strip()
