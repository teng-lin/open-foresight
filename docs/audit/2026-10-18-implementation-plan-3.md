# Structural refactoring plan (plan 3 of 3)

Refreshed 2026-10-21 against fetched main
`3fb259243a99137e3cba1d5e795c44100f42e688` (#168, after release 0.1.3). ADR-0007 is merged (#164);
Summary (#165), meeting AI workflows (#166) and CI routing/cache stabilization (#163) are baseline
behavior, not outstanding feature work. Owned-DMG recovery and independent parallel fixture
contracts (#168) are now baseline too; application/native/helper trees and runtime gate scripts
are unchanged from c28, whose recorded builds/pass counts remain historical exact-source evidence.
These are **planned PR numbers**,
not GitHub PR #6/#7. The [comprehensive execution
plan](../plans/2026-10-20-core-desktop-refactor-plan.md) is authoritative for implementation
sequencing, contracts, tests and completion; its [review
record](../plans/2026-10-20-core-desktop-refactor-reviews.md) records iterative native-team and
Claude CLI review. This refreshed inventory replaces the pre-lifecycle specifications for PRs 6 and
7 below; PR 8's deferral is unchanged. Line references in the retained PR 8, process and Windows
sections remain historical audit references and must be refreshed when their work resumes.

This continues [plan 1](2026-10-18-implementation-plan.md) and [plan
2](2026-10-18-implementation-plan-2.md), addressing the [P2 maintainability
backlog](2026-10-18-consolidated.md#p2-maintainability-backlog). Fetch main before starting and
assess any further delta; do not replay ADR-0007 or other fixes
already delivered. Preserve
[AGENTS.md](../../AGENTS.md) and the current lifecycle matrix.

| Historical work package | Refreshed status | Scope | P2 coverage |
| --- | --- | --- | --- |
| 6 (former `refactor/core-service`) | Relevant; not implemented by ADR-0007 | Typed RPC contracts, core services, persistence/schema residuals, narrow desktop API, relay documentation and measured responsiveness | P2-1, P2-4, P2-6 core, P2-7, P2-8, P2-9 core, P2-11 core |
| 7 (former `refactor/desktop-features`) | Relevant; depends on PR 6 interfaces | Feature libraries, shell/onboarding/shared visuals, async read models, projection-based notifications and desktop boundary | P2-2, P2-9 desktop, P2-11 desktop |
| 8 `refactor/native-runtime` | **Deferred by owner** | Native split, backend removal and detector consolidation | P2-3, P2-5, ARCH-18 |

Owner direction (2026-10-21): deliver work packages 6 and 7 in one PR on
`refactor/core-desktop`, with separately reviewable/testable commits. Integrate core interfaces
before migrating desktop consumers; both acceptance sets remain required. Before desktop feature
extraction, freeze the post-refresh core completion commit and pass its full Linux matrix; record
that SHA separately from the final combined head, whose complete Linux and HanSolo Mac matrix
remains required. Rebase/main integration invalidates the core checkpoint until rerun. Coordinate exact-source
HanSolo Mac tests and obtain native-team plus Claude CLI implementation review before opening
the combined PR and driving it to merge. Estimates from the
original audit are withdrawn until Phase 0 produces the reconciled dependency and test inventory. Do
not start PR 8 or Windows support as a side effect. P2-10 remains owner process work; P2-12 remains
deferred until a Windows port is scheduled.

## Ground rules for refactoring

1. Mechanical moves preserve behavior. API enforcement, error classification and migrations are
   explicit intentional changes with their own tests. Decode-first rejection intentionally stops
   malformed agent requests from stamping activity or entering dispatched work; require the lifetime
   regression and PR change note in the execution plan. They also leave desktop-departure grace and
   its scheduled exit intact; valid dispatched changed-argument refusals retain activity accounting.
2. Characterize uncovered behavior before moving it. Retain existing assertions; adapt setup and
   replace source-shape tests with equivalent runtime contracts where needed.
3. Freeze one reconciled source baseline and shipped migrations. Work in independently testable
   steps; do not combine moves with unrelated logic changes.
4. Refresh reviewed main before review and assess its delta. Integrate the core interfaces before
   desktop feature extraction on the same branch; coordinate ownership of shared files. There is
   no intermediate PR merge.
5. Preserve ADR-0007's two exit branches, full busy/activity accounting, cancellation settlement,
   approvals, workspace epochs/dedup, ordered shutdown and safe resend semantics.
6. Allocate schema numbers from current main at implementation, append steps only, and preserve
   historical Dart transforms and their helper dependencies.
7. Targets apply to touched/extracted code. Report misses; line counts do not justify unsafe
   topology changes, new product behavior or scope expansion.
8. Use current CI gate scripts and complete native/core/desktop/compiled-process/real-UI
   verification. The old plan 1 command list alone is insufficient. Full details and concrete
   commands are in the execution plan.

## PR 6: Core service structure

Area: `packages/foresight_core/lib/src/`, `packages/foresight_core/bin/`, helper migration code,
narrow desktop adapters and necessary guards. Baseline: Application 2,856 lines plus 735 lines of
Summary/workflow/preparation parts (3,591
combined), service 3,313, Store 1,803, remote domain 1,053; schema version 15.

### 6.1 Declare operation contracts and type the RPC boundary

Still pending. Replace negative-list/prefix policy with explicit operation descriptors, typed
decoding and one registry. Include scope, approval/capability policy, helper/model gates,
notifications, streaming, lifetime activity, epochs and dedup. Preserve service envelope and
injected conversation/request identity; MCP schemas are projections of an explicit tool subset, not
the whole RPC schema.

Migrate `RpcError` catch sites before changing inheritance; preserve legacy closing text, reasons
and safe retry behavior. Handler `TypeError` becomes `internal`, while decoder failures remain
`invalidArgument`. Specify old/new peers and connect/reconnect compatibility, including development,
CLI, MCP and probes, before enforcing API versions. Decode before epoch validation, approval and
helper waits as an explicit intentional admission change; preserve the existing raw argument digest
across DTO conversion. Keep internal `questions` generation unexposed through MCP, its ordinary
artifact semantics, and task field-presence/null/manual-edit behavior. Extend literal/registry
guards to `packages/foresight_core/bin/` without
relying on the old switch's textual shape. See execution step 6A.

### 6.2 Decompose Application

Still pending. Extract workspace administration, model registry, source operations, Google
maintenance, Summary, Actions/Preparation workflow, enhancement and recording with explicit
constructor dependencies. Preserve actual
future/stream settlement in busy state, including orphaned work; lifetime ownership stays in the
service. Split answer phases into immutable results and move application SQL into persistence/query
methods. The three new Application parts are partial file separation; replace them with independent
services while preserving generation reservations/preemption, owned child cancellation, Summary
checkpoints, task evidence/manual state, cache identities and atomic accepted derived sources.
Remove Expando/convenience ownership only after all consumers migrate. See 6B.

### 6.3 Preserve and document the relay; measure domain blocking

**The old speculative relay removal is superseded.** Frontend and worker now implement structured
closing, public-socket ownership and crash recovery. Keep both and extend their documentation.
Characterize responsiveness, move expensive reads behind revision-safe read-only workers and
investigate proven blocking joins. Async polling every 20 ms is not by itself evidence of blocking;
callback/native changes require their own ownership/ABI/cancellation evidence. Native redesign
remains PR 8/follow-up work. See 6C, including measured performance targets, deterministic liveness
gates and the explicit client/ownership/frontend/request-routing service split with one lifetime
authority.

### 6.4 Complete schema residuals and split Store

- Freeze application migrations 1–15, including migration-private transitive Dart transforms
  isolated from live business helpers, using verified-main-source bootstrap, subsequent main
  manifests and archive-safe fixtures.
  CI independently resolves current reviewed main, verifies bootstrap ancestry and fails for a
  changed migration set/closure with a rebase/refresh diagnostic. Already locked packages may be
  promoted to exact-pinned direct dev dependencies for guard tooling with no resolved-version
  upgrade and a PR-description justification.
- Source URI backfill is **already migration 5** and Google table creation is **already migration
  8**; do not duplicate them. Only constructor modification-time repair remains to move.
- Preserve shipped migration 14 (artifact manifests/Summary checkpoints) and 15 (action alias,
  structured tasks/document-summary cache); allocate 16 or the next free version. Keep workflow
  savepoints, derived-source acceptance, delete/clear cleanup and legacy schema13/14 upgrades.
  Normalize all legacy action artifacts, edited or not. Source soft-delete
  invalidates cache eligibility through revision/content checks; cache rows are physically retained
  until workspace clear, so a purge is not part of this refactor.
- Labels remain dual-stored despite migration 9 reconciliation. Make structured records
  authoritative; preserve legacy JSON first-occurrence order, deduplicate names intentionally,
  append structured-only labels deterministically and preserve matching metadata. JSON-only labels
  become manual labels. Use an explicit durable ordinal, named-column current writes and
  reorder/VACUUM/reopen fixtures; derive compatible JSON projections. This preserves records
  available at the new migration, not rows already discarded by frozen migration 9's valid-JSON
  authority on pre-9 upgrades. Keep that historical behavior and its five-column writes unchanged.
  Report the deliberate surviving-record union and historical recovery limit as data changes;
  every label/graph projection orders explicitly by document identity and durable position.
  In the same migration transaction, canonicalize saved graph-label signatures only for previously
  valid layouts with unchanged membership; preserve positions and never bless stale saved state.
  Test order-only preservation, actual membership changes and rollback.
- Version all three helper databases, preflight all future versions before mutation and migrate
  transactionally with rollback/retry tests. Whole-set preflight checks stable original/sidecar
  identities before live writable opens/creates. Hot-journal qualification conservatively checks
  current and applicable original page-1 versions without custom recovery; WAL qualification uses
  a stable private DB+WAL snapshot with private SHM. Apply WAL protection to application writer
  migration opens and profile-copy tooling too; direct read-only WAL can mutate SHM, and immutable
  can miss a future WAL-only version. Pin actual attached commit boundaries, hidden future versions
  and original file-set/byte preservation. Recurring crash recovery remains SQLite-owned and
  separate from once-only migration; qualification copies never run on query refresh.
- Every application-read path checks schema before dependent queries: worker snapshots,
  authoritative identity/epoch checks before dispatch/acceptance, and synchronous reader adapters.
  Schema and dependent rows share a snapshot; opaque token samples stay at autocommit boundaries.
  A future schema retires coordinator/cache without publishing rows or looping, settles/cleans up
  pending work and reports the same typed failure. Test identity-table changes at each boundary.
- Split connection/write ownership, migrations, typed queries, document parsing and label planning
  without changing transactions or extraction sandbox behavior.

See 6D for migration/compatibility matrices, guard enforcement and exact acceptance.

### 6.5 Publish narrow interfaces and finish core hygiene

Extend the existing curated `remote.dart` API. Replace concrete Store/helper exposure with typed
read/query APIs, immutable status and separate connection lifecycle/events. Remove remote helper
inheritance and desktop construction of a write-capable gRPC client. PR 6 must also migrate enough
current desktop consumers to compile; include background queries, export, model setup and
model-terms writes plus typed task/evidence/manifest/history reads, not just controllers. Do not
export the mixed read/write MeetingWorkflowStore extension as a reader. PR 7 reorganizes the adapted
consumers.

Retain the scoped trace/cancellation/digest/protocol/getter cleanups and grpc workaround
regression/version guards. Prepare any upstream issue as a draft unless publishing is separately
authorized. Consume the existing `tools/pins.json`; read grpc/http2 resolved versions from the core
pubspec lock. See 6E.

PR 6 is done only when typed contracts, persistence/data preservation, public interfaces, lifecycle
invariants and applicable full gates pass; measured responsiveness residuals are reported
explicitly. Targets: Application <600 lines, call <80, answer phases <100, extracted functions <150,
persistence files <600, other touched handwritten core files <1,000, with justified exceptions.

## PR 7: Desktop feature modules

Area: all affected `apps/desktop/lib/` production consumers and tests. Depends on work package 6's integrated
interfaces on the same branch. Baseline: sources 2,386 lines, meetings 2,197 plus the 492-line meeting AI view part
(2,689 combined), settings 1,348, integrations 669, chat 324, onboarding 282, main 1,059.

### 7.1 Replace shared part controllers with feature libraries

Still pending. Include `meeting_ai_views.dart`, shell/composition, onboarding and workspace visuals
so the
no-handwritten-main-parts target is real. Introduce narrow
navigation/account/approval/selection/error dependencies before moving settings, integrations, chat,
sources and meetings. Each feature owns its local work; composition owns the shared connection, and
note saves drain before disconnect.

Capture-level notification isolation **already exists**; retain it as regression coverage. Ordinary
changes still use coarse service events and a shared revision. Start with conservative invalidation
and immutable projection comparison, then notify only changed views; preserve all genuine
cross-feature dependencies and unknown/reconnect/clear fallback.

Read/query work moves outside render call paths into typed cached view models. Keys cover filters,
epoch, revision, profile/connection, week boundaries and helper generation as appropriate. Reject
stale completions on search/selection/clear/reconnect/dispose using the execution plan’s
same-connection token coordinator and a transaction containing the actual epoch and complete read
projection; never compare SQLite revision tokens across connections. Identity mismatches discard;
ordinary same-owner token changes may publish a snapshot-consistent preview with a coalesced
refresh, never falsely mark it current or starve the view under sustained writes. Preserve
pending-create dedup, autosave, approval-host lifetime and safe handoff behavior. Preserve all six
meeting panels, streamed Summary/cancellation, structured/manual tasks, local Preparation and
degraded retry, scoped Chat/automatic Q&A and portable detector setup. Capture scope identity in
query/cache state; never widen selected-empty scope or let a retired scope persist an answer.
Characterize stale dialogs and AI switch/clear/reconnect races instead of assuming untested safety.
See 7A/7B for
ordering and per-feature scenarios. Keep current workflow/core/desktop/compiled regressions and
CI #163 owner routing and #168's independent DMG fixture selection/parallel execution; retain owned
attachment/unchanged-byte recovery contracts. DMG fixture success does not establish Mac application
acceptance. Release GPU waivers remain explicit and never waive automated acceptance.

### 7.2 Close the desktop boundary and remove obsolete coupling

Use curated public APIs and remove implementation re-export shims only after every consumer
migrates. Architecture guards cover imports, exports, parts and exposed mutable types. Move platform
policy to startup-injected capabilities, preserving macOS/Linux behavior. Remove dead state/wrappers
only after verifying disposal replacements. Replace private shell-introspection test fixtures with
isolated feature fakes. See 7C.

PR 7 is done when every feature can be built independently, handwritten main parts and shell
back-references are gone, render paths perform no persistence/expensive graph work, stale async
state cannot leak, rebuild/dependency tests pass and complete Linux/macOS process/UI scenarios pass.
Targets: feature files <800 lines and widget-returning methods <150, with justified exceptions. Unit
tests alone do not establish desktop/service boundary correctness.

---

## PR 8: Native runtime consolidation (deferred)

> **Deferred by owner decision (2026-10-18). Do not implement this PR until the deferral is lifted.** The specification below is kept so the work can resume without re-auditing.
>
> **Why it is deferred:** removing the `llama_cpp` backend (8.1) would break the developer model setup, which still depends on it.
> - `native/model_registry.json` makes Qwen2.5-1.5B-Instruct GGUF, run through llama.cpp's `llama-completion`, the default generation model.
> - `native/setup_models.py` builds that llama.cpp runtime.
> - `README.md:184` tells contributors to run that script.
> - `tests/test_reproducible_builds.py` references the registry.
>
> Removing the backend first needs a decision on the replacement developer model.
> - **Option A:** a small `.litertlm` model from `litert-community`, pinned by revision and SHA-256, with `setup_models.py` fetching the LiteRT runtime.
> - **Option B:** keep `llama_cpp` as a developer and test-only backend that release packages never use.
>
> **Interim state** (from plans 1 and 2; nothing more is required while the deferral stands):
> - Plan 1 (2.7) changed only the default backend to `litert_lm`; an explicit `llama_cpp` keeps working.
> - Plan 2 (5.1, NAT-24) removes private text from argv on every path, including llama.cpp, which closes its privacy residual.
> - The native split (8.2) and the single question detector (8.3) stay as tracked debt. The Linux package keeps the Python question detector.
>
> **Revisit when** any of these happens:
> - the owner chooses Option A or B;
> - a Windows port is scheduled, since both 8.2 and 8.3 reduce the porting surface;
> - work on `native/foresight_native.cpp` becomes hard to review;
> - the Python question detector causes a packaging or security issue.
>
> If only 8.2 or 8.3 is wanted sooner, either can land alone: neither depends on 8.1.

Branch: `refactor/native-runtime`. Area: `native/`, `services/inference/`, `tools/package*.py` and the related Dart model setup.

### 8.1 Remove the `llama_cpp` backend (ARCH-18, P2-5 part)

**Problem:**
- `llama_cpp` (backend 0) is still selectable, and it was the default until plan 1.
- It keeps alive the legacy branches in `fs_conversation_create`: the llama.cpp argv contract (`foresight_native.cpp:895-912`) and the non-worker tool mode (`:913-932`).
- It still has default values at `native.dart:24,154`, `store.dart:193,622`, `domain.dart:318,400` and `model_setup.dart:22`, and backend identifiers are spelled two ways (ARCH-20: `helper.dart:92`, `settings_controller.dart:343`, `foresight_native.cpp:671`, `services/inference/main.cpp:176`).

**Change:**
1. **Migrate stored registrations.** Add a Store migration that marks any registration with backend `llama_cpp` as `unsupported`, keeping the row. The desktop shows "This model backend is no longer supported; set up the model again" and links to Gemma setup. The service refuses to load unsupported registrations with a structured error. Don't delete user files.
2. **Delete backend 0.** Remove it from the native library, the Dart enums and defaults, the settings UI and the docs. Require `worker_protocol` for LiteRT runtimes, and refuse runtimes that don't advertise it with an actionable error.
3. **One spelling per backend.** Unify the backend identifiers to a single shared constant set used by Dart and C++.

**Tests:**
- the migration test (a `llama_cpp` row becomes `unsupported`, and loading it gives a clear error);
- the existing generation tests on LiteRT;
- `one_shot_argv.cpp` updated for the removed path.

### 8.2 Split `foresight_native.cpp` (P2-5: ARCH-N5)

**Problem:** `native/foresight_native.cpp` grew from 1,086 to 1,880 lines. `fs_conversation_create` (`:793-1115`) contains a roughly 320-line worker lambda that mixes protocols, UTF-8 boundary handling, terminal-status derivation and GPU→CPU fallback (`:1044-1070`). Capture, speech, process and generation code share one translation unit, with 11 `__APPLE__` conditionals.

**Change:**
1. **Extract the generation units:** `PersistentGenerationSession` (worker lifecycle, framing, cancellation, fallback), `ToolProtocolParser` (tool-frame parsing) and `TerminalStatus` (status derivation). Give each its own header-only or `.cpp` unit and its own unit tests in `tests/native/`.
2. **Split the translation unit:** `generation.cpp`, `speech.cpp`, `capture.cpp` (with platform files `capture_linux.cpp` and `capture_macos.mm` replacing the `__APPLE__` branches), `process.cpp`, and a thin `foresight_native.cpp` that holds only the `extern "C"` exports and their exception barriers.
3. **Keep the C ABI unchanged.** Dart bindings must not change, and `tools/check_dart_bindings.py` stays green.

**Targets:** no native file over 600 lines; no function or lambda over 100 lines.

**Tests:** all CTest targets pass under GCC, under Clang with ASan/UBSan, and under TSan; the new unit tests cover framing, tool parsing and the fallback decisions.

### 8.3 One question-detector implementation (P2-3: ARCH-N3)

**Problem:**
- The dedicated question detector has two implementations.
- On Linux the launcher sets `FORESIGHT_QUERY_WORKER` to the Python `legacy_query_worker.py` (`tools/package.py:293`), with the Python executor in `tools/legacy_query_worker.py`, `legacy_query_executor.py` and `legacy_query_weights.py` (621 lines) and an optional bundled Python (`tools/package.py:214-226`).
- On macOS it is the C++ `foresight-query` (`tools/package_macos.py:163,208`, built from `services/inference/legacy_query.cpp`, 659 lines). That binary is already built and installed on every platform (`services/inference/CMakeLists.txt:33-48`).
- On the Dart side, `DedicatedQueryRuntime` names the executable `python` (`dedicated_query_runtime.dart:26-38`, `application.dart:~402-413`).

**Change:**
1. **Prove parity first.** Run the shared detector cases through both implementations: `tests/inference/test_native_query.py`, `test_legacy_query_worker.py`, `test_legacy_query_executor.py`, `test_raw_query_model.py` and `raw_query_probe.cpp`. Add a parity test over a fixed corpus of transcript windows, comparing detected questions and scores within a tolerance. Fix any divergence in the C++ implementation before switching.
2. **Switch Linux to the C++ binary.** Point the Linux launcher at the bundled `bin/foresight-query`, and stop bundling the Python runtime and wheels for the detector if nothing else needs them. Check `tools/package.py` and the package payload tests, and update the notices and copyright stanzas (plan 1, 1.2) if components drop out.
3. **Keep Python only as a test oracle.** Move the Python executor under `tests/` (as was done for citation checking), used only by the parity test.
4. **Rename the field.** In `DedicatedQueryRuntime`, rename `python` to `executable`, and update its callers.

**Tests:** the parity test; the installed-package acceptance (plan 2, 4.4) confirms the Linux package runs the C++ detector; the package payload tests confirm the Python detector files are gone.

**PR 8 is done when:**
- the targets are met;
- the native suites are green under all sanitizers;
- the Linux and macOS packages run the same detector;
- `services/inference/README.md` and the architecture docs describe the single runtime;
- the CHANGELOG notes the `llama_cpp` removal as a user-visible change.

---

## Process changes (P2-10, owner)

These are repository settings and team practice, not code:
- **Merge methods.** Allow only squash or rebase merges in the plan 1 Step 0 ruleset. Turn off merge commits.
- **PR size.** Adopt a guideline: under about 1,500 changed lines, or otherwise one reviewed design. The plan 3 PRs are an explicit exception, made reviewable by their commit structure.
- **Merge queue.** Enable a merge queue on `main`, so that `platform-checks` runs on the merged result.
- **Shared refactors land first.** Land shared refactors before feature work, and rebase feature branches onto them instead of merging `main` into branches.

## Deferred: P2-12 Windows seams

Do this only when a Windows port is scheduled. At that point:
- Introduce `LocalTransport` (Unix socket or named pipe), `PrivateFileOps` (POSIX modes or Windows ACLs) and `ProcessSandbox` interfaces, selected once at startup.
- Move the 42 POSIX-specific Dart references behind them: `/bin/chmod`, `/usr/bin/stat`, `/usr/bin/id`, `/usr/bin/dscl` and `/usr/bin/bwrap` in `platform_services.dart:114-122`, `profile_paths.dart:27-59` and `store.dart:1272-1319`.
- Abstract the Unix-socket IPC (`helper.dart:62-63`, `service.dart:1022-1024`).
- Abstract the native process control (`native/portable_process.h`, `services/helper/child_process.h`).

PR 6's `DocumentParser` split and PR 7's `PlatformCapabilities` are the first steps.
