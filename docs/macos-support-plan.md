# macOS support implementation plan

Add macOS support on top of the application-service refactor being developed on MSI. Keep Flutter for presentation, the plain Dart application core for business operations, and the existing retrieval and inference engines. Desktop and MCP must share one service, database writer, recording session, and model lifecycle per profile.

Implementation evidence is tracked in [macos-validation.md](macos-validation.md).
Build, bundle, MCP, and update commands are in [macos-support.md](macos-support.md).
The implementation has not yet passed the complete signed installed-release and
physical-audio gates; the acceptance checklist retains that distinction.

## Baseline and scope

Reviewed on 2026-10-15:

- Local checkout: `main`, revision `603c1a5d1688acd8992cbf0dfe0d36b90103c243`.
- MSI: `/home/blackmyth/src/open-foresight-mcp`, branch `feature/application-service-mcp`, at the same revision with substantial uncommitted work. Read `docs/application-service-plan.md`, `docs/application-service.md`, and the actual core, service, MCP, desktop, build, and test changes. Its documentation describes intended behavior; passing verification and merge readiness remain separate gates.
- MSI packaging worktree: `/home/blackmyth/src/open-foresight-packaging`, branch `feature/linux-packaging`, revision `4be81c6` with additional uncommitted changes. Coordinate shared build and runtime packaging changes with this branch.

Proposed first release target: Apple Silicon, macOS 15 and later, distributed as a signed and notarized application outside the Mac App Store. This is a scope choice, to be confirmed during the feasibility work. Intel/universal builds, older OS versions, App Store sandboxing, and a Rust migration are separate follow-up work.

The release includes source import/search, graph and notes, local answers, microphone and system-audio transcription, Google connections, desktop integration, and headless MCP. Microphone-only capture can be an intermediate milestone; it does not satisfy full meeting support. Headless means no Flutter window is required; first use of protected resources can still require explicit user interaction in a logged-in Mac session.

## Preserve the application boundary

The MSI refactor introduces `packages/foresight_core`, `Application`, `ApplicationService`, `ServiceConnection`, and `RemoteDomain`. The desktop uses a read-only SQLite connection for rendering; mutations go through service operations. Keep those ownership rules on macOS:

1. Flutter handles windows, dialogs, graph rendering, keyboard interaction, and user-facing setup.
2. The application service owns persistence, source revisions, indexing, Google sync, model configuration, generation, recording, and final transcription.
3. MCP remains a stdio adapter to the same operations. Its stdout contains protocol messages only.
4. The C++ helper and model/capture workers remain service-owned resources. A Mac capture component must be callable without Flutter.

Desktop disconnection must not stop capture. A second client must attach to the existing service. Cancellation remains scoped to the initiating request. Graceful service shutdown must flush transcription; crash recovery must mark interrupted work and resume pending indexing. Unknown-commit mutations must not be replayed automatically.

Add small platform interfaces in the core for paths/runtime discovery, filesystem ownership checks, system memory, browser opening, notifications, and audio capabilities. Use a Flutter-independent Mac adapter where the service needs native functionality; keep window activation, menus, shortcuts, and login-item UI in the desktop shell. Keep Linux implementations behind the same interfaces. Do not introduce a second application service or duplicate business operations in Swift.

## Phase 0 — Establish the integration baseline and prove feasibility

Budget: 3–4 engineering days. This phase determines whether later estimates hold.

- Obtain a committed application-service baseline from MSI before integrating its changes locally. Record the revision and rerun its core, service, desktop, and native gates. Do not copy a moving dirty worktree into the Mac implementation branch.
- Agree on the small platform interfaces and their owners. Land or rebase shared build changes in coordination with Linux packaging. Work on a separate Mac branch without modifying either active MSI worktree.
- In a signed development bundle, prove microphone capture and system-audio capture when the service is started desktop-first and MCP-first. Inspect the permission identity for the actual service/capture executable, including a launch from a GUI MCP host with a minimal environment.
- Evaluate Core Audio input capture plus Core Audio taps for system audio; compare ScreenCaptureKit if the first route cannot meet requirements. Select one route and record its supported OS floor, signing, permission, and packaging requirements. Apple documents taps and their system-audio usage description in its [Core Audio capture sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
- Prove the pinned LiteRT-LM `0.18.0` APIs used by generation, structured grounding, tokenization, and EmbeddingGemma on arm64. Validate CPU first, then the Mac GPU backend; test Whisper with a known audio file. Upstream [macOS support](https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/getting-started/build-and-run.md) does not establish compatibility with this exact adapter and model combination.

Exit: a recorded launch/permission strategy that works without a Flutter window, and successful embedding, grounded generation, and transcription probes. If a dedicated signed capture helper or agent is necessary, settle that architecture here. It must remain subordinate to the application service and survive desktop closure. A GUI-only capture plugin is insufficient.

## Phase 1 — Port the native helper and core platform services

Budget: 4–6 engineering days after the service baseline is available.

| Existing assumption | Planned change |
| --- | --- |
| `services/helper/child_process.h` uses `sys/prctl.h` and `PR_SET_PDEATHSIG` | Implement Mac worker launch and orphan cleanup while preserving Linux behavior. Use explicit process ownership, EOF handling, and reaping; removing the Linux call alone loses crash-cleanup semantics. |
| `native/foresight_native.cpp` and `services/helper/model.h` use `pipe2` | Add a portable close-on-exec pipe strategy suitable for the minimum deployment target and multithreaded launches. |
| `model.h` discovers installation via `/proc/self/exe` | Resolve the executable and bundled resources using Mac-supported APIs and explicit runtime configuration. |
| Core `helper.dart` inspects `/proc/<pid>/cmdline` before stopping an adopted helper | Add verified helper ownership/stop behavior using the private service contract or a supported process identity mechanism. Never stop an arbitrary PID based only on persisted state. |
| Core `service.dart` and desktop `main.dart` invoke GNU `stat -Lc` | Centralize private-directory validation with Mac-compatible owner and mode checks. Preserve user ownership and 0700/0600 protections. |
| `profile_paths.dart` assumes XDG paths | Resolve a Mac data directory under `~/Library/Application Support/Open Foresight`; preserve explicit overrides and consistent profile identity across all entrypoints. |
| Native loads assume `libforesight_native.so` | Centralize native-library and runtime resolution, including `.dylib` and bundle resources. |
| Model eligibility reads `/proc/meminfo` | Share Mac physical-memory detection between service capability reporting and desktop onboarding. |
| Core browser and reminder operations use `xdg-open` and `notify-send` | Inject browser and notification implementations that also work from the service. Return actionable permission/unavailability states. |

Unix socket paths must fit the Mac socket-address limit, including custom profiles. Use a short, private per-user runtime directory with a deterministic canonical-profile identifier; validate length, ownership, and collision behavior. Desktop, service, and MCP must derive exactly the same paths. Canonicalize aliases so the same profile cannot acquire competing owners through different runtime overrides.

Keep existing profile schemas and wire contracts. Rename neither `proto/linux` nor legacy database namespaces merely for appearance. Add an explicit, backed-up migration for any existing local profile; do not silently adopt profiles belonging to the reference Foresight application.

Exit: real service/helper/MCP subprocess tests pass on Mac for launch races, shared writes, indexing, restart, cancellation, and stale-socket recovery. Existing Linux gates remain green.

## Phase 2 — Build the Mac desktop and bundle runtime entrypoints

Budget: 3–4 engineering days, depending on Phase 1 runtime discovery.

- Generate and commit `apps/desktop/macos` runner/project files. Preserve app identity across development and release configurations and set a consistent minimum deployment target across Dart, native code, and dependencies.
- Add explicit platform selection to build tooling. Build native components plus AOT service/MCP binaries for arm64; select `flutter build macos` on Mac. Keep Linux output locations working.
- Define one bundle runtime configuration shared by Finder launch, the service, MCP, and command-line administration. Resolve resources relative to the installed bundle rather than the working directory or shell startup files. Carry the required runtime settings when the service is launched detached.
- Package the compiled desktop, service, MCP adapter, native library, C++ helper, and validated model workers. Document the actual MCP executable path and provide a configuration example that works with spaces in the application path and no terminal environment.
- Keep mutable models, caches, databases, credentials, and logs outside the signed application bundle. Inspect core generation and embedding cache defaults as well as Python bytecode/cache behavior.
- Check file selection, SQLite loading, source opening, imports, model setup, and permissions in a release build. Bundle PDF/RTF extraction dependencies or provide equivalent adapters so end users need no Homebrew installation.

Exit: a relocatable development `.app` supports sources, notes, graph, and answers; MCP can start or attach to its service with the desktop closed. The app runs without a source checkout, Dart/Flutter SDK, or developer Python environment.

## Phase 3 — Implement service-owned recording and permission behavior

Budget: 5–8 engineering days, following the Phase 0 choice.

- Implement microphone and system-audio discovery/capture in a native Mac adapter behind the existing capture/event contract where practical. Expose stable device IDs, separate audio channels, sample rates, levels, lifecycle states, and interruptions.
- Keep audio buffering, resampling, and capture callbacks outside the UI thread. Preserve bounded transcription queues, final/provisional segment separation, gap handling, and Stop-to-flush behavior.
- Report capture availability and permission state through the service. Desktop can show setup and recovery actions; MCP gets structured actionable failures without opening hidden dialogs or polluting stdout. Connecting MCP alone must not trigger capture or model downloads.
- Include microphone and system-audio purpose strings in the responsible signed component. Validate permission attribution in the installed layout for desktop-first, MCP-first, and service restart cases. Distinguish denied permission, unavailable device, and valid silence.
- Test default-device changes, explicit-device removal, Bluetooth/headset transitions, sleep/wake, service crashes, and permission revocation. Keep the existing distinction between following the default device and pinning a selected device; document any system-output selection differences.

Exit: a real meeting captures both channels and persists final transcripts; either client can observe it; closing the starting client leaves recording active; graceful stop flushes audio/transcription; crashes produce recoverable interrupted state. Repeat from an MCP host without an open desktop window.

## Phase 4 — Complete desktop behavior and local model setup

Budget: 3–5 engineering days. Some work can proceed after Phase 2 while audio is implemented.

- Implement window activation, app reopen, Command-key conventions, menus, global quick-meeting shortcut, and open-at-login behavior. Login settings must not create a competing service owner.
- Deliver meeting reminders through the platform notification adapter even while the Flutter window is closed. Keep scheduling and Google refresh ownership in the application service.
- Verify browser OAuth, loopback callback behavior, Drive/Calendar imports, reconnect, and credential persistence through the shared service. Keep sign-in explicit and credentials inaccessible to MCP tools.
- Complete resumable, verified model installation and eligibility checks on Mac. Preserve existing registrations when setup is canceled or fails. Report the effective CPU/GPU backend rather than assuming Linux Vulkan device semantics.
- Validate citation checks, structured output, cancellation, and worker cleanup with the pinned models. Record representative latency/memory/transcription throughput on the minimum intended Apple Silicon hardware. Define usable performance thresholds from Phase 0 measurements; make defaults fit the measured memory budget.

Exit: the Mac workflow checklist covers desktop interactions, Google connections, first-run model installation, and real local inference, alongside the same headless service operations.

## Phase 5 — Ship and validate the installed application

Budget: 4–6 engineering days, including integration fixes.

- Add Mac packaging alongside Linux packaging, sharing runtime metadata and entrypoint definitions rather than branching a single Linux script throughout. Audit Mach-O architecture, deployment targets, install names, and `@rpath`/loader-relative dependencies. Remove build-machine and Homebrew paths.
- Bundle a validated relocatable Python runtime if retaining the Python LiteRT adapter. Use Mac-specific dependency locks; the Linux model lock includes CUDA packages. Validate native Python modules and inference libraries after relocation.
- Configure direct distribution explicitly, including the App Sandbox decision, Hardened Runtime, resource access, and embedded executables. Flutter's [Mac build guidance](https://docs.flutter.dev/platform-integration/macos/building) distinguishes debug/release entitlements and sandbox settings.
- Sign nested executables/libraries and helper bundles before the enclosing app, notarize, staple the ticket, and produce a distributable archive or DMG. Follow Apple's [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution); do not rely on development ad hoc signing as release validation.
- Test installation, first launch, permissions, MCP launch, upgrade, and removal from a fresh Mac user account. Include a quarantined downloaded artifact, a minimal environment, and an app path containing spaces. Updates must coordinate with the long-lived service: gracefully finalize capture or explicitly defer replacement, then restart compatible clients/workers without mixed bundle versions.
- Add Mac CI for native/core/Flutter/service/MCP tests and unsigned packaging checks. Keep signed release and physical audio/permission checks as separate gates with retained results. Adapt `tests/service` beyond its Linux `pw-record` fixture, `.so` defaults, and Wayland UI launcher.

Exit: a signed, notarized artifact passes installed-app checks with no development tools or external runtime assumptions, and Linux regression checks pass on the integrated branch.

## Acceptance checklist

- [x] Application-service baseline is committed and its original Linux verification is recorded.
- [ ] Mac desktop and two MCP clients resolve the same profile and create exactly one service owner.
- [ ] Service/MCP work without Flutter installed or a desktop window open; stdout stays protocol-only.
- [ ] Source mutations, revision checks, read-only desktop queries, citations, graph persistence, and restart recovery retain their contracts.
- [ ] Launch races, private-directory validation, socket length, stale sockets, and adopted-helper shutdown pass on Mac.
- [ ] Real embeddings, grounded generation, Whisper, cancellation, model setup, and worker cleanup pass with the packaged runtimes.
- [ ] Microphone plus system audio work desktop-first and MCP-first, including denied/revoked permission, device changes, and desktop closure.
- [ ] Explicit stop flushes transcripts; service crash recovery preserves committed data and marks unfinished recordings interrupted.
- [ ] Shortcuts, app reopen, login, source links, imports, notifications, and Google authorization/sync work in release builds.
- [ ] A relocated, quarantined signed artifact works in a fresh account without Homebrew, SDKs, repository files, or a developer environment.
- [ ] Upgrading coordinates with an existing service/recording, and the documented support floor is exercised on actual hardware/OS versions.
- [ ] Integrated Linux build, packaging, and workflow verification remains green.

## Schedule and first implementation slice

The phase budgets total approximately 22–33 engineering days: plan on 5–7 weeks for one developer once a stable service baseline is available, signing access is arranged, and the Phase 0 experiments succeed. This includes the desktop, headless MCP, physical recording, packaging, and cross-platform regression gates. Service-refactor completion, approval/account provisioning, or a replacement inference integration can extend elapsed time. The phases are effort estimates; overlapping work does not remove dependencies.

The first implementation slice is a committed application-service baseline plus Mac platform/runtime discovery, portable native helper startup, and the existing MCP ownership tests running against a controlled isolated profile. Run permission/model feasibility experiments alongside this slice before committing to the full capture implementation. A developer UI milestone can arrive earlier; full support requires the acceptance checklist above.
