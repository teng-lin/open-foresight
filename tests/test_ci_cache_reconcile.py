"""Main cache discovery schedules warmers only for missing exact outputs."""

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from tools import ci_cache_reconcile as reconcile
from tools import ci_cache_publish_guard as guard

SOURCE = "a" * 40
HASHES = ("b" * 64, "c" * 64, "d" * 64)
ROOT = Path(__file__).resolve().parents[1]


def environment():
    return {
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": SOURCE,
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_JOB": "reconcile",
        "GITHUB_WORKFLOW_REF": "owner/repo/.github/workflows/linux-cache-publish.yml@refs/heads/main",
        "CORE_LOCK_HASH": HASHES[0],
        "UI_LOCK_HASH": HASHES[1],
        "MODEL_INPUT_HASH": HASHES[2],
    }


def cache(key, *, ref="refs/heads/main", size=1024):
    return {"key": key, "ref": ref, "size_in_bytes": size}


def fetch_for(rows, *, mains=None, calls=None):
    mains = iter(mains or [SOURCE, SOURCE])

    def fetch(repository, route):
        if calls is not None:
            calls.append((repository, route))
        if route == "commits/main":
            return {"sha": next(mains)}
        if route.startswith("actions/workflows/linux-cache-publish.yml/runs?"):
            return {"workflow_runs": []}
        assert route.startswith(
            "actions/caches?ref=refs%2Fheads%2Fmain&per_page=100&page="
        )
        page = int(route.rsplit("=", 1)[-1])
        return {"actions_caches": rows[(page - 1) * 100 : page * 100]}

    return fetch


def all_keys():
    return [key for keys in reconcile.cache_keys(*HASHES).values() for key in keys]


def test_warm_half_hour_reconciliation_does_not_launch_language_warmers():
    for _ in range(48):
        result = reconcile.reconcile(
            environment(),
            fetch=fetch_for([cache(key) for key in all_keys()]),
            head=SOURCE,
        )
        assert result["current"] is True
        assert result["common"] is False
        assert result["arch_stages"] == []
        assert result["models_macos"] is False
        assert not any(result[role] for role in reconcile.cache_keys(*HASHES))


@pytest.mark.parametrize(
    "role",
    [
        "formatter",
        "document",
        "models_linux",
        "models_macos",
        "arch_core",
        "arch_desktop",
    ],
)
def test_missing_output_selects_only_its_actual_publisher(role):
    keys = reconcile.cache_keys(*HASHES)
    absent = keys[role][-1]
    result = reconcile.reconcile(
        environment(),
        fetch=fetch_for([cache(key) for key in all_keys() if key != absent]),
        head=SOURCE,
    )
    assert result["missing"][role] == [absent]
    assert {name for name in keys if result[name]} == {role}
    assert result["arch_stages"] == (
        [role.removeprefix("arch_")] if role.startswith("arch_") else []
    )
    assert result["common"] == (role in {"formatter", "document", "models_linux"})


def test_paginated_api_ref_prefix_and_empty_entries_cannot_hide_a_miss():
    rows = [cache("noise-" + str(index)) for index in range(100)] + [
        cache(key) for key in all_keys()
    ]
    calls = []
    result = reconcile.reconcile(
        environment(), fetch=fetch_for(rows, calls=calls), head=SOURCE
    )
    assert result["common"] is False
    assert any(route.endswith("page=2") for _, route in calls)
    wrong = [cache(key, ref="refs/pull/9/merge") for key in all_keys()]
    wrong += [cache(key + "-restore-prefix") for key in all_keys()]
    wrong += [cache(key, size=0) for key in all_keys()]
    result = reconcile.reconcile(environment(), fetch=fetch_for(wrong), head=SOURCE)
    assert all(result[role] for role in reconcile.cache_keys(*HASHES))
    assert result["arch_stages"] == ["core", "desktop"]


@pytest.mark.parametrize("mains", [["f" * 40], [SOURCE, "f" * 40]])
def test_main_advancement_before_or_during_listing_prevents_stale_publication(mains):
    calls = []
    result = reconcile.reconcile(
        environment(), fetch=fetch_for([], mains=mains, calls=calls), head=SOURCE
    )
    assert result["current"] is False
    assert result["arch_stages"] == []
    assert not any(result[role] for role in reconcile.cache_keys(*HASHES))
    if len(mains) == 1:
        assert calls == [("owner/repo", "commits/main")]


@pytest.mark.parametrize(
    "key,value",
    [
        ("GITHUB_REF", "refs/pull/9/merge"),
        ("GITHUB_EVENT_NAME", "pull_request"),
        ("GITHUB_JOB", "linux-test"),
        (
            "GITHUB_WORKFLOW_REF",
            "owner/repo/.github/workflows/quality.yml@refs/heads/main",
        ),
        ("GITHUB_SHA", "main"),
        ("GITHUB_REPOSITORY", "invalid"),
    ],
)
def test_untrusted_requests_fail_before_any_api_or_warmer(key, value):
    env = environment() | {key: value}
    with (
        pytest.raises(ValueError, match="dedicated reviewed-main"),
        patch.object(reconcile, "api", side_effect=AssertionError("No API permitted")),
    ):
        reconcile.reconcile(env, head=SOURCE)


def test_missing_post_checkout_hash_and_wrong_checkout_fail_closed():
    with pytest.raises(ValueError, match="post-checkout"):
        reconcile.reconcile(environment() | {"CORE_LOCK_HASH": ""}, head=SOURCE)
    with pytest.raises(ValueError, match="checkout differs"):
        reconcile.reconcile(environment(), head="f" * 40)
    with pytest.raises(ValueError, match="response"):
        reconcile.main_cache_keys("owner/repo", fetch=lambda *_: {"actions_caches": {}})
    with pytest.raises(ValueError, match="exact key"):
        reconcile.main_cache_keys("owner/repo", fetch=fetch_for([cache(None)]))


def test_cache_api_failure_is_not_a_verified_hit_or_permission_to_warm_everything():
    def fail(repository, route):
        if route == "commits/main":
            return {"sha": SOURCE}
        raise RuntimeError("Cache listing unavailable; retry independent maintenance")

    with pytest.raises(RuntimeError, match="listing unavailable"):
        reconcile.reconcile(environment(), fetch=fail, head=SOURCE)


def test_cli_uses_reviewed_checkout_and_emits_exact_role_matrix(tmp_path, monkeypatch):
    result = reconcile.reconcile(environment(), fetch=fetch_for([]), head=SOURCE)
    output, github_output = tmp_path / "result.json", tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(github_output))
    monkeypatch.setattr("sys.argv", ["reconcile", "--output", str(output)])
    with patch.object(reconcile, "reconcile", return_value=result):
        reconcile.main()
    assert json.loads(output.read_text())["arch_stages"] == ["core", "desktop"]
    assert "arch_needed=true" in github_output.read_text()
    assert "registry_needed=true" in github_output.read_text()
    assert 'arch_stages=["core", "desktop"]' in github_output.read_text()
    with patch("subprocess.check_output", return_value=SOURCE + "\n"):
        assert reconcile.reconcile(environment(), fetch=fetch_for([]))["current"]
    monkeypatch.delenv("GITHUB_OUTPUT")
    with patch.object(reconcile, "reconcile", return_value=result):
        reconcile.main()
    assert json.loads(output.read_text())["current"] is True


@pytest.mark.parametrize(
    "workflow", ["linux-cache-publish.yml", "macos-cache-publish.yml"]
)
def test_model_save_guard_accepts_only_dedicated_main_model_owners(workflow):
    env = environment() | {
        "GITHUB_JOB": "publish-macos-models",
        "GITHUB_WORKFLOW_REF": f"owner/repo/.github/workflows/{workflow}@refs/heads/main",
    }
    assert guard.current_main(env, fetch=lambda *_: {"sha": SOURCE}, head=SOURCE)
    assert not guard.current_main(env, fetch=lambda *_: {"sha": "f" * 40}, head=SOURCE)
    for key, value in (
        ("GITHUB_JOB", "macos"),
        ("GITHUB_EVENT_NAME", "pull_request"),
        ("GITHUB_EVENT_NAME", "push"),
        ("GITHUB_EVENT_NAME", "schedule"),
        ("GITHUB_REF", "refs/pull/1/merge"),
    ):
        with pytest.raises(ValueError, match="dedicated main-only"):
            guard.current_main(env | {key: value}, head=SOURCE)


def test_model_save_guard_binds_actual_checkout_and_reports_main_advancement(
    tmp_path, monkeypatch, capsys
):
    env = environment() | {"GITHUB_JOB": "publish-macos-models"}
    with pytest.raises(ValueError, match="checkout differs"):
        guard.current_main(env, head="f" * 40)
    with patch("subprocess.check_output", return_value=SOURCE + "\n") as git:
        assert guard.current_main(env, fetch=lambda *_: {"sha": SOURCE})
    assert git.call_args.kwargs["timeout"] == 30
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    with patch.object(guard, "current_main", return_value=True):
        guard.main()
    assert output.read_text() == "current=true\n"
    assert "Current reviewed main" in capsys.readouterr().out
    monkeypatch.delenv("GITHUB_OUTPUT")
    with patch.object(guard, "current_main", return_value=False):
        guard.main()
    assert "Main advanced" in capsys.readouterr().out
    assert output.read_text() == "current=true\n"


def workflow(name):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())


def test_reconciler_is_independent_read_only_and_hashes_after_checkout():
    config = workflow("linux-cache-publish.yml")
    assert "concurrency" not in config
    reconcile_job = config["jobs"]["reconcile"]
    assert "concurrency" not in reconcile_job
    assert reconcile_job["permissions"] == {"contents": "read", "actions": "read"}
    steps = reconcile_job["steps"]
    assert steps[0]["uses"].startswith("actions/checkout@")
    reader = next(step for step in steps if step.get("id") == "source")
    assert (
        "hashFiles('packages/foresight_core/pubspec.lock')"
        in reader["env"]["CORE_LOCK_HASH"]
    )
    assert (
        "hashFiles('packages/foresight_core/pubspec.lock', 'apps/desktop/pubspec.lock')"
        in reader["env"]["UI_LOCK_HASH"]
    )
    assert "ci_cache_reconcile.py" in reader["run"]
    arch = config["jobs"]["publish-arch-caches"]
    assert "needs.reconcile.outputs.arch_needed == 'true'" in arch["if"]
    assert (
        arch["strategy"]["matrix"]["stage"]
        == "${{ fromJSON(needs.reconcile.outputs.arch_stages) }}"
    )
    assert (
        "needs.reconcile.outputs.common == 'true'"
        in config["jobs"]["publish-common-caches"]["if"]
    )


def test_manual_consumer_qualification_executes_real_sdk_container_and_evidence_chain():
    job = workflow("linux-cache-publish.yml")["jobs"]["qualification-consumers"]
    assert "github.event_name == 'workflow_dispatch'" in job["if"]
    assert "inputs.qualify_consumers" in job["if"]
    assert not any(value == "write" for value in job["permissions"].values())
    steps = job["steps"]
    sdk = next(step for step in steps if step.get("id") == "sdk")
    assert "ci_linux_shadow_sdk.py" in sdk["run"] and "--fork" not in sdk["run"]
    assert any("containerd-snapshotter" in str(step) for step in steps)
    execute = next(
        step for step in steps if "Build and freshly test" in step.get("name", "")
    )
    assert (
        execute["run"]
        == "bash tools/build_linux_container.sh --output build/qualify-consumers"
    )
    record = next(
        step["run"] for step in steps if "--record-application" in step.get("run", "")
    )
    assert (
        "--kind publisher" in record
        and "--record-application build/qualify-consumers" in record
    )
    assert "--exercise-record build/qualification/publisher.json" in record
    assert "--producer-job qualification-consumers" in record
    assert any(
        step.get("with", {}).get("name") == "ci-rollout-qualification" for step in steps
    )
    publisher = workflow("linux-cache-publish.yml")["jobs"]["publish-linux-caches"]
    upload = next(
        step
        for step in publisher["steps"]
        if step.get("with", {}).get("name", "").startswith("ci-tooling-")
    )
    assert upload["with"]["overwrite"] is True


def test_macos_models_have_one_independent_guarded_writer_and_no_toolchain_warming():
    linux = workflow("linux-cache-publish.yml")["jobs"]["publish-macos-models"]
    assert linux["with"] == {"publish_toolchain": False, "publish_models": True}
    config = workflow("macos-cache-publish.yml")
    assert "concurrency" not in config
    job = config["jobs"]["publish-macos-models"]
    assert "inputs.publish_models" in job["if"]
    assert "refs/heads/main" in job["if"]
    steps = job["steps"]
    assert not any(
        "precache" in step.get("run", "") or "pub get" in step.get("run", "")
        for step in steps
    )
    saves = [
        step for step in steps if step.get("uses", "").startswith("actions/cache/save@")
    ]
    assert len(saves) == 1
    assert saves[0]["with"]["key"].startswith(
        "main-integration-models-${{ runner.os }}-"
    )
    assert "steps.model-save-current.outputs.current == 'true'" in saves[0]["if"]
    verify = next(
        index
        for index, step in enumerate(steps)
        if "--prepare-models-only" in step.get("run", "")
    )
    guard_step = next(
        index
        for index, step in enumerate(steps)
        if step.get("id") == "model-save-current"
    )
    assert verify < guard_step < steps.index(saves[0])


NOW = datetime(2026, 10, 20, 12, tzinfo=timezone.utc)


def publisher(run_id=10, *, hours=1, state="success", attempt=1):
    started = NOW - timedelta(hours=hours)
    run = {
        "id": run_id,
        "path": reconcile.WORKFLOW,
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": SOURCE,
        "repository": {"full_name": "owner/repo"},
        "head_repository": {"full_name": "owner/repo"},
        "created_at": started.isoformat(),
    }
    active = state in {"queued", "in_progress"}
    job = {
        "id": run_id * 100 + attempt,
        "run_id": run_id,
        "run_attempt": attempt,
        "name": "publish-linux-caches",
        "status": state if active else "completed",
        "conclusion": None if active else state,
        "started_at": None if state == "queued" else started.isoformat(),
        "completed_at": None
        if active
        else (started + timedelta(minutes=1)).isoformat(),
    }
    return run, job


def registry_fetch(publishers, calls=None):
    runs = {run["id"]: run for run, _ in publishers}
    jobs = {
        run_id: [job for run, job in publishers if run["id"] == run_id]
        for run_id in runs
    }

    def fetch(repository, route):
        assert repository == "owner/repo"
        if calls is not None:
            calls.append(route)
        page = int(route.rsplit("page=", 1)[-1])
        if route.startswith("actions/workflows/linux-cache-publish.yml/runs?"):
            assert "event=workflow_dispatch&branch=main&head_sha=" + SOURCE in route
            values, key = list(runs.values()), "workflow_runs"
        else:
            assert "/jobs?filter=all&" in route
            values, key = jobs[int(route.split("/")[2])], "jobs"
        return {key: values[(page - 1) * 100 : page * 100]}

    return fetch


@pytest.mark.parametrize(
    "hours,state,needed",
    [
        (1, "success", False),
        (25, "success", True),
        (1, "failure", True),
        (1, "cancelled", True),
        (0.25, "in_progress", False),
        (0.25, "queued", False),
        (0.6, "in_progress", True),
        (0.6, "queued", True),
    ],
)
def test_registry_scheduling_uses_bounded_actual_publisher_readiness(
    hours, state, needed
):
    result = reconcile.registry_schedule(
        "owner/repo",
        SOURCE,
        fetch=registry_fetch([publisher(hours=hours, state=state)]),
        now=NOW,
    )
    assert result["needed"] is needed
    assert result["reason"]


def test_latest_executed_failure_and_rerun_override_older_green_without_skipped_jobs_hiding_readiness():
    old = publisher(10, hours=3)
    failed = publisher(20, hours=2, state="failure")
    skipped = publisher(30, hours=1, state="skipped")
    assert reconcile.registry_schedule(
        "owner/repo", SOURCE, fetch=registry_fetch([old, failed, skipped]), now=NOW
    )["needed"]
    rerun = publisher(10, hours=0.5, attempt=2)
    assert not reconcile.registry_schedule(
        "owner/repo",
        SOURCE,
        fetch=registry_fetch([old, failed, skipped, rerun]),
        now=NOW,
    )["needed"]
    cancelled = publisher(40, hours=0.25, state="cancelled")
    cancelled[1]["started_at"] = None
    assert not reconcile.registry_schedule(
        "owner/repo", SOURCE, fetch=registry_fetch([old, cancelled]), now=NOW
    )["needed"]


@pytest.mark.parametrize(
    "part,key,value",
    [
        (0, "path", ".github/workflows/quality.yml"),
        (0, "event", "push"),
        (0, "event", "pull_request"),
        (0, "head_branch", "feature"),
        (0, "head_sha", "f" * 40),
        (0, "repository", {"full_name": "foreign/repo"}),
        (0, "head_repository", {"full_name": "foreign/repo"}),
        (1, "name", "qualification-consumers"),
        (1, "run_id", 99),
        (1, "run_attempt", 0),
    ],
)
def test_wrong_source_event_workflow_repository_or_job_never_suppresses_registry_work(
    part, key, value
):
    row = publisher()
    row[part][key] = value
    assert reconcile.registry_schedule(
        "owner/repo", SOURCE, fetch=registry_fetch([row]), now=NOW
    )["needed"]


def test_registry_discovery_paginates_runs_and_all_original_attempt_jobs_and_ignores_own_future_job():
    rows = [publisher(run_id, state="skipped") for run_id in range(1, 102)]
    rows.append(publisher(102))
    rows.extend(
        publisher(102, state="skipped", attempt=attempt) for attempt in range(2, 103)
    )
    calls = []
    assert not reconcile.registry_schedule(
        "owner/repo", SOURCE, fetch=registry_fetch(rows, calls), now=NOW
    )["needed"]
    assert any("/runs?" in route and route.endswith("page=2") for route in calls)
    assert any("/jobs?" in route and route.endswith("page=2") for route in calls)
    own = publisher(999, hours=0.1, state="queued")
    assert reconcile.registry_schedule(
        "owner/repo", SOURCE, fetch=registry_fetch([own]), now=NOW, current_run=999
    )["needed"]


def test_registry_errors_propagate_and_timestamps_do_not_create_false_freshness():
    def unavailable(*args):
        raise RuntimeError("Registry scheduling API unavailable")

    with pytest.raises(RuntimeError, match="API unavailable"):
        reconcile.registry_schedule("owner/repo", SOURCE, fetch=unavailable, now=NOW)
    row = publisher()
    row[1]["completed_at"] = (NOW + timedelta(hours=1)).isoformat()
    with pytest.raises(ValueError, match="inconsistent"):
        reconcile.registry_schedule(
            "owner/repo", SOURCE, fetch=registry_fetch([row]), now=NOW
        )
    for value in (None, "bad", "2026-10-20T00:00:00"):
        with pytest.raises(ValueError, match="timestamp"):
            reconcile.timestamp(value)


@pytest.mark.parametrize(
    "inherited_ref", ["refs/pull/999/merge", "refs/heads/main", None]
)
def test_explicit_reconciliation_metadata_ignores_inherited_ci_ref_and_qualification_forces_real_registry_work(
    monkeypatch, inherited_ref
):
    if inherited_ref is None:
        monkeypatch.delenv("GITHUB_REF", raising=False)
    else:
        monkeypatch.setenv("GITHUB_REF", inherited_ref)
    metadata = environment() | {"QUALIFY_CONSUMERS": "true", "GITHUB_RUN_ID": "300"}
    assert reconcile.reconcile(
        metadata,
        fetch=fetch_for([cache(key) for key in all_keys()]),
        head=SOURCE,
        now=NOW,
    )["registry_needed"]
    for key, value in (("QUALIFY_CONSUMERS", "1"), ("GITHUB_RUN_ID", "0")):
        with pytest.raises(ValueError):
            reconcile.reconcile(
                metadata | {key: value}, fetch=fetch_for([]), head=SOURCE, now=NOW
            )
