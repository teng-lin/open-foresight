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
- [Credentials at rest](architecture/credentials-at-rest.md)
- [Application service and MCP](architecture/application-service.md)
- [Linux packaging and CI](platforms/linux-packaging.md)
- [CI dependencies, release promotion, and preview installers](platforms/ci-performance.md)
- [CI integrity rules](platforms/ci-integrity.md)
- [macOS build, bundle, and release gates](platforms/macos-support.md)

## Models and inference

- [Speech models](models/speech-models.md)
- [LiteRT patches, GPU dependencies, and stop tokens](../third_party/litert_lm/README.md)
- [Native inference worker](../services/inference/README.md)

## Validation and release

- [Application storage retention and recovery](validation/storage-recovery.md)
- [Explicit integration gates](validation/integration-gates.md)
- [Published installer acceptance](validation/release-acceptance.md)
