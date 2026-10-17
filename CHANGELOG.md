# Changelog

Notable changes to Open Foresight are recorded here. Versions follow
[Semantic Versioning](https://semver.org). The release version is
`apps/desktop/pubspec.yaml`.

## [Unreleased]

### Added

- Published installer acceptance tests the packages downloaded from a GitHub release. Installer provenance must match the release tag; explicit recovery audits remain available for historical assets.
- Model and virtual-audio checks run as explicit integration gates. A skipped test in the regular suite is not treated as acceptance.

### Changed

- Ask has one web-search control.
- Meeting text uses shared roles, and meeting panels fit a narrow window.
- Each chat conversation keeps its own draft, streaming text, and answer cancellation.
- Release preparation promotes tested candidates for one commit into a draft, then publishes only after installed-package acceptance succeeds. Public release assets are immutable.
- The documentation tree keeps the current build, release, and architecture guides.

### Fixed

- Release builds check out their tag, reject mismatched source revisions, and assign increasing Linux package releases on draft rebuilds.

- Drive and Calendar sign-in uses the Google application registration bundled in a release build. Sign-in can be cancelled from the import flows.
- Linux CPU generation keeps modality executors on CPU.
- Linux packages retain the SDK libraries those binaries need at load time.
- A native worker's exit status is preserved when the host reaps the child on Linux. Supervised worker results are reported on macOS as well.
- Installed-release acceptance runs generation on CPU and fails when the probe exits without a result.

### Security

- Private temporary directories are created atomically with `mkdtemp` and mode 0700.

## [0.1.0] - 2026-10-17

First experimental release.

### Added

- Local transcription, meeting notes, note enhancement, and grounded answers.
- Dedicated proactive-question detection and integrated model setup.
- Optional search and website summaries, using distribution configuration bundled with the package.
- Source organization, graph navigation, labels, and Markdown meeting export.
- Linux x86-64 `.deb`, `.rpm`, Arch `.pkg.tar.zst`, and portable archive packages, and an Apple Silicon `.dmg`, each with checksums and build reports.

### Fixed

- Recording recovery, and transcript and chat lifecycle cases found before this release.

The macOS disk image in this release is ad-hoc signed and is not notarized.
Physical-device recovery and echo-cancellation quality were not validated across
hardware. Model weights are downloaded after install and are not inside the packages.

[Unreleased]: https://github.com/teng-lin/open-foresight/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/teng-lin/open-foresight/releases/tag/v0.1.0
