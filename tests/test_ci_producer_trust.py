"""Producer identities are consumer-scoped before any workflow renaming."""

import itertools
import ast
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import zipfile

import pytest

from tools import ci_artifacts
from tools import sdk_producer_trust
from tools.ci_producer_trust import PRODUCERS
from test_ci_promotion import candidate, SOURCE, REPO


# Freeze the migration boundary: future jobs/tiers must be enabled deliberately
# with their new source and receipt proof, rather than by a broad name allowlist.
EXPECTED = {
    "weekly-audit-completion": (
        ("preview-packages.yml",),
        ("schedule", "workflow_dispatch"),
        {"": ("weekly-external-audit",)},
    ),
    "inrun-application": (
        ("macos.yml", "preview-packages.yml"),
        ("pull_request", "push", "workflow_dispatch", "schedule"),
        {"": ("linux-build", "build / linux-build")},
    ),
    "inrun-package-contract": (
        ("macos.yml", "preview-packages.yml"),
        ("pull_request", "push", "workflow_dispatch", "schedule"),
        {"": ("linux-build", "build / linux-build")},
    ),
    "main-acceptance": (
        ("macos.yml",),
        ("push", "workflow_dispatch"),
        {"": ("linux-bundle",)},
    ),
    "dependency-seed-current": (
        ("macos.yml", "preview-packages.yml"),
        ("push", "workflow_dispatch", "schedule"),
        {"": ("publish-caches", "build / publish-caches")},
    ),
    "artifact-pull": (
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

EXPECTED["release-preparation"] = EXPECTED["artifact-pull"]
EXPECTED["package-alias"] = (
    EXPECTED["dependency-sdk"][0],
    EXPECTED["dependency-sdk"][1],
    {
        name: jobs
        for name, jobs in EXPECTED["dependency-sdk"][2].items()
        if name.startswith("linux-")
    },
)
EXPECTED["sdk-promoted-source"] = (
    EXPECTED["dependency-sdk"][0],
    ("pull_request", "workflow_dispatch"),
    EXPECTED["dependency-sdk"][2],
)

EXPECTED["release-candidate"] = (
    ("release.yml",),
    ("workflow_dispatch",),
    {"linux-app": ("candidates / linux-build",), "macos-app": ("candidates / macos",)},
)
EXPECTED["release-candidate-receipt"] = (
    ("release.yml",),
    ("workflow_dispatch",),
    {"": ("candidate-receipt",)},
)
EXPECTED["release-preparation"] = EXPECTED["release-candidate"]
EXPECTED["legacy-release-candidate"] = (
    ("macos.yml",),
    ("push",),
    EXPECTED["artifact-pull"][2],
)

EXPECTED["release-inrun-application"] = (
    ("release.yml",),
    ("workflow_dispatch",),
    {"": ("candidates / linux-build",)},
)
EXPECTED["release-handoff"] = EXPECTED["release-inrun-application"]


def test_exact_legacy_rows_have_no_tier_requirement_yet():
    assert set(PRODUCERS) == set(EXPECTED) | {
        "shadow-fork-sdk",
        "shadow-handoff",
        "weekly-preview-audit",
    }
    for consumer, (paths, events, jobs) in EXPECTED.items():
        producer = PRODUCERS[consumer]
        assert producer.workflows == tuple(
            ".github/workflows/" + path for path in paths
        )
        assert producer.events == events
        assert producer.jobs == jobs
        assert producer.receipt_tier == (
            "release"
            if consumer
            in (
                "release-preparation",
                "release-candidate",
                "release-candidate-receipt",
                "release-inrun-application",
                "release-handoff",
            )
            else None
        )
        for component, names in jobs.items():
            for name in names:
                assert producer.matches_job({"name": name}, component)
            assert not producer.matches_job({"name": "unrelated-job"}, component)
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


def test_receipt_tier_is_optional_but_enforced_when_a_consumer_specifies_it():
    legacy = PRODUCERS["artifact-pull"]
    assert legacy.matches_receipt({})
    strict = replace(legacy, receipt_tier="release")
    assert strict.matches_receipt({"tier": "release"})
    for receipt in (None, {}, {"tier": "pr"}, {"tier": "preview"}):
        assert not strict.matches_receipt(receipt)
    assert "pr-package-contract" not in PRODUCERS
    assert not PRODUCERS["inrun-package-contract"].matches_job(
        {"name": "macos"}, "macos-app"
    )
    assert not PRODUCERS["package-alias"].matches_job(
        {"name": "Build macOS sdk"}, "macos-sdk"
    )


@pytest.mark.parametrize("tier", [None, "preview", "release"])
def test_release_tier_restriction_does_not_change_other_consumers(
    tmp_path, monkeypatch, tier
):
    artifact, _, _ = candidate(tmp_path, monkeypatch)
    monkeypatch.setitem(
        PRODUCERS,
        "tier-fixture",
        replace(PRODUCERS["artifact-pull"], receipt_tier="release"),
    )
    from tools import ci_release_candidates

    authorizations = []

    def authorize(repository, source, run_id, component):
        assert (repository, source, run_id, component) == (
            REPO,
            SOURCE,
            42,
            "linux-app",
        )
        authorizations.append(component)
        return "tier-fixture"

    monkeypatch.setattr(ci_release_candidates, "authorize", authorize)
    # Real ZIP/receipt/payload hashes remain authoritative when adding a tier.
    archive = tmp_path / "artifact.zip"
    with zipfile.ZipFile(archive) as stream:
        files = {name: stream.read(name) for name in stream.namelist()}
    receipt = json.loads(files["identity.json"])
    if tier is not None:
        receipt["tier"] = tier
    files["identity.json"] = json.dumps(receipt).encode()
    with zipfile.ZipFile(archive, "w") as stream:
        for name, data in files.items():
            stream.writestr(name, data)
    artifact["digest"] = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
    assert ci_artifacts.pull(
        REPO, "linux-app", SOURCE, tmp_path / "artifact-pull", consumer="artifact-pull"
    )
    if tier == "release":
        assert ci_artifacts.application_descriptor(
            REPO, "linux-app", SOURCE, 42, consumer="release-preparation"
        ) == {"version": "0.1.2", "build_number": 10}
    else:
        with pytest.raises(ValueError, match="receipt differs"):
            ci_artifacts.application_descriptor(
                REPO, "linux-app", SOURCE, 42, consumer="release-preparation"
            )

    assert authorizations


def test_producer_workflow_allowlists_are_only_declared_in_the_table():
    root = Path(__file__).resolve().parents[1]
    for name in (
        "ci_artifacts.py",
        "sdk_producer_trust.py",
        "sdk_approval_bridge.py",
        "sdk_final_approval.py",
        "create_sdk_approval.py",
        "prepare_release.py",
        "publish_linux_package_aliases.py",
    ):
        tree = ast.parse((root / "tools" / name).read_text())
        assert not any(
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and node.value.startswith(".github/workflows/")
            for node in ast.walk(tree)
        ), name


def test_weekly_audit_is_preview_only_and_does_not_authorize_release_lookup():
    row = PRODUCERS["weekly-preview-audit"]
    assert row.workflows == (".github/workflows/preview-packages.yml",)
    assert row.events == ("schedule", "workflow_dispatch")
    assert row.jobs == {"": ("build / linux-build",)}
    assert row.receipt_tier == "preview"
    assert row.matches_receipt({"tier": "preview"})
    assert not row.matches_receipt({"tier": "release"})
