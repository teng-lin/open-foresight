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
        return job.get("name") in self.jobs[component]


# Repository, reviewed-source/own-PR policy, original successful attempt, upload
# window and checksums are separate mandatory proofs in each consumer. In
# particular, a release-candidate row never authorizes a PR or preview handoff.
PRODUCERS = {
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
    "release-candidate": Producer(
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
