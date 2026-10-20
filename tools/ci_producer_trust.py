"""Consumer-scoped producer identities; byte and source proofs stay with consumers.

This table describes today's producers only. A missing receipt tier means the
legacy receipt has no tier field, not permission to accept future producer names.
Changing a workflow's jobs requires updating the relevant consumer row explicitly.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Producer:
    workflows: tuple[str, ...]
    events: tuple[str, ...]
    jobs: dict[str, tuple[str, ...]]
    receipt_tier: str | None = None

    def matches_run(self, run):
        return run.get("path") in self.workflows and run.get("event") in self.events

    def matches_job(self, job, component=""):
        return job.get("name") in self.jobs.get(component, ())

    def matches_receipt(self, receipt):
        return self.receipt_tier is None or (
            isinstance(receipt, dict) and receipt.get("tier") == self.receipt_tier
        )


# Repository, reviewed-source/own-PR policy, original successful attempt, upload
# window and checksums are separate mandatory proofs in each consumer. In
# particular, a release-candidate row never authorizes a PR or preview handoff.
PRODUCERS = {
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
    "pr-application": Producer(
        (".github/workflows/integration-acceptance.yml",),
        ("pull_request",),
        {"": ("ubuntu-application",)},
    ),
    "fork-sdk": Producer(
        (".github/workflows/integration-acceptance.yml",),
        ("pull_request",),
        {"": ("ubuntu-application",)},
    ),
    "artifact-pull": Producer(
        (".github/workflows/macos.yml",),
        ("push", "workflow_dispatch"),
        {"linux-app": ("linux-bundle",), "macos-app": ("macos",)},
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

# Separate consumer rows permit release-only tier tightening without changing
# the legacy fixtures used by PR packages or generic artifact restoration.
PRODUCERS["release-preparation"] = Producer(
    PRODUCERS["artifact-pull"].workflows,
    PRODUCERS["artifact-pull"].events,
    dict(PRODUCERS["artifact-pull"].jobs),
)
PRODUCERS["pr-package-contract"] = Producer(
    PRODUCERS["artifact-pull"].workflows,
    PRODUCERS["artifact-pull"].events,
    {"linux-app": PRODUCERS["artifact-pull"].jobs["linux-app"]},
)
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
