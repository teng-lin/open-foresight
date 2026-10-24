# Documentation

Start with the [project README](../README.md) for installation and usage.
Release history is in the [changelog](../CHANGELOG.md).
Earlier reverse-engineering notes, CI measurements, and branch audit notes
remain in git history. Current AI workflow research is linked below.

## AI workflow research and implementation

- [Foresight AI workflows and recovered prompts](research/foresight-ai-workflows.md)
- [AI workflow implementation plan](plans/2026-10-20-foresight-ai-parity-plan.md)

## Architecture and platforms

- [Repository remediation and unified logging implementation plan](plans/2026-10-24-repository-remediation-plan.md)
- [Combined remediation execution](plans/2026-10-24-repository-remediation-execution.md)

- [Schema migrations](architecture/schema-migrations.md)
- [Meeting Summary](architecture/meeting-summary.md)
- [Meeting AI workflows](architecture/meeting-ai-workflows.md)
- [Credentials at rest](architecture/credentials-at-rest.md)
- [Application service and MCP](architecture/application-service.md)
- [Linux packaging and CI](platforms/linux-packaging.md)
- [CI dependencies, release promotion, and preview installers](platforms/ci-performance.md)
- [CI integrity rules](platforms/ci-integrity.md)
- [macOS build, bundle, and release gates](platforms/macos-support.md)
- [Architecture decision records](adr/README.md)
- [Main validation evidence](platforms/ci-main-evidence.md)
- [CI qualification and activation](platforms/ci-rollout-qualification.md)

## Models and inference

- [Speech models](models/speech-models.md)
- [LiteRT patches, GPU dependencies, and stop tokens](../third_party/litert_lm/README.md)
- [Native inference worker](../services/inference/README.md)

## Validation and release

- [Explicit integration gates](validation/integration-gates.md)
- [Published installer acceptance](validation/release-acceptance.md)
- [Release preparation and recovery](../RELEASING.md)
- [Installed GUI approval acceptance](validation/installed-gui-approval.md)
- [Issue 142 functional follow-ups and remaining acceptance](validation/issue-142-functional-followups.md)
- [Test coverage gaps and integration priorities](validation/test-coverage-gaps.md)

## Historical reviews and execution records

These records retain their original source identities and acceptance limits.
Current remediation progress belongs in the combined execution record above.

- [Individual repository review](audit/2026-10-24-repository-review.md)
- [Agent-team repository review](audit/2026-10-24-repository-review-team.md)
- [CI restructuring execution](plans/2026-10-19-ci-restructure-progress.md)
- [CI improvements execution](plans/2026-10-20-ci-improvements-execution.md)
- [Desktop feature implementation reviews](plans/2026-10-22-desktop-feature-reviews.md)
