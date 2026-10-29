# Explicit integration gates

The regular Flutter suite intentionally does not load multi-GB models, start an
original application, or use a personal profile. These checks have explicit
validation paths rather than treating a skipped test as acceptance.

## Failure investigation and qualification

These practices come from the service work in
[#180](https://github.com/teng-lin/open-foresight/pull/180) and the saved-audio
qualification in [#189](https://github.com/teng-lin/open-foresight/pull/189).
They describe how to establish evidence; they do not declare the unresolved
failures in those investigations fixed.

### Keep the original failure authoritative

Before replaying a failed case, preserve its command, source revision, tool
versions, environment differences, expanded output, test events and subprocess
output. Give the investigation an owner and an exit criterion. Run the exact
failed consumer first, with the original instrumentation and execution mode.
A quiet isolated pass is diagnostic evidence, not proof that a concurrent
failure was harmless or caused by load. Do not call a failure flaky solely
because it did not recur.

Use one controlled probe for a concrete hypothesis, preserving the original
assertions and deadlines. If the probe cannot establish a cause within the
agreed scope, retain the failure as unconfirmed and report the remaining gap.
Keep invalid experiments too, with their reason for rejection. For example,
creating an HTTP request in one Dart error zone and awaiting its result in a
different error zone did not provide a valid comparison of error observers.

When a fixture pattern is wrong, inspect sibling call sites before another full
run. The audio investigation initially corrected one immediate reopen while
other positive restart fixtures still used the same incorrect operation.
Audit the whole class, preserve intentional negative controls, verify the
affected modules, then freeze a revision for the required full gates. Do not
alternate one-line fixes and expensive full runs for equivalent defects.

### Test ownership through independent fences

| Observation | What it establishes | What still needs proof |
| --- | --- | --- |
| A positive child PID exited and was reaped | That exact child ended | Supervisors or inherited descriptors may still hold resources |
| An authenticated refusal receipt has no child PID | No child was admitted through that path | Do not call `waitpid(-1)` or signal a sentinel PID; verify the refusal's actual cleanup contract |
| The real owner lock can be acquired | The last conflicting kernel lock reference was released | A lock file's presence or absence alone establishes neither ownership nor release |
| A readiness marker exists | Only that the marker was published | Its complete payload and the actual consumer phase must also be established |

Publish fixture readiness atomically after writing and checking its complete
payload. Observe child exit and resource release separately within one total
monotonic deadline. Cleanup must address the owned child safely even if a
negative control accidentally reaped it; use stable process identity where
available rather than signaling a potentially reused numeric PID.

Positive media restarts use `RecordingMedia.acquire`, the bounded production
admission path. An unrelated fork can briefly inherit a close-on-exec descriptor
until exec, even after the local owner closes. Acquisition may retry only actual
checked kernel contention. Keep synchronous `RecordingMedia.open` assertions
where the test intentionally proves immediate refusal. A reader held beyond the
bound, cancellation, and non-contention lock failures must still be rejected.

### Use the shared ownership helpers for child processes and barriers

`foresight_test_support/fixture_ownership.dart` holds the patterns above so
fixtures do not rebuild them:

- `OwnedCleanups` registers each step when its resource is allocated and runs
  them newest first. Every step is attempted, each is bounded, and all failures
  are reported together in one `FixtureCleanupFailure`, so a late failure cannot
  replace the first. `OwnedCleanups.forTest()` runs at the test's teardown.
- `OwnedProcesses.start` returns an `OwnedProcess` already registered for
  termination (SIGTERM, bounded wait, SIGKILL, bounded wait for the kernel
  exit). SIGKILL also ends a stopped or TERM-ignoring peer. Termination of an
  unobservable exit fails the cleanup instead of passing quietly.
  `expectNoneRunning` names owned children whose exit is unobserved. Only
  processes the fixture started are tracked or signaled; the helper never runs
  `ps` or walks process groups, so concurrent test files are not inspected.
  It does not detect leaked descriptors or sockets.
- `PhaseTrace` records the phases a fixture actually observed. Its `describe`
  keeps the last observed phase apart from a caller-supplied inferred pending
  operation, which it labels as not observed. `awaitMarker` waits for a marker
  file within exactly its stated deadline and adds that trace and the owning
  child's state to a timeout.
- `eventually` accepts `label` and `describe`. Neither changes the deadline;
  `describe` is sampled once, at the deadline, so the failure says which part of
  a compound condition was missing. Only the type of an error thrown by
  `describe` is reported.

These add diagnostics and cleanup. They are not retries and do not extend any
budget. A failure message that names a phase is evidence for investigation; it
does not establish the cause of a failure that has not been reproduced.

### Caller audit of the shared helpers

Counts are from a text search of every Dart file under `packages/*/test`,
`apps/*/test` and `apps/*/integration_test` at the head that added this table
(534 files). They locate candidates; no file below was reviewed line by line,
and "risk" names what a failed test could leave behind, not an observed failure.
Untimed `exitCode` counts include `ProcessResult.exitCode` and so overstate.

| Pattern | Sites | Using the shared helpers |
| --- | --- | --- |
| `Process.start` | about 120 in 53 files | 2 files (`model_transport_cancellation_ownership_test`, `fixture_ownership_test`) |
| `Process.run` / `runSync` | about 235 (mostly short `chmod`, `ps`, `kill -0`) | not applicable: finished before return |
| `eventually` | about 357 | fewer than 10 pass `label` / `describe` |
| Hand-rolled child cleanup in `foresight_test_support/lib` | `native_fixture.dart`, `hooked_service.dart`, `gated_helper.dart`, `capture_process.dart` | none |

Migrated for the nightly failures of
[#190](https://github.com/teng-lin/open-foresight/issues/190): every
`Process.start` in `model_transport_cancellation_ownership_test`, the waits of
the native close test in `storage_worker_session_test`, and the admission-lock
evidence added on top of [#194](https://github.com/teng-lin/open-foresight/pull/194)'s
bounded fixtures in `storage_worker_protocol_test`. The rest is a backlog,
ranked by the number of un-reaped or un-bounded patterns per file, not by
evidence of failure.

Already migrated upstream, with their own helpers rather than the shared ones:
- [#189](https://github.com/teng-lin/open-foresight/pull/189):
  `model_acquisition_transport_boundary_test` (`_assertHandshakeCancellation`
  joins the real worker before an entry failure escapes, and accepted sockets
  are observed).
- #194: `OwnedRpcServer` (`test/fixtures/owned_rpc_server.dart`) owns a fixture
  peer's listener, accepted sockets and serving futures, registers its close at
  bind, and retires unfinished HTTP/2 streams. `service_lifetime_test` and
  `service_idle_shutdown_test` use it; `storage_test` isolates the remaining
  direct classification fixture in an owned child, and the protocol and session
  fixtures bound positive admission on checked contention.

`OwnedRpcServer` owns servers and sockets; `fixture_ownership.dart` owns child
processes, cleanup order and phase evidence. They do not overlap, and neither
needs the other. Do not add a second owner to a migrated file; adopt the shared
`OwnedCleanups` there only if a later failure implicates it.
Migrate a file when a failure implicates it; do not rewrite them in bulk.

| Rank | File | Process owner | Sockets, streams, pending work | Risk if the test fails |
| --- | --- | --- | --- | --- |
| 1 | `restore_activation_test` | 5 starts, hand-rolled `kill` (7) and `finally` (7) | 2 stream listeners; 24 `exitCode` references, most untimed | A wait after SIGKILL has no bound or phase; a hung child blocks the test run |
| 2 | `service_closing_protocol_test` | 21 starts, each in its own `finally` (21) | 2 sockets; 11 `eventually` without evidence; 3 untimed `exitCode` | A start whose `finally` is skipped by an earlier throw leaks a service |
| 3 | `service_profile_identity_test` | 18 starts, 13 teardowns | 11 sockets; 11 untimed `exitCode` references, several in teardowns | Teardown awaits a killed child without a bound |
| 4 | `service_shutdown_handoff_test` | 1 start, 25 `finally` blocks | 2 sockets; 11 `eventually` without evidence | Wait failures carry no phase; shutdown ordering is not recorded |
| 5 | `helper_process_recovery_test` | 1 start, 4 `kill` | 5 `eventually` without evidence; 7 untimed `exitCode` references | Kill-then-await without a bound |
| 6 | `desktop_peer_process_test` | 3 starts, 2 `kill` | 4 sockets, 3 listeners; 5 untimed `exitCode` | A peer started before an assertion can outlive it |
| 7 | `service_connection_test` | 1 start | 9 sockets, 5 listeners; 11 `eventually` without evidence | Socket and wait failures are indistinguishable |
| 8 | `file_parser_test` | 9 starts handed to the production parser; no `kill` | none | The parser is the only owner; a parser failure leaves the helper to the OS |
| 9 | `foresight_test_support/lib/native_fixture.dart`, `hooked_service.dart`, `gated_helper.dart` | own SIGTERM/SIGKILL; `native_fixture` awaits `exitCode` unbounded after SIGKILL; `gated_helper` signals a recorded pid after matching its command | none | Unbounded reap; pid-based signaling instead of an owned handle |
| 10 | `remote_domain_test` (57 `eventually`), `recording_storage_failure_test` (16) | none | many pending operations | Failures say only that the 3 s deadline passed |

### Known gap: diagnostic admission treats any lock errno as `retry`

`DiagnosticStorage.admit` and `classify` take `admission.lock` with the
unchecked `tryExclusiveLease`, so a non-contention `flock` errno is reported the
same as contention: `admit` returns null and the worker answers `retry`. The
checked lease distinguishes them, but it reads errno in a second FFI call, which
is not a reliable errno read in Dart
([dart-lang/sdk#38832](https://github.com/dart-lang/sdk/issues/38832)); a
misread EWOULDBLOCK would mark the sink failed and disable it permanently.
Production is unchanged here. The recommended follow-up is a native shim that
returns the `flock` result and errno together. #194's protocol fixtures retry a
`retry` reply only after an independent checked probe confirms kernel
contention, so a non-contention errno fails the fixture; production still
reports it as `retry`. `admission_lock_evidence.dart` adds a post-failure probe
to those failures and does not claim that a `retry` was contention. The cause of the intermittent `retry` seen when suites
run concurrently in one process is unknown; a fork in another suite keeping a
closed lock description alive until exec is a hypothesis, not a finding.

### Make timing and error tests prove their intended phase

A short total budget can expire during connection setup before a retry-delay
test receives its first response. Such a failure has not exercised retry delay.
Establish the real connection as fixture setup, then begin the measured
operation and assert that the request, close and retry-delay callback actually
ran. Preserve separate cold-connection tests and the original measured budget;
do not increase a deadline to make scheduling assumptions pass.

An already-started Future can fail during cleanup even if a deadline or admission
check throws before the normal await is installed. Observe that Future before
the throwing check. Calculate the deadline before creating an aggregate Future
that could otherwise be abandoned. Side observers must not replace the normal
await or suppress the error returned to the caller. Create the controlled
operation inside the same error zone that records uncaught errors, prove the
old implementation fails, and require both the expected caller failure and zero
unexpected asynchronous errors after the fix.

For shutdown, a final ownership warning may replace an earlier close-stage
exception. Record the first failing stage and error type before replacement;
do not infer native-retirement failure from the terminal message alone. Private
diagnostics should use fixed stage/category values, preserve shutdown ordering,
and exclude request text, audio, tokens and profile contents. An existing
diagnostic compatibility function may intentionally discard its message: verify
what the consumer records before relying on a trace flag.

### Qualify the entrypoint and the bytes

Private local setup is not a substitute for a working checked-in launcher.
Required environment such as `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT` must reach
every applicable native, sanitizer and service entrypoint. Validate absent or
invalid inputs before constructing paths; missing environment must produce a
useful failure rather than a null-pointer crash. Use private short directories
with normal umask `022`, so negative permission checks remain meaningful.
Check the ownership and mode of each runtime directory the consumer validates;
a private ancestor does not make a newly created child directory mode `0700`.

Exercise standalone CMake configuration with its declared dependencies as well
as the root build. A host-installed JSON package can hide a missing prerequisite
in Python configuration tests. Check the intended failure message: a nonzero
exit caused by missing dependencies does not test an invalid installation path.
Minimal-host configuration and sanitizer execution are distinct evidence from
an ordinary developer build.

Required feature backends must fail configuration when their development files
are missing or too old. A successful build with an optional-backend warning can
ship a feature that fails before receiving its first sample. Inspect the first
native error from the qualified artifact, then exercise each affected route
with the rebuilt library. Legacy raw capture does not qualify durable capture's
graph-clock backend. Keep application tooling dependencies, runtime package
dependencies and configuration-only fixtures explicit and independently checked.

Check timestamp bounds across the native writer and the actual database span,
including resumed spans. A fast first raw buffer can have a drain estimate before
the span even when it is within the meeting's clock origin. Sync and WAV-header
validation do not establish that publication accepts that interval. Preserve the
distinction between fallback estimates and device acquisition timestamps.

Record source revisions separately for production code, changed fixtures and
the final tested candidate. Reusing unchanged native/codec products requires
checking their relevant source inputs and hashes; it is not a fresh build.
Production Dart changes require rebuilding the affected AOT and GUI products.
For package checks, run the actual installed loaders and executables with owned
profiles, then verify file/symlink inventory, hashes and signatures again.
Every new bundled dependency must reach the license inventory and each affected
package format's validation. A successfully assembled application directory or
macOS bundle does not prove DEB, RPM or Arch assembly accepts its added files.
Preserve strict unmapped-license failures; update the reviewed mapping rather
than dropping notices or weakening the inventory.

Likewise, widget tests and Linux UI acceptance do not establish macOS layout.
Exercise the actual desktop flow at the supported viewport and display settings,
including added recording controls. A small Flutter overflow is still a real
acceptance failure; do not suppress framework errors to obtain a passing journey.

Reports must distinguish the full gate from focused replays and applicable
subsets. Include pass/fail counts, skips, deselections, coverage status and
unexecuted environments. If tests fail before coverage generation, do not use an
older LCOV file as current qualification. A headless subset does not satisfy an
isolated native GUI gate. Do not fabricate display flags or use a personal
desktop to turn a missing runner prerequisite into a pass. Preserve local and
hosted results separately; new CI failures remain blockers even when local
checks passed. Keep a PR in draft while required qualification remains unresolved.

### Failure ledger

Work package 5 of [#192](https://github.com/teng-lin/open-foresight/issues/192)
asks for a named owner, a bounded next experiment and a concrete exit criterion
for each active failure. Every entry starts as UNKNOWN until evidence supports a
class. The class is one of product, fixture, environment, dependency, artifact
or UNKNOWN. Status is `open`, `mitigated` (diagnostics or a control added; the
original failure is neither explained nor reproduced at its source) or `closed`
(the exit criterion was met). **A successful rerun does not close an entry.**
Owner is "unassigned: needs named owner" until a person is named.

Source for every entry: nightly run
[40510685655](https://github.com/teng-lin/open-foresight/actions/runs/40510685655)
at `f7c06383`, tracked by
[#190](https://github.com/teng-lin/open-foresight/issues/190). Job-to-test
assignments are from the triage of that run, not re-read from raw logs here.

| ID | First job | Class | Exact error | Owner | Next bounded experiment | Exit criterion (controlling test) | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| L1 | `macos-checks (core)`, with coverage | UNKNOWN | `storage_worker_session_test` "busy native close cannot overtake a held late summary acknowledgement": `eventually` hit its 3 s deadline (~line 351) on `owner != null && owner.sink.records.isNotEmpty`. Passed on Linux. #194 since rewrote the test (waits for the native adapter first, prints setup state on failure, adds a delayed-setup variant). #200 found for a sibling, `native_queue_adapter_test`, that an idle cold native writer need not have drain credits until a bootstrap enqueue is admitted; whether that applies here is untested | unassigned: needs named owner | 200 runs of the file on macOS with and without coverage; read the owner-state line (and #194's `native_summary_setup_failure` line) | The loop either names the phase (owner never created vs created with empty records vs later wait) or shows zero failures in 200 runs per mode. Controls: "summary wait evidence separates a missing owner from empty records" | open: evidence added, cause unconfirmed |
| L2 | `linux-native / core-linux` | UNKNOWN | `storage_worker_protocol_test` "filesystem fixture writes only validated schema2 and closes before retirement": `classify` returned `retry`, expected `ok` (the test now runs as `contended=false/true` variants since #194) | unassigned: needs named owner | Run the concurrent loop (four simultaneous copies of the protocol, session and transport suites) on the Linux host against the #194 fixtures; collect the `admission.lock post-failure probe` lines from any exhaustion failure | The lock holder is named, then a deterministic control reproduces it. Before #194, reproduced locally on macOS only as the symptom: the unmodified base `1d208f31` failed "duplicate manifest fields stay occupied…" once in 60 (`admit` returned null), and with evidence in place later concurrent loops (about 240 runs) showed `admit` returning null with the probe `held` four times, `classify` returning `retry` once (probe `free`) and the post-retirement slot lease unavailable once. On Linux, with an extra 5.5 s control spawning a worker in a parallel isolate of the same VM process, the target test's post-retirement slot-lease assertion failed in 2 of 10 serial runs (second checked attempt observed `held`), against 0 in 50 runs without that control. Hypothesis, not finding: a fork in another suite keeps a closed description alive until exec. Production gap: a non-contention errno is also reported as `retry` (see the known-gap note) | mitigated: #194 bounds the fixture on independently checked contention; holder still unidentified, concurrent loops against the #194 fixtures not yet run |
| L3 | `linux-test` | UNKNOWN | `model_transport_cancellation_ownership_test` "broken config pipe preserves retry admission after confirmed exit": `TimeoutException` after 5 s where `RpcError` was expected (~line 458) | unassigned: needs named owner | Run the test file on the Linux host 200 times with and without a CPU load; read the phase line on any failure | Main already separated a 5 s setup wait from a 5 s retirement wait (from #189); the shared bound was the `f7c06383` version. This branch adds a cold start with its own 15 s setup budget ("a cold worker launch is setup with its own budget…"), a retirement that never settles still failing at its bound with its phase ("a retirement that never settles…", shortened to 100 ms in the control only) and "closed-stdin worker settles cleanup while paused". The 5 s failure of the same cold start (default setup bound, phase `launched`) was observed manually and is not encoded in a test: a fork-heavy 5 s control added spawn pressure to the shared VM process and made the admission-lease flake appear on Linux (see L2). The original shared-bound failure is not reproduced. Hypothesis only: cold launch and retirement shared the budget | open: fixture hardened, original cause unconfirmed |
| L4 | `acceptance-deb` | dependency (transient, per triage) | apt: `File has unexpected size (219540 != 3013728). Mirror sync in progress?` | unassigned: needs named owner | Reproduce the message with a fixture mirror serving a short package; read how the acceptance entrypoint classifies it | A simulated size mismatch is reported as dependency setup failure and retains its output, and a genuine `.deb` install failure is still a product failure. No control exists yet | open |
| L5 | `acceptance-checks`, `macos`, `platform-checks`, `nightly-checks` | consequence | Aggregates of L1 to L4 | not applicable | none | Go green when L1 to L4 are closed; a green aggregate alone closes nothing | consequence only |

Reliability measurement uses the existing CI statistics: first-attempt pass rate
with its denominator, recurring failures by boundary, and time to diagnose. Keep
platform, selection, execution mode and cold or warm cohorts separate, and label
qualification repeats. No dashboard is built for this.

## Regular pull-request gates

`macos.yml` keeps the existing required platform-checks aggregation. Its Linux
job now installs pinned Flutter 3.35.7 and runs core, desktop and native tests,
including a real desktop/service/MCP session under Xvfb/D-Bus with controlled
capture and inference fixtures. The Mac job also explicitly enables that native
UI fixture. A requested UI gate without a platform runner fails rather than
skipping. The compiled UI denies an MCP recording request, verifies that capture
stays inactive and no transcript is created, then requires a fresh approval for
a retry. This covers the application's recording approval boundary; actual OS
permission dialogs and physical audio are not exercised by those fixtures.
The same test then substitutes an owned capture executable that exits with a
permission-denied diagnostic. It verifies that native failure automatically
closes capture, persists an interrupted meeting without losing saved audio or
transcript, and leaves the
warning visible through later status updates. Restoring the executable permits
a fresh capture, which is stopped through the visible desktop control.

The separate `linux-document-imports` job requires one Python contract that
imports both PDF and RTF fixtures through the production Dart parser on an
Ubuntu host. It provisions the actual extractors, requires the sandbox to start,
and fails on missing prerequisites. Its result is required by `platform-checks`;
local runs missing required executables report a skip. See the
[document sandbox](platforms/linux-packaging.md#document-import-sandbox) for
the host-policy setup and retained evidence.

The generation-failure regression runs normally on both supported platforms.
It uses a short private `/tmp` directory for Unix sockets. After the Linux build,
`integration_gates.py --suite fast` runs that regression and the terminal capture
failure test with an owned failing pw-record executable. Neither needs a model
or physical microphone.

## Model and virtual-audio acceptance

In the held consolidated successor, relevant PR, main and nightly selections run
`acceptance-cpu`, `acceptance-audio` and `acceptance-deb` in `macos.yml` after the
successful in-run application producer. They consume its exact qualified bytes
without rebuilding an application. Main uses the per-merge candidate until WS5b;
nightly uses its labelled preview. Weekly drift consumes a green same-source
preview, without a new application build. The former
`integration-acceptance.yml` workflow is removed. This graph remains local until
the plan's hosted shadow gates pass. Acceptance receives no distribution secrets.
Public model fixtures retain the checksum-pinned Gemma E2B, EmbeddingGemma and
Whisper definitions already used by installer acceptance. The dedicated main
`publish-caches` job owns the Linux acceptance-tools registry cache and
`integration-models-v1`; the existing preview and release acceptance model-cache
writers retain their separately guarded contracts.

Runtime containers have no network, additional capabilities, host session
sockets or sound-device mounts. Virtual audio refuses to run if `/dev/snd` is
present; it creates a private runtime/home, PipeWire/Pulse/WirePlumber session,
null sink and remapped virtual source, disables hardware monitors, and stops
owned daemons on exit. LiteRT compilation caches live in a temporary directory
separate from the read-only model fixture mount.

| Group | Required executed tests | Scenarios |
| --- | --- | --- |
| Linux fast | 2 desktop | Generation failure; terminal capture failure persists through stop. |
| Models | 5 desktop + 1 core | Native load/late adoption, helper grounding/restart/deletion, meeting citation, local Google OAuth/API fixture into real retrieval, Gemma cancellation/reuse, controlled web-tool generation/memory. |
| Virtual audio | 3 desktop + 1 core | Whisper partial/final text while capturing, virtual microphone disappearance/return, overlap/pause exclusion and pinned-route recovery, and the meeting workflow (record, transcribe, summarize, cite, restart). |

That meeting workflow is `apps/desktop/integration_test/meeting_workflow_test.dart`,
run by the virtual-audio gate using `flutter test -d linux` inside the private
PipeWire session and an owned Xvfb server. It compiles the desktop test harness
from current Dart/runner sources, reusing the SDK and the verified bundle's
service, helper, inference libraries and model fixtures. No SDK or model rebuild
is needed for these test changes. The acceptance-tools image adds only Xvfb and
ImageMagick to its existing test prerequisites.

Native screenshots use ImageMagick's `import` on that server's root window.
They must be 1280×720 and pass the existing background and graph-selection pixel
assertions. The server chooses a free display, removes inherited display/session
settings, disables TCP listening and is stopped even if the test fails. The
summary identifies the compiled runner and screenshot backend. Older explicit
widget-only invocations still skip screenshots and must not be reported as native
UI acceptance. `tools/test_meeting_workflow.py` remains the local driver for an
owned Wayland display. Path filters that skip the job also skip this meeting
workflow; desktop app, application service and packaging changes select it.

The three older generation tests explicitly select LiteRT by default; an
explicit `FORESIGHT_GENERATION_BACKEND` can select a legacy runtime. The load
failure fixture uses a missing model because packaged LiteRT configuration may
replace a supplied runner path. The public-model checks do not exercise live
Google consent, web services or account data.

Each selected Dart group writes expanded logs, JSON test events and a summary.
A zero exit status is insufficient: the runner requires the exact expected
number of executed passing tests, no skips, and a successful final reporter
event. Stale event files are removed before a run. Artifacts are retained even
when a gate fails; the job stays failed if either model or audio checks fail.

Run against an already prepared bundle/model directory:

```sh
python tools/integration_gates.py --suite models \
  --bundle dist/open-foresight --models build/acceptance-models --output test-results/models
# Linux, inside a disposable container without /dev/snd or host session mounts:
dbus-run-session -- python tools/integration_gates.py --suite virtual-audio \
  --bundle dist/open-foresight --models build/acceptance-models --output test-results/virtual-audio
```

These jobs supplement installed-package acceptance; they do not prove physical
microphone/system audio quality, permissions, suspend/resume, or GPU fidelity.

## Live services

`live-services.yml` is separate from PR checks and runs only on `main`. Manual
dispatch executes the checks immediately; set repository variable
`FORESIGHT_LIVE_SERVICES=1` to enable the weekly schedule. Missing required
credentials fail a requested run with a `blocked` report rather than passing.
The workflow reuses the pinned Dart toolchain; it builds no native SDK, downloads
no model weights, and receives no personal application profile.

Provision a dedicated Google test account with a Google Doc containing a fixed,
non-sensitive marker. Complete consent once outside CI with this application's
Desktop OAuth client and its read-only Drive and identity scopes. Configure these
repository secrets:

| Secret | Value |
| --- | --- |
| `FORESIGHT_CI_GOOGLE_CLIENT_JSON` | That Desktop client's installed-client JSON. |
| `FORESIGHT_CI_GOOGLE_REFRESH_TOKEN` | The dedicated account's offline refresh grant. |
| `FORESIGHT_CI_GOOGLE_SUB` | Expected OpenID subject for that account. |
| `FORESIGHT_CI_GOOGLE_FILE_ID` | ID of the dedicated Google Doc. |
| `FORESIGHT_CI_GOOGLE_EXPECTED_TEXT` | Marker the exported document must contain. |
| `FORESIGHT_SEARCH_API_KEY` | Existing application search credential. |
| `FORESIGHT_WEB_CONTENT_API_KEY` | Existing application web-content credential. |

`packages/foresight_core/tool/verify_google_live.dart` uses production GoogleAuth
transport to refresh an expired credential, check the account identity, export
the expected document, and reopen its persisted authorization. All credentials
are kept in an owned temporary directory and removed after the run. It never
revokes the reusable CI grant. Reports contain statuses and error types, never
tokens, document text or account identifiers. The web step uses the existing
`verify_cloud_services.dart` search, website-summary and model-metadata checks;
it still runs if Google acceptance fails. Evidence includes the source SHA, run
and attempt and is retained on failure.

This smoke lane does not automate interactive Google consent, revocation, or
Google-to-semantic-index retrieval. The existing controlled Google/model group
covers the latter application's data flow. Interactive consent and revocation
need a separately provisioned account with a disposable grant; revoking a shared
scheduled credential would invalidate future runs.

## Physical-device release acceptance

Hosted virtual audio and software Vulkan remain separate from physical-device
evidence. This change does not provision a hardware runner or claim those paths
passed. Before adding a hardware job, provide a dedicated Linux/macOS runner with
an owned desktop session, a known speaker-to-microphone fixture, and the required
GPU. Reuse the installer and model artifacts already verified for that release.

| Scenario | Required observation on the dedicated runner |
| --- | --- |
| Physical microphone and system playback | Known speech appears on the intended channels; unrelated devices are not selected. |
| OS permission denial and revocation | Denial is visible, capture stops, existing text survives, and a subsequent grant permits a fresh recording. |
| Suspend/resume during capture | After actual suspend, recording recovers or reports interruption, without duplicated transcript segments or orphaned capture processes. |
| Physical GPU | Actual adapter identity, model startup/decode and known-audio transcription, bound to the tested installer digest. |

Use the existing manual probes below where applicable; keep per-scenario results
and logs tied to the installer checksum and source revision. Actual suspend and
OS consent must run on the dedicated machine, not be inferred from injected
lifecycle events. Until that runner is provisioned, record these cases as manual
or not run in release evidence.

## Restricted/reference and diagnostic paths

The remaining core cases need inputs that ordinary CI cannot distribute:

- Four dedicated-detector acquisition/runtime tests plus the application-level
  proactive-model test require an independently authorized, authenticated local
  detector asset. The proactive test now registers that detector instead of
  assuming chat-model substitution; it retains its English/Chinese assertions.
- Tokenizer equivalence needs existing original and port helper sockets.
- `saved_answer_native_test.dart` remains a manual diagnostic over an explicit
  private database copy and existing helper socket. Synthetic grounded answers
  and persistence are exercised by the automatic model group.

Nothing extracts or uploads a reference asset or personal database. To execute
the first two groups locally, provide the existing inputs explicitly:

```sh
python tools/integration_gates.py --suite reference-models \
  --bundle '/path/to/Open Foresight.app' --query-model /authorized/local/detector.tflite \
  --output /tmp/foresight-detector-evidence
python tools/integration_gates.py --suite reference-tokenizer \
  --bundle '/path/to/Open Foresight.app' --original-socket /path/to/original.sock \
  --port-socket /path/to/port.sock --output /tmp/foresight-tokenizer-evidence
```

`tools/integration_skips.json` records all Dart skip registrations, including
platform-only cases and native-library checks already enabled by the regular
core build. `check_integration_inventory.py` fails when a registration is added,
removed or changed without reviewing its path/reason. The scanner checks named
`skip:` registrations, not arbitrary control flow inside test bodies.

## Reading validation evidence

Executed-test counts for each group are enforced by
[`tools/integration_gates.py`](../tools/integration_gates.py). The workflow
invokes model and virtual-audio groups separately. A green offline suite does
not prove these build-dependent groups ran.

Use the retained Dart JSON reports and summaries for the source revision under
review. They distinguish executed passes, skips, and failures. The skip inventory
validates registrations; rerun `python tools/check_integration_inventory.py`
when changing tests, rather than copying an older local pass count into this guide.
Reference groups require their authorized inputs and must be reported separately.

To plan which of these groups a change needs, and to retain an evidence summary
that lists unavailable prerequisites and unexecuted platforms, use
[`tools.validate_change`](boundary-validation.md). A plan or partial run never
counts as acceptance of a group it did not execute.

## ThreadSanitizer probation

`native-thread-sanitizer` builds a separate Clang TSan SDK and test tree, covering
the native tests and helper vector index, contract, lifetime and adapter faults.
It cannot reuse the ASan SDK or combine address and thread sanitizers. A planted
data-race probe must be detected before a clean suite is trusted. Retained
`thread-sanitizer-evidence` contains the probe, fatal race logs and CTest results.

The first week (through 2026-10-24 UTC) is reporting-only. The workflow switches
to a failing gate automatically on 2026-10-25 UTC; repository administrators
should require the `native-thread-sanitizer` context after reviewing that week's
reports. Do not suppress a report without recording its cause and rationale.
An unsupported runtime or missing evidence is a failed probe, not a clean TSan
result.

## Native leak sanitizer

`tools/run_native_sanitizers.sh` enables LeakSanitizer (`detect_leaks=1`) for
every CTest process and child, including the preloaded CPython ctypes hosts
and helpers. Settings come from `tools/sanitizer_settings.py`, which the
probe verifier also uses. It is kept out of `tools/sanitizer_runtime.py` so
the instrumented SDK cache key does not change. Leak reports remain in the
`asan.*` or `ubsan.*` evidence files: the combined runtime can use either log
prefix. Both prefixes fail the gate for address, leak and UB reports.
ThreadSanitizer settings are unchanged.

CPython hosts run with `PYTHONMALLOC=malloc`. pymalloc arenas are mmap regions
that LSan does not scan, so they would make live interpreter objects look
leaked. Suppressions live only in `tools/lsan-cpython.supp`, and the settings
module refuses to produce settings unless every rule is an exact
`leak:^Symbol$` for an allowlisted CPython retained-allocation frame with its
own captured-stack `# reason:` comment. The active rules cover
`Py_InitializeFromConfig`, marshal constant reader `r_object`, parser name
reader `_PyPegen_name_token`, and the `itertoolsmodule_exec`,
`collections_exec`, and `_ctypes_add_objects` built-in module initializers.
They come from the clean CPython 3.13.17 host's retained allocation traces.
Eval-loop, call/import dispatch, finalization, generic allocator, ctypes
call-wrapper/libffi, module-path and wildcard rules are rejected because
application calls run beneath them. Allocation traces retain 128 frames to
keep recursive frozen-module reads attached to their specific startup owner.
Another interpreter build must pass the same clean-host and deliberately
leaking-host controls; unexpected allocations remain failures to diagnose.

`tools/verify_native_sanitizers.py` must pass before the suite runs. With the
gate's settings and suppression file it requires:

| Probe | Required result |
| --- | --- |
| `leak` | A native executable's unreachable 4242-byte block is reported and exits nonzero. |
| `retained` | A graph held by a static pointer, like native process-lifetime registries, exits 0 without a report. |
| `python-host-clean` | The CI virtualenv Python loads an instrumented library through ctypes, retains a graph and exits 0 without a report. |
| `python-host-application-leak` | The same host leaks 4243 bytes inside that library through ctypes, and the leak is reported. This checks that the planted application leak remains visible with the same Python call stack and suppressions. |

The existing `address` and `undefined` probes now use the same settings.
Each probe's log and `settings.txt` are kept in `native-sanitizer-evidence`.
Processes that end by signal or `_exit` skip the exit-time leak check. LSan
does not cover those paths.

## Probe index

`tools/integration_probes.json` records every `tools/test_*.py` and
`tools/accept_*.py` harness. Automated entries name their workflow or build script.
The manual probes below are diagnostics requiring the installed runtime, models,
a private desktop session, or physical hardware described by each script; they
are not release acceptance evidence unless actually run and recorded. Invoke a
probe only with its documented fixtures and authorization. Pure Google-client
and web-search release tests live under `tests/` and run in the offline suite.

| Manual probe | Purpose |
| --- | --- |
| `tools/test_capture_device_recovery.py` | Verify private PipeWire device loss/return without physical recording. |
| `tools/test_capture_terminal_state.py` | Exercise real native/Dart capture failure handling with a failing CLI fixture. |
| `tools/test_default_model_startup.py` | Check ordinary bundle launch on an owned desktop without a model override. |
| `tools/test_gemma_models.py` | Run real local Gemma native/helper acceptance without account data. |
| `tools/test_global_shortcut.py` | Verify the real Hyprland global key through a private microphone/profile. |
| `tools/test_global_shortcut_private.py` | Run global shortcut acceptance in a nested Hyprland on an owned headless desktop. |
| `tools/test_helper_worker.py` | Check persistent worker health/ownership through the actual helper RPCs. |
| `tools/test_litert_stop_sequences.py` | Check actual ordered-token stopping with the pinned SDK's test_lm fixture. |
| `tools/test_live_transcription_gap.py` | Verify real Whisper transcription across an owned virtual microphone outage. |
| `tools/test_meeting_workflow.py` | Exercise real meeting workflows on an owned headless desktop and private audio devices. |
| `tools/test_native_inference.py` | Exercise the shared native inference path with an empty executable PATH. |
| `tools/test_native_service.py` | Real-model acceptance through a packaged service and MCP in a private profile. |
| `tools/test_packaged_model_runtime.py` | Exercise real models through a relocated package's own inference processes. |
| `tools/test_packaged_note_enhancement.py` | Real packaged Application enhancement, including saved-transcript correction. |
| `tools/test_packaged_query_worker.py` | Relocate the native dedicated detector and test its installed protocol. |
| `tools/test_packaged_sentencepiece_coload.py` | Check both native/SentencePiece initialization orders in isolated children. |
| `tools/test_vision_model_runtime.py` | Opt-in real-model check of recovered vision startup and native ownership. |
| `tools/test_whisper_gpu.py` | Verify Vulkan Whisper and native speech events using a file, never a microphone. |

### Timing fixtures

Readiness polling in Dart tests always checks a condition and has a deadline; it does not assume readiness after a delay. The remaining nonzero polling intervals cover socket ownership, native capture/transcript readiness, search completion and process startup. Zero-duration delays only yield the event queue. The HTTP slow-stream fixture deliberately paces bytes to test the importer's wall-clock timeout, and the PipeWire pause fixture observes the full two-second no-capture window. These are measured negative assertions, not startup waits. Interrupted model downloads wait until the actual partial file has the expected bytes before breaking the socket. The PipeWire marker test waits for both owned sinks to become idle before resuming.

### Software Vulkan

The PR and weekly acceptance container installs Mesa lavapipe and selects only its ICD. The emulator explicitly opts in to CPU-type Vulkan device 0 with `GGML_VK_VISIBLE_DEVICES=0`; production launches do not set this override. CI requires exactly one installed lavapipe ICD and a successful Whisper Vulkan transcript; a missing driver, unavailable Whisper device, CPU fallback, or failed decode fails the gate with retained diagnostics. CI passes `--allow-litert-unavailable` only to permit the narrowly qualified LiteRT limitations described below. After a successful Whisper Vulkan transcript, exactly one enumerated llvmpipe/lavapipe device with the pinned runtime's explicit CPU-device-type warning records LiteRT GPU coverage as skipped before model startup; this CPU adapter provides no physical GPU coverage. Unknown, mixed or contradictory adapter evidence cannot trigger this skip. `accept_software_gpu.py` checks the shipped Vulkan Whisper runtime on two seconds of the pinned speech fixture, and otherwise attempts the shipped LiteRT GPU backend/model plus a 16-token decode. A missing OpenCL GPU API on the software driver is reported without failing the process: `unsupported_software_driver` by default, or `skipped` under the CI option. Unexpected capability failures and every attempted decode failure fail the gate. Lavapipe implements Vulkan, so it cannot establish OpenCL delegate support or production GPU correctness. Physical GPU inference remains a release-day manual check. Full probe diagnostics are retained with integration evidence.

Installed release and Preview `standard` validation both import generated PDF and RTF fixtures through the exact installed application service's Parser and sandbox, verifying persisted source URI, known extracted text and the real platform adapter. No developer Dart runtime substitutes for the installed service. Standard validation has no model fixtures, so a recorded post-parse indexing failure does not establish indexing or inference; the probe requires that extraction and storage already succeeded. Full acceptance runs the same document check alongside its model tests.

## Compiled first-run model acquisition

`tests/service/test_service_process.py::test_compiled_first_run_setup_download_restart_retry_adoption_and_indexing`
owns the tiny first-run journey. It freshly compiles the standard service and MCP
with the verified diagnostic Worker's exact public defines, and runs
`apps/desktop/integration_test/first_run_models_test.dart` as a native Flutter
application on an isolated display. It opens the actual first-run model surface;
it does not use `finishOnboarding` to mark setup complete.

The catalog substitution requires both the existing
`FORESIGHT_ENABLE_TEST_HOOKS=true` compile flag and an immutable
`FORESIGHT_MODEL_CATALOG_TEST_BASE64` define (JSON is base64-encoded because the Dart AOT CLI splits define values at
commas). Without the flag, the fixture define
has no effect. Entries require checksum-pinned bytes no larger than 64 KiB at
literal loopback URLs. Each redirect must remain one of the exact compiled
fixture URLs. Normal products retain the pinned catalog and HTTPS validation.
The real acquisition coordinator and reaped download worker retain consent,
range staging, checksum validation and publication ownership. These synthetic
bytes are not model weights: the controlled runtime and indexing fixture cannot
establish real inference, real model loading or physical audio acceptance.

The journey requires the pinned SDKs, a verified native/diagnostic companion
build and an isolated native display. The compiled service/MCP suite owns those
prerequisites; a selected first-run journey fails if they are missing. Retain its
compile logs, service/Flutter output, JSON test events, download range ledger and
partial journey report. Real-model acceptance remains in the separate model gate.

## Deferred macOS Keychain acceptance

The existing opt-in fixture remains unchanged in
`tests/integration/test_model_crypto_keychain.py`, enabled by
`FORESIGHT_MODEL_CRYPTO_KEYCHAIN_TEST=1`. Its actual isolated Mac attempt failed
with Security status -25308 (user interaction not allowed). Complete output is
retained privately. The user deferred further Keychain testing; this is neither
a passing result nor a current merge blocker. It does not establish Developer ID
signing, Finder launch or TCC acceptance.

## Opt-in native raw-query probe

The inference runtime owner builds `native_raw_query_probe` from
`tests/inference/raw_query_probe.cpp` in `native/CMakeLists.txt`. This is an
explicit manual executable path, excluded from ordinary CTest execution because
it needs an independently authorized local model and a prepared raw prompt.
Neither assets nor a model license are acquired by this probe.

After building that target with the reviewed LiteRT SDK and preparing its normal
verified library identity metadata, run from a private task directory:

```sh
FORESIGHT_LITERT_LIBRARY=/owned/sdk/liblitert-lm.so \
  /owned/build/native/native_raw_query_probe \
  /owned/models/authorized-model.litertlm "$PREPARED_RAW_PROMPT" 512 cpu \
  >raw-query.stdout 2>raw-query.stderr
```

Use the platform's `.dylib` path on macOS. Retain the exact model/library/prompt
provenance and both streams privately, plus the exit status. A missing LiteRT
library, identity, model or executable is an unmet prerequisite; it is never a
pass for a selected LiteRT lane. A zero exit code establishes only that this raw
prompt executed, not dedicated-model/tokenizer parity or inference quality. This
unit supplies no authorized real-model evidence for that manual probe.

## Retained audio worker fixtures

The recording recovery, speech-owner and backup-owner fixtures in the
`core-native` inventory use the freshly built native library (and helper where
required), disposable profiles and synthetic workers. They require no physical
audio device or inference weights. Codec-dependent compression, retained-audio
restore, playback assembly and exports additionally require explicit verified
worker identities. A regular core run without those inputs reports skips and
supplies no codec acceptance evidence.

For the codec extension, supply `FORESIGHT_NATIVE_LIBRARY`,
`FORESIGHT_TEST_SQL_SUPPORT_LIBRARY` and `FORESIGHT_SQLITE_LIBRARY` from the
matching application build. Select a complete checksum-verified pinned media
worker build or final signed installation receipt, then set
`FORESIGHT_TEST_MEDIA_WORKER` to its physical absolute executable path,
`FORESIGHT_TEST_MEDIA_SHA256` to the verified final executable SHA256, and
`FORESIGHT_TEST_MEDIA_BUILD_ID` to its recorded build identity. macOS also needs
`FORESIGHT_TEST_MEDIA_CDHASH` from that exact final signed artifact. These are
service-owned development fixture inputs, not RPC executable/path options.

From `packages/foresight_core`, run with the pinned Dart SDK and private temp root:

```sh
dart test test/native_audio_assembly_test.dart test/native_audio_media_test.dart \
  test/audio_transform_media_test.dart test/audio_profile_backups_test.dart \
  test/meeting_audio_runtime_export_native_test.dart --reporter expanded
```

Retain the exact source/artifact identities, count and skip reasons with output.
The assembly file has four actual tests: mixed raw PCM/seek/readers, real
compression plus reader-fenced purge and retained Opus reopening, and MP3/Opus
external publication with DB commit. Its three skip registration expressions
include the two-format export loop. Optional-worker skips are not evidence that
those cases executed. Retain the actual source and product identities with each
run; synthetic fixtures do not establish physical playback quality.
