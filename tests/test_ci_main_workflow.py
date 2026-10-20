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


def test_all_platform_workflow_callers_grant_declared_callee_permissions():
    import yaml

    root = Path(__file__).resolve().parents[1]
    callee = yaml.safe_load((root / ".github/workflows/macos.yml").read_text())
    ranks = {"none": 0, "read": 1, "write": 2}
    requested = dict(callee.get("permissions", {}))
    for job in callee["jobs"].values():
        for scope, value in job.get("permissions", {}).items():
            if ranks[value] > ranks[requested.get(scope, "none")]:
                requested[scope] = value
    callers = []
    for path in (root / ".github/workflows").glob("*.yml"):
        workflow = yaml.safe_load(path.read_text())
        for name, job in workflow.get("jobs", {}).items():
            if job.get("uses") != "./.github/workflows/macos.yml":
                continue
            callers.append((path.name, name))
            granted = job.get("permissions", workflow.get("permissions", {}))
            for scope, value in requested.items():
                assert ranks[granted.get(scope, "none")] >= ranks[value], (
                    path.name,
                    name,
                    scope,
                    value,
                )
    assert callers


def test_exercise_and_production_sweeps_cannot_evict_each_others_pending_run():
    import yaml

    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/macos.yml").read_text())
    assert (
        "format('main-sweep-{0}', inputs.sweep_namespace)"
        in workflow["concurrency"]["group"]
    )
