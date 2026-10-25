"""Fallback polls stay bounded and offset; event-driven paths stay immediate.

These contracts read only trigger metadata and drive the real freshness tools.
They do not mirror job bodies, permissions or artifact trust selectors.
"""

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path

import pytest
import yaml

from tools import ci_cache_reconcile as reconcile
from tools import ci_main_evidence as evidence
from tools import ci_qualification_index as index

ROOT = Path(__file__).resolve().parents[1]
MAIN_EVIDENCE = ".github/workflows/main-evidence.yml"
CACHE_PUBLISH = ".github/workflows/linux-cache-publish.yml"
QUALIFICATION_INDEX = ".github/workflows/ci-qualification-index.yml"
POLLED = (MAIN_EVIDENCE, CACHE_PUBLISH, QUALIFICATION_INDEX)
# Longest accepted interval between fallback polls of one duty. Every
# event-driven path is immediate; this bounds only lost-event/stale recovery.
FALLBACK = timedelta(minutes=60)
# Minimum spacing between different duties' polls, so maintenance never bursts.
OFFSET = 5
REPOSITORY = "example/reviewed"
SOURCE = "a" * 40
DAY = 24 * 60


def workflow(path):
    return yaml.safe_load((ROOT / path).read_text())


def triggers(path):
    config = workflow(path)
    return config.get("on", config.get(True))


def cron_field(text, low, high):
    values = set()
    for part in text.split(","):
        body, _, step = part.partition("/")
        step = int(step) if step else 1
        if body == "*":
            start, stop = low, high
        elif "-" in body:
            start, stop = (int(value) for value in body.split("-"))
        else:
            start = int(body)
            stop = high if part != body else start
        if step < 1 or not low <= start <= stop <= high:
            raise ValueError(f"Unsupported cron field: {text}")
        values.update(range(start, stop + 1, step))
    return values


def fire_minutes(path):
    """Minute-of-day UTC for every scheduled fire; day fields must be daily."""
    result = set()
    for row in triggers(path)["schedule"]:
        minute, hour, *days = row["cron"].split()
        assert days == ["*", "*", "*"], f"{path} fallback must poll every day"
        for h in cron_field(hour, 0, 23):
            result.update(h * 60 + m for m in cron_field(minute, 0, 59))
    return sorted(result)


def max_gap(minutes):
    return max(
        (later - earlier) % DAY or DAY
        for earlier, later in zip(minutes, minutes[1:] + minutes[:1], strict=True)
    )


def distance(first, second):
    gap = abs(first - second) % DAY
    return min(gap, DAY - gap)


def fires_after(path, moment):
    day = moment.replace(hour=0, minute=0, second=0, microsecond=0)
    for offset in range(3):
        for minute in fire_minutes(path):
            fire = day + timedelta(days=offset, minutes=minute)
            if fire > moment:
                yield fire


def test_cron_reader_rejects_unsupported_fields():
    assert cron_field("*/20", 0, 59) == {0, 20, 40}
    assert cron_field("5/30", 0, 59) == {5, 35}
    assert cron_field("1-3,9", 0, 23) == {1, 2, 3, 9}
    with pytest.raises(ValueError):
        cron_field("60", 0, 59)
    assert max_gap([17]) == DAY and max_gap([0, 30]) == DAY - 30
    assert max_gap(list(range(17, DAY, 60))) == 60


def test_every_duty_keeps_its_immediate_event_driven_triggers():
    observer = triggers(MAIN_EVIDENCE)
    assert observer["push"] == {"branches": ["main"]}
    assert observer["workflow_run"] == {
        "workflows": ["Platform candidates and checks"],
        "types": ["completed"],
        "branches": ["main"],
    }
    assert "exercise_sweep" in observer["workflow_dispatch"]["inputs"]
    cache = triggers(CACHE_PUBLISH)
    assert cache["push"] == {"branches": ["main"]}
    assert "qualify_consumers" in cache["workflow_dispatch"]["inputs"]
    proofs = triggers(QUALIFICATION_INDEX)
    assert "workflow_dispatch" in proofs
    assert proofs["workflow_run"]["types"] == ["completed"]
    assert {
        "CI candidate qualification",
        "Preview packages",
        "Arch rolling toolchain drift",
        workflow(CACHE_PUBLISH)["name"],
    } <= set(proofs["workflow_run"]["workflows"])


@pytest.mark.parametrize("path", POLLED)
def test_fallback_poll_is_retained_bounded_and_no_longer_half_hourly(path):
    minutes = fire_minutes(path)
    assert minutes, f"{path} must keep a stale-recovery fallback"
    assert timedelta(minutes=max_gap(minutes)) <= FALLBACK
    # The previous half-hour polling (48/day) was redundant with the events
    # above; raising it again needs a new freshness requirement in the docs.
    assert len(minutes) <= 24


def test_maintenance_offsets_avoid_bursts_and_index_wakeups():
    fires = {path: fire_minutes(path) for path in POLLED}
    for path, minutes in fires.items():
        assert all(minute % 60 for minute in minutes), f"{path} polls at :00"
    for path in POLLED:
        for other in POLLED:
            if path < other:
                assert min(
                    distance(first, second)
                    for first in fires[path]
                    for second in fires[other]
                ) >= OFFSET, (path, other)
    # Every completed cache-publish run wakes the index through workflow_run.
    # Keep the index's own poll clear of that wakeup window.
    jobs = workflow(CACHE_PUBLISH)["jobs"]
    window = sum(jobs[name]["timeout-minutes"] for name in ("reconcile", "dispatch-refresh"))
    for wake in fires[CACHE_PUBLISH]:
        for poll in fires[QUALIFICATION_INDEX]:
            assert not 0 <= (poll - wake) % DAY <= window


def publisher_fetch(job, *, present=(), main=SOURCE):
    run = {
        "id": 7,
        "path": reconcile.WORKFLOW,
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": SOURCE,
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
        "created_at": job.get("started_at"),
    }

    def fetch(repository, route):
        assert repository == REPOSITORY
        if route == "commits/main":
            return {"sha": main}
        if route.startswith("actions/workflows/linux-cache-publish.yml/runs?"):
            return {"workflow_runs": [run] if job else []}
        if route.startswith("actions/runs/7/jobs?"):
            return {"jobs": [job]}
        if route.startswith("actions/caches?"):
            return {
                "actions_caches": [
                    {"ref": "refs/heads/main", "size_in_bytes": 1, "key": key}
                    for key in present
                ]
            }
        raise AssertionError("Unexpected API route: " + route)

    return fetch


def publisher_job(state, moment):
    stamp = moment.isoformat().replace("+00:00", "Z")
    job = {
        "name": "publish-linux-caches",
        "run_id": 7,
        "run_attempt": 1,
        "id": 70,
        "started_at": stamp,
        "steps": [],
    }
    if state == "active":
        return dict(job, status="in_progress", conclusion=None)
    step = {"name": reconcile.PUBLISH_STEP, "status": "completed", "conclusion": state}
    return dict(job, status="completed", conclusion=state, completed_at=stamp, steps=[step])


@pytest.mark.parametrize(
    "state,threshold",
    [
        ("success", timedelta(hours=24)),
        ("active", timedelta(minutes=30)),
        ("failure", timedelta(0)),
    ],
)
def test_registry_staleness_is_recovered_within_one_bounded_fallback(state, threshold):
    """Drive the real scheduler for every minute-of-day event phase."""
    gap = timedelta(minutes=max_gap(fire_minutes(CACHE_PUBLISH)))
    base = datetime(2026, 10, 20, tzinfo=timezone.utc)
    for phase in range(DAY):
        event = base + timedelta(minutes=phase, seconds=13)
        fetch = publisher_fetch(publisher_job(state, event))
        recovered = next(
            fire
            for fire in fires_after(CACHE_PUBLISH, event)
            if reconcile.registry_schedule(REPOSITORY, SOURCE, fetch=fetch, now=fire)["needed"]
        )
        assert recovered - event <= threshold + gap <= threshold + FALLBACK, (state, event)
        assert recovered - event >= threshold, (state, event)
    # A source with no executed publisher (the push path) needs no poll at all.
    assert reconcile.registry_schedule(
        REPOSITORY, SOURCE, fetch=publisher_fetch({}), now=base
    )["needed"] is True


def schedule_environment():
    return {
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_SHA": SOURCE,
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_EVENT_NAME": "schedule",
        "GITHUB_JOB": "reconcile",
        "GITHUB_WORKFLOW_REF": f"{REPOSITORY}/{CACHE_PUBLISH}@refs/heads/main",
        "GITHUB_RUN_ID": "9",
        "CORE_LOCK_HASH": "1" * 64,
        "UI_LOCK_HASH": "2" * 64,
        "MODEL_INPUT_HASH": "3" * 64,
    }


def test_scheduled_poll_recovers_evicted_cache_keys_and_is_otherwise_a_noop():
    env = schedule_environment()
    keys = reconcile.cache_keys(env["CORE_LOCK_HASH"], env["UI_LOCK_HASH"], env["MODEL_INPUT_HASH"])
    every = [key for values in keys.values() for key in values]
    now = datetime(2026, 10, 20, 12, tzinfo=timezone.utc)
    fresh = publisher_job("success", now - timedelta(hours=1))
    evicted = [key for key in every if key not in keys["models_linux"]]
    result = reconcile.reconcile(env, fetch=publisher_fetch(fresh, present=evicted), head=SOURCE, now=now)
    assert result["current"] and result["models_linux"] and result["common"]
    assert result["registry_needed"] is False
    idle = reconcile.reconcile(env, fetch=publisher_fetch(fresh, present=every), head=SOURCE, now=now)
    assert idle["registry_needed"] is False and idle["common"] is False
    assert idle["arch_stages"] == [] and idle["models_macos"] is False
    advanced = reconcile.reconcile(
        env, fetch=publisher_fetch(fresh, present=evicted, main="b" * 40), head=SOURCE, now=now
    )
    assert advanced["current"] is False and advanced["common"] is False


def test_scheduled_cache_poll_only_dispatches_and_publishers_stay_dispatch_only():
    jobs = workflow(CACHE_PUBLISH)["jobs"]
    assert '"schedule"' in jobs["reconcile"]["if"]
    refresh = jobs["dispatch-refresh"]
    assert '"push","schedule"' in refresh["if"]
    for output in ("registry_needed", "common", "arch_needed", "models_macos"):
        assert f"needs.reconcile.outputs.{output} == 'true'" in refresh["if"]
    assert "push|schedule" in refresh["steps"][0]["run"]
    for name, job in jobs.items():
        if name not in ("reconcile", "dispatch-refresh"):
            assert "github.event_name == 'workflow_dispatch'" in job["if"], name


def test_scheduled_observer_and_coordinator_reconcile_current_main(tmp_path, monkeypatch):
    jobs = workflow(MAIN_EVIDENCE)["jobs"]
    # Non-workflow_run events (push, dispatch, schedule) bypass the PR filter.
    assert "github.event_name != 'workflow_run' ||" in jobs["observe"]["if"]
    assert "schedule" not in jobs["coordinate"]["if"]
    observe = next(step for step in jobs["observe"]["steps"] if step.get("id") == "observation")
    assert observe["env"]["SOURCE"].endswith("|| github.sha }}")
    from tests.test_ci_main_evidence import FixtureReader, SOURCE as OBSERVED

    output = tmp_path / "receipt.json"
    for name in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "GITHUB_SHA"):
        monkeypatch.delenv(name, raising=False)
    for name, value in {
        "GITHUB_REPOSITORY": "example/reviewed",
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_EVENT_NAME": "schedule",
    }.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr("sys.argv", ["evidence", "--source", OBSERVED, "--output", str(output)])
    monkeypatch.setattr(evidence, "Reader", lambda repository: FixtureReader())
    monkeypatch.setattr(evidence, "selected_on_push", lambda *args: dict.fromkeys(evidence.APPLICATION, True))
    evidence.main()
    assert json.loads(output.read_text())["source"] == OBSERVED


@pytest.mark.parametrize("event", ["schedule", "workflow_run", "workflow_dispatch", "push"])
def test_index_publishes_from_fallback_and_wakeups_only(event, tmp_path, monkeypatch):
    output = tmp_path / "index.json"
    monkeypatch.setattr("sys.argv", ["ci-index", "--output", str(output)])
    for name, value in {
        "GITHUB_SHA": SOURCE,
        "GITHUB_REPOSITORY": REPOSITORY,
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_EVENT_NAME": event,
        "GITHUB_WORKFLOW_REF": f"{REPOSITORY}/{index.WORKFLOW}@refs/heads/main",
        "GITHUB_RUN_ID": "999",
        "GITHUB_RUN_ATTEMPT": "1",
    }.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(index.artifacts, "api", lambda *args: {"sha": SOURCE})
    monkeypatch.setattr(index, "collect", lambda *args: {"capabilities": []})
    if event == "push":
        with pytest.raises(ValueError, match="dedicated"):
            index.main()
        return
    index.main()
    assert json.loads(output.read_text())["producer"]["run_id"] == 999
