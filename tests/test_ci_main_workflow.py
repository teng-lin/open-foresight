"""Required boundaries for the read-only observer and gated coordinator."""

from pathlib import Path
import unittest


class EvidenceWorkflowTests(unittest.TestCase):
    def test_observer_never_has_write_scopes_or_pr_execution(self):
        import yaml

        root = Path(__file__).resolve().parents[1]
        workflow = yaml.safe_load(
            (root / ".github/workflows/main-evidence.yml").read_text(),
        )
        self.assertNotIn("pull_request", workflow.get("on", workflow.get(True)))
        self.assertNotIn("write", workflow["permissions"].values())
        observer = workflow["jobs"]["observe"]
        self.assertNotIn("permissions", observer)
        self.assertIn(
            "github.event.workflow_run.event != 'pull_request'", observer["if"]
        )
        self.assertIn(
            "17,47 * * * *",
            [row["cron"] for row in workflow.get("on", workflow.get(True))["schedule"]],
        )
        writer = workflow["jobs"]["coordinate"]
        self.assertIn("needs.observe.outputs.activate == 'true'", writer["if"])
        self.assertEqual(writer["permissions"]["actions"], "write")
        self.assertEqual(writer["steps"][0]["with"]["ref"], "${{ github.sha }}")
