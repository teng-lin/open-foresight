"""Consumer-scoped producer identities; byte and source proofs stay with consumers.

This table describes today's producers only. A missing receipt tier means the
legacy receipt has no tier field, not permission to accept future producer names.
Changing a workflow's jobs requires updating the relevant consumer row explicitly.
"""

from dataclasses import dataclass


# Display labels are not artifact identities. This closed table covers only
# reviewed platform jobs and the two existing reusable-workflow callers. Raw
# API rows, original job IDs/attempts/windows and receipts remain unchanged.
_DISPLAY_JOBS = {
    "macOS bundle / build and smoke": "macos",
    "Linux bundle / build": "linux-build",
    "Linux bundle / integration": "linux-test",
    "Linux checks / document imports": "linux-document-imports",
    "Linux acceptance / CPU models": "acceptance-cpu",
    "Linux acceptance / virtual audio": "acceptance-audio",
    "Linux acceptance / deb installer": "acceptance-deb",
    "macOS packaging / dmg contracts": "dmg / dmg",
    "Arch Linux checks / full build and tests": "arch",
    "address and undefined behavior": "native-sanitizers",
    "thread policy": "thread-policy",
    "thread": "native-thread-sanitizer",
}
for _stage in ("native", "core", "desktop", "service"):
    _DISPLAY_JOBS["Linux checks / " + _stage] = "linux-native / " + _stage + "-linux"
for _stage in ("contracts", "native", "core", "desktop", "service"):
    _DISPLAY_JOBS["macOS checks / " + _stage] = "macos-checks (" + _stage + ")"
for _format in ("deb", "rpm", "arch"):
    _DISPLAY_JOBS["Linux packaging / " + _format + " contracts"] = "packaging / linux-" + _format
for _label, _job in (
    ("address and undefined behavior", "native-sanitizers"),
    ("thread policy", "thread-policy"),
    ("thread", "native-thread-sanitizer"),
):
    _DISPLAY_JOBS["Linux sanitizer checks / " + _label] = "sanitizers / " + _job
_JOB_ALIASES = {
    prefix + display: prefix + logical
    for prefix in ("", "build / ", "candidates / ")
    for display, logical in _DISPLAY_JOBS.items()
}


def evidence_job_name(job):
    """Exact current label or unchanged historical name; never fuzzy matching.

    Every caller must still enforce its workflow/repository/source/attempt and
    artifact rules. This function grants no producer authority on its own.
    """
    name = job.get("name", "")
    return _JOB_ALIASES.get(name, name) if isinstance(name, str) else ""


@dataclass(frozen=True)
class Producer:
    workflows: tuple[str, ...]
    events: tuple[str, ...]
    jobs: dict[str, tuple[str, ...]]
    receipt_tier: str | None = None

    def matches_run(self, run):
        return run.get("path") in self.workflows and run.get("event") in self.events

    def matches_job(self, job, component=""):
        return evidence_job_name(job) in self.jobs.get(component, ())

    def matches_receipt(self, receipt):
        return self.receipt_tier is None or (
            isinstance(receipt, dict) and receipt.get("tier") == self.receipt_tier
        )


# Repository, reviewed-source/own-PR policy, original successful attempt, upload
# window and checksums are separate mandatory proofs in each consumer. In
# particular, a release-candidate row never authorizes a PR or preview handoff.
PRODUCERS = {
    "linux-ci-tooling": Producer(
        (".github/workflows/linux-cache-publish.yml",),
        ("workflow_dispatch",),
        {"": ("publish-linux-caches",)},
        receipt_tier="tooling",
    ),
    "shadow-fork-sdk": Producer(
        (".github/workflows/macos.yml",),
        ("pull_request",),
        {"": ("linux-build",)},
        receipt_tier="pr",
    ),
    "shadow-handoff": Producer(
        (".github/workflows/macos.yml", ".github/workflows/preview-packages.yml"),
        ("pull_request", "push", "workflow_dispatch", "schedule"),
        {"": ("linux-build", "build / linux-build")},
    ),
    "weekly-audit-completion": Producer(
        (".github/workflows/preview-packages.yml",),
        ("schedule", "workflow_dispatch"),
        {"": ("weekly-external-audit",)},
    ),
    "weekly-preview-audit": Producer(
        (".github/workflows/preview-packages.yml",),
        ("schedule", "workflow_dispatch"),
        {"": ("build / linux-build",)},
        receipt_tier="preview",
    ),
    "inrun-application": Producer(
        (".github/workflows/macos.yml", ".github/workflows/preview-packages.yml"),
        ("pull_request", "push", "workflow_dispatch", "schedule"),
        {"": ("linux-build", "build / linux-build")},
    ),
    "inrun-package-contract": Producer(
        (".github/workflows/macos.yml", ".github/workflows/preview-packages.yml"),
        ("pull_request", "push", "workflow_dispatch", "schedule"),
        {"": ("linux-build", "build / linux-build")},
    ),
    "dependency-sdk": Producer(
        (".github/workflows/ci-dependencies.yml",),
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
    "sanitizer-sdk": Producer(
        (".github/workflows/native-sanitizers.yml",),
        ("push", "pull_request", "workflow_dispatch"),
        {
            "address": ("native-sanitizers",),
            "thread": ("native-thread-sanitizer",),
        },
    ),
    "dependency-seed": Producer(
        (".github/workflows/macos.yml",),
        ("push",),
        {"": ("linux-bundle",)},
    ),
    "release-acceptance": Producer(
        (
            ".github/workflows/release.yml",
            ".github/workflows/release-acceptance.yml",
        ),
        ("workflow_dispatch",),
        {"": ("acceptance", "acceptance / acceptance")},
    ),
}

# Dependency aliases and SDK promotion retain their own producer contracts.
# Application lookup is release-tier only; in-run PR/preview checks stay separate.
PRODUCERS["package-alias"] = Producer(
    PRODUCERS["dependency-sdk"].workflows,
    PRODUCERS["dependency-sdk"].events,
    {
        name: jobs
        for name, jobs in PRODUCERS["dependency-sdk"].jobs.items()
        if name.startswith("linux-")
    },
)
PRODUCERS["sdk-promoted-source"] = Producer(
    PRODUCERS["dependency-sdk"].workflows,
    ("pull_request", "workflow_dispatch"),
    dict(PRODUCERS["dependency-sdk"].jobs),
)

# WS5b-1: the index verifier separately proves every required release gate.
PRODUCERS["release-candidate"] = Producer(
    (".github/workflows/release.yml",),
    ("workflow_dispatch",),
    {"linux-app": ("candidates / linux-build",), "macos-app": ("candidates / macos",)},
    receipt_tier="release",
)
PRODUCERS["release-candidate-receipt"] = Producer(
    PRODUCERS["release-candidate"].workflows,
    PRODUCERS["release-candidate"].events,
    {"": ("candidate-receipt",)},
    receipt_tier="release",
)

PRODUCERS["release-preparation"] = PRODUCERS["release-candidate"]
PRODUCERS["artifact-pull"] = PRODUCERS["release-candidate"]

# Release in-run consumers have distinct caller and job identities.
PRODUCERS["release-inrun-application"] = Producer(
    (".github/workflows/release.yml",),
    ("workflow_dispatch",),
    {"": ("candidates / linux-build",)},
    receipt_tier="release",
)
PRODUCERS["release-handoff"] = PRODUCERS["release-inrun-application"]
