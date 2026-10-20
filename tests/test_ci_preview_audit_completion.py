"""Weekly cadence uses actual successful gates and authenticated completion bytes."""

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import zipfile

import pytest
import yaml

from tools import ci_artifacts as artifacts
from tools import ci_preview_audit as audit
from tests.test_ci_preview_audit import preview as preview, MONDAY
from tests.test_integration_application import (
    producer as producer,
    SOURCE,
    REPOSITORY,
    RUN,
)

TUESDAY = datetime(2026, 10, 20, tzinfo=timezone.utc)


@pytest.fixture
def history(tmp_path, monkeypatch):
    run = {
        "id": RUN,
        "run_attempt": 2,
        "head_sha": SOURCE,
        "head_branch": "main",
        "path": ".github/workflows/preview-packages.yml",
        "event": "schedule",
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
        "status": "in_progress",
    }
    job = {
        "id": 300,
        "name": "weekly-external-audit",
        "run_id": RUN,
        "head_sha": SOURCE,
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "started_at": "2026-10-19T01:00:00Z",
        "completed_at": "2026-10-19T03:00:00Z",
        "steps": [
            dict(name=name, status="completed", conclusion="success")
            for name in audit.AUDIT_STEPS
        ],
    }
    receipt = {
        "schema": 1,
        "kind": "weekly-external-audit",
        "repository": REPOSITORY,
        "workflow": run["path"],
        "event": "schedule",
        "source_commit": SOURCE,
        "source_run": RUN,
        "source_run_attempt": 1,
        "job": "weekly-external-audit",
        "gates": {"cpu": "success", "audio": "success", "deb": "success"},
        "completed_at": "2026-10-19T02:00:00Z",
    }
    item = {
        "id": 200,
        "name": f"weekly-external-audit-completion-{RUN}-1",
        "expired": False,
        "workflow_run": {"id": RUN, "head_sha": SOURCE},
        "created_at": "2026-10-19T02:01:00Z",
    }
    state = dict(
        run=run, job=job, receipt=receipt, item=item, ancestry="ahead", calls=[]
    )
    archive = tmp_path / "completion.zip"

    def pack(member="completion.json", mode=None, extra=False):
        with zipfile.ZipFile(archive, "w") as stream:
            entry = zipfile.ZipInfo(member)
            if mode is not None:
                entry.external_attr = mode << 16
            stream.writestr(entry, json.dumps(receipt))
            if extra:
                stream.writestr("extra", "ambiguous")
        item.update(
            digest="sha256:" + artifacts.digest(archive),
            size_in_bytes=archive.stat().st_size,
        )

    pack()
    state["pack"] = pack

    def request(repository, route):
        assert repository == REPOSITORY
        state["calls"].append(route)
        if route.startswith("actions/workflows/preview-packages.yml/runs?"):
            assert "created=" in route
            return {"workflow_runs": [run]}
        if route.startswith(f"actions/runs/{RUN}/artifacts?"):
            return {"artifacts": state.get("items", [item])}
        if route.startswith(f"actions/runs/{RUN}/jobs?"):
            assert "filter=all" in route
            return {
                "jobs": [
                    job,
                    {**job, "id": 301, "run_attempt": 2, "conclusion": "failure"},
                ]
            }
        if route.startswith("compare/"):
            return {"status": state["ancestry"]}
        raise AssertionError(route)

    def download(arguments, *, stdout, **kwargs):
        assert arguments == [
            "gh",
            "api",
            f"repos/{REPOSITORY}/actions/artifacts/200/zip",
        ]
        state["downloads"] = state.get("downloads", 0) + 1
        stdout.write(archive.read_bytes())

    monkeypatch.setattr(artifacts, "api", request)
    monkeypatch.setattr(artifacts.subprocess, "run", download)
    return state


def test_completed_original_attempt_with_failed_retry_satisfies_only_this_week(history):
    assert audit.audited_this_week(REPOSITORY, TUESDAY)
    assert not audit.audited_this_week(REPOSITORY, TUESDAY.replace(day=27))
    assert not audit.audited_this_week(REPOSITORY, MONDAY)
    assert any("filter=all" in route for route in history["calls"])


@pytest.mark.parametrize(
    "section,key,value",
    [
        ("run", "path", ".github/workflows/macos.yml"),
        ("run", "event", "pull_request"),
        ("run", "head_branch", "feature"),
        ("run", "repository", {"full_name": "fork/repo"}),
        ("run", "head_repository", {"full_name": "fork/repo"}),
        ("run", "id", True),
        ("run", "run_attempt", True),
        ("run", "head_sha", "invalid"),
        ("item", "expired", True),
        ("item", "name", "unrelated"),
    ],
)
def test_unqualified_or_expired_completions_do_not_suppress_audit(
    history, section, key, value
):
    history[section][key] = value
    assert not audit.audited_this_week(REPOSITORY, TUESDAY)


@pytest.mark.parametrize(
    "section,key,value",
    [
        ("item", "id", True),
        ("item", "workflow_run", {"id": True, "head_sha": SOURCE}),
        ("item", "workflow_run", {"id": RUN, "head_sha": "b" * 40}),
        ("item", "digest", "sha256:" + "b" * 64),
        ("item", "size_in_bytes", True),
        ("item", "size_in_bytes", 2 * 1024 * 1024),
        ("item", "name", f"weekly-external-audit-completion-{RUN}-3"),
        ("item", "created_at", "2026-10-19T04:00:00Z"),
        ("job", "run_attempt", True),
        ("job", "status", "in_progress"),
        ("job", "head_sha", "b" * 40),
        ("job", "name", "other-job"),
        ("job", "id", True),
    ],
)
def test_invalid_original_producer_or_archive_proof_fails_closed(
    history, section, key, value
):
    history[section][key] = value
    with pytest.raises(ValueError):
        audit.audited_this_week(REPOSITORY, TUESDAY)


@pytest.mark.parametrize("name", audit.AUDIT_STEPS)
@pytest.mark.parametrize("change", ["skipped", "missing", "duplicate", "pending"])
def test_successful_job_without_each_performed_audit_step_is_not_a_completion(
    history, name, change
):
    steps = history["job"]["steps"]
    step = next(step for step in steps if step["name"] == name)
    if change == "missing":
        steps.remove(step)
    elif change == "duplicate":
        steps.append(dict(step))
    elif change == "pending":
        step.update(status="in_progress", conclusion=None)
    else:
        step["conclusion"] = "skipped"
    if change == "duplicate":
        with pytest.raises(ValueError, match="Ambiguous actual weekly audit step"):
            audit.audited_this_week(REPOSITORY, TUESDAY)
    else:
        assert not audit.audited_this_week(REPOSITORY, TUESDAY)
        assert history.get("downloads", 0) == 0


@pytest.mark.parametrize(
    "key,value",
    [
        ("schema", True),
        ("kind", "other"),
        ("repository", "fork/repo"),
        ("workflow", ".github/workflows/macos.yml"),
        ("event", "pull_request"),
        ("source_commit", "b" * 40),
        ("source_run", True),
        ("source_run_attempt", 2),
        ("source_run_attempt", True),
        ("job", "other"),
        ("gates", {"cpu": "skipped", "audio": "success", "deb": "success"}),
        ("completed_at", "2026-10-19T00:00:00Z"),
        ("completed_at", "2026-10-19T03:00:00Z"),
        ("completed_at", "2026-10-19T02:00:00"),
        ("completed_at", None),
    ],
)
def test_actual_zip_receipt_identity_and_recording_window_are_mandatory(
    history, key, value
):
    history["receipt"][key] = value
    history["pack"]()
    with pytest.raises(ValueError):
        audit.audited_this_week(REPOSITORY, TUESDAY)


@pytest.mark.parametrize(
    "options",
    [
        {"member": "../completion.json"},
        {"mode": 0o120777},
        {"mode": 0o040755},
        {"extra": True},
    ],
)
def test_completion_zip_is_one_regular_exact_receipt(history, options):
    history["pack"](**options)
    with pytest.raises(ValueError, match="ZIP members"):
        audit.audited_this_week(REPOSITORY, TUESDAY)


def test_unreviewed_completion_source_and_ambiguous_uploads_fail(history):
    history["ancestry"] = "diverged"
    with pytest.raises(ValueError, match="reviewed main"):
        audit.audited_this_week(REPOSITORY, TUESDAY)
    history["items"] = [history["item"], dict(history["item"])]
    with pytest.raises(ValueError, match="Ambiguous"):
        audit.audited_this_week(REPOSITORY, TUESDAY)


def test_verified_completion_skips_daily_audit_but_explicit_full_runs(
    preview, monkeypatch
):
    monkeypatch.setattr(audit, "audited_this_week", lambda *args: True)
    assert (
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)["selected"] == "false"
    )
    assert (
        audit.plan(REPOSITORY, SOURCE, "workflow_dispatch", True, now=TUESDAY)[
            "selected"
        ]
        == "true"
    )


@pytest.mark.parametrize("status", ["queued", "in_progress"])
def test_exact_source_active_producer_defers_without_dispatch_or_wait(preview, status):
    preview["values"][3].update(
        status=status,
        updated_at="2026-10-19T23:45:00Z",
        run_started_at="2026-10-19T23:45:00Z",
    )
    preview["values"][5].update(status="in_progress", conclusion=None)
    assert (
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)["selected"] == "false"
    )


@pytest.mark.parametrize(
    "change", ["source", "event", "fork", "skipped", "failed", "no-build"]
)
def test_other_sources_or_nonproducers_never_hide_missing_current_preview(
    preview, change
):
    run = preview["values"][3]
    run["status"] = "in_progress"
    if change == "source":
        run["head_sha"] = "b" * 40
    elif change == "event":
        run["event"] = "pull_request"
    elif change == "fork":
        run["head_repository"] = {"full_name": "fork/repo"}
    else:
        for job in [preview["values"][5], *preview["closure"]]:
            job.update(
                status="completed",
                conclusion="failure" if change == "failed" else "skipped",
            )
            if change == "no-build":
                job["name"] = "planning-only"
    with pytest.raises(ValueError, match="No retained green"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)


@pytest.fixture
def record_environment(monkeypatch):
    values = {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_WORKFLOW_REF": f"{REPOSITORY}/.github/workflows/preview-packages.yml@refs/heads/main",
        "GITHUB_EVENT_NAME": "schedule",
        "GITHUB_JOB": "weekly-external-audit",
        "GITHUB_RUN_ID": str(RUN),
        "GITHUB_RUN_ATTEMPT": "1",
        "AUDIT_CPU": "success",
        "AUDIT_AUDIO": "success",
        "AUDIT_DEB": "success",
    }
    for key, value in values.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setattr(
        audit.subprocess, "check_output", lambda *args, **kwargs: SOURCE + "\n"
    )


def test_record_cli_writes_actual_completed_gates(
    record_environment, tmp_path, monkeypatch
):
    import sys

    output = tmp_path / "nested/completion.json"
    monkeypatch.setattr(
        sys, "argv", ["audit", "record", "--source", SOURCE, "--output", str(output)]
    )
    audit.main()
    receipt = json.loads(output.read_text())
    assert receipt["source_run"] == RUN
    assert receipt["source_run_attempt"] == 1
    assert receipt["gates"] == {"cpu": "success", "audio": "success", "deb": "success"}
    recorded = datetime.fromisoformat(receipt["completed_at"])
    assert recorded.tzinfo is not None
    assert recorded.microsecond == 0  # Match the API upload timestamp precision.


@pytest.mark.parametrize(
    "key,value",
    [
        ("GITHUB_REF", "refs/pull/999/merge"),
        ("GITHUB_EVENT_NAME", "pull_request"),
        ("GITHUB_JOB", "other"),
        ("GITHUB_WORKFLOW_REF", "other.yml"),
        ("GITHUB_REPOSITORY", "invalid"),
        ("GITHUB_RUN_ID", "0"),
        ("GITHUB_RUN_ATTEMPT", "01"),
        ("AUDIT_CPU", "skipped"),
        ("AUDIT_AUDIO", "failure"),
        ("AUDIT_DEB", "cancelled"),
    ],
)
def test_record_refuses_skipped_or_untrusted_gates(
    record_environment, tmp_path, monkeypatch, key, value
):
    monkeypatch.setenv(key, value)
    with pytest.raises(ValueError, match="three performed audit gates"):
        audit.record(SOURCE, tmp_path / "completion.json")
    assert not (tmp_path / "completion.json").exists()


def test_matrix_names_derive_from_workflow_and_preserve_real_api_regression():
    root = Path(__file__).resolve().parents[1]
    job = yaml.safe_load((root / ".github/workflows/preview-packages.yml").read_text())[
        "jobs"
    ]["linux"]
    names = [
        job["name"].replace("${{ matrix.format }}", row["format"])
        for row in job["strategy"]["matrix"]["include"]
    ]
    assert set(names) == {
        name for name in audit.NIGHTLY_REQUIRED if name.startswith("linux (")
    }
    fixture = root / "tests/fixtures/preview-jobs/nightly39271527879-package-names.json"
    assert (
        artifacts.digest(fixture)
        == "b0b50d69ea7c20490b98b51295e6ada29f69032c1bed04bfd4dfd902fcb047a4"
    )
    actual = json.loads(fixture.read_text())
    assert actual["run_id"] == 39271527879
    assert {row["id"] for row in actual["actual_API_rows"]} == {
        118141862347,
        118141862368,
        118141862668,
    }
    assert all(
        row["name"].startswith("linux (") and row["name"] not in names
        for row in actual["actual_API_rows"]
    )
    run = {"id": actual["run_id"], "run_attempt": 1}
    controls = [
        {
            "id": 1000 + index,
            "name": name,
            "run_id": run["id"],
            "head_sha": actual["source"],
            "run_attempt": 1,
            "status": "completed",
            "conclusion": "success",
        }
        for index, name in enumerate(audit.NIGHTLY_REQUIRED)
        if name not in names
    ]
    assert not audit.green_closure(
        [*controls, *actual["actual_API_rows"]], run, actual["source"]
    )
    # Narrowly migrate only the job names to the explicit workflow template;
    # preserve every original API identity/status/source/attempt field.
    revised = [
        {
            **row,
            "name": job["name"].replace(
                "${{ matrix.format }}", row["name"].split("(", 1)[1].split(",", 1)[0]
            ),
        }
        for row in actual["actual_API_rows"]
    ]
    assert audit.green_closure([*controls, *revised], run, actual["source"])


def test_completion_upload_requires_the_three_actual_named_gates():
    root = Path(__file__).resolve().parents[1]
    steps = yaml.safe_load(
        (root / ".github/workflows/preview-packages.yml").read_text()
    )["jobs"]["weekly-external-audit"]["steps"]
    for gate, name in zip(("cpu", "audio", "deb"), audit.AUDIT_STEPS[:3], strict=True):
        step = next(step for step in steps if step.get("name") == name)
        assert step["id"] == gate + "-audit"
        assert "continue-on-error" not in step
    marker = next(step for step in steps if step.get("id") == "completed-audit")
    assert marker["name"] == audit.AUDIT_STEPS[3]
    assert all(
        f"steps.{gate}-audit.outcome == 'success'" in marker["if"]
        for gate in ("cpu", "audio", "deb")
    )
    upload = next(
        step
        for step in steps
        if step.get("name") == "Upload completed weekly external audit receipt"
    )
    assert upload["if"] == "steps.completed-audit.outcome == 'success'"
    assert (
        upload["with"]["name"]
        == "weekly-external-audit-completion-${{ github.run_id }}-${{ github.run_attempt }}"
    )
    assert upload["with"]["path"] == "test-results/weekly-audit/completion.json"
    assert upload["with"]["if-no-files-found"] == "error"
    assert upload["with"]["overwrite"] is True


@pytest.mark.parametrize("conclusion", ["failure", "cancelled", "timed_out"])
def test_failed_completion_upload_does_not_poison_later_weekly_audits(
    history, conclusion
):
    history["job"]["conclusion"] = conclusion
    assert not audit.audited_this_week(REPOSITORY, TUESDAY)
    assert history.get("downloads", 0) == 0


@pytest.mark.parametrize("status", ["pending", "waiting", "requested"])
def test_pending_same_source_retry_defers_within_bounded_age(preview, status):
    preview["values"][3].update(
        status=status,
        updated_at="2026-10-19T23:45:00Z",
        run_started_at="2026-10-19T23:45:00Z",
    )
    assert (
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)["selected"] == "false"
    )


def test_stale_queued_producer_fails_actionably_instead_of_deferring_forever(preview):
    preview["values"][3].update(status="queued", updated_at="2026-10-19T23:29:59Z")
    with pytest.raises(ValueError, match="30-minute"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)


@pytest.mark.parametrize("seconds,selected", [(0, False), (1800, False), (1801, None)])
def test_deferral_age_has_an_exact_thirty_minute_limit(preview, seconds, selected):
    preview["values"][3].update(
        status="queued", updated_at=(TUESDAY - timedelta(seconds=seconds)).isoformat()
    )
    if selected is None:
        with pytest.raises(ValueError, match="30-minute"):
            audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)
    else:
        assert (
            audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)["selected"]
            == "false"
        )


@pytest.mark.parametrize(
    "timestamp", [None, "invalid", "2026-10-20T00:00:01Z", "2026-10-20T00:00:00"]
)
def test_unknown_or_future_producer_age_cannot_defer_indefinitely(preview, timestamp):
    preview["values"][3].update(status="waiting", updated_at=timestamp)
    with pytest.raises(ValueError, match="30-minute"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)


@pytest.mark.parametrize("conclusion", ["failure", "cancelled", "timed_out"])
def test_nonqualification_cannot_hide_known_artifact_identity_or_upload_window_contradictions(
    history, conclusion
):
    history["job"]["conclusion"] = conclusion
    history["item"]["created_at"] = "2026-10-19T04:00:00Z"
    with pytest.raises(ValueError, match="outside its original producer"):
        audit.audited_this_week(REPOSITORY, TUESDAY)
    assert history.get("downloads", 0) == 0


def test_incomplete_original_audit_cannot_suppress_week_or_download_bytes(history):
    history["job"].update(status="in_progress", conclusion=None)
    assert not audit.audited_this_week(REPOSITORY, TUESDAY)
    assert history.get("downloads", 0) == 0


def test_ambiguous_original_audit_cannot_be_ignored_as_nonqualification(
    history, monkeypatch
):
    request = artifacts.api

    def ambiguous(repository, route):
        response = request(repository, route)
        if "jobs" in response:
            return {"jobs": [*response["jobs"], dict(history["job"])]}
        return response

    monkeypatch.setattr(artifacts, "api", ambiguous)
    with pytest.raises(ValueError, match="Ambiguous"):
        audit.audited_this_week(REPOSITORY, TUESDAY)


def test_active_running_attempt_uses_start_age_not_recent_unrelated_update(preview):
    preview["values"][3].update(
        status="in_progress",
        run_started_at="2026-10-19T23:00:00Z",
        updated_at="2026-10-20T00:00:00Z",
    )
    preview["values"][5].update(status="in_progress", conclusion=None)
    with pytest.raises(ValueError, match="30-minute"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)


@pytest.mark.parametrize(
    "created", ["2026-10-19T00:59:59Z", "2026-10-19T04:00:00Z", None]
)
def test_incomplete_job_nonqualification_does_not_mask_known_upload_contradictions(
    history, created
):
    history["job"].update(status="in_progress", conclusion=None)
    history["item"]["created_at"] = created
    with pytest.raises(ValueError):
        audit.audited_this_week(REPOSITORY, TUESDAY)
    assert history.get("downloads", 0) == 0


def test_incomplete_job_without_end_checks_known_start_before_ignoring(history):
    history["job"].update(status="in_progress", conclusion=None, completed_at=None)
    assert not audit.audited_this_week(REPOSITORY, TUESDAY)
    assert history.get("downloads", 0) == 0


def test_running_producer_without_start_cannot_extend_deferral_via_updates(preview):
    preview["values"][3].update(
        status="in_progress", run_started_at=None, updated_at="2026-10-20T00:00:00Z"
    )
    preview["values"][5].update(status="in_progress", conclusion=None)
    with pytest.raises(ValueError, match="30-minute"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)


@pytest.fixture
def multi_preview(preview, monkeypatch):
    request = artifacts.api

    def two_runs(repository, route):
        assert repository == REPOSITORY
        if route.startswith(f"actions/runs/{RUN + 1}/artifacts?"):
            return {"artifacts": []}
        if route.startswith(f"actions/runs/{RUN + 1}/jobs?"):
            return {
                "jobs": [
                    {
                        **preview["values"][5],
                        "id": 5000,
                        "run_id": RUN + 1,
                        "run_attempt": preview["values"][3]["run_attempt"],
                        "status": "in_progress",
                        "conclusion": None,
                    }
                ]
            }
        return request(repository, route)

    monkeypatch.setattr(artifacts, "api", two_runs)
    return preview


@pytest.mark.parametrize(
    "status", ["queued", "pending", "waiting", "requested", "in_progress"]
)
def test_newer_stale_queue_cannot_hide_older_qualified_original_bundle(
    multi_preview, status, tmp_path
):
    preview = multi_preview
    run = preview["values"][3]
    preview["runs"] = [
        {
            **run,
            "id": RUN + 1,
            "status": status,
            "updated_at": "2026-10-19T23:00:00Z",
            "run_started_at": "2026-10-19T23:00:00Z",
        },
        run,
    ]
    result = audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)
    assert result["selected"] == "true"
    assert result["producer_run"] == str(RUN)
    assert result["artifact_id"] == str(preview["values"][4]["id"])
    output = tmp_path / "restored"
    qualification = audit.restore(
        REPOSITORY,
        SOURCE,
        RUN,
        1,
        preview["values"][4]["id"],
        preview["values"][2],
        output,
    )
    assert (output / "application.tar.gz").read_bytes() == (
        preview["values"][0] / "application.tar.gz"
    ).read_bytes()
    assert qualification["producer_run"] == RUN
    assert qualification["producer_attempt"] == 1
    assert qualification["producer_job"] == preview["values"][5]["id"]


@pytest.mark.parametrize("status", ["queued", "in_progress"])
def test_fresh_canonical_alternative_can_defer_after_newer_stale_queue(
    multi_preview, status
):
    preview = multi_preview
    run = preview["values"][3]
    run.update(
        status=status,
        updated_at="2026-10-19T23:45:00Z",
        run_started_at="2026-10-19T23:45:00Z",
    )
    if status == "in_progress":
        run["run_attempt"] = 1
        preview["values"][5].update(status="in_progress", conclusion=None)
    preview["runs"] = [
        {
            **run,
            "id": RUN + 1,
            "updated_at": "2026-10-19T23:00:00Z",
            "run_started_at": "2026-10-19T23:00:00Z",
        },
        run,
    ]
    assert (
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)["selected"] == "false"
    )


def test_newer_queue_cannot_turn_an_older_artifact_identity_error_into_deferral(
    multi_preview,
):
    preview = multi_preview
    run = preview["values"][3]
    preview["runs"] = [
        {
            **run,
            "id": RUN + 1,
            "status": "queued",
            "updated_at": "2026-10-19T23:45:00Z",
        },
        run,
    ]
    preview["values"][4]["workflow_run"]["head_sha"] = "b" * 40
    with pytest.raises(ValueError, match="differs from its successful original upload"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)


def test_stale_queue_still_fails_when_older_bundle_expired(multi_preview):
    preview = multi_preview
    run = preview["values"][3]
    preview["runs"] = [
        {
            **run,
            "id": RUN + 1,
            "status": "queued",
            "updated_at": "2026-10-19T23:00:00Z",
        },
        run,
    ]
    preview["values"][4]["expired"] = True
    with pytest.raises(audit.ProducerDeferralLimit, match="30-minute"):
        audit.plan(REPOSITORY, SOURCE, "schedule", now=TUESDAY)
