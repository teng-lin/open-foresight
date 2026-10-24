# Changelog

Notable changes to Open Foresight are recorded here. Versions follow
[Semantic Versioning](https://semver.org). The release version is
`apps/desktop/pubspec.yaml`.

## [Unreleased]

### Added

- Rename meetings from the workspace header. Manual names persist across restarts
  and calendar refreshes.
- Keep private pre-upgrade application database snapshots, limited to two copies
  for seven days. Each snapshot can require space comparable to the database.

### Changed

- Bound retained content history to 20 revisions per entity, 32 MiB in total and
  90 days. Upgrades prune excess history while preserving current content.
- Refuse database upgrades when a verified backup cannot be created or earlier
  privacy cleanup cannot finish. Deleting saved content invalidates managed
  snapshots and prepared restore copies; failed cleanup remains pending.

### Fixed

- Check direct Google client setup before signing out Granola accounts when switching providers.
- Show separate Google and Granola connection choices, with explicit provider switching and account sign-out confirmation. Recover direct Google sign-in after failed Granola attempts and preserve Google client setup across provider changes and restarts.
- Use Granola’s macOS client profile for authorization and calendar API calls on Linux.

- Enforce owner capabilities before service dispatch and refuse installer shutdown while a desktop is attached.
- Require visible desktop approval before agents replace saved notes, meeting tasks or artifacts, and retain previous content atomically for recovery. Deletion and workspace clear erase retained revisions.
- Keep native worker pipes separate from closed standard input, output or error descriptors.
- Bound web-summary RPCs by the caller's deadline and cancel stalled transports.
- Continue credential cleanup after an individual keyring failure and retry remaining profile-scoped keys after restart without retaining account tokens in the cleanup journal.

- Preserve Chat history scroll position while its source scope refreshes.

- Refresh Stats at the local Monday boundary and after an awake timezone change, keeping chart labels aligned with the displayed calendar period.

- Bind desktop approval to the verified local desktop executable, rotate its attach capability, and preserve its host slot while hidden. Hidden windows refuse new capture and finish active capture; requests through the quick-meeting socket require visible confirmation.
- Packaged installations refuse model executables outside their installation directory, including saved runtimes restored after restart and direct Linux service/MCP launches. Select a bundled runtime in model settings to recover an older external registration.
- Keep using the bundled LiteRT worker when generation setup or registration names a retired runner.
- Clear the approval warning after the visible desktop successfully reconnects.
- Generate summaries from meeting-list previews, retain the selected note when a save finishes late, and finish runtime setup after an onboarding retry.
- Keep existing notes unsavable until their body loads successfully, and preserve editor drafts when retrying a failed load.
- Show failures from settings and meeting controls, and dismiss the sign-in dialog without closing another dialog above it.
- Keep desktop widget tests isolated from desktop shortcuts, application configuration, URI launchers and notifications.
- Release the activation listener when desktop startup cannot protect its socket.
- Discover the usual account folders when macOS launches without a HOME environment variable.

## [0.1.3] - 2026-10-21

### Added

- Meeting tasks, Enhanced Notes, Live Q&A, meeting preparation, and scoped Chat bring more meeting workflows into the desktop app.
- First-run onboarding guides desktop setup. Google account avatars and account switching make connected accounts easier to manage.
- Meeting Summary uses dedicated Overview/Details prompts, full or incremental generation, and sequential map/reduce for long transcripts. Streaming progress and cancellation preserve accepted versions; compatible checkpoints and generation provenance persist with the searchable summary.
- Experimental Google Calendar connection through Granola’s hosted WorkOS flow and calendar API, with a Foresight-owned return URL, separate app-session handling, and no Drive access. A manual return-link field accepts Granola’s HTTPS app-redirect and native completion links, including sign-ins that open Granola.

### Changed

- Physical GPU validation can be explicitly waived per release; automated installer acceptance and provenance verification remain required, and release notes record the waiver.
- Release candidates are produced on demand, and publication verifies retained installer evidence. CI reuses verified dependencies and build outputs while keeping preview and release artifacts separate.
- Expanded recovery, persistence, desktop, and compiled-service checks strengthen application validation and measured test coverage.

### Fixed

- Application service shutdown, reconnect, and handoff preserve active agent work and shut down after idle. Connections recover when a listener closes during connection setup.
- Local edits survive service failures, and meeting and model restarts recover more reliably.
- Retrieval context and desktop behavior remain consistent across meeting workflows.

## [0.1.2] - 2026-10-18

### Changed

- README source-build instructions cover macOS and Linux prerequisites, dependency reuse, runtime bundling, packaging, and launch commands.
- Desktop Start/Resume transcribing controls act directly without a second confirmation or duplicate red capture banner; waveform, pause and Stop controls remain visible, and external recording requests still require approval.
- Linux RTF imports remove the converter's leading separator when quiet output omits its translation banner, preserving separators within the document body.
- CI pins Python 3.13, Dart protobuf tooling, shared dependency versions and dated Ubuntu archives; monthly snapshot updates arrive as draft review PRs, with weekly dependency and vulnerability reports.
- Native and helper tests have a separate ThreadSanitizer gate with a real race-detection probe and one-week reporting probation. Software Vulkan acceptance exercises shipped GPU runtimes; release publication requires installer-bound manual GPU evidence.
- Offline Python and desktop tests enforce measured coverage baselines. Test fixtures share isolated disk-backed temporary paths and cached native stubs, and every optional integration probe has an explicit validation path.
- Preview and release installers verify PDF/RTF extraction through their installed application service and real document sandbox.
- Release publication preserves Latest on the highest stable version and correlates fresh candidate builds to their own dispatch. Shared DMG provenance binds preview and release installer bytes to the source revision, version and build number.
- Linux packages ship the nlohmann-json notice and complete copyright stanzas for bundled license files; unknown licenses stop packaging.
- Installer workflows publish signed build provenance and SBOM attestations. Dependency artifact downloads verify GitHub ZIP digests.
- Offline Python tests use directory discovery with an explicit inventory for build and device harnesses. Integration acceptance reports an always-running required check.

### Fixed

- Documentation-only main pushes skip application packaging and model acceptance; shipped license notices still select package validation.
- CI software Vulkan explicitly selects lavapipe and records unavailable GPU support as skipped. Disposable installer-test containers permit the real document sandbox to initialize isolated networking.
- macOS CI consumes the same PR source as dependency producers and waits only for matching trusted producers, with pinned source fallback when no eligible producer exists.
- Stale CMake Python paths fail before native work. Workspace cleanup waits for observed completion under parallel load; speech GPU-to-CPU retry and cancellation cover both worker protocols.
- Long meeting generation includes balanced beginning, middle and ending evidence within the model context. HTML imports honor bounded meta encodings, and Unicode truncation preserves supplementary characters.
- Local edits use a structured schema flag and URL imports deduplicate by source URI. Helper crash recovery resets after a quiet window, and answer validation failures are visible by reason.
- Native worker failures clean up owned processes and roll back busy handles; model framing and one-shot requests keep prompts out of argv. Reconfiguration respects cancellation, audio writes detect failures, and Linux LiteRT loading binds hashes to the loaded descriptor.
- Workspace clear securely deletes application rows and attempts checkpoint/VACUUM; helper deletions erase freed database content.
- Package upgrades ignore installation locks with invalid ownership, permissions or symlinks, preventing other local users from blocking updates.
- Clearing a workspace works offline, discards pending meeting drafts and retries helper deletion after reconnect. Stale speech audio is removed on startup.
- Calendar refresh preserves local edits and deletions and bounds untrusted invitation HTML parsing.
- Failed answers discard partial text and citations; cancelled note enhancements restore the previous notes.
- Background credential and recording failures no longer escape the service worker. Interrupted meetings are indexed after restart.
- Native adapter writes and model probes have deadlines, and worker output replaces invalid UTF-8. New generation registrations default to LiteRT-LM.

### Security

- Dependency artifact promotion binds output to the producing workflow and tools and accepts only the final reviewed PR head.
- macOS parser confinement, sealed runtime code paths, private startup configuration and private temporary socket roots reduce exposure. Service-specific Keychain access controls remain deferred pending signing and runtime-integrity work.
- Local source links reveal files instead of launching their default handlers. Approval dialogs highlight risky options and limit repeated identical prompts; verified peer identity and trusted gesture redesign remain deferred.
- Automatic question-model downloads require configured genuine publisher terms and revision-specific acknowledgment. Missing terms configuration disables automatic acquisition.
- Release builds disable crash and delay test hooks, and system integration commands use absolute paths.

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

[Unreleased]: https://github.com/teng-lin/open-foresight/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/teng-lin/open-foresight/releases/tag/v0.1.3
[0.1.2]: https://github.com/teng-lin/open-foresight/releases/tag/v0.1.2
[0.1.1]: https://github.com/teng-lin/open-foresight/releases/tag/v0.1.1
[0.1.0]: https://github.com/teng-lin/open-foresight/releases/tag/v0.1.0
