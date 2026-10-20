"""Weekly drift consumes green same-main-source preview bytes without a rebuild."""

from datetime import datetime, timezone
import json
from pathlib import Path

import pytest

from tests.test_integration_application import (
    producer as producer,
    changed_receipt,
    SOURCE,
    REPOSITORY,
    RUN,
    ARTIFACT,
)
from tools import ci_preview_audit as audit
from tools import ci_artifacts as artifacts

LABEL = "nightly.20261019.3"
MONDAY = datetime(2026, 10, 19, tzinfo=timezone.utc)


@pytest.fixture
def preview(producer, monkeypatch):
    producer[3].update(
        path=".github/workflows/preview-packages.yml",
        event="schedule",
        head_branch="main",
        status="completed",
    )
    producer[5]["name"] = "build / linux-build"
    (producer[0] / "distribution-stamp.json").write_text(
        json.dumps(
            {
                "version": "0.1.2",
                "build_number": 3,
                "label": LABEL,
                "source_commit": SOURCE,
            }
        )
    )
    values = changed_receipt(producer, tier="preview", label=LABEL)
    closure = [
        {**values[5], "id": 1000 + index, "name": name}
        for index, name in enumerate(audit.NIGHTLY_REQUIRED)
        if name != "build / linux-build"
    ]
    nightly = next(job for job in closure if job["name"] == "nightly-checks")
    state = {
        "main": SOURCE,
        "runs": [values[3]],
        "nightly": nightly,
        "values": values,
        "closure": closure,
    }

    def api(repository, route):
        assert repository == REPOSITORY
        if route == "commits/main":
            return {"sha": state["main"]}
        if route.startswith("actions/workflows/preview-packages.yml/runs?"):
            return {"workflow_runs": state["runs"]}
        if "/jobs?" in route:
            return {"jobs": [values[5], *state["closure"]]}
        if route.startswith(f"actions/runs/{RUN}/artifacts?"):
            return {"artifacts": [values[4]]}
        if route == f"actions/runs/{RUN}":
            return values[3]
        if route == f"actions/artifacts/{ARTIFACT}":
            return values[4]
        raise AssertionError(route)

    def download(arguments, *, stdout, **kwargs):
        assert arguments == [
            "gh",
            "api",
            f"repos/{REPOSITORY}/actions/artifacts/{ARTIFACT}/zip",
        ]
        stdout.write(values[1].read_bytes())

    monkeypatch.setattr(artifacts, "api", api)
    monkeypatch.setattr(
        artifacts.subprocess, "check_output", lambda *args, **kwargs: SOURCE + "\n"
    )
    monkeypatch.setattr(artifacts.subprocess, "run", download)
    return state


def test_monday_audit_qualifies_original_preview_and_downloaded_bytes(
    preview, tmp_path
):
    result = audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)
    assert result["selected"] == "true"
    assert result["producer_run"] == str(RUN)
    output = tmp_path / "restored"
    qualification = audit.restore(
        REPOSITORY, SOURCE, RUN, 1, ARTIFACT, preview["values"][2], output
    )
    assert (output / "application.tar.gz").read_bytes() == (
        preview["values"][0] / "application.tar.gz"
    ).read_bytes()
    assert qualification["source_receipt"]["tier"] == "preview"
    assert qualification["source_receipt"]["label"] == LABEL
    assert (
        json.loads((output / "distribution-stamp.json").read_text())["source_commit"]
        == SOURCE
    )


@pytest.mark.parametrize(
    "event,full,day,selected",
    [
        ("schedule", False, MONDAY, True),
        ("workflow_dispatch", True, MONDAY.replace(day=20), True),
        ("schedule", False, MONDAY.replace(day=20), True),
        ("push", False, MONDAY, False),
    ],
)
def test_only_weekly_schedule_or_explicit_full_selects_consumption(
    preview, event, full, day, selected
):
    result = audit.plan(REPOSITORY, SOURCE, event, full, now=day)
    assert (result["selected"] == "true") == selected


@pytest.mark.parametrize(
    "section,key,value",
    [
        ("run", "path", ".github/workflows/macos.yml"),
        ("run", "event", "pull_request"),
        ("run", "head_sha", "b" * 40),
        ("run", "head_branch", "feature"),
        ("run", "repository", {"full_name": "other/repo"}),
        ("run", "head_repository", {"full_name": "fork/repo"}),
        ("job", "conclusion", "failure"),
        ("job", "status", "in_progress"),
        ("nightly", "conclusion", "failure"),
        ("nightly", "conclusion", "cancelled"),
        ("artifact", "expired", True),
        ("artifact", "created_at", "2025-01-01T00:03:00Z"),
        ("artifact", "digest", "sha256:" + "c" * 64),
        ("artifact", "workflow_run", {"id": RUN + 1, "head_sha": SOURCE}),
    ],
)
def test_unqualified_or_failed_previews_never_authorize_audit(
    preview, section, key, value, tmp_path
):
    target = (
        preview["nightly"]
        if section == "nightly"
        else preview["values"][{"run": 3, "artifact": 4, "job": 5}[section]]
    )
    target[key] = value
    if section == "artifact" and key == "digest":
        # Metadata-only planning may select a plausible ZIP digest; restore must
        # hash the actual download rather than trusting the API field alone.
        audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)
        with pytest.raises(ValueError, match="ZIP digest"):
            audit.restore(
                REPOSITORY,
                SOURCE,
                RUN,
                1,
                ARTIFACT,
                value.removeprefix("sha256:"),
                tmp_path / "restored",
            )
    else:
        with pytest.raises(ValueError):
            audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)
    assert not (tmp_path / "restored").exists()


def test_superseded_source_does_not_stamp_compile_or_audit_ancestor(preview):
    preview["main"] = "b" * 40
    assert audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)["selected"] == "false"
    with pytest.raises(ValueError, match="Main advanced"):
        audit.restore(
            REPOSITORY, SOURCE, RUN, 1, ARTIFACT, preview["values"][2], Path("unused")
        )


@pytest.mark.parametrize(
    "field,value",
    [
        ("source_commit", "b" * 40),
        ("build_number", 4),
        ("label", "nightly.20261019.4"),
        ("version", "0.1.3"),
    ],
)
def test_preview_stamp_must_match_the_actual_package_receipt(
    preview, field, value, tmp_path
):
    producer = preview["values"]
    stamp = producer[0] / "distribution-stamp.json"
    metadata = json.loads(stamp.read_text())
    metadata[field] = value
    stamp.write_text(json.dumps(metadata))
    updated = changed_receipt(producer, tier="preview", label=LABEL)
    preview["values"] = updated
    # The API/download fixture closures intentionally share the same receipt
    # and artifact objects; only the newly hashed ZIP checksum changes here.
    with pytest.raises(ValueError, match="stamp"):
        audit.restore(
            REPOSITORY, SOURCE, RUN, 1, ARTIFACT, updated[2], tmp_path / "restored"
        )


def test_incomplete_latest_attempt_cannot_replace_the_selected_green_receipt(
    preview, tmp_path
):
    audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)
    preview["nightly"]["conclusion"] = "failure"
    with pytest.raises(ValueError, match="latest"):
        audit.restore(
            REPOSITORY,
            SOURCE,
            RUN,
            1,
            ARTIFACT,
            preview["values"][2],
            tmp_path / "restored",
        )


@pytest.mark.parametrize("command", ["plan", "restore"])
def test_cli_never_dispatches_or_stamps_a_new_preview(monkeypatch, tmp_path, command):
    from unittest.mock import Mock
    import sys

    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_EVENT_NAME", "schedule")
    arguments = ["audit", command, "--source", SOURCE]
    if command == "restore":
        arguments += [
            "--producer-run",
            str(RUN),
            "--attempt",
            "1",
            "--artifact-id",
            str(ARTIFACT),
            "--artifact-digest",
            "a" * 64,
            "--directory",
            str(tmp_path),
        ]
    else:
        arguments += ["--full"]
    monkeypatch.setattr(sys, "argv", arguments)
    operation = Mock(return_value={"source_receipt": {"label": LABEL}})
    monkeypatch.setattr(audit.acceptance, "prepare", Mock())
    monkeypatch.setattr(audit, command, operation)
    audit.main()
    operation.assert_called_once()
    if command == "plan":
        assert operation.call_args.args == (REPOSITORY, SOURCE, "schedule", True)
    else:
        assert operation.call_args.args == (
            REPOSITORY,
            SOURCE,
            RUN,
            1,
            ARTIFACT,
            "a" * 64,
            tmp_path,
        )
    monkeypatch.setattr(sys, "argv", ["audit", "restore", "--source", SOURCE])
    with pytest.raises(SystemExit, match="2"):
        audit.main()


def test_restore_cli_emits_original_preview_package_version(
    preview, monkeypatch, tmp_path
):
    import sys

    monkeypatch.chdir(tmp_path)
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_REPOSITORY", REPOSITORY)
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "audit",
            "restore",
            "--source",
            SOURCE,
            "--producer-run",
            str(RUN),
            "--attempt",
            "1",
            "--artifact-id",
            str(ARTIFACT),
            "--artifact-digest",
            preview["values"][2],
        ],
    )
    audit.main()
    assert output.read_text().splitlines() == [
        f"version=0.1.2~{LABEL}",
        f"source={SOURCE}",
        "release=1",
    ]
    assert (tmp_path / "artifacts/source-qualification.json").is_file()
    assert (
        tmp_path / "build/portable/dist/open-foresight/executable"
    ).read_bytes() == b"immutable original application"


@pytest.mark.parametrize("actual", ["b" * 40, "invalid"])
def test_audit_checkout_is_the_exact_compiled_main_source(monkeypatch, actual):
    monkeypatch.setattr(
        audit.subprocess, "check_output", lambda *args, **kwargs: actual + "\n"
    )
    with pytest.raises(ValueError, match="actual"):
        audit.checkout(SOURCE)


def test_planner_emits_failure_selection_before_transport_error(
    preview, monkeypatch, tmp_path
):
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.setattr(
        audit.artifacts,
        "api",
        lambda *args: (_ for _ in ()).throw(RuntimeError("transport")),
    )
    with pytest.raises(RuntimeError, match="transport"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)
    assert "selected=true" in output.read_text()


def test_weekly_graph_is_consume_only_and_does_not_change_nightly_watermarks():
    import yaml

    root = Path(__file__).resolve().parents[1]
    jobs = yaml.safe_load(
        (root / ".github/workflows/preview-packages.yml").read_text()
    )["jobs"]
    assert jobs["weekly-audit-plan"]["needs"] == ["plan", "nightly-checks"]
    assert "!cancelled()" in jobs["weekly-audit-plan"]["if"]
    audit_job = jobs["weekly-external-audit"]
    assert audit_job["needs"] == "weekly-audit-plan"
    assert "!cancelled()" in audit_job["if"]
    assert "selected == 'true'" in audit_job["if"]
    text = str(audit_job)
    assert "stamp" not in " ".join(step.get("run", "") for step in audit_job["steps"])
    assert "linux_sdk_artifacts.py produce" not in " ".join(
        step.get("run", "") for step in audit_job["steps"]
    )
    assert all(value == "read" for value in audit_job["permissions"].values())
    assert "weekly-external-audit" not in jobs["nightly-checks"]["needs"]
    assert "ci_linux_sdk_reference.py restore" in text
    assert "ci_dependency_wait.py" not in text
    writer = jobs["weekly-audit-issue"]
    assert "refs/heads/main" in writer["if"] and "workflow_dispatch" in writer["if"]
    assert writer["concurrency"]["group"] == "ci-preview-external-drift-issue"
    assert any(
        "ci_drift_issue.py preview-packages.yml" in step.get("run", "")
        for step in writer["steps"]
    )
    assert not (root / ".github/workflows/integration-acceptance.yml").exists()


@pytest.mark.parametrize("conclusion", ["success", "failure"])
def test_unselected_daily_audits_cannot_overwrite_actual_weekly_drift(
    monkeypatch, conclusion
):
    from tools import ci_drift_issue as drift

    run = {
        "id": 100,
        "head_sha": SOURCE,
        "path": ".github/workflows/preview-packages.yml",
        "head_branch": "main",
        "head_repository": {"full_name": REPOSITORY},
        "event": "schedule",
        "status": "completed",
    }
    calls = []

    def request(repository, route, method="GET", data=None, optional=False):
        calls.append((route, method, data))
        if route == "actions/runs/100":
            return run
        if route.startswith("actions/workflows/"):
            return {"workflow_runs": [{**run, "id": 101}, run]}
        if route.startswith("actions/runs/101/jobs"):
            return {
                "jobs": [
                    {
                        "name": "weekly-external-audit",
                        "status": "completed",
                        "conclusion": "skipped",
                    }
                ]
            }
        if route.startswith("actions/runs/100/jobs"):
            return {
                "jobs": [
                    {
                        "name": "weekly-external-audit",
                        "status": "completed",
                        "conclusion": conclusion,
                    }
                ]
            }
        if route.startswith("issues?"):
            return []
        if route.startswith("labels/"):
            return {"name": "existing"}
        if route == "issues" and method == "POST":
            return {}
        raise AssertionError(route)

    drift.reconcile(REPOSITORY, "preview-packages.yml", 100, SOURCE, request=request)
    writes = [row for row in calls if row[1] == "POST"]
    if conclusion == "failure":
        assert len(writes) == 1
        assert "runs/100" in writes[0][2]["body"]
        assert "weekly external audit" in writes[0][2]["title"]
    else:
        assert not writes


def test_invalid_original_attempt_never_authorizes_audit(preview):
    preview["values"][5]["run_attempt"] = True
    with pytest.raises(ValueError, match="No retained green"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)


def test_ambiguous_original_artifact_never_authorizes_audit(preview, monkeypatch):
    request = artifacts.api

    def duplicate(repository, route):
        response = request(repository, route)
        if "artifacts" in response:
            return {"artifacts": response["artifacts"] * 2}
        return response

    monkeypatch.setattr(artifacts, "api", duplicate)
    with pytest.raises(ValueError, match="Ambiguous"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)


@pytest.mark.parametrize("status", ["completed", "in_progress"])
def test_current_monday_preview_can_be_consumed_only_after_full_actual_closure_green(
    preview, status
):
    preview["values"][3]["status"] = status
    result = audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)
    assert result["selected"] == "true"


@pytest.mark.parametrize("name", audit.NIGHTLY_REQUIRED)
@pytest.mark.parametrize(
    "change",
    ["pending", "failure", "missing", "duplicate", "wrong-source", "wrong-attempt"],
)
def test_a_green_aggregate_cannot_hide_any_incomplete_or_replaced_critical_child(
    preview, name, change
):
    if name == "build / linux-build":
        job = preview["values"][5]
    else:
        job = next(row for row in preview["closure"] if row["name"] == name)
    if change == "pending":
        job.update(status="in_progress", conclusion=None)
    elif change == "failure":
        job["conclusion"] = "failure"
    elif change == "missing":
        job["name"] = "missing-required-job"
    elif change == "duplicate":
        preview["closure"].append(dict(job))
    elif change == "wrong-source":
        job["head_sha"] = "c" * 40
    else:
        job["run_attempt"] = 3
    with pytest.raises(ValueError, match="No retained green"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)


def test_in_progress_nonaggregate_build_descendant_also_blocks_audit(preview):
    preview["closure"].append(
        {
            **preview["values"][5],
            "id": 5000,
            "name": "build / macos-stages / native-macos",
            "status": "in_progress",
            "conclusion": None,
        }
    )
    with pytest.raises(ValueError, match="No retained green"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=MONDAY)


def test_nightly_legacy_arch_failure_cannot_be_ignored_by_audit(preview):
    rows = [preview["values"][5], *preview["closure"]]
    extra = {
        **preview["values"][5],
        "id": 99999,
        "name": "build / linux-native / native-linux",
        "conclusion": "failure",
    }
    assert audit.green_closure(rows, preview["values"][3], SOURCE)
    assert not audit.green_closure([*rows, extra], preview["values"][3], SOURCE)
