# Changelog

Notable changes to Open Foresight are recorded here. Versions follow
[Semantic Versioning](https://semver.org). The release version is
`apps/desktop/pubspec.yaml`.

## [Unreleased]

### Changed

- Native and helper tests run in a separate ThreadSanitizer configuration with a real race-detection probe and retained triage evidence; the initial reporting-only probation expires after one week.

- Python tooling uses 3.13 with matching protobuf type stubs and reproducible lock recipes; current CI guidance is separated from historical measurements and shared dependency pins guard workflow literals.

- Build tooling pins the Dart protobuf compiler and Ubuntu archive snapshot; monthly snapshot changes arrive as draft review PRs. Weekly dependency and vulnerability reports keep lockfile updates visible. Every CI job has a finite timeout.

### Security

- Dependency artifact promotion binds output to the producing workflow and tools and accepts only the final reviewed PR head.

### Fixed

- macOS CI consumes the same PR source as dependency producers and builds pinned dependencies locally when no trusted artifact is available, including fork PRs.

### Changed

- Release publication preserves Latest on the highest stable version and correlates fresh candidate builds to their own dispatch. Shared DMG provenance binds preview and release installer bytes to the source revision, version and build number.
- Linux packages ship the nlohmann-json notice and complete copyright stanzas for bundled license files; unknown licenses stop packaging.
- Installer workflows publish signed build provenance and SBOM attestations. Dependency artifact downloads verify GitHub ZIP digests.
- Offline Python tests use directory discovery with an explicit inventory for build and device harnesses. Integration acceptance reports an always-running required check.

### Fixed

- Package upgrades ignore installation locks with invalid ownership, permissions or symlinks, preventing other local users from blocking updates.
- Clearing a workspace works offline, discards pending meeting drafts and retries helper deletion after reconnect. Stale speech audio is removed on startup.
- Calendar refresh preserves local edits and deletions and bounds untrusted invitation HTML parsing.
- Failed answers discard partial text and citations; cancelled note enhancements restore the previous notes.
- Background credential and recording failures no longer escape the service worker. Interrupted meetings are indexed after restart.
- Native adapter writes and model probes have deadlines, and worker output replaces invalid UTF-8. New generation registrations default to LiteRT-LM.

## [0.1.1] - 2026-10-17

### Added

- Native macOS inference replaces the bundled Python runtime; unused ONNX and MiniLM embedding backends have been removed.
- Application profiles use ordered, atomic schema migrations.
- A persistent Whisper worker handles successive speech segments without reloading the model.
- The shared operation registry keeps desktop, RPC and MCP contracts aligned, with desktop approval for sensitive agent requests.
- Published installer acceptance tests the packages downloaded from a GitHub release. Installer provenance must match the release tag; explicit recovery audits remain available for historical assets.
- Model and virtual-audio checks run as explicit integration gates. A skipped test in the regular suite is not treated as acceptance.

### Changed

- Ask has one web-search control.
- Meeting text uses shared roles, and meeting panels fit a narrow window.
- Each chat conversation keeps its own draft, streaming text, and answer cancellation.
- Release preparation promotes tested candidates for one commit into a draft, then publishes only after installed-package acceptance succeeds. Public release assets are immutable.
- The documentation tree keeps the current build, release, and architecture guides.

### Fixed

- Clearing a workspace removes private conversation checkpoints locally, works offline, and rejects work from the cleared generation.
- Citation groups are checked consistently by the shipped C++ and macOS Python checkers. The shared Dart contract rejects malformed answer payloads, and unverified drafts are not saved as answers.
- Cancelled meeting generation does not save artifacts; search and refresh validate source revisions, preserve local edits, and follow the service's adopted helper state.
- Meeting worker failures retain indexed transcript segments, paused meetings recover after a crash, Stop has a deadline, and explicit resume restores an exhausted helper. Speech retries on CPU; failed GPU generation prepares CPU for a retry.
- Native capture overflow writes interruption rows, and global shortcut failures appear in the workspace.
- Release builds check out their tag, reject mismatched source revisions, and assign increasing Linux package releases on draft rebuilds.
- Drive and Calendar sign-in uses the Google application registration bundled in a release build. Sign-in can be cancelled from the import flows.
- Linux CPU generation keeps modality executors on CPU.
- Linux packages retain the SDK libraries those binaries need at load time.
- A native worker's exit status is preserved when the host reaps the child on Linux. Supervised worker results are reported on macOS as well.
- Installed-release acceptance runs generation on CPU and fails when the probe exits without a result.

### Security

- Refresh tokens are stored in macOS Keychain or Linux Secret Service instead of plaintext profile preferences.
- Agent file imports require selected roots and bounded regular files, and cannot read the private profile. Sensitive actions require visible desktop approval; recording shows an indicator and stops when the desktop is hidden or closed.
- URL imports pin validated public addresses, recheck redirects, refuse HTTPS downgrades, and parse bounded HTML outside the service isolate. Private network access requires an explicit opt-in; response charsets are decoded correctly.
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

[Unreleased]: https://github.com/teng-lin/open-foresight/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/teng-lin/open-foresight/releases/tag/v0.1.1
[0.1.0]: https://github.com/teng-lin/open-foresight/releases/tag/v0.1.0
