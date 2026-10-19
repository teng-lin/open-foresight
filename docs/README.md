# Documentation

Start with the [project README](../README.md) for installation and usage.
Release history is in the [changelog](../CHANGELOG.md).
Historical reverse-engineering notes, CI measurements, and branch audit notes
are in git history. They are not part of the current documentation.

## Architecture and platforms

- [Schema migrations](architecture/schema-migrations.md)
- [Credentials at rest](architecture/credentials-at-rest.md)
- [Application service and MCP](architecture/application-service.md)
- [Linux packaging and CI](platforms/linux-packaging.md)
- [CI dependencies, release promotion, and preview installers](platforms/ci-performance.md)
- [macOS build, bundle, and release gates](platforms/macos-support.md)

## Models and inference

- [Speech models](models/speech-models.md)
- [LiteRT patches, GPU dependencies, and stop tokens](../third_party/litert_lm/README.md)
- [Native inference worker](../services/inference/README.md)

## Validation and release

- [Explicit integration gates](validation/integration-gates.md)
- [Published installer acceptance](validation/release-acceptance.md)
