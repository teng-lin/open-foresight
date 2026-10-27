# Open Foresight repository review

Review date: 2026-10-24. Source: `2f26d8fc9d1ef83e7df2d709fa776c55c8c01ace`
(`Allow users to rename meetings`, #177). The working tree was clean at the start.

Open Foresight has strong application boundaries, substantial failure-path testing,
and unusually careful installer provenance and migration handling. Its most urgent
identified defect is a recording-stop path that can leave capture running after a
database write fails, including when the desktop becomes hidden or disconnects.
Request bookkeeping and acquisition deadlines also need targeted fixes. These
findings warrant focused changes before broader refactoring.

This assessment covers first-party Dart, Flutter, native C++, Python tooling,
packaging, workflows, and supporting documentation. Three native review agents
independently assessed architecture and quality; security and reliability; and
testing, deployment, and dependencies. The coordinating reviewer cross-checked
findings against current source and assessed performance and diagnostics. Existing
audit plans were context, not evidence that their historical findings remain open.

## Ratings

Scores are engineering judgments about the reviewed implementation: 1–2 means
fundamental deficiencies; 3–4 means substantial weaknesses; 5–6 means adequate
but uneven; 7 means strong with material gaps; 8 means strong with enforced
controls; 9 means highly mature with few remaining gaps; 10 means exemplary with
no significant identified improvement. They are not coverage percentages or
release certification. Overlapping findings affect more than one aspect.

| Aspect | Score | Assessment |
| --- | ---: | --- |
| Architecture | **8/10** | One service owns mutations and resources; desktop capabilities, typed operations, and read projections have executable boundary guards. Lifecycle cleanup still has an important failure case. |
| Security and privacy | **7/10** | Strong local peer verification, visible consent, SSRF defenses, parser confinement, and credential controls. The recording-stop defect weakens the visible-desktop privacy guarantee under storage failure. |
| Reliability and data integrity | **7/10** | Transactional migrations, WAL/journal qualification, workspace epochs, durable cleanup intent, and explicit producer settlement are strengths. Capture cleanup, duplicate request IDs, and stalled acquisition remain gaps. |
| Code quality | **8/10** | Typed dispatch, named persistence APIs, immutable values, lint/type checks, and native exception barriers support safe changes. Cleanup paths need more consistent independence from fallible persistence. |
| Testing and verification | **8/10** | Layered unit, native, compiled service, UI, model, installer, and upgrade checks; meaningful coverage and skip accounting. Complete first-run acquisition and native coverage visibility remain weaker. |
| Deployment and release | **7/10** | Installer identity, original-byte preservation, attestations, and prior-release upgrades receive careful verification. Most manual scenarios are outside machine-enforced publication evidence; signed macOS distribution remains unfinished. |
| Dependencies and supply chain | **8/10** | Hash-pinned Python dependencies, Dart lockfiles, pinned actions/build inputs, SBOMs, and consumer-scoped artifact trust. Vulnerability reporting covers less than the shipped native dependency chain and has no blocking response policy. |
| Maintainability | **7/10** | Explicit core owners and feature boundaries improve change isolation. Large shared Dart libraries, substantial native modules, and version-sensitive transport integration retain maintenance cost. |
| Performance and responsiveness | **7/10** | Persistent read workers, coalescing, tracked cancellation, and a provenance-aware RPC measurement tool are good foundations. Synchronous native teardown remains a known blocking path; current-head latency and hardware throughput were not measured. |
| Observability and supportability | **7/10** | Typed errors, service status, bounded transport traces, startup diagnostics, and retained acceptance reports help diagnosis. Free-form logs and potentially content-bearing malformed-frame traces need a consistent redacted diagnostic format. |
| Documentation and developer experience | **7/10** | Useful contribution instructions, build entry points, ADRs, threat-model notes, and honest platform limitations. Coverage and migration documentation have drifted from executable configuration. |

## Implemented strengths

### Architecture and ownership

The desktop receives a curated [public API](../../packages/foresight_core/lib/desktop.dart)
and a separate startup surface. It does not own database writes or construct the
retrieval transport. [Boundary tests](../../packages/foresight_core/test/desktop_boundary_test.dart)
and [desktop architecture checks](../../apps/desktop/test_support/desktop_architecture.dart)
guard imports, exports, forbidden capabilities, and feature ownership. These are
implemented constraints, rather than documentation-only layering.

The [operation registry](../../packages/foresight_core/lib/src/operation_registry.dart#L24)
checks request/handler agreement, scope, duplicates, and missing handlers.
[Generation coordination](../../packages/foresight_core/lib/src/application_services/generation_coordinator.dart#L6)
retains reservations until producers actually settle. The
[read coordinator](../../packages/foresight_core/lib/src/read_coordinator.dart#L12)
binds results to owner, profile, connection, epoch, and revision, and keeps tracking
underlying SQLite work after subscriber deadlines. These decisions address real
concurrency and stale-result hazards.

### Security and persistent data

[Unix peer verification](../../packages/foresight_core/lib/src/unix_peer_identity.dart#L23)
uses OS credentials and executable identity. The
[approval gate](../../packages/foresight_core/lib/src/agent_access.dart#L125)
authenticates desktop attachment, rotates capabilities, and requires a visible
host for external operation approvals. Pending approvals are scoped to their
owners. Same-user local access remains part of the documented
trust model; the application is not a sandbox against every process of its owner.

[Web imports](../../packages/foresight_core/lib/src/web_import.dart#L114)
pin connections to checked DNS addresses and revalidate redirects. Document
extraction uses [Linux confinement](../../packages/foresight_core/lib/src/document_parser.dart#L130)
and a [macOS parser sandbox](../../native/file_parser.swift#L14).
[Credential storage](../architecture/credentials-at-rest.md) documents both
platform protections and the private plaintext fallback. These tradeoffs should
remain explicit, rather than be mistaken for universal at-rest encryption.

[Store startup](../../packages/foresight_core/lib/src/store.dart#L69) qualifies
schema compatibility before writable opens and applies migrations transactionally.
Frozen historical migration closures and real SQLite crash fixtures protect
upgrade behavior. Durable privacy-maintenance intent survives deferred checkpoint
and VACUUM work. Authenticated model downloads verify complete bytes before
adoption; the acquisition deadline finding below does not indicate acceptance of
corrupt models.

### Testing and release integrity

[Python coverage](../../.coveragerc) includes branches and subprocesses with a
95% threshold. The [portable Linux test path](../../tools/linux_container_test.sh#L14)
enforces the core 90% line gate; [desktop gates](../../tools/build_dart_gates.sh#L105)
enforce 90% lines on Linux. These configured thresholds are not fresh measurements.
Integration tooling checks [executed test counts and terminal reporter results](../../tools/integration_gates.py#L25),
and test discovery and skip inventories make exclusions reviewable. Native
ASan/UBSan and separate TSan configurations exist. On this review date, the
[TSan probation policy](../../.github/workflows/native-sanitizers.yml#L195)
has a 2026-10-25 UTC endpoint; it should not yet be described as an unconditional
ordinary PR gate.

Release trust verifies [producer context](../../tools/ci_producer_trust.py#L30),
[attested source and workflow identity](../../tools/ci_release_attestation.py#L19),
and exact installer bytes. [Uploads reject conflicting existing assets](../../tools/release_upload.py#L65).
All four installer formats need functional and
[previous-release upgrade evidence](../../tools/release_acceptance_report.py#L81).
SBOM and provenance attestations already exist; the vulnerability-monitoring gap
below concerns their use in scanning, not their absence.

## Prioritized findings

P1 means an urgent privacy or core-correctness defect. P2 means a material
reliability, verification, or process gap. P3 means lower-risk documentation or
maintenance work. “Source-confirmed” means the implementation establishes the
described control flow; it does not mean an end-to-end reproduction ran.

### F1 Recording shutdown depends on a successful database write

**P1 · Source-confirmed defect · Security and reliability**

[`_stopRecording`](../../packages/foresight_core/lib/src/application_services/recording_controller.dart#L238)
cancels maintenance and inactivity timers, then writes `transcribing` at line
246 before entering the `try/finally` containing `active.stop()` and ownership
cleanup. [`CaptureQueries.setState`](../../packages/foresight_core/lib/src/persistence/capture_queries.dart#L23)
is a direct SQLite update and can throw.

A storage or other SQLite write failure therefore bypasses device shutdown and
leaves the recording owner populated. The
[hide/detach handlers](../../packages/foresight_core/lib/src/service_operation_handlers.dart#L81)
and [desktop-disconnect handler](../../packages/foresight_core/lib/src/application_service.dart#L635)
invoke that same stop path and only log its rejection. A retained recording also
counts as [busy service work](../../packages/foresight_core/lib/src/application_service.dart#L109).
Capture can consequently continue after an intended Stop, hide, or disconnect
while the service remains alive. This does not establish survival after process
exit, and no live-audio leak was reproduced.

Make capture finish/disposal unconditional and independent of status persistence.
Preserve committed transcript segments and the original storage error; attempt
final status persistence separately. Add regressions for direct Stop, hide, and
disconnect using a synthetic SQLite trigger that rejects the `transcribing`
update. Assert that native capture stops and recording ownership clears even
when the database update fails. Existing speech-failure coverage does not prove
this storage-failure case.

### F2 Duplicate active RPC IDs replace ownership records

**P2 · Source-confirmed defect · Protocol reliability**

[Admission](../../packages/foresight_core/lib/src/service_admission.dart#L16)
validates ID type, but the service does not reject an ID already active on the
connection. The [32-request limit](../../packages/foresight_core/lib/src/application_service.dart#L610)
uses subscription-map length; admission then
[replaces the lease and subscription](../../packages/foresight_core/lib/src/application_service.dart#L683)
under that ID. Completion removes entries by ID, and
[cancellation](../../packages/foresight_core/lib/src/application_service.dart#L925)
can reach only the currently mapped owner.

A raw or buggy same-user local client can leave older producers running while
their bookkeeping is replaced. Earlier completion can remove a newer request's
entry, and repeated reuse can evade the map-based active-request limit. This is
a local cancellation and availability defect, not a demonstrated cross-user
privilege escalation. No runtime reproduction ran.

Reject duplicate active IDs before lease creation and use identity-checked
removal as a defensive measure. Add a raw-socket test with a held producer,
duplicate ID, cancellation, and disconnect; verify producer settlement and the
active-request bound.

### F3 Question model acquisition lacks application transport deadlines

**P2 · Source-confirmed gap · Setup reliability**

The [metadata RPC](../../packages/foresight_core/lib/src/model_acquisition.dart#L62)
sets credentials but no call deadline. The downloader creates its default
`HttpClient` without a configured connection timeout and
[awaits connection, headers, and body iteration](../../packages/foresight_core/lib/src/model_acquisition.dart#L246)
without application deadlines. [Dedicated acquisition](../../packages/foresight_core/lib/src/dedicated_query_acquisition.dart#L140)
awaits these operations directly.

A stalled transport can leave setup pending without consuming the five retry
attempts, because retrying requires the current attempt to fail. Manual
cancellation and close paths exist, and fixed size/digest authentication still
precedes model adoption. This finding concerns the dedicated question-model path;
it is not a claim about every model downloader.

Add finite metadata, connection, and response-header deadlines plus a body
inactivity deadline. Use local stalling transports to verify timeout, retry,
cancellation, reservation release, and preservation of the previous usable model.

### F4 Native Linux capture hardcodes its temporary directory

**P2 · Source-confirmed resilience gap · Runtime portability**

[`CapturePcmPipe`](../../native/foresight_native.cpp#L174) uses
`/tmp/foresight-capture-XXXXXX` at line 180. Setting `TMPDIR` to the short private
disk-backed root required by [AGENTS.md](../../AGENTS.md) does not relocate this
FIFO directory. Capture can therefore fail on `/tmp` allocation or quota limits
despite a usable configured temporary root. No quota failure was reproduced.

Honor a validated temporary root while preserving private directory/FIFO modes,
bounded path lengths, and cleanup. Verify that capture uses the configured root
and handles allocation failures cleanly.

### F5 Publication evidence does not represent the full manual checklist

**P2 · Source-confirmed process gap · Release acceptance**

After automated installer and upgrade checks,
[`aggregate`](../../tools/release_acceptance_report.py#L106) derives overall
`passed` from GPU evidence. [`require_publication`](../../tools/release_acceptance_report.py#L160)
checks GPU status and installer bindings but does not consume the
[manual acceptance template](../validation/release-acceptance-manual.json).
That checklist includes guided setup, physical audio, permission revocation,
sleep/wake, native export, and Finder quarantine. The
[release guide](../validation/release-acceptance.md#L115) requires these separate
observations before describing a release as fully validated.

Publication machinery can thus accept automated and GPU evidence without those
other manual records. This is not an artifact-integrity bypass and does not prove
that maintainers have omitted manual checks on any actual release.

Agree on an owner-reviewed receipt bound to exact installer hashes, recording
per-scenario results or explicit scoped waivers. Keep incomplete manual status
visible. Changes to publication policy or artifact-trust code require the owner
review specified in [CI integrity](../platforms/ci-integrity.md).

### F6 Main native UI journeys bypass complete first run acquisition

**P2 · Source-confirmed verification gap · Testing**

The shared [onboarding helper](../../apps/desktop/test_support/onboarding.dart#L5)
skips model setup; model fixtures are installed separately. The compiled
[service and MCP UI journey](../../apps/desktop/integration_test/service_mcp_test.dart#L155)
uses this helper. Richer
[onboarding widget tests](../../apps/desktop/test/onboarding_workflow_test.dart#L24)
use test domains and helpers. Backend tests meaningfully cover pending imports
and cancellation, but those checks do not establish the combined independent
desktop/service acquisition and restart journey.

Add a focused compiled UI/service scenario with a fresh profile: persist partial
setup, restart, interrupt a deterministic loopback download, reject checksum
failure, retry, adopt a verified inference fixture, and observe usable indexing.
Retain separate real-model acceptance rather than treating transport fixtures as
proof of inference quality.

### F7 Vulnerability monitoring covers only part of the dependency surface

**P2 · Source-confirmed monitoring gap · Supply chain**

The [weekly OSV workflow](../../.github/workflows/osv-scan.yml#L12) is reporting-only:
both the job and scanner step permit failure. Its explicit inputs cover Python
and application Dart lockfiles, while native build inputs such as the
[core SDK](../../packaging/sdk-core.Dockerfile#L20) and
[LiteRT SDK](../../packaging/sdk-litert.Dockerfile#L13) are outside that input list.
Installer SBOMs exist, but this scanner does not consume them.

No specific vulnerable dependency or CVE was established. The gap is incomplete
monitoring and the absence of an enforced response path in this workflow.
Preserve the difference between scanner failure and vulnerability findings,
retain actionable results, assign triage responsibility, and extend assessment
to shipped native dependencies. Any severity-based publication gate needs owner
review.

### F8 Coverage and migration documentation have drifted

**P3 · Source-confirmed documentation defects · Developer experience**

[CONTRIBUTING.md](../../CONTRIBUTING.md) and the
[README coverage description](../../README.md#L376) still state a 76.35% desktop
minimum; the executable Linux desktop gate is 90%. The README also describes
macOS PR core coverage enforcement, while the
[macOS PR environment](../../.github/workflows/macos.yml#L23) disables collection
and sets its minimum to zero. The selected portable Linux PR lane still enforces
core coverage; there is no finding that PR coverage is absent repository-wide.

The [migration table](../architecture/schema-migrations.md#L40) ends at version
17, while [Store](../../packages/foresight_core/lib/src/store.dart#L31) is at 19:
[migration 18](../../packages/foresight_core/lib/src/persistence/schema_migrations.dart#L88)
adds content history and migration 19 adds manual meeting-title state. Update
the table and platform-specific coverage guidance. These mismatches do not imply
that the migrations or coverage implementation are defective.

## Maintenance and maturity constraints

These concerns inform the ratings but are distinct from newly identified
functional defects.

**Large shared desktop libraries.** The
[meetings controller](../../apps/desktop/lib/features/meetings/meetings_controller.dart#L22)
and its seven parts total **3,108 lines**; the
[sources controller](../../apps/desktop/lib/features/sources/sources_controller.dart#L24)
and its eight parts total **3,076 lines**. Parts share private library state. The
[size guard](../../apps/desktop/test_support/desktop_architecture.dart#L170)
checks each physical file against its budget, so passing that guard does not
establish narrow state ownership across the combined library. Incrementally
extract widgets with explicit view data and callbacks where that reduces
coupling; assess logical-library complexity alongside physical size. File size
alone is not evidence that behavior is wrong.

**Native teardown responsiveness.**
[`NativeRuntime.close`](../../packages/foresight_core/lib/src/native.dart#L663)
invokes synchronous destruction on its Dart isolate, and
[conversation destruction](../../native/foresight_native.cpp#L1268) joins native
work. The existing [follow-up](../plans/2026-10-21-native-close-follow-up.md)
records historical real-model blocking measurements. Those are not measurements
of this head. Preserve single handle ownership and real completion semantics
when designing asynchronous teardown; moving calls to another isolate without
an ownership protocol is insufficient. The
[RPC measurement tool](../../tools/measure_service_rpc.py#L419) retains 100
samples per condition and checks generation/capture overlap, a useful basis for
future verification.

**Diagnostic consistency.**
[Service diagnostics](../../packages/foresight_core/lib/src/service_diagnostics.dart#L7)
bound individual transport trace strings and keep internal stack diagnostics off
the wire. However, the opt-in
[invalid-frame trace](../../packages/foresight_core/lib/src/service_client.dart#L92)
includes raw malformed reply text. Prefer structured event names, request
correlation, failure categories, and redaction over content-bearing transport
payloads. This is an observability/privacy improvement, not evidence that normal
logging exports user data or that a log leak occurred.

**macOS distribution.** The [platform guide](../platforms/macos-support.md)
and [README](../../README.md#L99) correctly identify Developer ID signing and
notarization as unfinished. Current ad-hoc DMGs and runtime tests do not establish
signed, quarantined Finder launch or fresh-account permission attribution.
Complete that acceptance before claiming a finished signed distribution path.

**Native coverage visibility.** CTest and sanitizer suites exercise native code,
but no numerical C++ line/branch gate was found in the inspected CMake/workflow
paths. Add a scoped coverage report if it helps identify untested native
lifecycle paths; do not combine Python and Dart percentages into a repository-wide
coverage claim.

## Recommended sequence

1. Fix F1 first with storage-fault regressions for Stop, hide, and disconnect.
   Keep the change focused on unconditional resource cleanup and honest errors.
2. Fix F2 and F3 independently, with raw-protocol and stalling-transport tests.
   Address F4 through a narrow native capture change.
3. Add the compiled first-run journey in F6 and align publication evidence with
   the agreed manual policy in F5. Triage and native dependency monitoring in F7
   can proceed alongside this work.
4. Correct F8, then reduce demonstrated feature coupling and address native
   teardown with measured ownership/liveness acceptance. Preserve existing
   coverage, integrity checks, and installer trust boundaries throughout.

Runtime changes need the relevant full native, core, desktop, compiled service,
and isolated-display checks in [AGENTS.md](../../AGENTS.md), with Dart tests using
the freshly built native library/helper. Do not replace those checks with the
small source checks executed for this review.

## Validation and limitations

| Check | Result for this review |
| --- | --- |
| Repository baseline and inventory | Clean starting tree; reviewed SHA recorded above; 1,486 tracked files. |
| `python tools/check_subprocess_timeouts.py` | **Passed**; 368 Python source files inventoried. This is an AST timeout-policy check, not subprocess runtime acceptance. |
| `python tools/check_integration_inventory.py` | **Passed**; 40 Dart skip registrations have explicit validation paths. Its probe validation also covers 24 tool entries. This does not execute those skipped tests or probes. |
| Feature library inventory | Independently counted controller parts and physical lines; totals recorded above. |
| Document checks | Local source links and cited line anchors checked; new-file whitespace and final repository status checked. |

The two Python policy checks ran with the installed **Python 3.14.8**, not the
project's supported Python 3.13. They used `TMPDIR` and
`FORESIGHT_TEST_TEMP_ROOT` set to the private mode-0700 disk-backed directory
`/var/tmp/of-rev-1024`. Their output logs remain there as
`subprocess-timeouts.log` and `integration-inventory.log`.

No pytest suite, Ruff, mypy, Dart analysis/format/tests/coverage, Flutter tests,
native build/CTest/sanitizers, or compiled service/UI suite ran: the pinned Python
environment, Dart/Flutter, CMake/Ninja, prepared package configuration, and built
native outputs were absent from this checkout or PATH. Actionlint and ShellCheck
were also absent; no workflows were changed. Docker builds and installed-package
acceptance were not attempted. Actual macOS, physical audio/GPU, OS permissions,
sleep/wake, and real/restricted-model acceptance were not executed.

Source review cannot certify the absence of other bugs or vulnerabilities.
Historical test counts, coverage percentages, and timing records were not
reported as fresh passes. No application code, tests, configuration, workflow,
dependency, or release policy was changed. This review document is the sole
repository addition; no commit or push was made.
