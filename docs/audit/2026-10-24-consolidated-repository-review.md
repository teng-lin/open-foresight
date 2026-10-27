# Open Foresight consolidated repository review

Review date: 2026-10-24. Source: `2f26d8fc9d1ef83e7df2d709fa776c55c8c01ace`
(`Allow users to rename meetings`, #177) on `main`.

This report merges two independent audits of the same commit:

- **[C] Codex review** (`2026-10-24-repository-review.md`): three review agents plus a
  coordinator.
- **[T] Claude agent-team review** (`2026-10-24-repository-review-team.md`): seven
  aspect reviewers plus a coordinator.

Each finding is tagged with its origin: [C], [T], or [C+T] when both reached it
independently. Before merging, the consolidating reviewer re-checked against current
source every finding that only one review reported. Findings raised by both reviews
are the most reliable.

**Scope exclusion.** The owner has excluded one topic: how the release distribution
credentials are sourced (`tools/reference_distribution_config.py` and the related
packaging of those values). This report does not assess it, and findings that depended
on it are left out. These include scoping of distribution secrets to PR artifacts and
the README statement about packaging.

## 1. Summary

The two reviews agree on what is strong:

- a single service that owns mutations and native resources;
- desktop and operation boundaries enforced by tests;
- exact-count, zero-skip verification gates;
- careful SQLite migration and recovery;
- sandboxed parsing and DNS-pinned SSRF defences;
- SHA- and digest-pinned build inputs;
- release publication tied to attested, installed, upgrade-tested bytes.

They also agree on the most urgent defect. **Recording stop writes database state
before tearing down capture**, so a storage failure can leave the microphone running
after Stop, hide or desktop disconnect. That breaks the guarantee in ADR 0006 that
recording stops when the desktop disconnects.

Combining the reviews adds four further themes:

1. **Live-meeting cost grows quadratically.** Every segment rewrites, re-embeds and
   snapshots the full transcript, and history is never pruned [T].
2. **Diagnostics and resilience have gaps.** Linux discards service and worker stderr
   [T]. Model acquisition has no transport deadlines [C], and native capture ignores
   `TMPDIR` [C].
3. **Release process controls rely on convention.** Approval, the manual acceptance
   checklist and vulnerability response are policy rather than enforced checks [C+T].
4. **The heaviest code carries maintenance load.** Large desktop controller libraries
   [C], the service-wide `Domain` locator [T], untyped Python tooling [T], and drift in
   the most-read documentation [C+T].

**Overall: 6.5/10** (unweighted mean of eleven consolidated scores).

## 2. Ratings

Rubric (shared by both reviews): 1–2 fundamental deficiencies · 3–4 substantial
weaknesses · 5–6 adequate but uneven · 7 strong with material gaps · 8 strong with
enforced controls · 9 highly mature, few gaps · 10 exemplary.

| Aspect | [C] | [T]¹ | **Consolidated** | Basis for the consolidated score |
| --- | ---: | ---: | ---: | --- |
| Architecture | 8 | 7 | **7** | The single-owner service and analyzer-checked boundary are real. The boundary hides names but not the compile graph, `Domain` acts as a service locator, model setup runs in widgets, and two controller libraries exceed 3,000 lines. |
| Security and privacy | 7 | 7 | **7** | Strong peer verification, consent gating, SSRF and parser confinement. The capture-stop defect weakens the visible-desktop guarantee. MCP reads need no approval, and two `/tmp` paths and an import TOCTOU remain. |
| Reliability and data integrity | 7 | 7 | **6** | Each review alone scored 7. Their combined findings lower the score: the stop path, duplicate request IDs, unbounded history, stop blocked behind indexing, stalled acquisition and the hardcoded capture `/tmp` path. |
| Performance and responsiveness | 7 | 5 | **6** | Read workers, coalescing and isolate offloading are good. Live meetings do quadratic re-embedding and snapshotting, capture drains share an isolate with synchronous work, and native teardown is synchronous. No head-of-tree measurements exist. |
| Code quality | 8 | 7 | **7** | All configured analyzers are clean, with few suppressions and almost no TODO debt. Python is largely unannotated, the C ABI duplicates its exception barrier, and smoke-check errors are opaque. |
| Maintainability | 7 | 6 | **6** | Compile-time exhaustiveness and architecture tests help. Large shared controller libraries, about 41k lines of CI tooling against about 70k lines of product code, three Python import mechanisms, and PRs over the 100-file rule work against it. |
| Testing and verification | 8 | 8 | **8** | Layered suites, exact-count gates, three coverage gates and sanitizers with positive controls. Gaps: the first-run acquisition journey, coverage gated on Linux only, one load-sensitive flake, manual-only GPU, audio and macOS paths, and no native coverage. |
| Deployment and release | 7 | 6 | **6** | Exact-commit candidates, multi-distribution installed acceptance and attested bytes. Approvals are not platform-enforced, and the manual checklist is not part of publication evidence. Linux packages are unsigned, the DMG is not notarized, and there is no rollback or update channel. |
| Dependencies and supply chain | 8 | 5¹ | **7** | Pinning discipline is excellent. Vulnerability scanning is non-blocking and covers Python and Dart only. Updates have stalled, and some release packaging inputs and macOS ICU are unpinned. |
| Observability and supportability | 7 | 4 | **5** | Typed errors and a bounded opt-in trace. On Linux, service stderr is never captured and worker stderr goes to `/dev/null`. Logging is free-form, raw invalid frames are traced, and there is no troubleshooting or bug-report path. |
| Documentation and developer experience | 7 | 6 | **6** | Extensive and mostly accurate. Coverage gates, the migration table, the MCP tool list, the OAuth import description and the release steps are wrong in the most-read files. There are 12 broken links and unmarked historical plans. |

¹ The [T] supply-chain score of 5, and its reduction of the security score, partly
reflected the excluded credential topic. With that topic set aside, the [T] evidence
supports 6–7 for supply chain and 7 for security.

## 3. Consolidated findings

Priorities: **P1** is an urgent privacy, core-correctness or data-growth defect.
**P2** is a material reliability, verification or process gap. **P3** is lower-risk
hardening, documentation or maintenance work. "Confirmed" means the source establishes
the control flow. Unless a finding says otherwise, no end-to-end reproduction ran.

### 3.1 Summary table

| ID | Finding | Pri. | Origin | Aspects |
| --- | --- | --- | --- | --- |
| F1 | Recording stop depends on a successful database write | P1 | C+T | Security, Reliability |
| F2 | Content history grows quadratically during live meetings, with no retention | P1 | T | Reliability, Performance |
| F3 | Live indexing re-embeds the entire transcript after every segment | P1 | T | Performance |
| F4 | Linux service and native-worker diagnostics are discarded | P1 | T | Observability |
| F5 | Duplicate active RPC IDs replace ownership records | P2 | C+T | Reliability |
| F6 | Stop waits behind the source-mutation queue and blocks the next recording | P2 | T | Reliability |
| F7 | Dedicated question-model acquisition has no transport deadlines | P2 | C | Reliability |
| F8 | Native capture FIFO hardcodes `/tmp`, and the install lock uses a predictable shared-`/tmp` path | P2 | C, T | Reliability, Security |
| F9 | Capture pipeline robustness: shared-isolate starvation, queue-inclusive speech deadline, lost segments | P2 | T | Reliability, Performance |
| F10 | Vulnerability monitoring is non-blocking and covers only part of the dependency surface | P2 | C+T | Supply chain |
| F11 | Release authority and manual acceptance are not enforced by the platform or by publication evidence | P2 | C, T | Deployment |
| F12 | Verification gaps: first-run acquisition journey, never-run tests, load-sensitive flake | P2 | C, T | Testing |
| F13 | MCP clients read every transcript and note without approval or provenance tags | P2 | T | Security |
| F14 | The desktop/core boundary hides names but not code; `Domain` is a service locator | P2 | T | Architecture |
| F15 | Large shared desktop controller libraries, and model setup in widgets | P2 | C, T | Maintainability, Architecture |
| F16 | Synchronous native teardown on the service isolate | P2 | C | Performance |
| F17 | Dependency updates stalled; release packaging inputs and ICU unpinned | P2 | T | Supply chain |
| F18 | Documentation drift: coverage gates, migrations, MCP tools, OAuth import, release steps | P3 | C+T | Documentation, Testing |
| F19 | Diagnostic content and structure: raw invalid-frame traces, free-form logs, no support guide | P3 | C+T | Observability |
| F20 | No end-user trust or update channel, and no rollback | P3 | C+T | Deployment |
| F21 | Security hardening: import TOCTOU, helper liveness after upgrade, approval-dialog spoofing, native spawn robustness, credential-file details | P3 | T | Security |
| F22 | Code-quality debt: untyped Python, duplicated C ABI barriers, import mechanisms, duplicated helpers, opaque smoke errors | P3 | T | Code quality |
| F23 | Lower-severity reliability risks: read-worker recovery, `busy_timeout`, socket backpressure, unchecked ABI version | P3 | T | Reliability, Architecture |
| F24 | CI system weight and change size | P3 | T | Maintainability, Deployment |
| F25 | Sanitizer and native coverage gaps; coverage gated on Linux only | P3 | C+T | Testing |

### 3.2 P1 findings

**F1. Recording stop depends on a successful database write. P1, confirmed [C+T].**

- **Evidence:**
  - `_stopRecording` cancels its timers, then calls `queries.setState(id, 'transcribing')`
    at `application_services/recording_controller.dart:246`. That call sits outside the
    `try/finally` that holds `active.stop()` and ownership cleanup (lines 248–265).
  - `CaptureQueries.setState` is a direct SQLite `UPDATE`
    (`persistence/capture_queries.dart:23-24`).
  - The hide/detach handlers (`service_operation_handlers.dart:71-112`) and the
    disconnect handler (`application_service.dart:635-643`) call this path and only log
    a rejection.
  - A retained recording counts as busy service work (`application_service.dart:109`).
  - Start has the mirror problem [T]: `recording = active` is set at line 175, before
    the state write at line 182.
- **Consequence:** after a disk-full or I/O error, capture keeps running after Stop,
  hide or disconnect, and nothing retries. On start, the client receives an error while
  capture is actually live. Neither review reproduced a live-audio leak, and neither
  claims capture survives process exit.
- **Fix:** stop and dispose native capture unconditionally, independent of status
  persistence. Keep committed segments and the original storage error, and attempt the
  final status write separately with a retry. On start, dispose if the state write
  fails.
- **Regression tests:** Stop, hide and disconnect with a synthetic SQLite trigger that
  rejects the `transcribing` update. Assert that native capture stops and recording
  ownership clears.

**F2. Content history grows quadratically during live meetings, with no retention.
P1, confirmed [T].**

- **Evidence:**
  - Migration 18 installs a `BEFORE UPDATE` trigger that copies the full old content
    into `content_revisions` (`persistence/schema_migrations.dart:183-190`). The same
    trigger exists on `sources`, `meeting_notes`, `notes` and `artifacts`.
  - Live indexing runs 1 s after each committed segment
    (`recording_controller.dart:124-133`) and upserts the whole `meeting-$id`
    transcript (`meeting_indexer.dart:45-56`; `persistence/source_store.dart:53`).
  - Only deletion triggers ever remove history rows.
- **Measurement (synthetic, outside the app):** replaying the trigger and upsert SQL
  for 600 appends of 200 bytes gave a 120 KB transcript and **36.3 MB** of history.
- **Consequence:** long meetings multiply database size and slow VACUUM. Erasure work
  also grows, because deleting the entity must remove all of its history.
- **Fix:** keep history out of system-generated sources such as transcripts. Add
  count- or age-based retention, or store diffs.

**F3. Live indexing re-embeds the entire transcript after every segment. P1 for long
meetings, confirmed [T].**

- **Evidence:** `meeting_indexer.dart:37-56` re-reads all transcript rows.
  `domain.dart:300-312` sends the full content to `IndexDocument`, which re-chunks and
  re-embeds it (`services/helper/main.cpp:621-622`). Note-embedding and proactive work
  also run per segment (`recording_controller.dart:120-123`).
- **Consequence:** embedding work grows with the square of meeting length and competes
  with whisper for CPU, which makes speech timeouts (F9) more likely.
- **Fix:** index the transcript in append-only chunks. Alternatively, throttle live
  indexing and run the full index once at stop.

**F4. Linux service and native-worker diagnostics are discarded. P1 for
supportability, confirmed [T].**

- **Evidence:**
  - On Linux the service starts with `ProcessStartMode.detached` and no log redirect.
    Only the macOS launch path adds `--stderr service-startup.log`
    (`service_startup.dart:688-715`).
  - Worker stderr is opened to `/dev/null` (`native/foresight_native.cpp:290`;
    `services/helper/child_process.h:45`).
  - Helper stdout and stderr are drained and dropped, so only `helper exited ($code)`
    survives (`helper.dart:242-266`).
- **Consequence:** a crash or internal error in an installed Linux build leaves no
  record, so neither the user nor a maintainer can diagnose it afterwards.
- **Fix:** write a private (0600), size-capped, rotated service log on both platforms.
  Keep an in-memory tail of helper and worker stderr, and show it through `--status`
  and the helper monitor. Add log levels and redaction (see F19).

### 3.3 P2 findings

**F5. Duplicate active RPC IDs replace ownership records. Confirmed [C+T].**

- **Evidence:**
  - Admission validates only the ID's type (`service_admission.dart:16`).
  - `_leases[client]![id]` and `_subscriptions[client]![id]` overwrite any existing
    entry (`application_service.dart:683,716`).
  - Completion removes entries by ID (lines 729–741), so an earlier request can remove
    a later one's entries.
  - Cancellation (line 925), disconnect cleanup (line 647) and terminal frames
    (lines 987–995) reach only the currently mapped owner.
  - The 32-request limit counts map entries (line 610).
- **Consequence:** a raw or buggy same-user client can orphan producers and get around
  the request limit. This is a local availability defect, not a privilege escalation.
  The repository's own client uses a monotonic counter.
- **Fix:** reject an ID that is already active, before creating its lease, and remove
  entries only after checking identity.
- **Test:** a raw-socket test that holds a producer, reuses its ID, then cancels and
  disconnects.

**F6. Stop waits behind the source-mutation queue and blocks the next recording.
Confirmed [T].**

- **Evidence:**
  - `_stopRecording` awaits `indexer.indexMeeting` (`recording_controller.dart:258`).
    That call goes through the FIFO `_serialize` queue (`domain.dart:219-275`), and each
    queued index may take up to 30 minutes (`domain.dart:311`).
  - `recording` is cleared only in `finally` (line 265), and `startRecording` refuses
    while it is set (line 93).
- **Consequence:** if a large PDF or a Google sync is indexing, the stopped meeting
  stays in `transcribing` and no new recording can start for minutes.
- **Fix:** publish the final state and release `recording`, then index in the
  background.

**F7. Dedicated question-model acquisition has no transport deadlines. Confirmed [C],
re-verified.**

- **Evidence:** the metadata RPC sets credentials but no call deadline
  (`model_acquisition.dart:62`). The downloader uses a default `HttpClient`
  (`model_acquisition.dart:155`) and awaits `getUrl`, `request.close()` and stream
  iteration without timeouts (`model_acquisition.dart:246-275`).
  `dedicated_query_acquisition.dart:140` awaits these directly.
- **Consequence:** a stalled transport leaves setup pending indefinitely. The five
  retry attempts never apply, because a retry needs the current attempt to fail.
  Size and digest checks still run before the model is adopted. The Gemma downloader
  does have a 30 s idle timeout, so this applies to the question-model path only.
- **Fix:** add finite deadlines for metadata, connection and response headers, plus a
  body inactivity deadline.
- **Tests:** stalling loopback transports that verify retry, cancellation, release of
  the reservation, and that the previous usable model is kept.

**F8. Hardcoded and shared `/tmp` paths. Confirmed [C] and [T], re-verified.**

- **Capture FIFO [C].** `CapturePcmPipe` uses `mkdtemp("/tmp/foresight-capture-XXXXXX")`
  (`native/foresight_native.cpp:180`) and ignores `TMPDIR`. Capture can therefore fail
  on `/tmp` quota or allocation limits even when a usable private temporary root is
  configured, which AGENTS.md itself warns about.
- **Install lock [T].** The lock lives at `/tmp/of-install-$uid-$sha256(root)[:24]/lock`
  (`platform_services.dart:606`), and `privateDirectory` refuses a directory owned by
  another user. Another local user can pre-create that predictable directory, which
  permanently blocks the victim's packaged service; the sticky bit stops the victim
  removing it. Any user holding their own lock file also blocks root's package
  upgrade (`packaging/upgrade_lock.sh:44-68`).
- **Fix:**
  - Capture: honour a validated temporary root, keeping private modes, bounded path
    lengths and cleanup.
  - Lock: move it to `$XDG_RUNTIME_DIR` or a per-user cache directory, and have the
    installer enumerate only real users' runtime directories.

**F9. Capture pipeline robustness. Confirmed by reading; blocking times not measured
[T].**

- **Starvation.** The 20 ms drain timer (`recording.dart:258`) shares an isolate with
  synchronous work:
  - a recursive `listSync` (`source_operations.dart:258`);
  - per-file `queries.documents`, which loads every source's content
    (`source_operations.dart:200`; `persistence/source_queries.dart:32-38`);
  - synchronous native joins.

  The native queue drops audio after 255 frames (`foresight_native.cpp:551-554`).
- **Speech deadline.** Two channels share one speech worker behind a `timed_mutex`
  (`foresight_native.cpp:1458-1463`). The 60 s deadline starts before the job holds the
  mutex (`recording.dart:569-573`). A timeout discards the segment and kills the shared
  worker, which forces a model reload.
- **Lost segments.** A failed synchronous transcript write re-enters `interruption`,
  which writes to the database again. That second throw escapes into an unhandled zone
  error, losing both the text and the PCM (`recording_controller.dart:110-118`;
  `recording.dart:520-526,613-624`).
- **Fix:**
  - Look sources up by URI in SQL, and move directory listing off the isolate.
  - Start the speech deadline when the job starts running.
  - Keep the last N segments in memory and retry failed writes; guard the error-path
    callbacks.
  - Consider a dedicated capture isolate.

**F10. Vulnerability monitoring covers only part of the dependency surface. Confirmed
[C+T].**

- **Evidence:**
  - `osv-scan.yml:12,18` sets `continue-on-error` on both the job and the step.
  - The scan inputs are 3 Python locks and 2 pub locks (`osv-scan.yml:22-26`).
  - Not covered: gRPC/abseil/boringssl, whisper.cpp, LiteRT, SQLite, bundled CPython,
    the Flutter engine, Ubuntu snapshot packages, and Homebrew ICU
    (`packaging/sdk-core.Dockerfile:20`; `packaging/sdk-litert.Dockerfile:13`).
  - Installer SBOMs exist but are not scanned.
  - [T] found that the only run so far (2026-10-19) reported GHSA-6w46-j5rx-g56g in
    pytest 9.0.2 and still concluded success. pytest is still at 9.0.2
    (`requirements-dev.lock:592`); this is a development-only dependency.
- **Fix:** keep a scanner failure distinct from a vulnerability finding. Scan the
  release SBOMs, or a manifest generated from `tools/pins.json`. Assign triage
  responsibility, and open issues for High and Critical findings. Any severity-based
  publication gate needs owner review.

**F11. Release authority and manual acceptance are not enforced. Confirmed [C] and
[T].**

- **Approval [T].**
  - The main ruleset requires 0 approvals and no code-owner review. There is no
    CODEOWNERS file and no protected `release` environment.
  - `release.yml` is a plain `workflow_dispatch`, and its `main` checks live in the
    workflow file itself (`release.yml:2-3,83`).
  - Attestation verification pins only `--repo` (`RELEASING.md:165-167`).
  - AGENTS.md says workflow and trust-code changes need owner review, but nothing
    technically enforces it.
- **Manual checklist [C].** `aggregate` derives the overall status from GPU evidence
  (`tools/release_acceptance_report.py:106`), and `require_publication` (line 160)
  never reads `docs/validation/release-acceptance-manual.json`. That checklist covers
  guided setup, physical audio, permission revocation, sleep/wake, native export and
  Finder quarantine. `docs/validation/release-acceptance.md:115` requires those
  observations. This is not an artifact-integrity bypass, and neither review claims
  manual checks were skipped on any real release.
- **Fix:**
  - A `release` environment with a required reviewer, main-only deployment and
    environment-scoped secrets.
  - CODEOWNERS for `.github/**`, `tools/ci_*`, `tools/*trust*` and `packaging/**`, with
    one required approval.
  - `--signer-workflow` and `--source-ref` in the verification instructions.
  - An owner-reviewed manual receipt bound to the exact installer hashes, with explicit
    scoped waivers.

  All of these changes need owner review under `docs/platforms/ci-integrity.md`.

**F12. Verification gaps. Confirmed [C] and [T].**

- **First-run journey [C].** `apps/desktop/test_support/onboarding.dart:5-16` skips
  model setup, and the compiled service/MCP journey uses that helper
  (`integration_test/service_mcp_test.dart:155`). No compiled scenario covers a fresh
  profile through partial setup, restart, an interrupted download, checksum rejection,
  retry, adoption and indexing.
- **Never-executed tests [T].**
  - `tests/inference/test_raw_query_model.py` has no `add_test`, and its
    `pytest-exclusions.json` reason ("CTest CLI harness") is misleading.
  - `tests/integration/test_model_crypto_keychain.py:22-26` needs an env var that
    nothing sets.
  - 18 of the 24 probes in `tools/integration_probes.json` are manual.
  - Software-GPU acceptance allows LiteRT to be unavailable
    (`tools/linux_acceptance.sh:54`).
- **Load-sensitive failure [T].** `packages/foresight_core/test/proactive_application_test.dart:405`
  failed once during a full run that shared the CPU (expected `completed`, actual
  `failed`). It passed 3/3 when run alone.
- **Fix:**
  - Add the compiled first-run scenario with a deterministic loopback download, and keep
    real-model acceptance as a separate check.
  - Correct the exclusion reasons and wire the Keychain test into macOS CI.
  - Make the proactive test deterministic with `fake_async` or completers, and run a
    scheduled CPU-stress pass.

**F13. MCP clients read every transcript and note without approval. By design; impact
is a risk judgement [T].**

- **Evidence:** read descriptors are `readOnly: true, approval: ApprovalPolicy.never`
  (`operation_descriptors/sources.dart:7,24`; `docs/architecture/application-service.md:141`).
  [C] notes that same-user access is part of the documented trust model.
- **Risk:** an imported web page or Drive file carrying instructions aimed at an agent
  can lead it to read every transcript headlessly. Untrusted-content labels exist only
  in Ask prompts, not in MCP output.
- **Fix:** an opt-in approval or time-boxed grant for transcript, note and Drive reads,
  plus provenance and trust tags on MCP results.

**F14. The boundary hides names, not code, and `Domain` is a service locator.
Confirmed [T].**

- **Compile graph.** The closure of `desktop.dart` plus bootstrap reaches 206 modules,
  including `application_service.dart`, `domain.dart`, `store.dart` and
  `recording.dart` (via `remote_domain.dart:18` and `service.dart:5,10`). The boundary
  test *asserts* that coupling (`desktop_boundary_test.dart:41-42`).
- **Locator.** 15 of 17 coordinators take the whole `Domain`.
  `application.dart:136-137` wires back into it after construction.
- **Generator ownership.** The handle is replaced at six sites after an `await`, with
  no compare-and-swap and no close of the previous value (`domain.dart:406,412,432,502,507`;
  `model_registry.dart:242`).
- **Untyped desktop API.** `command(Operation, Map<String, dynamic>) → Object?`
  (`desktop_connection.dart:114-132`) has 72 call sites, while the service decodes
  typed requests.
- **Fix:**
  - Split client and server barrels, and invert the assertion so service modules must
    be *absent* from the desktop and MCP closures.
  - Add a single-owner `GenerationRuntimeSlot` and pass narrow ports.
  - Make `encode()` and typed result decoders part of each operation request.

**F15. Large shared desktop controller libraries, and model setup in widgets.
Confirmed [C] and [T].**

- **Controller size [C].** `features/meetings/meetings_controller.dart` and its parts
  total 3,108 lines; `features/sources/sources_controller.dart` and its parts total
  3,076. The parts share private library state, and the size guard
  (`test_support/desktop_architecture.dart:170`) checks physical files only.
- **Model setup [T].**
  - `gemma_setup_view.dart:231-296` runs the runtime check, download and install from a
    widget `State`.
  - There are two downloaders (`gemma_download.dart` and `model_acquisition.dart:145`).
  - Audio device discovery runs in the desktop process (`audio_devices.dart:20-45`).
- **Fix:**
  - Extract widgets incrementally with explicit view data and callbacks, and measure
    complexity per logical library.
  - Make model acquisition a service operation with streamed progress, merge the two
    downloaders, and serve device enumeration from the service.

**F16. Synchronous native teardown on the service isolate. Confirmed [C].**

- **Evidence:** `NativeRuntime.close` calls synchronous destruction
  (`native.dart:663`), and conversation destruction joins native work
  (`foresight_native.cpp:1268`). `docs/plans/2026-10-21-native-close-follow-up.md`
  records historical blocking measurements, not measurements of this commit.
- **Consequence:** this compounds F9, because native joins sit on the same isolate as
  the capture drain.
- **Fix:** design asynchronous teardown with an explicit ownership protocol. Moving the
  calls to another isolate is not enough. Verify with `tools/measure_service_rpc.py`.

**F17. Dependency updates stalled; release packaging inputs unpinned. Confirmed [T].**

- **Stalled updates:**
  - Dependabot PRs #113–#116 were closed without merging.
  - `actions/upload-artifact` is at v4.6.2 in 94 places and at v7.0.2 in one
    (`linux-packages.yml:126`).
  - There are no ignore rules for Ubuntu or Fedora major versions.
  - No updater covers digests, `ARG *_COMMIT` values or `tools/build_macos_sdk.py`
    pins, and the gRPC commit is duplicated.
  - Snapshot bot PRs opened with `GITHUB_TOKEN` don't trigger CI.
- **Unpinned release packaging:** `rpm-build`, `makepkg` and `pacman -Syu` come from
  live mirrors (`packaging/ci/package-and-test.sh:13-19`). `brew install icu4c` is
  unpinned (`.github/actions/setup-macos-stage/action.yml:44`), and ICU is linked into
  `foresight-model`.
- **Fix:**
  - Add the ignore rules and merge the grouped updates.
  - Centralise native pins in `tools/pins.json` with a consistency test.
  - Use a GitHub App token for bot PRs.
  - Use snapshot repositories for package jobs, pin or build ICU, and add a periodic
    reproducibility diff.

### 3.4 P3 findings

**F18. Documentation drift. Confirmed [C+T].**

| Claim | Location | Actual |
| --- | --- | --- |
| Desktop coverage gate is 76.35% | `README.md:376`; `CONTRIBUTING.md:33` | 90%, Linux only (`tools/build_dart_gates.sh:105-106`) |
| macOS PR CI enforces 90% core coverage | `README.md:376` | Minimum `0` and coverage off on PRs (`macos.yml:23-24`). The portable Linux lane does enforce 90%. |
| Migration table ends at v17 | `docs/architecture/schema-migrations.md:40-58` | `schemaVersion = 19` (`store.dart:31`): v18 adds content history, v19 adds manual title state |
| MCP tool list | `application-service.md:159-170` | 4 tools missing |
| Advanced OAuth configuration import | `README.md:80,353` | Removed; a test asserts it is absent (`google_setup_ui_test.dart:138`) |
| Release by pushing to main | `README.md:390-395` | Contradicts the PR-and-tag flow in `RELEASING.md:29-53` |
| Handler counts 75 and 8 | `application-service.md:174` | The test asserts 76 and 9 |
| ADR 0007 status "Proposed" | `docs/adr/README.md:13` | The record says Accepted |
| Desktop runner is Linux only | `apps/desktop/README.md:3` | A macOS runner exists |

Other documentation issues:

- 12 broken relative links (9 into the git-ignored `.granola-analysis/`).
- 7 unlinked documents.
- ADRs and RELEASING.md are missing from the docs index.
- `docs/plans/` holds 15 files (7.6k lines) with no status markers; some contain
  machine-local paths.

**Fix:** correct each item. Generate or CI-check the drift-prone facts: gates, the
migration table, the MCP tool table and handler counts. Add a link checker to
`quality.yml`, and archive the plans or mark each one with its status.

**F19. Diagnostic content and structure. Confirmed [C+T].**

- The opt-in invalid-frame trace includes raw malformed reply text
  (`service_client.dart:92-97`).
- `RpcError.from` sends `error.toString()`, which for a `FormatException` can include
  the source text (`rpc_error.dart:100-109`).
- About 50 free-form `stderr.writeln` calls, with no levels.
- No troubleshooting guide, no `ISSUE_TEMPLATE`, and no documented log locations or
  `FORESIGHT_SERVICE_TRACE`.
- The macOS `service-startup.log` is append-only (`service_startup.dart:697`).

Neither review found evidence that normal logging exports user data.

**Fix:** structured event names with request correlation, failure categories and
redaction; fixed messages for internal and format errors; a "Troubleshooting and bug
reports" guide; and an issue form.

**F20. No end-user trust or update channel, and no rollback. Confirmed and documented
[C+T].**

- Linux packages are unsigned and there is no package repository
  (`docs/platforms/linux-packaging.md:215-216`).
- The DMG is ad-hoc signed and not notarized. Signed, quarantined Finder launch and
  fresh-account permission attribution are unverified (`docs/platforms/macos-support.md:77-78`).
- There is no update check.
- The store correctly refuses newer schemas (`store.dart:196-200`), but no backup is
  taken before migrating.

**Fix:** Developer ID signing and notarization, plus Finder acceptance. Signed packages
or a signed repository. A `VACUUM INTO` snapshot before migrating, with a documented
rollback. A minimal update notice.

**F21. Security hardening. Confirmed by reading [T].**

- **Import TOCTOU.** `ImportPolicy.validate` checks the canonical path
  (`agent_access.dart:26-48`), then the file is re-opened by name
  (`source_operations.dart:184-189`; `document_parser.dart:117-135`). Fix: open from
  the root descriptor with `O_NOFOLLOW`, `fstat` it, and pass the descriptor to bwrap.
- **Helper liveness after upgrade.** On Linux, `/proc/<pid>/exe` gains a ` (deleted)`
  suffix after the binary is replaced, so the exact filename compare reports a live
  helper as gone (`foresight_native.cpp:1918-1923`). There is also no PID-reuse check.
  Fix: compare device and inode, and check the process start time.
- **Approval-dialog spoofing.** Argument values are joined with newlines and shown
  unescaped (`apps/desktop/lib/agent_approval_surface.dart:138-181`). Fix: a key/value
  table with control characters escaped.
- **Native spawn robustness.**
  - Child output is buffered without limit (`foresight_native.cpp:1047-1057,1489`).
  - `posix_spawn_file_actions_*` return values are unchecked
    (`foresight_native.cpp:283-301`).
  - `posix_spawnp` falls back to a bare name and searches `PATH`
    (`portable_process.h:175,224`).
- **Credential files.**
  - The first `.desktop-capability` file is written before it is `chmod`ed
    (`application_service.dart:189-190`), whereas rotation stages the file safely.
  - The access token stays in `tokens.json` alongside the secret store.
  - A failed secret-store write silently falls back to a plaintext refresh token
    (`google_auth.dart:333-339`).
  - Note that `docs/architecture/credentials-at-rest.md` already documents the
    plaintext fallback [C]. The gap is that the user is not told.

**F22. Code-quality debt. Measured [T].**

- **Untyped Python.**
  - mypy uses only `check_untyped_defs` (`pyproject.toml:17-27`), and adding
    `--disallow-untyped-defs` reports 964 errors in 160 of 166 files.
  - `tests/` (67k lines) is not type-checked.
  - Fix: a typing ratchet per module, starting with the shared `ci_*` modules.
- **C ABI barriers.**
  - 35 hand-written `catch (...)` blocks across 31 exports, while `ffi_barrier`
    (`native/exception_barrier.h:47`) has 0 uses in `foresight_native.cpp`.
  - Fix: route every export through it and test for unguarded bodies.
- **Python import mechanisms.**
  - `from tools.` imports without a `tools/__init__.py` (400 uses), `sys.path.insert`
    in 84 files, and 38 `spec_from_file_location`/`runpy` loads. Together they force
    108 `noqa: E402`.
  - Fix: make `tools` a package and run scripts with `python -m`.
- **Duplicated helpers.**
  - `def digest` exists 9 times and `def run` 14 times.
  - Fix: a shared `tools/_common.py`.
- **Opaque smoke errors.**
  - 32 bare `"Verification failed"` raises (`packaging/smoke_installed.py`,
    `tools/smoke_macos_bundle.py`).
  - Fix: a `require(cond, msg, **observed)` helper that reports the observed values.
- **Complexity and strictness.**
  - 111 functions exceed ruff C901 complexity 10.
  - Core lacks `avoid_dynamic_calls`, which the desktop enables (11 sites).
  - `-Werror` is set only on the helper target, and there is no clang-tidy.

**F23. Lower-severity reliability and architecture risks. Confirmed by reading [T].**

- **Read worker.** `sqlite_read_worker.dart:28,85-87` caches `_starting` permanently,
  so there is no respawn after the worker exits. Reads run one at a time, and SQL is not
  interrupted when a deadline passes.
- **SQLite.** No `busy_timeout` on Dart connections. `importText` runs two statements
  without a transaction (`source_store.dart:52-66`).
- **Socket writes.** They ignore backpressure (`service_message_writer.dart:64-66`).
- **Native ABI version.** `fs_abi_version` is exported but never checked from Dart.
  The helper version uses exact string match only (`helper.dart:24`).
- **Design.**
  - Per-entity data is stored under `preferences` key prefixes, with no foreign keys.
  - The ambient `runtimeConfiguration` global is read at 52 sites.
  - One six-module import cycle runs from persistence through answer retrieval to the
    desktop reader.

**F24. CI system weight and change size. Measured [T].**

- About 16k lines of CI Python, about 23k lines of CI tests, and 6.2k workflow lines.
- Three 30-minute crons, which ran 136 times in about 2.5 days.
- Intricate recovery rules (`RELEASING.md:243-305`) and leftover transitional triggers
  (`arch-drift.yml:5-8`).
- A 14.7 MB evidence tarball is committed in git
  (`tests/fixtures/ci-acceptance-failures-20261020.evidence.tar.gz`).
- Commits `75898380` (504 files) and `294b2b03` (411 files) break the AGENTS.md rule of
  about 100 files per PR.
- **Fix:**
  - Freeze CI tooling scope and retire transitional mechanisms, and reduce cron
    frequency.
  - Enforce PR size in CI.
  - Move large fixtures to LFS or a checksummed release asset.
  - Generate the per-operation boilerplate, and derive the asserted counts from the
    registry.

**F25. Sanitizer and native coverage gaps. Confirmed [C+T].**

- `run_native_sanitizers.sh:14` sets `detect_leaks=0` globally.
- TSan stays on probation until **2026-10-25 UTC** (`native-sanitizers.yml:195-214`).
  Until then it should not be described as an unconditional PR gate.
- There is no numerical C++ line or branch coverage.
- Core and desktop coverage are gated only on Linux.
- **Fix:**
  - Enable LSan with a CPython suppression file.
  - Confirm the TSan probation actually expires.
  - Add a report-only llvm-cov build.
  - Add a macOS coverage floor, or state explicitly that macOS coverage is not gated.
  - Do not combine Python and Dart percentages into a repository-wide figure [C].

## 4. Agreed strengths

These were independently credited by both reviews unless tagged otherwise.

- **Ownership and boundaries.**
  - One service owns database writes, the helper and native runtimes.
  - The desktop receives a curated API, checked by an analyzer-based boundary test
    (`packages/foresight_core/test/desktop_boundary_test.dart`) and by desktop
    architecture checks.
  - The operation registry is exhaustive and disjoint
    (`test/typed_operation_registry_test.dart:25-50`), and MCP tools are generated from
    operation descriptors (`lib/src/mcp/rpc_tools.dart:30-52`).
- **Concurrency correctness [C].**
  - Generation reservations are held until producers settle
    (`application_services/generation_coordinator.dart`).
  - The read coordinator binds results to owner, profile, connection, epoch and
    revision, and keeps tracking SQLite work after subscriber deadlines
    (`read_coordinator.dart`).
- **Local trust boundary.**
  - Peer identity comes from `SO_PEERCRED`/`LOCAL_PEERCRED` plus an executable-identity
    check (`unix_peer_identity.dart`).
  - Approvals are rotated, expiring and rate-limited, require a visible host, and are
    scoped to their owner (`agent_access.dart`).
  - Packaged builds ignore code-path environment overrides.
- **Untrusted input.**
  - Web import uses DNS-pinned connections with every redirect re-checked, size and
    type caps, and isolate parsing (`web_import.dart`).
  - Extraction is confined with bwrap on Linux and `sandbox_init` on macOS.
  - Generated Markdown never fetches remote images.
- **Persistent data.**
  - Migrations run in one transaction against frozen historical closures, with real
    SQLite crash fixtures, and newer profiles are refused (`store.dart:69-101`).
  - Startup recovers interrupted meetings and indexing.
  - Privacy maintenance intent survives a deferred checkpoint or VACUUM [C].
  - Helper indexing is atomic, with the search snapshot published after commit [T].
- **Process hygiene [T].** An ownership pipe makes the supervisor kill the worker
  process group when the owner dies (`native/portable_process.h:96-155`).
- **Verification.**
  - Python coverage is 95% line and branch, with subprocess instrumentation. Core and
    desktop gates are 90% each on Linux.
  - Integration gates require an exact count, zero skips and a final event
    (`tools/integration_gates.py`).
  - Skip and exclusion inventories are themselves tested.
  - ASan, UBSan and TSan run with positive-control probes.
  - Real-model and virtual-audio containers run without network access.
  - No mock frameworks, and no test retries.
- **Release integrity.**
  - Release candidates are built from an exact commit.
  - Producer context, source and workflow identity are attested
    (`tools/ci_producer_trust.py`; `tools/ci_release_attestation.py`).
  - Uploads reject a conflicting existing asset (`tools/release_upload.py`).
  - Installed acceptance runs on Ubuntu, Debian, Fedora, Arch and macOS, with
    N-1→N upgrade checks.
  - Each installer gets an SBOM and provenance attestation.
- **Pinning.**
  - SHA-pinned actions are enforced at the repository level, and all checkouts use
    `persist-credentials: false`.
  - Base images are digest-pinned, Ubuntu packages come from a snapshot, and native
    sources are commit-pinned.
  - Python locks are hash-pinned, and pub runs with `--enforce-lockfile`.
- **Static quality [T].**
  - `ruff`, `mypy`, `dart analyze`, `flutter analyze` and `dart format` are all clean.
  - Suppressions are few and explained, and there is one TODO (from the Flutter
    template).

## 5. Recommended sequence

1. **F1 first.** Make capture teardown unconditional and add storage-fault regressions
   for Stop, hide and disconnect. Release `recording` before indexing (F6), and guard
   transcript-write failures (F9).
2. **Live-meeting cost (F2, F3).** Exclude transcripts from `content_revisions`, add
   retention, and switch live indexing to append-only chunks. Measure with
   `tools/measure_service_rpc.py` before and after.
3. **Independent narrow fixes.** Reject duplicate request IDs (F5). Add acquisition
   deadlines with stalling-transport tests (F7). Make the capture FIFO honour `TMPDIR`,
   and move the install lock to a per-user directory (F8).
4. **Diagnostics (F4, F19).** A persistent, bounded, redacted service log with stderr
   tails, a troubleshooting guide and an issue form.
5. **Process controls, with owner review (F10, F11, F17).** Protected release
   environment, CODEOWNERS, a manual-acceptance receipt bound to installer hashes, SBOM
   or native-pin vulnerability scanning with assigned triage, and merging the stalled
   updates.
6. **Verification (F12, F25).** The compiled first-run acquisition journey,
   de-flaking the proactive test, correct exclusion reasons, LSan, native coverage
   reporting, and a decision on macOS coverage.
7. **Documentation (F18).** Correct the drift and add drift checks plus a link checker.
8. **Structural work (F14, F15, F16, F22, F24).**
   - Split client and server barrels, replace the `Domain` locator, and add a
     single-owner generator slot.
   - Move model setup into the service and extract controller widgets.
   - Asynchronous native teardown with an ownership protocol.
   - Python typing ratchet, `ffi_barrier` everywhere, and a freeze on CI tooling growth.
9. **Distribution (F20).** Signing and notarization, signed Linux packages, a
   pre-migration backup and an update notice.

Every runtime change still needs the full checks in AGENTS.md:

- native CTest from the root build;
- core and desktop suites against the freshly built native library and helper;
- the core coverage gate;
- the compiled service/MCP suite;
- isolated-display desktop integration tests.

The source checks run for these reviews do not replace them.

## 6. Validation record

| Check | Review | Result |
| --- | --- | --- |
| `python tools/check_subprocess_timeouts.py` | C | Passed; 368 Python files inventoried (static AST policy check) |
| `python tools/check_integration_inventory.py` | C | Passed; 40 Dart skip registrations and 24 probe entries have validation paths (not executed) |
| `pytest -q -rs` | T | 5,511 passed, 57 skipped, 3 failed, 24 errors, 1,395 subtests passed. All 27 failures and errors were `FileNotFoundError: 'cmake'` (no CMake on the host). |
| Dart core (`tools/run_core_tests.sh`, no native library) | T | 2,101 passed, 41 skipped, 1 failed (load-sensitive; F12). 28 skips are for the missing native library or helper, 9 are macOS-only. |
| Flutter desktop (`flutter test --coverage`, test hooks on) | T | 556 passed, 17 skipped, 0 failed; 93.70% line coverage, above the 90% gate |
| `ruff check .`, `mypy` | T | Pass (166 files) |
| `dart analyze` (core), `flutter analyze` (desktop), `dart format --set-exit-if-changed` | T | No issues; 0 of 718 files changed |
| Strictness probes (Dart strict modes, mypy strict flags, ruff C901) | T | Metrics only (F22) |
| Repository rulesets, environments and Actions settings; OSV run log; Dependabot history (`gh`, read-only) | T | Reported in F10, F11, F17 |
| Markdown link check (71 files, 217 relative links) | T | 12 broken |
| Controller library line counts | C, re-checked | 3,108 (meetings), 3,076 (sources) |
| History trigger and upsert simulation (synthetic SQLite, outside the app) | T | 600 rewrites → 120 KB transcript, 36.3 MB history |
| Consolidation re-check of single-source findings | — | Source re-read for F2, F4, F5, F7, F8, F11 (manual checklist), F12 (onboarding helper), F14 and F15 |

Environment notes:

- Both reviews used Python 3.14.8; the project supports 3.13.
- Both used private, mode-0700 `/var/tmp` roots as `TMPDIR` and
  `FORESIGHT_TEST_TEMP_ROOT`.

**Not executed.** None of the following should be read as passing:

- Native CMake build and CTest, sanitizers, the compiled service/MCP suite, the
  isolated-display UI suite, and the model and virtual-audio integration gates.
- Docker builds and installed-package acceptance, actionlint, ShellCheck, zizmor and
  clang-tidy.
- Anything on macOS: Core Audio, Keychain, TCC, signing, Gatekeeper.
- Physical audio and GPU, OS permissions and sleep/wake.
- Disk-full fault injection for F1, and stalled-transport reproduction for F7.
- Any latency or throughput measurement of this commit.
- `gh attestation verify` against released assets.
- Native-backed Dart tests. These were deliberately not run against installed
  `/opt/open-foresight` binaries, because those are not a fresh build.

Source review cannot certify that no other defects exist. No application code, tests,
configuration, workflows or release policy were changed. Nothing was committed.
