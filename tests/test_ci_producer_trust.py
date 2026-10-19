"""Producer identities are consumer-scoped before any workflow renaming."""

import itertools

import pytest

from tools import ci_artifacts
from tools import sdk_producer_trust
from tools.ci_producer_trust import PRODUCERS


# Freeze the migration boundary: future jobs/tiers must be enabled deliberately
# with their new source and receipt proof, rather than by a broad name allowlist.
EXPECTED = {
    "pr-application": (
        ("integration-acceptance.yml",),
        ("pull_request",),
        {"": ("ubuntu-application",)},
    ),
    "fork-sdk": (
        ("integration-acceptance.yml",),
        ("pull_request",),
        {"": ("ubuntu-application",)},
    ),
    "release-candidate": (
        ("macos.yml",),
        ("push", "workflow_dispatch"),
        {"linux-app": ("linux-bundle",), "macos-app": ("macos",)},
    ),
    "dependency-sdk": (
        ("ci-dependencies.yml",),
        ("push", "workflow_dispatch", "schedule", "pull_request"),
        {
            "macos-sdk": ("Build macOS sdk",),
            "macos-runtime": ("Build macOS runtime",),
            "macos-vendor": ("Build macOS vendor",),
            "linux-sdk": ("Assemble Linux SDK",),
            "linux-core": ("Build Linux core",),
            "linux-litert": ("Build Linux litert",),
            "linux-whisper": ("Build Linux whisper",),
        },
    ),
    "sanitizer-sdk": (
        ("native-sanitizers.yml",),
        ("push", "pull_request", "workflow_dispatch"),
        {"address": ("native-sanitizers",), "thread": ("native-thread-sanitizer",)},
    ),
    "dependency-seed": (
        ("macos.yml",),
        ("push",),
        {"": ("linux-bundle",)},
    ),
    "release-acceptance": (
        ("release.yml", "release-acceptance.yml"),
        ("workflow_dispatch",),
        {"": ("acceptance", "acceptance / acceptance")},
    ),
}


def test_exact_legacy_rows_have_no_tier_requirement_yet():
    assert set(PRODUCERS) == set(EXPECTED)
    for consumer, (paths, events, jobs) in EXPECTED.items():
        producer = PRODUCERS[consumer]
        assert producer.workflows == tuple(
            ".github/workflows/" + path for path in paths
        )
        assert producer.events == events
        assert producer.jobs == jobs
        assert producer.receipt_tier is None
        for component, names in jobs.items():
            for name in names:
                assert producer.matches_job({"name": name}, component)
            assert not producer.matches_job({"name": "linux-build"}, component)
            assert not producer.matches_job({}, component)


@pytest.mark.parametrize("consumer", EXPECTED)
def test_workflow_event_cross_product_is_scoped_to_consumer(consumer):
    paths, events, _ = EXPECTED[consumer]
    all_paths = {path for row in EXPECTED.values() for path in row[0]}
    all_paths.update(("preview-packages.yml", "unknown.yml"))
    for path, event in itertools.product(
        all_paths,
        ("push", "workflow_dispatch", "schedule", "pull_request", "workflow_run", None),
    ):
        run = {"path": ".github/workflows/" + path, "event": event}
        assert PRODUCERS[consumer].matches_run(run) == (
            path in paths and event in events
        )
    assert not PRODUCERS[consumer].matches_run({})


@pytest.mark.parametrize("component", ["linux-app", "macos-app"])
def test_release_candidates_reject_pr_fork_preview_and_unreviewed_branch(component):
    run = {
        "path": ".github/workflows/macos.yml",
        "event": "push",
        "head_branch": "main",
        "head_repository": {"full_name": "owner/repo"},
    }
    assert ci_artifacts.trusted_run(run, component, repository="owner/repo")
    for change in (
        {"event": "pull_request"},
        {"event": "schedule"},
        {"path": ".github/workflows/preview-packages.yml"},
        {"path": ".github/workflows/integration-acceptance.yml"},
        {"head_branch": "feature"},
        {"head_repository": {"full_name": "fork/repo"}},
    ):
        assert not ci_artifacts.trusted_run(
            run | change,
            component,
            own_head="a" * 40,
            own_pr=123,
            repository="owner/repo",
        )


def test_sdk_job_names_share_the_single_table_without_changing_recipe_inputs():
    assert sdk_producer_trust.JOBS == ci_artifacts.JOBS
    assert "tools/ci_producer_trust.py" in sdk_producer_trust.PRODUCER_CONTROLS
    assert all(
        "tools/ci_producer_trust.py" not in inputs
        for inputs in ci_artifacts.FILES.values()
    )
