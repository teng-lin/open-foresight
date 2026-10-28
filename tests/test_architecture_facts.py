"""Tests for tools/check_architecture_facts.py (stdlib unittest; pytest-compatible)."""

from __future__ import annotations

import io
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

from tools import check_architecture_facts as facts_tool

ROOT = Path(__file__).resolve().parents[1]


class PacketTest(unittest.TestCase):
    """Each test works on a private copy of the authority sources and docs."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        inputs = [
            *facts_tool.SOURCES.values(),
            facts_tool.SCHEMA_DOC,
            facts_tool.SERVICE_DOC,
        ]
        for relative in inputs:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def replace(self, relative: str, old: str, new: str) -> None:
        path = self.root / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def errors(self) -> list[str]:
        return facts_tool.check(self.root, facts_tool.collect(self.root))


class CurrentFactsTest(PacketTest):
    def test_supplied_registries_yield_expected_facts(self) -> None:
        facts = facts_tool.collect(self.root)
        self.assertEqual(facts.migration_steps, list(range(1, 26)))
        self.assertEqual(facts.content_revisions_step, 18)
        self.assertEqual(facts.schema_version_symbol, "applicationSchemaVersion")
        self.assertEqual(facts.application_schema_version, 25)
        self.assertEqual(facts.request_key_lifetime_hours, 24)
        self.assertEqual(facts.workspace_epoch_key, "workspaceEpoch")
        self.assertEqual(len(facts.operations), 100)
        self.assertEqual(facts.operations[0], "recordingsRead")
        self.assertEqual(facts.operation_wires[-1], "service.stop_if_idle")
        self.assertEqual(len(facts.mcp_tools), 32)
        self.assertEqual(facts.mcp_tool_operations["ask"], "answerStream")
        self.assertEqual(
            sorted(facts.registry_rejects), ["cross-scope", "duplicate", "missing"]
        )

    def test_corrected_docs_match(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_main_reports_success(self) -> None:
        with redirect_stderr(io.StringIO()):
            self.assertEqual(facts_tool.main(["--root", str(self.root)]), 0)


class DriftTest(PacketTest):
    def test_schema_table_stopping_at_17_is_rejected(self) -> None:
        doc = self.root / facts_tool.SCHEMA_DOC
        lines = doc.read_text(encoding="utf-8").splitlines(keepends=True)
        kept = [
            line
            for line in lines
            if not any(line.startswith(f"| {n} |") for n in range(18, 26))
        ]
        doc.write_text("".join(kept), encoding="utf-8")
        errors = self.errors()
        self.assertTrue(
            any("missing [18, 19, 20, 21, 22, 23, 24, 25]" in e for e in errors), errors
        )

    def test_new_migration_step_requires_doc_update(self) -> None:
        self.replace(
            facts_tool.SOURCES["migrations"],
            "      default:",
            "      case 26:\n        db.execute('SELECT 1');\n      default:",
        )
        errors = self.errors()
        self.assertTrue(any("missing [26]" in e for e in errors), errors)
        self.assertTrue(any("latest migration step" in e for e in errors), errors)

    def test_old_operation_count_is_rejected(self) -> None:
        self.replace(
            facts_tool.SERVICE_DOC, "declares 100 operations", "declares 75 operations"
        )
        self.assertTrue(any("stated as 75" in e for e in self.errors()))

    def test_per_scope_handler_split_claim_is_rejected(self) -> None:
        self.replace(
            facts_tool.SERVICE_DOC,
            "The `Operation` enum declares",
            "The registries own 78 and eight handlers. The `Operation` enum declares",
        )
        self.assertTrue(any("unverifiable" in e for e in self.errors()))

    def test_tools_table_must_list_every_registered_tool(self) -> None:
        self.replace(
            facts_tool.SERVICE_DOC,
            "| `get_meeting_tasks`, `edit_meeting_task` |",
            "| `edit_meeting_task` |",
        )
        self.assertTrue(any("omits ['get_meeting_tasks']" in e for e in self.errors()))

    def test_tools_table_rejects_unregistered_tool(self) -> None:
        self.replace(facts_tool.SERVICE_DOC, "| `ask` |", "| `ask`, `summon` |")
        self.assertTrue(any("unregistered ['summon']" in e for e in self.errors()))

    def test_content_revisions_step_must_match(self) -> None:
        self.replace(facts_tool.SERVICE_DOC, "Schema 18 retains", "Schema 17 retains")
        self.assertTrue(
            any("content_revisions schema step" in e for e in self.errors())
        )

    def test_application_schema_value_must_match_migration_steps(self) -> None:
        path = self.root / facts_tool.SOURCES["schema"]
        path.write_text("const applicationSchemaVersion = 21;\n", encoding="utf-8")
        self.assertTrue(any("applicationSchemaVersion=21" in e for e in self.errors()))
        path.write_text("const applicationSchemaVersion = 25;\n", encoding="utf-8")
        self.assertEqual(self.errors(), [])


class InputShapeTest(PacketTest):
    def test_direct_tool_cannot_bypass_projection(self) -> None:
        self.replace(
            facts_tool.SOURCES["rpc_tools"],
            "  return [\n",
            "  return [\n    RpcTool('extra', Operation.answer, '', {}, []),\n",
        )
        with self.assertRaisesRegex(
            facts_tool.InputError, "bypasses operation projection"
        ):
            facts_tool.collect(self.root)

    def test_missing_schema_authority_exits_2(self) -> None:
        (self.root / facts_tool.SOURCES["schema"]).unlink()
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(facts_tool.main(["--root", str(self.root)]), 2)
        self.assertIn("application_schema.dart", err.getvalue())

    def test_missing_source_exits_2(self) -> None:
        (self.root / facts_tool.SOURCES["rpc_tools"]).unlink()
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(facts_tool.main(["--root", str(self.root)]), 2)
        self.assertIn("rpc_tools.dart", err.getvalue())

    def test_projection_and_tool_list_must_agree(self) -> None:
        self.replace(
            facts_tool.SOURCES["projections"],
            '"ask",\n    Operation.answerStream,',
            '"ask",\n    Operation.answer,',
        )
        with self.assertRaises(facts_tool.InputError):
            facts_tool.collect(self.root)

    def test_non_contiguous_steps_fail_closed(self) -> None:
        self.replace(
            facts_tool.SOURCES["migrations"], "      case 19:", "      case 99:"
        )
        with self.assertRaises(facts_tool.InputError):
            facts_tool.collect(self.root)

    def test_drift_exit_status_is_1(self) -> None:
        self.replace(
            facts_tool.SERVICE_DOC, "exposes 32 MCP tools", "exposes 28 MCP tools"
        )
        with redirect_stderr(io.StringIO()):
            self.assertEqual(facts_tool.main(["--root", str(self.root)]), 1)


if __name__ == "__main__":
    unittest.main()
