# Zoom speaker attribution implementation plan for macOS and Linux

Implement Zoom participant-name and active-speaker extraction on both supported
desktop platforms, then associate those observations with recorded transcript
segments. macOS and Linux are both part of the initial scope. Platform-specific
observers feed shared Dart attribution, persistence, service, and presentation
code.

Status: proposed implementation. Source baseline:
`f7c063834b0e9e17f3c3507dd2ab93c8f34a1eeb`. The application schema at this baseline
is version 23; allocate the next available ordered migration during implementation.
Live Zoom acceptance is a required deliverable for each platform.

## Product behavior and delivery scope

A user recording a Zoom meeting can enable speaker names, complete the relevant
accessibility setup, and see supported names beside transcript segments. Saved
names survive restart and appear consistently in transcript views, service
responses, search, notes, summaries, and exports. Recording continues when
speaker naming is unavailable.

Deliver two milestones separately:

1. Extract and display the current speaker and observed participant roster in a
   real Zoom meeting on macOS and Linux.
2. Persist supported attribution on recorded speech and integrate every transcript
   consumer.

The first release attributes existing final transcript segments conservatively.
Precise text splitting within a segment containing several speakers is a separate
milestone requiring recognizer timestamps or a validated segmentation change.

Use public operating-system accessibility APIs. Official meeting APIs, meeting
bots, browser extensions, OCR, voice identification, and meeting-joining behavior
are outside the initial scope. Existing audio capture and speech recognition
remain the foundation.

Initial platform targets follow the repository's supported matrix:

| Platform | Initial acceptance target | Expansion |
| --- | --- | --- |
| macOS | Apple Silicon, macOS 15+, Zoom 7.2.2 (88465) | Current Zoom releases after explicit-marker validation; additional layouts and locales as tested |
| Linux | x86-64, Ubuntu 24.04, the exact installed Linux Zoom build, Wayland and Xorg | Debian 13, Fedora 44, Arch/Omarchy through their installed-package gates |

Record the actual Zoom and OS versions in acceptance evidence. macOS 7.2.2
eligibility does not establish compatibility with a similarly numbered Linux
build. Parser fixtures and live-tested support are separate claims.

## Existing architecture and required refactoring

The application service already owns recording, native resources, profile writes,
and workflow coordination. Retain that ownership and extend it with one supervised
meeting observer per recording session.

| Existing code | Current behavior | Required change |
| --- | --- | --- |
| [meeting_speakers.dart](../../packages/foresight_core/lib/src/meeting_speakers.dart) | Microphone, Remote, and Unknown describe capture channels | Add participant and attribution models while preserving legacy channel semantics |
| [recording.dart](../../packages/foresight_core/lib/src/recording.dart) | Segment times derive from captured samples; gaps are excluded | Preserve PCM timing metadata and map sample ranges onto a monotonic timeline |
| [recording_controller.dart](../../packages/foresight_core/lib/src/application_services/recording_controller.dart) | Owns recording lifecycle and schedules derived work | Own the observer and attribution session; reject stale callbacks |
| [recording_transcript_persistence.dart](../../packages/foresight_core/lib/src/application_services/recording_transcript_persistence.dart) | Bounded transactional transcript retry queue | Commit attribution with its transcript row and retain idempotent retry behavior |
| [meeting_store.dart](../../packages/foresight_core/lib/src/persistence/meeting_store.dart) | Saves text, finality, sample-based times, and source | Add transactional participant and attribution writes |
| [read_models.dart](../../packages/foresight_core/lib/src/read_models.dart) | Transcript projection has no person attribution | Add nullable participant, display-name, method, and state fields |
| [meeting_operations.dart](../../packages/foresight_core/lib/src/application_services/meeting_operations.dart) | Public speaker fields are derived from audio channels | Add compatible person fields and explicit channel fields |
| [meeting_transcript_projection.dart](../../packages/foresight_core/lib/src/persistence/meeting_transcript_projection.dart) | Indexes channel-prefixed transcript text | Render supported names and invalidate projections when attribution changes |
| [transcript_view.dart](../../apps/desktop/lib/features/meetings/transcript_view.dart) | Renders channel labels | Render supported names with channel-label fallback |
| [package_macos.py](../../tools/package_macos.py), [package.py](../../tools/package.py), and [package_linux.py](../../packaging/package_linux.py) | Package existing platform workers and runtimes | Package the observer, runtime path, dependencies, and provenance |

This is a focused extension of recording metadata and transcript handling.
Rewriting the capture engine, replacing the application service, or adding a
Node.js runtime is unnecessary. In particular, speaker-name extraction does not
require a macOS audio-capture Node addon.

## Shared observer contract

Introduce a service-owned `MeetingSpeakerObserver` abstraction with capability
inspection, explicit accessibility setup, start, stop, and dispose operations.
Implement macOS and Linux backends behind the same interface.

Use bounded newline-delimited JSON between Dart and the observer helper. Version
the protocol and include request IDs, recording/session IDs, and sequence numbers.
Define startup, capability, observation, unavailable, error, and shutdown frames.
Stdout contains protocol frames; bounded diagnostics go to stderr.

An observation carries:

- Target process, meeting-window identity, Zoom version, and locale when known.
- Observation read start and end in a defined monotonic clock domain.
- Observed participant references, display names, and self markers.
- Zero, one, or several active-speaker candidates, with evidence method.
- Snapshot completeness, parser version, and availability state.

Differentiate an observed absence of an active speaker from a failed read or
missing window. Failed reads create unavailable intervals and cannot extend a
previous speaker indefinitely. Treat all observed strings as source data.

Start observation for the selected Zoom recording, rather than merely because
Zoom is installed or running. If several candidate meetings or windows are
ambiguous, require a target selection or report ambiguity. Do not combine them.

Bound individual API calls, tree depth, node count, frame size, read duration,
restart attempts, and shutdown time. On a stalled read, terminate and reap only
the owned observer. Never block capture, speech processing, or the service event
loop waiting for accessibility.

## macOS adapter

Add an Objective-C++ helper, provisionally `native/zoom_observer_macos.mm`, linked
against the required Apple frameworks. Identify Zoom through the bundle identifier
`us.zoom.xos`, resolve its process, and read its relevant windows through
`AXUIElement`.

Build snapshots from roles, descriptions, values, identifiers, and children.
Keep platform snapshot collection separate from pure parsing so fixtures can
exercise the parser without requiring operating-system permission.

Implementation notes and the unexecuted live-validation checklist are in
[macOS observer helper](zoom-observer-macos.md).

### Participant and active-speaker parsing

Implement these independent evidence paths:

| Path | Parsing contract |
| --- | --- |
| Ordinary participant tile | Require `AXTabGroup`; extract the name before the earliest recognized localized computer-audio status, or before a supported active-speaker suffix when audio status is absent |
| Explicit active speaker | Require the localized active-speaker suffix in the expected status structure; an unmuted microphone alone is insufficient |
| Compact window | Require the recognized compact-window controls and structure, then exactly one matching direct `AXStaticText` talking label |
| Self identity | Search the localized Participants-list `AXOutline` for a descendant self-labelled text value |
| Ordered-tile fallback | Restrict to a separately validated version/layout allowlist and complete, internally consistent snapshots |

Preserve legitimate name punctuation, including commas within names. Normalize
comparison whitespace and case separately from the display spelling. Use
structural and status-token checks so unrelated labels cannot become speakers.

Ordinary tiles take precedence over compact-window inference. In the normal
compact shape, controls include localized forms of `Hide thumbnail video` and
`Show active speaker video`. A separate two-child `Show video render` shape needs
its own fixture and live acceptance before support. Anchor the localized
`Talking: Name` form; reject multiple candidate talking values and truncated
snapshots for fallback inference.

Prepare fixture coverage for the 17 identified locale pattern sets. Begin live
acceptance with English and Simplified Chinese, then record additional live
coverage explicitly. Unsupported locales remain unavailable rather than using
unrelated English substring guesses.

### Version-specific ordering

Treat ordered-tile attribution as experimental and disabled initially. The
candidate version set is 7.2.0, 7.2.1, and 7.2.2; activation requires actual live
evidence for the supported version and layout.

Require a complete snapshot, the expected window structure, participant-count
agreement, recognized layout controls, applicable sharing/self-count conditions,
an eligible unmuted candidate, and absence of disqualifying pinned or spotlighted
states. Explicit active-speaker markers take precedence. Duplicate identities or
conflicting candidates prevent inference. Do not generalize this rule to later
versions or Linux.

### Collection, permissions, and application identity

Start with a 500 ms polling baseline and add useful `AXObserver` notifications
where the target Zoom build emits them. Retain periodic reconciliation. Set
Accessibility messaging timeouts inside the isolated helper and enforce an outer
process deadline as well. Apple documents both
[application observers](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate?language=objc)
and [messaging timeouts](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).

Use a stable helper bundle identity and the existing nested-bundle packaging
pattern. The helper performing reads must report its own Accessibility trust
status. An explicit setup operation may request access and guide the user to
System Settings. Capability inspection must not prompt.

Verify the identity macOS presents in System Settings using the installed app;
do not assume existing service audio permissions transfer to the helper. Test
denial, grant, revocation during recording, regrant, application restart, and
application update. Keep microphone/system-audio setup independent.

The normal observer is passive. Do not open the Participants panel, change the
meeting layout, or activate Zoom to obtain a self name. When passive self evidence
is unavailable, retain unknown identity.

## Linux adapter

Use a Python GI/AT-SPI diagnostic probe to establish the live tree and event
behavior quickly. Implement the production reader in a small C++ executable using
`libatspi`, provisionally `native/zoom_observer_linux.cpp`, so the default package
does not gain a runtime Python dependency.

Enumerate accessible applications, identify the Zoom executable and process,
select the relevant meeting window, and collect the names, descriptions, roles,
states, and attributes the target build exposes. Derive Linux parsing rules from
those snapshots; retain shared name utilities only where semantics match.

Use accessible-name/description, state, and children-change events where useful,
with periodic snapshots to recover missed changes. The event types are documented
by [AT-SPI](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/method.EventListener.register.html).
Measure event reliability before relying on it for attribution.

Inspect accessibility availability without changing desktop settings. Explicit
setup may enable the appropriate desktop accessibility support. Qt documents
AT-SPI activation through accessibility-bus properties or
`QT_LINUX_ACCESSIBILITY_ALWAYS_ON`; establish what the actual Zoom build requires
before prescribing a restart or launch option.
[Qt accessibility documentation](https://doc.qt.io/qt-6/qaccessible.html)

Run under the user's desktop session and its session bus. Missing AT-SPI,
inaccessible Zoom trees, headless service use, or missing session access produce
a capability result without interrupting recording. Test Wayland and Xorg
independently. Do not introduce X11-only automation into the reader.

## Participant identity and attribution policy

Create separate models for `AudioChannel`, `MeetingParticipant`,
`SpeakerObservation`, and `TranscriptAttribution`. Keep the existing
`MeetingSpeaker` channel API compatible while consumers migrate.

Participant identity is meeting-local. Use observed object identity when available,
scoped to the process/window/session, and track display-name changes separately.
Accessible object paths and snapshot indexes are not automatically durable user
IDs. Duplicate display names, rejoining, or uncertain rename continuity must not
silently merge different participants.

Retain explicit evidence methods such as participant status, compact talking
label, validated layout inference, and manual attribution. Avoid presenting an
uncalibrated numeric score as a probability. Keep unknown, multiple-speaker, stale,
and unavailable states distinct internally.

Initially enable only evidence paths validated for the target platform. A sole
remote-participant assumption is a later optional policy requiring credible self
identity, complete roster evidence, stability, freshness, and distinct provenance.
It must not masquerade as a direct active-speaker observation.

Do not assign the remote highlight to microphone speech. A microphone can serve
more than one person, and local account identity alone does not establish who
spoke. Keep its channel fallback unless supported local identity and capture
conditions justify a name.

## Capture timeline and transcript alignment

Native PCM events already include a monotonic `timestamp_ms`. Dart currently uses
sample counts to derive transcript times, excluding capture gaps. Add a
`CaptureTimeline` that maps each channel's captured sample ranges to monotonic
intervals without changing the existing saved timing semantics.

Define the clock domain explicitly and verify its compatibility between native
capture and each observer helper. Add a clock probe if an offset must be measured.
Never equate wall-clock time, arbitrary process-relative stopwatches, and native
steady-clock timestamps without a mapping.

Preserve timing spans through buffer accumulation, provisional snapshots, ASR
queues, and final callbacks. Represent channel startup offsets, pause/resume,
device recovery, dropped frames, and sample-rate epochs. Native frame emission
time is an anchor with capture/buffering uncertainty, not necessarily a precise
hardware presentation timestamp; measure the resulting alignment error.

Implement a pure Dart `SpeakerAttributor` that joins mapped audio intervals with
observation intervals. Keep compact observation history until all relevant queued
ASR jobs settle; coalesce unchanged observations and bound retained data. If
history is unavailable, attribution becomes unknown while text remains saveable.

Measure indicator delay for each platform and evidence method. Keep the lag
adjustment configurable and prevent adjusted transitions from moving backward.
Do not treat the poll period itself as a measured detection delay.

For version one, attribute a final segment only when coverage, timing uncertainty,
and competing evidence support a single participant under a documented policy.
Avoid naming a whole segment merely because one participant has the largest
overlap. Keep conflicting or boundary-crossing speech unattributed.

System playback may contain non-Zoom audio. Record the capture-route context and
document the initial supported condition. Evaluate app-scoped playback capture as
a separate change if acceptance shows mixed-system audio cannot be attributed
reliably. A Zoom indicator alone cannot identify unrelated application audio.

## Persistence and compatibility

Add an ordered schema migration for meeting participants and transcript
attribution. Keep immutable transcript IDs and raw text. Store nullable participant
references, display-name snapshots, attribution state, method, parser/policy
version, and the compact timing evidence needed to explain or recompute the
association. Persist only necessary observation history, not full desktop trees.

Commit the transcript and initial attribution in the existing transactional retry
boundary. Attribution lookup failure must not prevent saving text. Define a
transactional update operation for later corrections and manual overrides; an
automatic observation must not overwrite a manual override.

Attribution changes must increment meeting revision, invalidate affected cached
inputs, and enqueue transcript reprojection. Existing transcript triggers watch
text/source/timing columns; add equivalent invalidation for attribution changes.
Batch participant changes so a roster refresh does not reindex every row.

Maintain backward compatibility for historical meetings with no attribution.
Legacy public `speaker_id` values continue to identify audio channels. Add
explicit channel and nullable participant fields, update projection validation,
and regenerate bindings only when their schemas change. Keep transcript-index
channel keys unchanged; render supported names in indexed text initially.

Test migration upgrades, rollback, interrupted writes, retry idempotency,
participant renaming, manual corrections, deletion, workspace clear, backup and
restore, stale index batches, and application restart.

## Transcript consumers and user experience

Provide an application-owned attributed-transcript formatter with explicit modes
for display, export, retrieval, and model input. Preserve raw transcript quotation
and evidence IDs separately from rendered name prefixes.

Update transcript rows, question rows, provisional presentation, copy-full-
transcript, and export paths. Show a supported display name and retain channel
fallback when attribution is absent. Expose naming availability independently of
recording health. Add a minimal attribution correction/reset control after the
persisted update operation is available.

Route service and MCP consumers through the same stored attribution. Include
names in search projections, live/final notes, summaries, and relevant question
context. Attribution revisions must invalidate the corresponding caches and
reject stale in-flight generation inputs while preserving accepted user edits.

Keep source names and transcript content untrusted in prompts. Preserve action-
owner validation: a displayed name does not relax the existing exact-quotation
requirements. Resolving a first-person commitment to a participant requires a
separate structured-evidence policy and regression tests.

## Lifecycle and operational behavior

`RecordingController` owns one observer session and one attribution coordinator.
Do not attach observation lifetime to Flutter widgets or give MCP a second reader.
Bind callbacks to both recording generation and workspace generation.

On pause, stop new attribution intervals and clear provisional speaker state. On
resume, establish fresh observation and capture anchors. On stop, finish the
observation interval, terminate/reap the helper within its deadline, and retain
the timeline needed by final ASR jobs before releasing the session. Permission
revocation, Zoom exit, lost meeting windows, observer failure, and service shutdown
must clear freshness and prevent cross-meeting attribution.

Use bounded restarts with backoff. Report capability failures, timeouts, restart
counts, traversal duration, truncation, and attribution coverage without logging
participant names or transcript text by default. Make diagnostic tree capture
explicit and local; use controlled or sanitized fixtures in the repository.

## Build and packaging

Build the macOS helper with the supported deployment target and architecture.
Extend nested-bundle assembly, runtime configuration, dependency/architecture
audits, signature enumeration, and installed-bundle verification. Validate the
actual helper's permission identity using the shipped signing mode; do not claim
Developer ID or notarization acceptance from an ad-hoc build.

Build the Linux helper against the supported compatibility baseline. Declare its
AT-SPI dependencies for Debian, RPM, and Arch packaging, and document the portable
bundle's host requirements. Missing optional observer dependencies must not stop
the application or recording from starting. Include the new binary in ABI audits,
runtime path validation, notices, manifests, and relocation tests.

Follow [macOS packaging](../platforms/macos-support.md),
[Linux packaging](../platforms/linux-packaging.md), and
[CI integrity](../platforms/ci-integrity.md). Workflow permissions, publishing,
and artifact-trust changes require the existing owner review; this feature does
not imply authorization to expand those boundaries.

## Work packages and completion gates

Each row is an independently verified integration batch. Create the implementation
issue and branch before production changes, following
[CONTRIBUTING](../../CONTRIBUTING.md). Assign a named owner to each batch when
execution starts; the owner column below specifies the responsibility.

| Order | Work package | Owner responsibility | Completion gate |
| --- | --- | --- | --- |
| 1 | Live probes and fixtures on macOS and Linux | Platform adapter owner | Three-person calls establish exact roster/speaker signals, layout limits, timestamps, and setup requirements on both platforms |
| 2 | Shared protocol, macOS helper, Linux helper, and supervision | Native/runtime owner | Bounded reads, correct capability/setup behavior, process cleanup, and actual service-to-helper interoperability |
| 3 | Participant model, capture timeline, and attribution | Recording/core owner | Clock/gap/ASR-queue tests pass; ambiguous speech remains unnamed; capture lifecycle remains intact |
| 4 | Ordered migration and transactional persistence | Storage owner | Upgrade/rollback/retry/restart and attribution invalidation tests pass without changing legacy channel meaning |
| 5 | UI, service/MCP, correction, export, search, and AI consumers | Application owner | All consumers use persisted attribution consistently and stale work cannot overwrite corrections |
| 6 | Packages, live acceptance, support documentation, and changelog | Platform acceptance owner | Installed Mac and Linux products pass their declared acceptance matrix with retained evidence |

If a live signal is missing, the platform owner gets a bounded investigation:
inspect setup state, complete tree snapshots, supported views, and target-version
differences. Exit with a reproduced signal or an explicit unsupported case.
Do not respond by enabling unvalidated ordering or expanding into OCR/API work
inside the same batch. A working platform can proceed behind capability checks
while the other remains explicitly unqualified.

## Validation matrix

| Layer | Required checks |
| --- | --- |
| Parser fixtures | Roles, exact status structure, muted/unmuted distinction, names with punctuation, locales, compact shapes, malformed/truncated trees, duplicates, conflicting candidates, version/layout guards |
| Platform collection | Real Zoom windows, permission/setup lifecycle, hidden/background/minimized states, screen sharing, layout switches, process/window replacement, API stalls, and loss/recovery of access |
| Timeline and attribution | Separate channel startup, pauses, reconnects, overflow, rate changes, observation delays, missing history, stale markers, overlapping speakers, and delayed final ASR |
| Lifecycle/protocol | Bounded frames and timeouts, malformed responses, restart limits, termination/reaping, cancellation during startup/read/shutdown, and stale recording/workspace callbacks |
| Storage and consumers | Transaction rollback/retry, migrations, manual corrections, restart, deletion/restore, projection invalidation, service/MCP fields, UI, copy/export, search, notes, and summaries |
| Installed product | Actual packaged Foresight recording a real Zoom call on both operating systems; saved attribution verified after reopen and through downstream consumers |

Use controlled participant names and ground-truth turn schedules. Include at least
100 labelled turn transitions per initial platform across supported normal views,
a 30-minute continuous session, and a longer soak test after basic acceptance.
Measure named-segment precision, attribution coverage, speaker-switch delay,
observer CPU/memory, truncation/timeouts, and recording regressions separately.

Initial engineering targets are at least 99% precision among named single-speaker
segments, at least 90% attribution coverage in the declared normal-view scenario,
and a 95th-percentile current-speaker update delay below 1.5 seconds. These are
proposed acceptance thresholds, not measured results. Exclude ambiguous segments
from single-speaker precision only with explicit classification and report them
in coverage. Report counts and results by platform, view, and evidence method;
unsupported states must not disappear into an aggregate score.

Run applicable native CTest, Dart analyze/test, Flutter analyze/test, Python
tooling, migration integrity, and installed-package checks from
[CONTRIBUTING](../../CONTRIBUTING.md). Before every push run
`.venv/bin/python -m tools.check_local_validation` and the applicable platform
gates. Retain failures, reuse verified SDKs, and distinguish implemented,
locally verified, CI-passed, and live-accepted states. Use private `/var/tmp`
directories with `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT` set. No skipped live
environment counts as acceptance.

## Effort and follow-up scope

For one engineer with access to both real desktop environments, allow roughly
one week for dual-platform feasibility and four to six weeks total for the first
production release, assuming usable live accessibility signals. Work packages
may need smaller integration batches even within one feature PR.

| Work | Estimated engineering days |
| --- | --- |
| Live feasibility and fixture capture on both platforms | 3–5 |
| Production helpers, protocol, permissions, and supervision | 5–8 |
| Shared timeline, attribution, migration, and persistence | 4–6 |
| UI, service, export, search, and AI integration | 4–6 |
| Packaging and live hardening | 4–6 |

The total range is approximately 20–31 working days; permission/signing issues,
missing Linux signals, or unsupported Zoom changes can extend it. Re-estimate
after the live-probe gate.

Follow-up work includes word-level attribution, validated speaker-boundary audio
segmentation, app-scoped playback capture where required, additional locale and
Zoom-version acceptance, and other meeting applications. Keep each expansion
behind its own measured support and regression criteria.
