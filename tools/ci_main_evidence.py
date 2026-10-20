#!/usr/bin/env python3
"""Observe reviewed main validation; receipts never authorize application bytes.

Discovery is untrusted. Every locator is re-read through the API, including the
latest readiness attempt and the separate original artifact-upload attempt.
Production activation is deliberately absent until the hosted rollout qualifies.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import ci_release_candidates as candidate  # noqa: E402
from tools.build_sequence import request  # noqa: E402
from tools.ci_nightly import pages  # noqa: E402
from tools.github_job_attempts import canonical_jobs  # noqa: E402

PLATFORM = ".github/workflows/macos.yml"
WORKFLOW = ".github/workflows/main-evidence.yml"
APP = 15368
REQUIRED = {
    "python": ".github/workflows/quality.yml",
    "format": ".github/workflows/quality.yml",
    "contracts": ".github/workflows/quality.yml",
    "platform-checks": PLATFORM,
    "acceptance-checks": PLATFORM,
}
APPLICATION = (
    "linux-build",
    "linux-test",
    "macos",
    "linux-document-imports",
    "dmg",
    "linux-native",
    "acceptance-cpu",
    "acceptance-audio",
    "acceptance-deb",
)
GROUPS = {
    "linux-native": tuple(
        "linux-native / " + name
        for name in ("native-linux", "core-linux", "desktop-linux", "service-linux")
    ),
    "dmg": ("dmg / dmg",),
}
SHA = re.compile(r"[0-9a-f]{40}")


def fingerprint(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def require_source(source):
    if not isinstance(source, str) or not SHA.fullmatch(source):
        raise ValueError("Main evidence requires an exact source SHA")
    return source


def scoped_run(run, repository, workflow, source, events):
    if (
        run.get("path") != workflow
        or run.get("event") not in events
        or run.get("head_sha") != source
        or (run.get("repository") or {}).get("full_name") != repository
        or (run.get("head_repository") or {}).get("full_name") != repository
        or not candidate.positive(run.get("id"))
        or (run.get("event") != "pull_request" and run.get("head_branch") != "main")
    ):
        raise ValueError(
            "Main evidence producer repository/workflow/ref/source mismatch"
        )
    return run


def selection_jobs(selection):
    if selection.get("superseded") is not False:
        raise ValueError("Selection lacks explicit non-superseded execution evidence")
    gates = selection.get("selection")
    expected = {
        "macos",
        "linux-build",
        "linux-test",
        "linux-document-imports",
        "packaging",
        "dmg",
    }
    if (
        not isinstance(gates, dict)
        or set(gates) != expected
        or any(type(value) is not bool for value in gates.values())
    ):
        raise ValueError("Missing or incompatible platform selection schema")
    phases = selection.get("acceptance_phases")
    if gates["linux-build"] and phases is not None and (not isinstance(phases, dict) or set(phases) != {"cpu-models", "software-gpu", "virtual-audio"} or any(value is not True for value in phases.values())):
        raise ValueError("Partial acceptance phases cannot promote full main validation")
    if type(selection.get("arch_retired", False)) is not bool:
        raise ValueError("Arch retirement selection must be an explicit boolean")
    result = {name: gates.get(name, False) for name in APPLICATION}
    result["linux-native"] = gates["linux-build"] and not selection.get("arch_retired", False)
    for name in ("acceptance-cpu", "acceptance-audio", "acceptance-deb"):
        result[name] = gates["linux-build"]
    return result


def require_ready(run):
    """Old green jobs cannot stand in for an unfinished or failed new attempt."""
    if (
        run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or not candidate.positive(run.get("run_attempt"))
    ):
        raise ValueError("Latest validation run attempt is not completed successfully")
    return run


def job_proof(jobs, name):
    return {child: candidate.latest(jobs, child) for child in GROUPS.get(name, (name,))}


class Reader:
    def __init__(self, repository, *, api=request, mode="observation"):
        if mode not in ("observation", "production"):
            raise ValueError("Unknown main receipt namespace")
        self.repository = repository
        self.api = api
        self.mode = mode
        self._arch_retirement: dict[str, bool] = {}

    def get(self, route):
        return self.api(self.repository, route)

    def arch_retired(self, source):
        """A selection marker cannot retire an owner without current hosted proof."""
        if source in self._arch_retirement:
            return self._arch_retirement[source]
        try:
            from tools.ci_qualification_index import capability

            capability("arch_retirement", source, repository=self.repository, api=self.api)
        except (ImportError, ValueError, KeyError, TypeError):
            self._arch_retirement[source] = False
            return False
        self._arch_retirement[source] = True
        return True

    def application_owners(self, source):
        return tuple(
            name for name in APPLICATION
            if name != "linux-native" or not self.arch_retired(source)
        )

    def rows(self, route, key):
        return pages(self.repository, route, key, request=self.api)

    def run(self, run_id):
        return self.get(f"actions/runs/{run_id}")

    def jobs(self, run):
        raw = self.rows(f"actions/runs/{run['id']}/jobs?filter=all", "jobs")
        return canonical_jobs(
            raw,
            run,
            lambda attempt: self.get(f"actions/runs/{run['id']}/attempts/{attempt}"),
        )

    def runs(self, workflow, source):
        return sorted(
            self.rows(
                f"actions/workflows/{workflow.rsplit('/', 1)[-1]}/runs?head_sha={source}",
                "workflow_runs",
            ),
            key=lambda row: row["id"],
            reverse=True,
        )

    def latest_run(self, workflow, source, events):
        # A newer bad/cancelled attempt must not be hidden by an older green run.
        matches = [
            run for run in self.runs(workflow, source) if run.get("event") in events
        ]
        if not matches:
            raise ValueError("No authoritative latest validation run")
        return scoped_run(matches[0], self.repository, workflow, source, events)

    def artifact(self, run, name, member, job_name):
        jobs = self.jobs(run)
        items = self.rows(f"actions/runs/{run['id']}/artifacts", "artifacts")
        proofs = []
        for job in jobs:
            if job.get("name") != job_name or job.get("conclusion") != "success":
                continue
            try:
                item = candidate.original(items, name, run, job)
            except candidate.CandidateArtifactsUnavailable:
                continue
            except ValueError:
                continue
            proofs.append((job, item))
        if len(proofs) != 1:
            raise ValueError("Artifact lacks one original successful uploading attempt")
        job, item = proofs[0]
        record = candidate.read_json(self.repository, item, member)
        return record, {
            "run": run["id"],
            "job": job["id"],
            "attempt": job["run_attempt"],
            "artifact": item["id"],
            "sha256": item["digest"],
        }

    def selection(self, run):
        selection, upload = self.artifact(
            run, "ci-selection-platform", "ci-selection.json", "changes"
        )
        selection_jobs(selection)
        if selection.get("arch_retired") is True and not self.arch_retired(run["head_sha"]):
            raise ValueError("Arch retirement selection lacks verified hosted qualification")
        return selection, upload

    def input_identity(self, source):
        commit = self.get(f"git/commits/{source}")
        tree = self.get(f"git/trees/{commit['tree']['sha']}?recursive=1")
        if tree.get("truncated") is not False:
            raise ValueError("Complete validation input tree unavailable")
        # Conservative shared closure: even a quality-only test change may cause
        # a sweep. No application/SDK/control input can be hidden by path rules.
        entries = [
            (row["path"], row["mode"], row["type"], row["sha"])
            for row in tree["tree"]
            if row["type"] != "tree"
            and not row["path"].startswith(("docs/", ".github/ISSUE_TEMPLATE/"))
            and (
                not row["path"].endswith(".md")
                or row["path"].startswith("packaging/notices/")
            )
        ]
        return fingerprint(sorted(entries))

    def required_checks(self, head):
        rules = self.get("rules/branches/main")
        required = [
            check
            for rule in rules
            if rule.get("type") == "required_status_checks"
            for check in rule["parameters"]["required_status_checks"]
        ]
        if {check["context"] for check in required} != set(REQUIRED) or any(
            check.get("integration_id") != APP for check in required
        ):
            raise ValueError("Main required-check set or GitHub App binding changed")
        checks = self.rows(f"commits/{head}/check-runs?filter=all", "check_runs")
        proofs = {}
        workflows = {}
        for name, workflow in REQUIRED.items():
            matches = [row for row in checks if row.get("name") == name]
            if not matches:
                raise ValueError(f"Missing required check: {name}")
            check = max(matches, key=lambda row: row["id"])
            if workflow not in workflows:
                current = require_ready(
                    self.latest_run(workflow, head, ("pull_request",))
                )
                workflows[workflow] = (current, self.jobs(current))
            run, jobs = workflows[workflow]
            if (
                check.get("head_sha") != head
                or check.get("app", {}).get("id") != APP
                or check.get("status") != "completed"
                or check.get("conclusion") != "success"
                or check.get("check_suite", {}).get("id") != run.get("check_suite_id")
            ):
                raise ValueError(
                    f"Latest named required check is not trusted green: {name}"
                )
            job = candidate.latest(jobs, name)
            proofs[name] = {
                "check": check["id"],
                "run": run["id"],
                "job": job["id"],
                "attempt": job["run_attempt"],
                "completed_at": job["completed_at"],
            }
        return proofs

    def previous(self, source, identity):
        for run in self.runs(WORKFLOW, source):
            scoped_run(
                run,
                self.repository,
                WORKFLOW,
                source,
                ("push", "workflow_run", "workflow_dispatch", "schedule"),
            )
            try:
                namespace = (
                    "observation" if self.mode == "observation" else "validation"
                )
                owner = "observe" if self.mode == "observation" else "coordinate"
                receipt, upload = self.artifact(
                    run, f"ci-main-{namespace}-{source}", "receipt.json", owner
                )
            except ValueError:
                continue
            if (
                type(receipt.get("schema")) is not int
                or receipt.get("schema") != 1
                or receipt.get("mode") != self.mode
                or receipt.get("source") != source
                or receipt.get("repository") != self.repository
                or receipt.get("input_identity") != identity
                or receipt.get("decision") != "validated"
                or receipt.get("required") != REQUIRED
            ):
                raise ValueError("Predecessor receipt is incompatible")
            # Revalidate every original PR's current readiness. The receipt is
            # an index, never authority to trust a stale green check.
            contexts: dict = {}
            for origin in receipt["jobs"].values():
                self.verify_origin(origin, contexts=contexts)
            return receipt, upload
        raise ValueError("Predecessor has no qualified per-job evidence")

    def verify_origin(self, origin, *, contexts=None):
        head = require_source(origin["head"])
        sweep = origin.get("kind") == "sweep"
        contexts = {} if contexts is None else contexts
        key = (head, sweep, origin["run"])
        if key not in contexts:
            checks = None if sweep else self.required_checks(head)
            if sweep:
                from tools.ci_main_sweep import qualify, validation_runs

                run = self.run(origin["run"])
                if run.get("head_sha") != head:
                    raise ValueError("Sweep origin source differs from its receipt")
                current = validation_runs(self, head)
                if not current or current[0]["id"] != run["id"]:
                    raise ValueError("Sweep origin is no longer the latest production validation")
                qualify(self, run)
            else:
                run = self.latest_run(PLATFORM, head, ("pull_request",))
            selection, upload = self.selection(run)
            contexts[key] = (checks, run, selection, upload, self.jobs(run))
        checks, run, selection, upload, jobs = contexts[key]
        if not sweep and checks != origin["required_checks"]:
            raise ValueError("Original PR readiness changed after receipt creation")
        if (
            upload != origin["selection_upload"]
            or not selection_jobs(selection)[origin["name"]]
        ):
            raise ValueError("Original job selection changed or did not execute")
        jobs = job_proof(jobs, origin["name"])
        observed = {
            name: {"job": job["id"], "attempt": job["run_attempt"]}
            for name, job in jobs.items()
        }
        if run["id"] != origin["run"] or observed != origin["executions"]:
            raise ValueError("Original job readiness is no longer authoritative")

    def proposal(self, source, before, selected):
        source, before = require_source(source), require_source(before)
        base = {
            "schema": 1,
            "mode": self.mode,
            "repository": self.repository,
            "source": source,
            "before": before,
            "required": REQUIRED,
            "recorded_at": datetime.now(timezone.utc).isoformat(),
            "jobs": {},
        }
        try:
            owners = self.application_owners(source)
            base["owners"] = list(owners)
            commit = self.get(f"git/commits/{source}")
            if before != commit["parents"][0]["sha"]:
                raise ValueError("Push predecessor is not a direct main parent")
            prs = self.rows(f"commits/{source}/pulls", None)
            matches = [
                pr
                for pr in prs
                if pr.get("merged_at") and pr.get("merge_commit_sha") == source
            ]
            if len(matches) != 1:
                raise ValueError("Main source lacks one authoritative merged PR")
            pr = matches[0]
            head = require_source(pr["head"]["sha"])
            if (
                pr["base"]["ref"] != "main"
                or pr["base"]["repo"]["full_name"] != self.repository
                or pr["head"]["repo"]["full_name"] != self.repository
                or pr["user"]["login"] == "dependabot[bot]"
            ):
                raise ValueError(
                    "Foreign or Dependabot PR cannot promote main validation"
                )
            current_main = self.get("commits/main")["sha"]
            if self.get(f"compare/{source}...{current_main}")["status"] not in (
                "ahead",
                "identical",
            ):
                raise ValueError(
                    "Source is not reachable from authoritative reviewed main"
                )
            if self.get(f"git/commits/{head}")["tree"]["sha"] != commit["tree"]["sha"]:
                raise ValueError("Final PR and reviewed main trees differ")
            identity = self.input_identity(source)
            base.update(tree=commit["tree"]["sha"], head=head, input_identity=identity)
            checks = self.required_checks(head)
            run = self.latest_run(PLATFORM, head, ("pull_request",))
            selection, upload = self.selection(run)
            executed = selection_jobs(selection)
            jobs = self.jobs(run)
            previous = None
            for name in owners:
                if executed[name]:
                    executions = job_proof(jobs, name)
                    base["jobs"][name] = {
                        "name": name,
                        "head": head,
                        "source": source,
                        "run": run["id"],
                        "executions": {
                            child: {"job": job["id"], "attempt": job["run_attempt"]}
                            for child, job in executions.items()
                        },
                        "required_checks": checks,
                        "selection_upload": upload,
                    }
                elif selected[name]:
                    raise ValueError(
                        f"Selected main job did not execute on final PR: {name}"
                    )
                else:
                    if previous is None:
                        previous = self.previous(before, identity)
                    predecessor, locator = previous
                    base["jobs"][name] = predecessor["jobs"][name]
                    base["predecessor"] = locator
            base.update(
                decision="validated",
                reason="Every application job has fresh or chained evidence",
            )
        except (ValueError, KeyError, TypeError) as error:
            base.update(decision="sweep", reason=str(error), jobs={})
        return base

    def actual(self, source, selected):
        run = self.latest_run(PLATFORM, source, ("push",))
        result = {
            "run": run["id"],
            "status": run["status"],
            "conclusion": run.get("conclusion"),
            "attempt": run.get("run_attempt"),
            "jobs": {},
        }
        jobs = self.jobs(run)
        result["historical_failure"] = bool(
            run.get("run_attempt", 1) > 1
            and any(
                job.get("run_attempt", 1) < run["run_attempt"]
                and job.get("conclusion") in ("failure", "timed_out")
                for job in jobs
            )
        )
        try:
            for name in ("platform-checks", "acceptance-checks"):
                candidate.latest(jobs, name)
            result["aggregates_success"] = True
        except ValueError:
            result["aggregates_success"] = False
        owners = self.application_owners(source)
        for name, required in selected.items():
            if not required or name not in owners:
                continue
            try:
                proof = job_proof(jobs, name)
                result["jobs"][name] = {
                    "result": "success",
                    "executions": {
                        child: {"job": job["id"], "attempt": job["run_attempt"]}
                        for child, job in proof.items()
                    },
                }
            except ValueError as error:
                result["jobs"][name] = {"result": "unresolved", "reason": str(error)}
        return result


def observation_qualified(proposal):
    actual = proposal.get("actual_main", {})
    if (
        actual.get("status") != "completed"
        or actual.get("conclusion") != "success"
        or actual.get("aggregates_success") is not True
        or any(
            job.get("result") != "success" for job in actual.get("jobs", {}).values()
        )
    ):
        return False
    if proposal.get("decision") == "validated":
        return True
    return set(actual.get("jobs", {})) == set(proposal.get("owners", APPLICATION))


def selected_on_push(root, before, source):
    import subprocess
    from tools.ci_changes import select_gates

    paths = (
        subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", before, source, "--"],
            cwd=root,
            timeout=300,
        )
        .decode()
        .split("\0")
    )
    return selection_jobs(
        {
            "selection": select_gates([path for path in paths if path]),
            "superseded": False,
        }
    )


def observation_case(proposal):
    if not observation_qualified(proposal):
        return None
    if proposal["actual_main"].get("historical_failure") is True:
        return "failed-rerun"
    if proposal.get("decision") == "validated":
        if any(
            origin.get("source") != proposal.get("source")
            for origin in proposal.get("jobs", {}).values()
        ):
            return "partially-selected"
        return "identical"
    if proposal.get("reason") == "Final PR and reviewed main trees differ":
        return "divergent"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--before")
    parser.add_argument("--qualification-output", type=Path)
    parser.add_argument(
        "--output", type=Path, default=Path("main-evidence/receipt.json")
    )
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    if os.environ.get("GITHUB_REF") != "refs/heads/main" or os.environ.get(
        "GITHUB_EVENT_NAME"
    ) not in ("push", "workflow_run", "workflow_dispatch", "schedule"):
        raise ValueError("Observer requires a main-only trusted workflow event")
    source = require_source(args.source)
    reader = Reader(repository)
    # A workflow_run's SHA is default-branch controls, not its triggering source.
    current = reader.get(f"git/commits/{source}")
    before = args.before or current["parents"][0]["sha"]
    selected = selected_on_push(Path.cwd(), before, source)
    proposal = reader.proposal(source, before, selected)
    try:
        proposal["actual_main"] = reader.actual(source, selected)
    except ValueError as error:
        proposal["actual_main"] = {"status": "unavailable", "reason": str(error)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(proposal, indent=2, sort_keys=True) + "\n")
    case = observation_case(proposal)
    qualified = case is not None and source == os.environ.get("GITHUB_SHA")
    if args.qualification_output and qualified:
        from tools.ci_rollout import descriptor

        record = descriptor(
            source,
            run_id=int(os.environ["GITHUB_RUN_ID"]),
            attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]),
            producer_job="observe",
        )
        record["observation"] = {
            "decision": proposal["decision"],
            "actual_main": proposal["actual_main"],
        }
        record["observer_case"] = case
        args.qualification_output.parent.mkdir(parents=True, exist_ok=True)
        args.qualification_output.write_text(json.dumps(record, sort_keys=True) + "\n")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"qualified={str(qualified).lower()}\n")
    summary = (
        f"Observation only: {proposal['decision']} for {source}: {proposal['reason']}\n"
    )
    print(summary)
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a") as stream:
            stream.write(summary)


if __name__ == "__main__":
    main()
