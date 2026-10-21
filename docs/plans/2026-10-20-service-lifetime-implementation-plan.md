# ADR 0007 implementation plan: service lifetime and the desktop/agent boundary

This plan implements [ADR 0007](../adr/0007-service-lifetime-and-desktop-agent-boundary.md) (revision 6) as one PR. It is written for an agent working without other context. Read the ADR first; this plan does not restate the decision, it says how to build it, where the ADR's text disagrees with the code, and how to verify the result.

| | |
|---|---|
| Base | `main` at `896596f8`: PR #159 (`6a5216f2`, the lifecycle integration) plus its follow-up PR #160 (both merged 2026-10-20). Line numbers below are given at `a7243915`, the last head of `open-foresight-services`, whose tree #159 squashed unchanged. #160 moved lines in three cited files only: `remote_domain.dart` (+12 from line 420, +39 from line 642), `commit_safety_test.dart` (+1 from line 9) and `tests/service/test_service_process.py` (+1 from line 1524, +4 from line 1548); every other cited line holds. Always locate code by symbol name. The Codex agent's integration branch `codex/pr159` is reset to that `main` before work starts. The idle exit relies on #159's closing protocol, `RpcErrorReason` and the resend-once handoff. |
| Branches | Three workstream branches from `codex/pr159` (section 0.1), each in its own worktree, merged back into `codex/pr159` with `--no-ff` after review; then one PR from `codex/pr159` to `main`. |
| Scope guard | Only the files named in this plan (section 0.1 lists them per workstream). No refactors of `Application` or `ApplicationService` beyond what a step says. Follow `AGENTS.md`: run the full verification before pushing, and list every existing test's verdict in the PR description. |
| Size | About 450 lines of production Dart across the core, 40 in the desktop, 30 in Python tools and fixtures, plus 800 to 1000 lines of tests. Five to seven days including both verification environments, more than the ADR's estimate because of the cancellation threading in step 1.3. |

## 0.1 Workstreams, worktrees and the merge order

The steps in section 2 split into three workstreams that touch disjoint files, so they can be implemented in parallel in separate worktrees (`git worktree add ~/src/ofs-adr7-<ws> -b svc/adr7-<ws> codex/pr159`). The only shared contract is the `status.lifetime` object of section 1.6 and the `stop_if_idle` messages of step 2.2; both are fixed by this plan, so B and C can be written before A merges and are verified end to end after it.

| Workstream | Branch | Steps | Files | Depends on |
|---|---|---|---|---|
| A, core | `svc/adr7-core` | 0 (ADR revision 7), 1, 2, 3, 4, and the coverage matrix (step 7.3) | `packages/foresight_core/lib/src/{service,application,domain,helper,rpc_error,agent_access,google_connections,reference_note_transcript_cache}.dart`; every `Domain` subclass that overrides `index` or `waitForSourceWork` (step 1.3 lists the ten, including one under `apps/desktop/test/` and two under `packages/foresight_test_support/lib/`); the two `GoogleConnections` test doubles under `apps/desktop/test/` (step 1.3); `packages/foresight_core/test/*`; `packages/foresight_test_support/lib/*`; `docs/adr/0007-*.md`; `docs/architecture/service-lifecycle-tests.md` | nothing |
| B, desktop | `svc/adr7-desktop` | 5 | `apps/desktop/lib/settings_controller.dart`, `apps/desktop/test/desktop_parity_audit_test.dart` | nothing (the preference key is a string) |
| C, process suite and docs | `svc/adr7-suite-docs` | 6.1, 6.2, 7.1, 7.2 | `tests/service/test_service_process.py`, `tools/smoke_macos_bundle.py`, `tests/test_macos_tools.py`, `docs/architecture/application-service.md`, `README.md`, `docs/platforms/macos-support.md`, `services/inference/README.md`, `docs/validation/issue-142-functional-followups.md` | A for its end-to-end run; it is written against the contract first |

Within A the steps are serial (1 → 2 → 3 → 4); do not split A further, because steps 2 and 3 both edit `_accept`, `_results`, `_execute` and `_close`. The coverage matrix is A's because its cells cite exact test names that only A knows.

Merge order into `codex/pr159`: A first (`git merge --no-ff svc/adr7-core`), then B and C in either order, each after its own review and after re-running its verification on the merged tip. After all three are in: the cold-start measurement (step 6.3) is one final commit on `codex/pr159`, then the full Linux verification of section 4, the Mac verification, and the one PR to `main`. The three branches are never pushed to `origin`.

PR #160 (the #159 follow-up) is already in the base. One more fix is queued: branch `svc/fix-161` at `1f3ecc9e` ("treat a listener that closes during a connect as gone, not an error"), one commit on top of `896596f8`, changing `service_socket.dart`, `ServiceClient` in `service.dart` (`:666-682`, +8 lines), `service_connection_test.dart`, `service_socket_test.dart` and the coverage matrix (+4 lines). Once it merges, every `service.dart` reference in this plan at or after `:674` moves by +8 and the matrix cells by +4; workstream A overlaps on `service.dart` and the matrix and rebases onto `main` before its review. Check `gh pr list` before opening the final PR and rebase `codex/pr159` onto `main` if anything else has merged meanwhile.

## 0. Corrections to the ADR before coding

The inventory of `a7243915` and the first review round found the following places where ADR revision 6 does not match the code or itself. Commit an ADR revision 7 as the first commit of workstream A, with these corrections, so the ADR and the code never disagree. Each is referenced by its letter below.

| | ADR text | Correction |
|---|---|---|
| C1 | Tests item 8: a `needsDesktop` denial still produces "the agent-activity stamp". | No. Decision 2 and "The rule" stamp only at dispatch, and `AgentAccessGate.authorize` throws before dispatch (`agent_access.dart:173-177`, before its first `await`). Test 8 asserts `denied` with `reason: needsDesktop` and that `last_agent_activity` stays `null`. |
| C2 | Tests item 6: fix-plan tests 2 and 7 "reused with the idle exit as the trigger", including "a request dispatched before it gets `outcomeUnknown`". | A dispatched non-`status` request is busy and holds both exits, so an automatic exit never produces `outcomeUnknown` for one. Only the `closing` half is reused with the idle exit; `outcomeUnknown` stays the explicit-stop and SIGTERM case. The one exception is a `status` dispatched in the microtask between `lease.waiting = false` and its `application.call`, which an exit started by another event can still meet; it gets `outcomeUnknown` exactly as today (`service_closing_protocol_test.dart:1065` pins that frame for SIGTERM), and a client may always resend `status` (fix plan 3.2). |
| C3 | Tests preamble: short periods "use a fractional `serviceIdleMinutes` over `preferences.set`". | `preferences.set` is approval-gated for non-host connections (`operations.dart:87-120` omits it) and is not an MCP tool. In-process Dart tests set it with `Store.setPreference`; child-process Dart tests seed it with `Store` before launching; Python tests set it through the `ApprovalDesktop` fixture before its review thread starts (step 6.1). |
| C4 | "The rule" item 3 lists `_modelBusy` and `_queryAcquisition` as model work "with no lease", and Context says dedicated query acquisition has no lease. | Both are set only inside a leased `models.*` call (`application.dart:682`, `:1209`). They stay in `backgroundBusy` as a guard, but item 1's operation tracking already covers them. |
| C5 | "The rule" item 3: "A scheduled but unfired `_enhance` timer is not busy … on the idle branch it fires inside the period anyway." | Two timers exist: 30 s after a notes edit (`application.dart:1861`) and a 3 s retry (`:2151`); targeted edits start enhancement at once with no timer (`:1851-1853`). The rule stands (an unfired timer is not busy), and the sentence "it fires inside the period anyway" is dropped: it holds for the default period and not for a test period. |
| C6 | "The rule" item 3: "an underlying proactive answer drain not yet settled". | No such future exists today: the `Future.any` at `application.dart:296-324` discards the `indexMeeting` and `drain()` futures. Step 1.5 adds the tracking. |
| C7 | Changes item 1: `current` is forwarded "for `sources.index`" only. | A cancelled operation parked in `waitForSourceWork` from any of `sources.import`, `import_file`, `import_url`, `import_directory`, `sources.refresh`, `google.import_file`, `google.import_folder`, `google.refresh` or a leased meeting index would hold the idle exit until sources are resumed. Step 1.3 threads cancellation through all of them. |
| C8 | "The rule" item 3: a helper `_start` in flight is terminated by `close()` as today. | `Helper.stopping` is set only by `helper.close`, which runs after `application.close` (`service.dart:1792-1799`). While `application.close` finishes a recording, a pending ping can succeed and `onReady` can start `Domain.resume` model loads after the exit decision. Step 3.6 clears `helper.onReady` synchronously at the start of `_close`. |
| C9 | Changes item 1: `Helper` exposes `starting` as "`_startupProbe` or `_launching` pending". | Those fields are assigned (`helper.dart:189`, `:217`) and never cleared. Step 1.6 adds completion flags and a probe-timeout seam for tests. |
| C10 | Tests item 9 lists the unchanged tests. | `service_closing_protocol_test.dart:285` (`a request in flight when the worker begins closing gets a terminal outcomeUnknown frame (SL-4)`) uses a desktop close while a non-desktop `notes.save` is dispatched and gated. Under the ADR that request blocks the close, and the test would time out. Step 3.9 changes its trigger to SIGTERM. |
| C11 | Changes item 1: replace `_desktopShutdown` with `_lifetime`. | The seven uses of `desktopShutdownScheduled` in `service_agent_access_test.dart` (lines 251-369) must keep working. The getter stays and means "the desktop-branch shortcut is armed and its close has not begun". |
| C12 | Changes item 6 (docs). | `application-service.md:109` ties `reason` to `unavailable` errors only; it gains `needsDesktop` on `denied`. |
| C13 | Changes item 5 (Settings row). | `DesktopSettingSelect` wraps `DropdownButton`, which asserts that the value is one of the items. A stored value outside the list (`0.05` from a test profile) would throw. The row adds the stored value as an extra item when it is not in the list. |
| C14 | Changes item 4: `idle_minutes: n`. | It is a JSON number (double), not a string, so `0.05` round-trips. |
| C15 | "Exit", desktop branch: "no non-`status` agent operation dispatched or in cancellation cleanup". | Also no non-`status` agent lease waiting for helper readiness (`lease.helperWait`, set immediately before `await _ready` at `service.dart:1696` and before `Stream.fromFuture(_ready)` at `:1602`, cleared at dispatch). A lease waiting for approval does not count: `detach` fails it synchronously (`agent_access.dart:131-140`) but its `onError` removal runs a microtask later, after the arming decision in the same `onDone` handler, so counting every waiting lease would wrongly leave the service on the idle branch. Without C15, a desktop departure during a helper start refuses the agent's first request with `closing` and the resend pays a second cold start on the replacement, which Decision 1 ("no client disconnect interrupts agent work") exists to prevent. A waiting lease still stamps nothing until it is dispatched. |
| C16 | "The rule" names `_exitIfIdle`, `_shouldExit`, `lastDesktopDeparture`, `_lifetime`; Changes item 1 also names `_busy`. | The plan uses exactly those names (section 1). |
| C17 | Decision 2: the default "is unmeasured: the implementing PR records a cold start … and keeps 30 only if a gap of that length costs more idle memory than one cold start is worth." | The comparison is not defined in measurable terms. The PR records the numbers (step 6.3) and reports them in the ADR; the default stays 30 unless the repository owner changes it on reading them. The implementer does not choose. |
| C18 | "The rule" busy item 2: `captureState['active'] == true \|\| captureState['finishing'] == true`. | Implemented as `application.recording != null`, which is what `captureState['active']` reads (`application.dart:605`) and which stays non-null through `finishing` and finalization (`:2353`); `captureState` builds a map on every read and the predicate now runs on every helper and change event. |
| C19 | Tests item 5 names "model configuration" and "a cancelled search whose retrieval is still gated (then `stop_if_idle` refuses until the retrieval is released)". | With no gRPC helper in the in-process fixture, `sources.search` fails before any gate and `models.*` fails at once, so neither can be held. The cancelled-and-still-executing case is covered by a `notes.save` held at `request.committed.notes.save` after its lease is cancelled; model configuration is covered by lease busy (item 1) and `_modelBusy`. |
| C20 | Decision 2: `lastAgentActivity` is stamped when "a request from a connection not in `_desktopClients` is dispatched". | Whether a lease is agent work is fixed when the lease is created, not at dispatch. The two agree in practice (a desktop reserves on its connection before any business call, `remote_domain.dart:256-300`, and a departing desktop's waiting leases are cancelled before they could dispatch), and a creation-time value is simpler to reason about. |
| C21 | "The rule", desktop branch: busy item 2 need not hold it because the close finishes transcription, "which `test_service_stop_waits_for_active_capture_and_finalizes_transcript[desktop-close]` pins". | After this change that test's peer has done agent work, so it exercises the idle branch (step 6.1). The desktop-branch claim is pinned instead by `[explicit-stop]` (the same close path) and by the step 3 test "departure with an active `TestRecording` and `recordingMeeting` set, no agent work: the close begins after the grace and `stop()` runs before cleanup completes". |
| C22 | Tests items 1 and 3 name `sources.search` and `answer.stream`. | The in-process fixture has no gRPC helper, so item 1 uses `notes.list` (any non-`status` agent request stamps alike) and item 3 holds `meetings.generate` with a fixture generator (`answer.stream` is an alternative where a generator fixture serves it); the Python suite exercises `search` through the real helper in the agent-only relaunch test. |

Also add to the ADR's Status row: "Revision 7, <date>: corrections C1 to C22 from the implementation plan" and link this plan.

## 1. The design in one page

All lifetime state lives in `ApplicationService` (`packages/foresight_core/lib/src/service.dart`). `Application` and `Domain` only report whether background work is executing. Nothing below the service decides to exit.

### 1.1 State

```dart
// Replaces `Timer? _desktopShutdown` (service.dart:948).
Timer? _lifetime;                    // created with domain.createTimer; cancelled in _close and _discard
final DateTime _started;             // `_started = domain.clock.now()` in the private constructor's initializer
                                     // list (:963); stands in for lastAgentActivity. It must exist before the
                                     // changes listener at :989, which can call _exitIfIdle before _start ends.
DateTime? lastAgentActivity;         // public for tests and status
DateTime? lastDesktopDeparture;      // set when the last desktop leaves AND the shortcut is armed; null otherwise
final _dispatched = <_RequestLease>{}; // non-status operations whose work or stream cleanup has not settled, any origin
```

`_RequestLease` (`service.dart:921-931`, constructor `_RequestLease(this.id, this.method)`) becomes `_RequestLease(this.id, this.method, {required this.agent})` with `final bool agent` (decided at lease creation, `:1505-1511`: `!_desktopClients.contains(client)`, C20), `bool streamed = false` (set in `_results` for `answer.stream`, `google.sign_in`, `google.add_account`, `:1604-1621`) and `bool helperWait = false` (set immediately before `await _ready` in `_execute`, `:1696`, and before `Stream.fromFuture(_ready)` in `_results`, `:1602`, and cleared by `_dispatch`, so it is true only while the lease waits for helper readiness; C15).

`double get _idleMinutes`: `double.tryParse(domain.store.preference('serviceIdleMinutes', '30')) ?? 30`, then `0` when the value is not finite or `<= 0`. `Duration? get _period => _idleMinutes == 0 ? null : Duration(milliseconds: (_idleMinutes * 60000).round())`. Both read on every evaluation, so `preferences.set` takes effect at once.

`bool get _unpinned => _desktopClients.isEmpty && !access.hasHost;`

`bool _stampExempt(String method) => method == Operation.status.wire || method.startsWith('security.') || method.startsWith('service.');`

### 1.2 Busy

```dart
/// Shared by the automatic exit and service.stop_if_idle. Synchronous: never add an await.
bool _busy() =>
    // 1. a lease other than status, waiting or dispatched (today's _stopIfIdle check, service.dart:1654-1662)
    _leases.values.any((l) => l.values.any((x) => x.method != Operation.status.wire)) ||
    // 1b. dispatched work whose future or stream cleanup has not settled, including cancelled leases
    _dispatched.isNotEmpty ||
    // 2. capture (C18): `recording != null` is exactly captureState['active'] (application.dart:605),
    //    it stays non-null through finishing and finalization (:2353), and it avoids building the map
    application.recording != null ||
    // 3. model work with no lease
    application.backgroundBusy;
```

`Application.backgroundBusy` (new getter, step 1.7):

```dart
bool get backgroundBusy =>
    _modelBusy ||                                  // C4: a guard only
    domain.resumeInProgress ||                     // _resuming != null
    domain.initializationPending ||                // _initialization set and not yet complete; not the restoring latch
    _activeEnhancements > 0 ||                     // producers running, survives workspace.clear
    proactive.running || _proactiveWork > 0 ||     // detection, plus the discarded answer and index futures (C6)
    _noteTranscriptCache.computing > 0 ||
    domain.mutating > 0 ||
    _queryAcquisition != null ||
    (domain.generator?.generating ?? false);
```

Not busy, by decision: a scheduled unfired `_enhance` or `_liveIndex` timer; durable work parked in `waitForSourceWork`; a helper `_start` in flight; the Google maintenance timer and its network phase. `domain.mutating` is bounded by the helper RPC deadlines: 30 minutes for `indexDocument` (`domain.dart:247-256`), 5 s for pending deletes (`:89`), and the client default of 45 s for `_delete` (`helper.dart`, `helperClient`); the ADR's Decision 1 accepts the 30-minute hold for an indexing drain.

### 1.3 Exit

```dart
/// A non-status agent lease waiting for helper readiness, dispatched, or in cancellation cleanup (C15).
bool get _agentWorkInFlight =>
    _leases.values.any((l) => l.values.any((x) => x.agent && x.helperWait && x.method != Operation.status.wire)) ||
    _dispatched.any((lease) => lease.agent);

/// The earliest time close() may begin, or null when no exit is scheduled.
DateTime? _exitAfter() {
  if (_closing || !_unpinned) return null;
  if (lastDesktopDeparture != null) return lastDesktopDeparture!.add(_desktopDetachGrace); // desktop branch
  final period = _period;
  if (period == null || _busy()) return null;                                             // idle branch
  return (lastAgentActivity ?? _started).add(period);
}

bool _shouldExit() {
  if (_closing || !_unpinned) return false;
  final now = domain.clock.now();
  if (lastDesktopDeparture != null) {
    // Desktop branch: Decision 1 keeps an executing serialized mutation; everything else is cancelled by close().
    return !now.isBefore(lastDesktopDeparture!.add(_desktopDetachGrace)) &&
        !_agentWorkInFlight &&
        domain.mutating == 0;
  }
  final period = _period;
  if (period == null || _busy()) return false;
  return !now.isBefore((lastAgentActivity ?? _started).add(period));
}
```

**Arming the shortcut** happens only in the socket `onDone` handler where today's timer is created (`service.dart:1570-1587`): when `_desktopClients.remove(client)` leaves it empty, `!access.hasHost`, `!_closing`, `!_agentWorkInFlight`, and `lastAgentActivity == null || (_period != null && !now.difference(lastAgentActivity!).isNegative && now.difference(lastAgentActivity!) >= _period!)`. Then `lastDesktopDeparture = now`. Otherwise it stays `null` and the idle branch governs. **Disarming:** any agent dispatch (`lastDesktopDeparture = null` in `_dispatch`), and any desktop reservation (`_desktopClients.add` at `:1406` and `:1479`, which today cancel the timer). The timestamp ageing out never re-arms it.

**`desktopShutdownScheduled`** (C11) becomes `lastDesktopDeparture != null && !_closing`.

Reentrancy: the arming and the `_exitIfIdle()` that follows it are the last statements of the `onDone` handler, after `client.destroy()` (`:1569`). The handler's own `_cancel` loop (`:1560-1562`) runs with reevaluation suppressed (`_cancel(client, id, reevaluate: false)`), so an agent disconnecting with a never-dispatched lease after the period does not start `close()` in the middle of the handler, before `_leases.remove(client)` and `client.destroy()`; the handler's final `_exitIfIdle()` makes the decision once. With `desktopDetachGrace: Duration.zero` (`service_closing_protocol_test.dart:761-764`) `_shouldExit` is already true at that point, so `close()` now starts synchronously inside the handler instead of from a zero timer; that is safe because `_close` sets `_closing` before its first await.

### 1.4 Reevaluation

```dart
void _exitIfIdle() {
  _lifetime?.cancel();
  _lifetime = null;
  if (_closing) return;
  if (_shouldExit()) {
    // No await between the decision and close(): nothing can become busy in between.
    unawaited(close().catchError((Object error) {
      stderr.writeln('Automatic service exit: $error');
    }));
    return;
  }
  final after = _exitAfter();
  final now = domain.clock.now();
  var delay = const Duration(seconds: 30);
  if (after != null && after.isAfter(now) && after.difference(now) < delay) delay = after.difference(now);
  _lifetime = domain.createTimer(delay, _exitIfIdle);
}
```

Called from:
- the end of `_start`, immediately before `return service` (`:1218`), once `helper.start()` has been kicked off; `_started` itself comes from the constructor initializer list (section 1.1), because `application.startBackground()` (`:1168`) can emit `changed()` before `_start` returns;
- `_dispatch` and `_settle` (step 2.1);
- **every lease removal**, `status` included: the outer subscription's `onDone` and `onError` after `_send` and `_leases[client]?.remove(id)` (`:1528-1541`), `_cancel` after its removal (`:1718`, unless called with `reevaluate: false` from the socket `onDone` handler; from `_close`'s terminal loop it returns at once because `_closing` is set), and the pre-dispatch failures that reach `onError` (authorize denial, rate limit, `closing`). A `status` dispatch itself never reevaluates (an evaluation before `application.call` could close the service and refuse that very request). This is what lets a test advance the injected clock and trigger the exit with a `status` call: the reply is written before the lease is removed, so the caller sees its result and the close begins after; only an exit that another event started independently can still end it with `closing` (not yet dispatched) or `outcomeUnknown` (dispatched), and the tests tolerate both;
- the socket `onDone` handler after the shortcut decision;
- both desktop reservations (`:1406`, `:1479`), and after the explicit `security.detach_desktop` at `:1415` (a reschedule only: the socket stays in `_desktopClients`, so `_unpinned` is still false). Not after the `access.detach` at `:1551` inside the socket `onDone` handler, which must decide once, at its end (section 1.3);
- the `application.changes` listener in the constructor (`:989`, `_changes = application.changes.stream.listen(...)`), which `preferences.set`, capture changes and every settle notification of step 1.8 reach;
- the `helper.changed` wrapper (`:1202`).

The heartbeat (`:999`) does not call it. With no event, the timer re-checks every 30 s, so a laptop that slept past the period exits on its first tick after wake.

### 1.5 The close

`close()` is called with no acknowledgement client, exactly as today's timer callback at `:1577-1585`. In `_close` (`:1748`): in the synchronous prologue, cancel `_lifetime` where `_desktopShutdown` is cancelled (`:1751`) and set `domain.helper.onReady = null` there too (C8; `onReady` is read at call time, `await onReady?.call()` at `helper.dart:297`, and the `close.begin` and `close.leases_terminated` gates at `:1786-1788` are awaited before `application.close`, so a later assignment would leave a window under a held gate). The terminal-frame loop (`:1766-1775`) is unchanged: a dispatched `status` still gets `outcomeUnknown` (C2). `_discard` (`:1006-1010`) cancels `_lifetime` too.

### 1.6 Status

In `_execute` (`:1689-1715`), when `method == Operation.status.wire`, merge `'lifetime': _lifetimeState()` into the map `application.call` returned (the map is built at `application.dart:695-719`; nothing merges into it today). `IsolatedApplicationService` copies bytes, so nothing changes there; `--status` prints the whole map (`packages/foresight_core/bin/service.dart:130-131`).

```dart
Map<String, Object?> _lifetimeState() => {
  'pinned_by_desktop': !_unpinned,
  'busy': _busy(),
  'last_agent_activity': lastAgentActivity?.millisecondsSinceEpoch,
  'idle_minutes': _idleMinutes,            // double, 0 when disabled (C14)
  'exit_after': _exitAfter()?.millisecondsSinceEpoch,
};
```

`exit_after` is `null` while pinned, while the idle branch is busy, and when the period is disabled with no shortcut armed. It is the earliest time the close can begin; cleanup follows it.

## 2. Steps

Each step is one or more commits that compile and pass tests on their own. Write the step's tests first and confirm they fail on the base where the behavior changes.

### Step 1. Instrumentation in `Domain`, `Application` and `Helper` (no behavior change)

**1.1 `Domain.mutating`** (`domain.dart:155-164`). A counter incremented inside the `.then` closure of `_serialize` after `checkWorkspace(generation)` and before `operation()`, decremented when `operation()` settles (`try/finally` around the awaited call). A paused `index` closure that returns `false` at once (`:204`) counts for zero time. Add `void Function()? onBackgroundSettled`, called after each decrement; `Application` sets it to `changed` (step 1.8). Test, `domain_mutating_test.dart`, with `DelayedIndexService` (`packages/foresight_test_support/lib/delayed_index_service.dart:8-30`, `started`/`release` completers): `mutating` is 1 while blocked and 0 after; a queued second `index` does not count until it starts; `delete` and `retryPendingHelperDeletes` count the same way.

**1.2 Resume and initialization flags** (`domain.dart:394-405`). `bool get resumeInProgress => _resuming != null;`. `bool _initializationDone = false;` set in `initialize` through `task.whenComplete`, which also calls `onBackgroundSettled`; `bool get initializationPending => _initialization != null && !_initializationDone;`. `resume`'s `whenComplete` (`:403`, `_resuming ??= _resume().whenComplete(() => _resuming = null)`) calls `onBackgroundSettled` **after** `_resuming = null` inside that same callback; called before it, the notification would reach `_exitIfIdle` with `resumeInProgress` still true. `restoring` is unchanged (the latch the ADR excludes; `modelBusy` keeps using it). Test: `initializationPending` is true until the manifest registration task completes, even when `resume` never runs; `resumeInProgress` is false after `_resume` throws; both transitions notify.

**1.3 Cancellation that reaches parked and shared work** (C7). One mechanism in `Domain`:

```dart
/// Completes with RpcError(cancelled) once [current] returns false. Re-checked by
/// checkCancellations() and on every source-work wake; the watcher is removed when
/// the returned future is no longer awaited (the caller wraps its Future.any in try/finally
/// and calls the returned registration's dispose()).
CancellationWatch whenCancelled(bool Function() current);
void checkCancellations();   // ApplicationService._cancel calls this after marking the lease cancelled
```

- `Future<void> waitForSourceWork({bool Function()? current})` (`:137-143`): with `current`, each wait is `Future.any([resumed.future, watch.future])` and `current` is tested before each wait and after each wake; a false result throws `RpcError(RpcErrorCode.cancelled, 'Operation cancelled')`.
- `Future<void> index(String id, {bool Function()? current})` (`:198-209`) passes it to `waitForSourceWork`.
- Every `Domain` subclass that overrides `index` or `waitForSourceWork` must accept the new optional parameter (Dart rejects an override that drops it). At `a7243915` there are ten: `packages/foresight_core/test/application_test.dart:12`, `commit_safety_test.dart:23`, `meeting_failure_recovery_test.dart:23`, `note_transcript_cache_application_test.dart:92`, `proactive_application_test.dart:27`, `application_operations_test.dart:63` (`OperationsDomain extends AdapterDomain`), `google_connections_test.dart:19` (`FailingImportDomain extends AdapterDomain`); `packages/foresight_test_support/lib/google_connections.dart:269` and `:284`; `apps/desktop/test/pending_create_workflow_test.dart:27` (`LostReplyDomain`). Classes that implement `DesktopConnection` (`apps/desktop/test/controller_fixture.dart:66`, `desktop_connection_fixture.dart:73`, `:83`) keep their signatures. Grep `Future<void> index(` and `waitForSourceWork(` across `packages/` and `apps/` after the rebase. `DesktopConnection` (`desktop_connection.dart:104`, `:109`) and `RemoteDomain` keep their signatures: an implementation may add optional parameters the interface lacks.
- `Application.importFile` (`application.dart:1465-1496`) and `importUrl` (`:1505-1533`) gain `bool Function()? indexing`: the pre-publication `waitForSourceWork` at `:1465`/`:1505` receives `current` (which in `reimport` is the revision guard), and `domain.index` at `:1495`/`:1532` receives `indexing ?? current`. `reimport` (`:1584-1612`) passes `current: sourceCurrent, indexing: () => current?.call() ?? true`: `sourceCurrent` checks the source revision that `importText` itself advances (`store.dart:573`), so it must not guard the post-publication index wait, and `indexing` must be non-null even when `reimport` itself was called with no callback (as `application_operations_test.dart:1046` does), otherwise the `indexing ?? current` fallback reinstates the revision guard. The `Application.call` cases `sourcesImport` (`:749`), `sourcesImportUrl` (`:754`), `sourcesImportDirectory` (`:759`), `sourcesRefresh` (`:763`), `sourcesImportFile` (`:771`) and `sourcesIndex` (`:775`) forward the wrapped `current` from `:640-643` (through `importDirectory` at `:1557` and `reimport` at `:1593`/`:1606`).
- `reimport` (`:1584-1616`) also forwards `current` to its generic `domain.index(s['id'])` (`:1608`) and to the trailing `google.refresh()` (`:1616`).
- Whenever a leased caller awaits `Future.any([shared, whenCancelled])` on a shared future (the Google refresh, the shared meeting index, the shared `stopRecording`), it first attaches `.ignore()` (or an error listener) to the shared future: once `Future.any` completes with the cancellation, nothing else listens to the shared future, and a later failure of the shared work would otherwise surface as an unhandled error.
- `GoogleConnections` (`google_connections.dart`): `_checkpoint(String account, {bool Function()? current})` (`:81-85`) passes it to `waitForSourceWork`; `_publish` (`:162`, `index` at `:201`), `importDriveFile` (`:211`), `importDriveFolder` (`:311`), `importLastYear` (`:368-383`, calling `importDriveFile` at `:377`) and the attachment path that reaches `importDriveFile` (`:660`) take and forward `current` through their whole call chains; `_refresh` (`:576`) does not, see the next sentence. `refresh({bool Function()? current})` (`:556-557`) keeps the coalesced run and the shared `_refresh` always runs lease-less (no `current`, so one caller's cancellation cannot fail every later `_checkpoint` of a run that others share); every leased caller, the one that started the run included, awaits `Future.any([shared, domain.whenCancelled(current).future])`, so its lease settles on cancellation while the shared work continues (not busy while parked, busy only inside `_serialize`). `_checkpoint(current)` therefore matters for the import paths, not for refresh. The `Application.call` cases `googleImportFile` (`:876`), `googleImportFolder` (`:879`), `googleImportYear` (`:882`), `googleAttachments` (`:892`) and `googleRefresh` (`:885`) forward `current`; `maintainGoogle` (`:579`) passes none. The desktop test doubles that override `importDriveFile` and `importDriveFolder` must accept the new optional parameter: `PendingDrive` (`apps/desktop/test/google_picker_workflow_test.dart:7`) and its subclass `BatchDrive` (`apps/desktop/test/google_multi_import_test.dart:42`, `:61`, whose folder override forwards `current` to its own `importDriveFile` call). Both files belong to workstream A, and their widget tests run in A's verification.
- `Application.indexMeeting({bool Function()? current})` (`:1624-1687`): the leased callers `meetings.transcript` (`:1110`) and `meetings.index` (`:1113`) forward `current`, and the `await indexing` at `:1685` becomes `Future.any([indexing, whenCancelled])` with the same dispose discipline, because the `_meetingIndexes` job (`:1673`) is shared. `_indexMeetingSource` (`:1691`) stays unthreaded: it is the shared job.
- `meetings.stop` (`:2346` is inside `_stopRecording`, whose future is shared through `_stopping` (`:2284-2285`) by RPC callers, host departure (`service.dart:1554`) and `Application.close` (`:2410`)): do not thread `current` into the finalizer. The leased `meetings.stop` case awaits `Future.any([stopRecording(), whenCancelled])`, so one cancelled waiter settles while finalization, its `indexMeeting` and the other waiters are untouched. Test: cancelling one of two concurrent `meetings.stop` waiters leaves the meeting `completed` and the other waiter successful.
- `Domain.invalidateWorkspace` (`domain.dart:78`) calls `checkCancellations()` after advancing the generation: `Application.call`'s wrapped `current` (`application.dart:639-643`) turns false on a generation change, and `workspace.clear` (`:1013`) otherwise leaves a request parked on paused sources holding its lease. Test: a clear while an agent's `sources.index` is parked settles that request with `cancelled`.
- `ApplicationService._cancel` (`service.dart:1717-1729`) calls `domain.checkCancellations()` after `lease.cancelled = true`.

Known and out of scope: if sources are paused after `_stopRecording`'s `indexMeeting` passed its pause check (`:1677-1685`), the shared finalizer parks with `recording` still set, which holds the idle exit and, as today, holds `Application.close` until `Domain.close` would have woken it; this pre-exists the ADR and is listed in section 5.

Tests (`domain_cancellation_test.dart`; `sources.index` needs no approval, but `sources.refresh`, `google.refresh`, `google.import_*` and `meetings.stop` do (`operations.dart:91-117`), so send those from the attached host connection or through an approving desktop; the URL refresh passes `allow_private_network: true` on the refresh call itself, since `reimport` forwards its own flag (`application.dart:1571`, `:1596`) and `WebPageImporter.fetch` rejects loopback otherwise (`web_import.dart:121-125`)): with sources paused, a `sources.index` whose lease is cancelled settles with `cancelled` at once and its source stays `pending`; a non-cancelled one still waits; `resumeSources` still drains; a cancelled `sources.refresh` of an existing file source whose indexing is parked settles, while a successful refresh of an existing file and an existing URL source (pause after retrieval starts and before indexing, then resume), once with a `current` and once through a direct `reimport()` with none, still completes with the new revision indexed through the production `Domain.index` (the URL case serves from a loopback `HttpServer` with `allow_private_network: true`, as `web_import_test.dart:735-747`, because `importUrl` constructs `WebPageImporter()` itself at `application.dart:1508`); a leased `google.refresh` joining a maintenance-started refresh settles on cancellation and the shared run finishes; a leased `meetings.stop` whose shared meeting index is parked settles on cancellation; no watcher remains registered after each case.

**1.4 `ReferenceNoteTranscriptCache.computing`** (`reference_note_transcript_cache.dart`). An `int computing` incremented where `schedule` starts `_drain` (`:55`) and decremented in `_drain`'s `finally` (`:79-81`), so drains orphaned by `clear` (`:28-32`), `invalidate` (`:36-39`) and eviction (`:43`) still count until they settle. Call an `onSettled` callback after each decrement; `Application` wires it to `changed`. Test, after `note_transcript_cache_application_test.dart:18-28`'s fixture pattern: `computing` is 1 during a blocked embedding, still 1 after `clear()`, 0 after the blocked call returns.

**1.5 Proactive work tracking** (C6). In `Application`, `int _proactiveWork = 0;` incremented for the `askInConversation(...).drain()` future before the `Future.any` at `application.dart:308-324` and decremented in its `whenComplete(...)`, which also calls `changed()`; attach `.ignore()` to the chain, because a future the `Future.any` discarded can still fail after cancellation and would otherwise surface as an unhandled error. Do **not** count the `indexMeeting(id)` future at `:296-304`: a shared meeting index that meets a pause after its check parks on durable work, which must not hold the exit; while it executes, `domain.mutating` already counts it. Tests (after `proactive_application_test.dart`'s fixture): a proactive answer cancelled by the coordinator while retrieval is blocked keeps `_proactiveWork > 0` until the retrieval future settles, with `proactive.running` already false; sources paused after preparation started, then a coordinator cancel, leaves `backgroundBusy` false without resuming sources.

**1.6 `Helper.adopted`, `Helper.starting`, identity verification** (C9, `helper.dart`). `bool get adopted => _adopted;`. `bool _probing = false, _launchingNow = false;` set around the `await` of `_startupProbe` (`:189`) and `_launching` (`:217`) with `try/finally`; `bool get starting => _probing || _launchingNow;`. Add a constructor parameter `Helper(..., {Duration startupProbeTimeout = const Duration(milliseconds: 400)})` used at `:191`, threaded from a new `ApplicationService.start({Duration? helperStartupProbeTimeout})` to the `Helper` construction in `_start` (`service.dart:1160`), because `helper.start()` runs inside `_start` (`:1214-1218`) and the probe's `CallOptions` are built at once, so a value set through `service.domain.helper` afterwards is too late. Declare `enum AdoptedIdentity { notAdopted, gone, matches, unknown }` in `helper.dart` and add `Future<AdoptedIdentity> verifyAdoptedIdentity()`: it runs the `fs_process_matches` lookup from `_close` (`:341-362`) without signalling, and returns `unknown` when the native library cannot be opened, the instance id does not parse, or the match result is neither 0 nor 1. Extract the lookup into a private helper shared with `_close`. Tests (`helper_close_test.dart` or a new file): move `AdoptionRag` and `AdoptionControl` (`helper_adoption_test.dart:13`, `:22`) and a public `HeldPing` modelled on `_HeldPing` (`service_failure_isolation_test.dart:19-26`) into `packages/foresight_test_support/lib/`, since the private class cannot be imported, and update their two importers (`service_failure_isolation_test.dart:16`, `service_startup_recovery_test.dart:12`); with that fixture, which completes an `entered` completer when the ping arrives and answers it on release, and `startupProbeTimeout` 10 s passed at construction, and with `FORESIGHT_HELPER` set to `/must-not-launch-a-second-helper` for the test (the probe runs only when the variable is set and no process is owned, `helper.dart:178-179`; `helper_close_test.dart` sets none today), `starting` is true after `entered` and false after release; `verifyAdoptedIdentity` returns `unknown` for `instanceId: '0-1'` and `notAdopted` for a fresh helper.

**1.7 `Application.backgroundBusy`** as in section 1.2, plus `int _activeEnhancements`: increment immediately before the `try` at `application.dart:1939` (the entry at `:1936` is synchronous with it; the early returns at `:1895`, `:1906`, `:1918` precede it), decrement as the **last** statement of the `finally` that begins at `:2098`, after `_requestAutomaticNoteEnhancement` has run (that call synchronously starts the next producer to its first `await`, so an earlier decrement would dip to zero between two active producers). A producer that keeps running after `workspace.clear` emptied `_noteEnhancements` (`:1004`) still counts. Test: each term flips `backgroundBusy` and clears it (for `generating`, a subclass of `ArtifactGenerator` that overrides the hard-coded `false` at `application_operations_test.dart:116`); `restoring` latched true with `_resuming == null` and `_initialization == null` does not make it busy; a chained enhancement never reads zero between producers.

**1.8 Settle notifications.** Every decrement in 1.1, 1.2, 1.4, 1.5 and 1.7, and the end of `maintainGoogle`, reach `Application.changed()`, which the service already listens to (`service.dart:989`). This is what makes the exit prompt instead of waiting for the 30 s tick. `changed()` is a no-op after close (`:589`).

### Step 2. Operation tracking, `_busy`, `stop_if_idle` and `status.lifetime`

**2.1 Tracking.** Add to `ApplicationService`:

```dart
/// Called where today `lease.waiting = false` runs (:1604, :1618, :1706), after `await _ready`.
void _dispatch(_RequestLease lease) {
  lease.waiting = false;
  lease.helperWait = false;
  if (lease.method == Operation.status.wire) return;   // status neither counts nor reevaluates here;
                                                        // its lease removal does (section 1.4)
  _dispatched.add(lease);
  if (lease.agent && !lease.cancelled && !_stampExempt(lease.method)) {
    lastAgentActivity = domain.clock.now();
    lastDesktopDeparture = null;       // an agent dispatch during the grace disarms the shortcut
  }
  _exitIfIdle();
}

/// Called when a dispatched operation's work and stream cleanup have both settled.
void _settle(_RequestLease lease) {
  if (!_dispatched.remove(lease)) return;
  if (lease.agent && !_stampExempt(lease.method)) lastAgentActivity = domain.clock.now();
  _exitIfIdle();
}
```

- `lease.agent` is fixed at lease creation (`:1505-1511`), not at dispatch, so a desktop whose request is still waiting when it disconnects does not turn into an agent.
- Immediately before each `_dispatch(lease)` (in `_execute` at `:1706`, so it covers both the `requiresHelper` branch that awaited `_ready` at `:1696` and the no-helper branch that waited only for approval; and inside the `asyncExpand` callback of the `answer.stream` branch at `:1603`) add `if (lease.cancelled) throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');`. Without it, a lease cancelled while waiting for helper readiness is dispatched later, stamps activity and disarms the shortcut; today it also runs `application.call` only to fail at `application.dart:644-646`.
- Future operations: in `_results` (`:1624`), `final work = _execute(lease.method, args, lease); work.whenComplete(() => _settle(lease)).ignore(); return Stream.fromFuture(work);`. Cancelling a `Stream.fromFuture` subscription does not wait for the future, so the future is tracked itself; `_settle` runs before the outer `onDone`, and the lease-removal `_exitIfIdle` of section 1.4 runs after, so the exit sees the lease gone.
- Stream operations (`lease.streamed`): settle from the outer subscription's `onDone`/`onError` after the lease removal (`:1528-1541`), and from `_cancelSubscription` in a `finally` after `await subscription.cancel()` (`:1731-1741`), which for an `async*` body happens after its cleanup; the `catch` at `:1734-1739` exists because that cleanup can throw, and a `_settle` placed inside the `try` would be skipped on that path and leave the lease in `_dispatched` forever. Pass the lease to `_cancelSubscription` and settle there **only when `lease.streamed`**: for a future operation the subscription cancel returns while `_execute` still runs. `_cancel` (`:1717`) has the lease and passes it; the handler's leftover-subscription loop (`:1564-1568`) runs after `_leases.remove(client)` and is empty in practice because the `_cancel` loop already removed each subscription by id (`:1727-1728`), so it passes no lease and settles nothing.
- A lease that errors before dispatch (authorize denial, `closing`, rate limit) was never added, so `_settle` is a no-op; the lease-removal `_exitIfIdle` still runs.

`security.*` requests and `service.stop_if_idle` never create a lease (`:1402-1455`, `:1483-1490`), so they are never tracked.

**2.2 `_busy()`** as in section 1.2, with `_stopIfIdle` (`:1627-1687`) rewritten to use it while keeping the messages that tests match on, checked in this order, all `RpcErrorCode.busy`:
1. `application.recording != null`: `'Recording is active or finalizing. Stop recording and wait for the final transcript before upgrading.'`
2. leases or `_dispatched`: `'Application operations are in progress. Retry the upgrade after they finish.'`
3. `application.backgroundBusy`: `'Background model work is in progress. Retry the upgrade after it finishes.'`

**2.3 Helper refusals before teardown.** After the busy checks and before `close()`:
- `if (domain.helper.starting) throw RpcError(busy, 'The helper is still starting. Retry the upgrade after it is ready.')`.
- `if (domain.helper.adopted || (domain.helper.snapshot != null && domain.helper.process == null))`: `switch (await domain.helper.verifyAdoptedIdentity())`: `unknown` throws `RpcError(busy, 'Helper shutdown could not be verified. The application was not cleared for upgrade.')` with the service still serving; `gone` and `matches` proceed. This is the one `await` in `_stopIfIdle` before `close()`; after it, re-run the synchronous checks in this order: `if (_closing) throw _closingRefusal();` (the automatic exit fires on the same idle condition the installer probes), then the three busy checks, then `close()` immediately.
- The post-close `shutdownVerified` check (`:1664-1667`) stays for a helper that ignores SIGTERM.

**2.4 `status.lifetime`** as in section 1.6. Until step 3, `_exitAfter` returns `null` always; add the field in this step so the Python and smoke changes in step 6 have something to poll.

**Tests for step 2** (`service_idle_shutdown_test.dart` and the new `service_lifetime_test.dart`; in process. Helper variable, per test: with `FORESIGHT_HELPER=''` (`service_cancellation_test.dart:32`) `_ready` settles after the 400 ms probe and the failed `Process.start('')` (`helper.dart:184-217`), during which `helper.starting` is true; use this for tests that dispatch `requiresHelper` operations (`meetings.generate` is one), and wait for readiness first through a `@visibleForTesting Future<void> get ready => _ready` on the service. With the key removed (`service_idle_shutdown_test.dart:28`) `starting` is false at once but `_ready` stays pending through the 20-iteration ping loop (about 5 s), so use this for tests that call `stop_if_idle` early and dispatch only no-helper operations (`notes.list`, `notes.save`); gates need no hook define in process: set `runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES']` as `service_closing_protocol_test.dart:755-756` does). Move `TestRecording` (`service_idle_shutdown_test.dart:10-17`) to `packages/foresight_test_support/lib/` so both files share it.
- `unverified adopted helper shutdown cannot certify an upgrade` (`:192-211`) now expects `RpcError` with code `busy` and a message containing `'could not be verified'`, and then `status` still answers with the same pid and the socket still exists. The endpoint-record assertion stays.
- New: a `notes.save` held at the `request.committed.notes.save` gate, cancelled with the per-request cancel frame (`service.dart:715`, `:1380-1381`), keeps `lifetime.busy` true and `stop_if_idle` refusing with `'operations are in progress'` after its lease was cancelled; releasing the gate clears both.
- New: `stop_if_idle` while `helper.starting`: `FORESIGHT_HELPER` set to a path that must never launch (`/must-not-launch-a-second-helper`, as `helper_adoption_test.dart:58-59`), the `HeldPing` fixture listening on the helper socket before `ApplicationService.start(profile, helperStartupProbeTimeout: Duration(seconds: 10))`; wait for the fixture's `entered` before calling: the refusal is `busy` with `'still starting'` and the service keeps serving; release the ping well inside the raised timeout and `starting` becomes false. The release takes the adoption path (`getState` is served and `validateHelperCompatibility` runs, `helper.dart:197-209`), so either serve the adoption test's `State` with `FORESIGHT_RUNTIME_REVISION` set (`helper_adoption_test.dart:58-69`) or assert nothing about `_ready` after the release. Do not then expect `stop_if_idle` to succeed: see the next bullet.
- A service whose helper is any in-process gRPC fixture is **adopted and unverifiable** under step 2.3: the released probe sets `_adopted` (`helper.dart:195-196`) or `watchState` fills `snapshot` with `process == null` (`:284-289`), the fixture's `control.State` carries no parseable `instanceId` (`:336-339`), and these fixtures remove `FORESIGHT_NATIVE` (`service_failure_isolation_test.dart:45-47`), so `verifyAdoptedIdentity` returns `unknown` and `stop_if_idle` refuses with `'could not be verified'`. Every test that uses such a fixture therefore asserts the `lifetime.busy` flip and the `busy` refusal with the expected message only, never a successful `stop_if_idle`. Successful `stop_if_idle` is asserted only in no-helper fixtures and in the Python suite with the real helper.
- New: each `backgroundBusy` term, set through its production path, refuses `stop_if_idle` with the background message and reports `lifetime.busy == true`, and clearing it clears both: a blocked `_serialize` closure (`DelayedIndexService`; add a gated `deleteDocument` to that fixture, since its current one returns at once, `delayed_index_service.dart:31-35`); an active enhancement (`ControlledNoteGenerator` from `note_enhancement_stream_test.dart:12`, which overrides `loaded` and gates `generateConversation`; `ArtifactGenerator` gates only `generate` and reports `loaded == false`, so enhancement never reaches it; start the enhancement through a `meetings.notes` edit so no lease masks the counter); `Domain.resume` in progress (an embedding `models` row with a `.litertlm` path, `domain.dart:418-429`, `helper.dart:119-120`, a control `getState`, and the fixture's `updateModelPaths` held); a transcript-cache drain and a proactive answer need a gRPC fixture helper with `pipeline == 'ready'` (`note_transcript_cache_application_test.dart:18-28`, `service_failure_isolation_test.dart:228-238`), otherwise `_computeNoteEmbedding` returns `[]` (`application.dart:140-142`).
- New: `status` reports `lifetime` with `pinned_by_desktop` true after `security.attach_desktop` and, after the desktop closes, false once the service has observed the departure (`eventually(() => !service.access.hasHost)` as `service_agent_access_test.dart:105-108` does; the local socket close is not a barrier), with a long grace (`longGrace`, `:56`, 5 s) so the reading does not race the shortcut.

### Step 3. The lifetime rule

**3.1 Clock and timers.** `ApplicationService.start` (`service.dart:1014-1039`) and `_start` gain `Clock? clock` and `Timer Function(Duration, void Function())? createTimer`, passed to `Domain(store, helper, webSearch: webSearch, clock: clock, createTimer: createTimer)` at `:1161` (beside the `helperStartupProbeTimeout` of step 1.6). `IsolatedApplicationService` is unchanged (child-process tests use the preference).

**3.2 State and predicates** from section 1: delete `_desktopShutdown` and its `Timer(...)` at `:1570-1587`, add the fields, `_idleMinutes`, `_period`, `_unpinned`, `_busy`, `_agentWorkInFlight`, `_exitAfter`, `_shouldExit`, `_exitIfIdle`, `_lifetimeState`. `_started` is set in the private constructor's initializer list (`:963`). At the end of `_start`, immediately before `return service` (`:1218`): `service._exitIfIdle();` (so an agent-only service that only ever gets `get_status` exits one period after start).

**3.3 Departure.** Replace the timer creation in the `onDone` handler with the arming rule of section 1.3 followed by `_exitIfIdle()`, as the handler's last statements. Replace the comment "agent connections must not keep its helper/models alive forever" (`:1574-1575`) with one line: "The desktop pins the service; without one it exits one idle period after the last agent request, or after the grace when no agent worked within the period."

**3.4 Reservations and host changes.** At `:1406-1407` and `:1479-1480` replace `_desktopShutdown?.cancel()` with `lastDesktopDeparture = null; _exitIfIdle();`. After the explicit `access.detach` at `:1415` call `_exitIfIdle()` (a reschedule only). The `access.detach` at `:1551` gets no call: the `onDone` handler evaluates once at its end.

**3.5 Listeners.** Wrap the `application.changes` listener (`:989`) and `helper.changed` (`:1202`) so each also calls `_exitIfIdle()`. Add `_exitIfIdle()` after every lease removal (section 1.4).

**3.6 The close** as in section 1.5.

**3.7 Preference.** `serviceIdleMinutes` is read as in section 1.1. `preferencesSet` already notifies changes (`operations.dart:168-181` does not exclude it), so a change reaches `_exitIfIdle`.

**3.8 `desktopShutdownScheduled`** (C11) as in section 1.3.

**3.9 Existing test changes** (Dart):
- `service_closing_protocol_test.dart:285` (C10): trigger the close with `HookedServiceProcess.signal` (`foresight_test_support/lib/hooked_service.dart:340`, SIGTERM) instead of closing the desktop; keep its bridge-specific assertions (the terminal frame before `close.leases_terminated`, `committedNotes`), which `service_lifecycle_test.dart:274-336` does not make. Update the matrix cell at `service-lifecycle-tests.md:100`: trigger SIGTERM, and note that an automatic exit never interrupts dispatched work.
- `service_agent_access_test.dart:361-372` `headless agent connections do not acquire the desktop lifetime`: keep as is, and add a variant `headless agent work keeps the service until one idle period has passed`: a `startService` overload that passes `clock: Clock(() => now)`; the agent calls `notes.list` once; the never-attached desktop closes; the service stays (`desktopShutdownScheduled` false, `status.lifetime.exit_after` equals the stamp plus the period); `now` advances past the period; the next `status` call returns and the exit follows (`service.closed` completes, socket gone).
- `service_closing_protocol_test.dart:417` (the wire-compatibility test): it calls `stop_if_idle` right after `owner.ready()`, which checks only the pid (`hooked_service.dart:312`), while the child's `FORESIGHT_HELPER=''` (`:286`) leaves the probe and failed launch pending, so step 2.3's `'still starting'` refusal can now win the race. Before the call, wait for the child's `Helper startup:` stderr line (`service.dart:1214`), which is written once startup has failed, as the barrier.
- Every other test in those files is unchanged; run them and record the verdicts.

**Tests for step 3** (`service_lifetime_test.dart`; in process; `FORESIGHT_HELPER=''` with the `starting` caveat above; `clock: Clock(() => now)` with real timers; the period set with `service.domain.store.setPreference('serviceIdleMinutes', …)`; the exit observed through `service.closed`, triggered by a `status` call after advancing `now`, never by sleeping; a `status` sent while the close is already running may get `closing`, `outcomeUnknown` or EOF and the test tolerates all three). The ADR's Tests items 1 to 5 map as follows; each bullet is one `test`:
1. Agent only: `notes.list` (non-`status`, needs no helper), advance past the period, `status` from a second client: the first client's socket reaches EOF, `service.closed` completes, the record and socket are gone, the lock file can be acquired. A service that only ever received `status` exits one period after `_started`.
2. One-shot agent: the agent disconnects right after a request; the service stays for the period; a second agent connecting before it sees the same pid; after it, `ensureService` launches exactly one replacement. The launcher counter needs `HookedServiceBuild.compile()` in `setUpAll` (`hooked_service.dart:103-136`, `service_closing_protocol_test.dart:249`) and `build.launcher(...)` (`:279-283`), so this one test lives in `service_closing_protocol_test.dart`, with the in-process owner started as at `:761-764` plus the injected clock.
3. Desktop and agent: an `ArtifactGenerator` with `entered`/`release` assigned to `service.domain.generator` holds an agent `meetings.generate` (as `service_cancellation_test.dart:10-17, 42`) or `answer.stream` when the desktop closes; after `release`, the stream completes with its result, the pid is unchanged, and the service exits one period after the stream settled, not one period after dispatch.
4. Desktop branch, one test per ADR bullet: completed agent work older than the period, desktop attaches, works, closes → exit after the grace. Agent completes within the period, desktop closes → waits for the period. Desktop opens and closes mid-request → request completes, waits for the period. A request longer than the period is in flight at departure → completes, exit one period after it settles. Last agent activity 29 minutes old at departure → exit one minute later; advancing the clock further does not arm the shortcut. Departure during a `Domain.resume` model load with no agent activity → `close()` begins after the grace while resume is incomplete (observe the `close.begin` gate). This bullet and the C15 bullet below need `onReady` to be reachable, which `FORESIGHT_HELPER=''` never is (the failed `Process.start('')` settles `_ready` before the ping loop, `helper.dart:179-221`): for these two tests remove `FORESIGHT_HELPER` and every other `FORESIGHT_*` key, serve `HeldPing` plus `AdoptionControl(control.State())` on `${profile.runtime}/helper.sock` before `ApplicationService.start`, hold the first ping until the `onReady` wrapper is installed, then release it, as `service_failure_isolation_test.dart:228-250` does. For a resume that is actually in progress, three more things: seed an embedding `models` row with a `.litertlm` path before start (`domain.dart:418-429`; `hasActiveModel` returns false at once for an empty `control.State`, `helper.dart:119-147`), serve a Rag fixture whose `updateModelPaths` awaits a completer (`AdoptionRag`'s `noSuchMethod` rejects it, `helper_adoption_test.dart:13-20`, so extend the fixture), and make the `onReady` wrapper save the closure installed at `service.dart:1203-1212` and call it after `release` (the plain replacement wrapper at `:243-246` never runs `domain.resume()`); then assert `service.domain.resumeInProgress` before the desktop closes and release the held RPC in `addTearDown`. The C15 bullet keeps the plain replacement wrapper. Departure while a `_serialize` closure is executing (`DelayedIndexService`) → the close begins only after it settles. Departure with an active `TestRecording` and no agent work → the close begins after the grace and the recording's `stop()` has run before `service.closed` completes (C21). The departing desktop must hold only a lifetime reservation (`status {desktop: true, token}`, `service.dart:1462-1480`) and never `security.attach_desktop`: an attached host's departure stops the recording in the `onDone` handler itself (`:1549-1557`), which would not exercise the close path (`application.dart:2410`). `TestRecording` gains a `stopped` flag by overriding `stop` and calling through (safe on a fresh fixture: `recording.dart:299`, `:348-352` iterate empty captures), as `FailingDetachRecording` (`service_agent_access_test.dart:12-23`) shows the shape. `_stopRecording` returns before `stop()` when `recordingMeeting == null` (`application.dart:2325-2327`), so the test also creates a meeting without an agent lease (`service.domain.application.call('meetings.create', ...)` directly, as `commit_safety_test.dart:685-691` does) and sets `application.recordingMeeting` to its id beside `application.recording`; with no transcript rows `indexMeeting` returns at `:1636`, so no helper is needed. An agent lease waiting on `_ready` at departure holds the desktop branch; after release the request dispatches and the service exits one period after it settles (C15). Hold readiness without a seam by replacing `service.domain.helper.onReady` with a completer-gated wrapper, as `service_failure_isolation_test.dart:243-246` does (`_ready` is `helper.start()`, which awaits `onReady` at `helper.dart:297`), in the gRPC-fixture mode of the previous bullet; the agent's request is one that `requiresHelper` and settles against the fixture, for example `meetings.generate` with `service.domain.generator` set to an `ArtifactGenerator` (`service_cancellation_test.dart:10-17, 42`). `status` polling every 100 ms does not postpone either exit (tolerating one `closing`, `outcomeUnknown` or EOF at the end). `serviceIdleMinutes = 0` disables the idle branch and keeps the desktop branch.
5. Busy conditions: for each of active recording (`TestRecording`), finishing, a dispatched `notes.save` held at its commit gate, an executing meeting index, an active enhancement, a proactive answer (gRPC fixture), `Domain.resume` in progress, a cancelled `notes.save` whose commit is still gated: `exit_after` is `null`, advancing the clock and polling does not exit, and clearing the condition exits on the next evaluation. Paused sources with pending work do not hold it; a helper `_start` in flight does not hold it (the no-helper fixture exits within the grace as today). (`sources.import` needs an approval host; use `notes.save` for the dispatched case, or attach, approve and leave.)
6. A request arriving after `close()` began gets `closing` (reuse the `close.begin` gate pattern from `service_closing_protocol_test.dart:745-832` with the idle exit as the trigger). The `outcomeUnknown` half is C2 and is not written.

Each new test asserts, after `service.closed`, that `_dispatched` becomes empty (`eventually(...)`: `_close` fires `_cancelSubscription` unawaited at `:1727-1728`, so a departed desktop's cancelled stream can settle just after `closed`) and that every `backgroundBusy` counter is zero (expose them through `@visibleForTesting` getters); a stuck counter is the one failure the 30 s tick cannot hide. Determinism: these tests pass 20 times at `--concurrency=1` and 5 times at `--concurrency=8` (the execution plan's loop), with no `Future.delayed` for ordering.

### Step 4. `RpcErrorReason.needsDesktop`

Add `needsDesktop` to the enum (`rpc_error.dart:16-27`) with a doc comment: "The request needs a desktop approval host and none is attached. Retrying is safe once the desktop is open." Attach it at `agent_access.dart:173-177` (`host == null`, "Open the desktop app to review this operation"). `toJson` already serializes it (`rpc_error.dart:61-65`); `RpcError.from` drops unknown reasons in older peers; MCP already copies `toJson()` into `structuredContent.error` (`packages/foresight_core/bin/mcp.dart:161`). `rpc_error_test.dart:67-84` round-trips every value and needs no change. Test (ADR 8, corrected by C1): after `security.detach_desktop`, an agent `sources.import` fails with `denied` and `reason: needsDesktop`, and `status.lifetime.last_agent_activity` is still `null`. An MCP protocol test asserts `structuredContent.error.reason == 'needsDesktop'`.

### Step 5. Desktop Settings row

`apps/desktop/lib/settings_controller.dart:909-930` has the inactivity row; add a `DesktopSettingSelect<String>` row after it through the same `settingRow(title, subtitle, control)` helper (`:723`): title "Stop the background service after agent inactivity", subtitle "With the window closed, the service and its models exit this long after the last agent request.", value `d.store.preference('serviceIdleMinutes', '30')`, items `['0', '15', '30', '60', '120']` labelled "Never", "15 minutes", "30 minutes (Default)", "60 minutes", "120 minutes", plus the stored value with the label "$v minutes" when it is not in the list (C13). Write through the existing `preference(key, value)` helper (`:718-721`). Give the new row a `Key('serviceIdleMinutes')` and make `desktop_parity_audit_test.dart:38-40` find selects by key or label instead of by value, because `select('30')` would otherwise match both rows; extend that test to pick `60` on the new row and assert `store.preference('serviceIdleMinutes') == '60'`.

### Step 6. Python suite, smoke and installer scripts, measurement

**6.1 `tests/service/test_service_process.py`.**
- Fixture: `ApprovalDesktop.__init__` (`:101-112`) gains `preferences=None`, a dict applied with `self.peer.call("preferences.set", {"key": k, "value": v})` after `security.allow_import_root` and **before** `self.thread.start()`, because the review thread consumes `peer.reader` afterwards (`:113-124`) and a later `peer.call` would lose its reply. The `running` fixture (`:257-389`) accepts a comma-separated param string: its two equality reads of `getattr(request, "param", None)` (`:304`, `== "capture_poll_gate"`; `:356`, `!= "without_embedding"`) become membership tests on the split list, with `None` (unparametrized uses and the `explicit-stop` case) treated as an empty list, so `"without_embedding,idle=0.05"` works alongside the existing usages (`:392`, `:610`, `:669`), and `idle=` reaches `ApprovalDesktop` as `{"serviceIdleMinutes": value}`. `test_service_stop_waits_for_active_capture_and_finalizes_transcript` is parametrized by `shutdown` (`:1002`); give it one combined `parametrize("running,shutdown", [("idle=0.1", "desktop-close"), (None, "explicit-stop")], indirect=["running"], ids=["desktop-close", "explicit-stop"])` rather than two stacked marks, so only `[desktop-close]` gets the preference and the test ids this plan cites survive. The host needs no approval and stamps nothing. Confirm in each new test that `peer.call("status")["lifetime"]["idle_minutes"]` equals the parametrized value. Every bounded `status` poll in these tests stops on any of `AssertionError` (EOF, `Peer.result` `:77`), `OSError` (a send on a socket the service closed) and `RuntimeError` (a `closing` refusal, `:84`). Timestamps compared with `exit_after` or `last_agent_activity` use `time.time()` in seconds times 1000, since those fields are wall-clock `millisecondsSinceEpoch`, not `time.monotonic()`.
- `test_service_stop_waits_for_active_capture_and_finalizes_transcript[desktop-close]` (`:1001-1052`): parametrize `running` with `idle=0.1`. The peer's `models.register` and `meetings.start` are agent work, so the shortcut is not armed and the desktop close does not interrupt finalization. Do not poll `status` after the close (the exit can begin the moment capture settles, and a poll in flight then raises in `Peer.result`, `:77`, `:84`); keep `running["process"].wait(timeout=15)` and the SQLite assertions (`:1039-1052`), which prove finalization. No timing bound: the last agent stamp is at `meetings.start`'s settle, before the sample poll (`:1015-1025`), so the period may already have elapsed when the desktop closes and the exit may follow finalization at once; the step 3 in-process tests pin the period arithmetic. Invert the comment at `:1024`. `[explicit-stop]` is unchanged.
- `test_idle_upgrade_shutdown_defers_capture_and_requires_verified_ack` (`:1055-1118`): after `meetings.stop`, poll `status["lifetime"]["busy"] == False` (stop on EOF), then run `--stop-if-idle`; on `returncode != 0` with `"Background model work"` in stderr, retry up to 3 times at 1 s, because a 3 s enhancement retry timer can fire between the poll and the call.
- `test_idle_shutdown_verifies_a_real_adopted_helper` (`:1168-1265`): after adoption is observed, the same `busy == False` poll and bounded retry before `--stop-if-idle` (`Domain.resume` after adoption is busy now). In the `helper_exits_first` case the helper is gone, so `verifyAdoptedIdentity` returns `gone` and the acknowledgement is unchanged.
- `test_native_desktop_and_mcp_share_service` (`:732-844`): no assertion change. Add a comment at `:762-765` that the peer's model calls are agent activity, so the fixture service outlives the `ApprovalDesktop` and the Flutter desktop attaches to it; `desktop_restart_preserved_owner` no longer races the grace.
- New `test_agent_only_service_exits_after_the_idle_period`: `running` with `"without_embedding,idle=0.1"` (the default param's `models.embedding` leaves `_serialize` work settling, which would make `exit_after` `null`); record `t0`, then the peer calls `notes.list`; the desktop closes; poll `peer.call("status")` (bounded, stop on EOF) until `pinned_by_desktop` is false and `exit_after` is non-null, because `ApprovalDesktop.close` returns before the service's socket callback runs (`:126-134`, `service.dart:1549-1570`); on that reading `exit_after >= t0 + 6 s` (the stamp is at settle, after `t0`) and the pid is unchanged; then `process.wait(timeout=15)` returns 0; record, socket and lock are released. Then an `McpPeer` started with an env whose `FORESIGHT_SERVICE` is a counting wrapper (as `:1449-1456`) calls `list_notes`: exactly one line in the launches file, the call succeeds, and the replacement is stopped in a `finally` by the identity-checked teardown of `:1538-1550`, since the `running` teardown (`:375-388`) only stops the original.
- New `test_desktop_departure_without_agent_work_exits_after_the_grace`: `running` parametrized `"without_embedding"`; the desktop closes with no peer work; `process.wait(timeout=15)` returns 0 (the 1 s grace plus the real helper's SIGTERM, which may take the full 5 s before SIGKILL, `helper.dart:326-328`). This pins today's behavior with the built binaries.

**6.2 `tools/smoke_macos_bundle.py`.** Before `install(..., stop_services=True, profiles=[data])` (`:674-680`), poll `--status` until `lifetime.busy` is false (bounded at 60 s), because the preceding `source_graph_probe` leaves indexing executing. Rewrite the comment at `:649-652` ("Closing it schedules the production desktop-close shutdown after one second"): the two MCP peers' `save_note` and `list_notes` are agent activity, so the owner stays after the test desktop closes and the check at `:639-648` is deterministic. `tools/install_macos.py` needs no change: a `busy` refusal already becomes `Deferred` (`:172-175`), exit 3, and the user retries. Extend `tests/test_macos_tools.py:463` with the background-work message so the refusal path is pinned for the new text.

**6.3 Cold-start measurement** (C17), one final commit on `codex/pr159` after the Mac run. On the macOS verifier with the representative generator `gemma-4-E2B-it.litertlm` (`tools/model_pins.py:62`) and the default embedding model, record once: (a) `--status` until `helper.pipeline == 'ready'` and `generation.state == 'ready'` (as `tools/test_native_service.py:131` polls; there is no `loaded` field) after a cold `foresight-service` launch, and the time to the first successful `search` through the MCP adapter after an idle exit; (b) resident set size of the service and helper processes while idle with both models loaded. Put both numbers in the PR description and in ADR Decision 2 in place of "The default is unmeasured"; the default stays 30 unless the owner says otherwise. If the macOS verifier cannot run the generator, say so in the PR and keep the ADR's sentence.

### Step 7. Documentation and the coverage matrix

**7.1** Apply ADR Changes item 6 verbatim, plus C12, in `docs/architecture/application-service.md`: line 15 "inactivity shutdown" → "inactivity shutdown, the idle exit"; line 98 `get_status` row gains "and the service lifetime (`lifetime`)"; line 109 gains "A `denied` error may carry `reason: needsDesktop` when the operation needs the desktop's approval and no desktop is attached."; lines 115-117: replace the lifetime sentences of the paragraph with the ADR's lifecycle table and one sentence for `serviceIdleMinutes`, keeping the lock and capture sentences, and "neither client disconnect unloads the generator" → "models are released only when the process exits"; line 135's last sentence → "Google reminders and refresh timers run in the service while it is running, which with no desktop attached is until the idle exit."; the `--stop-if-idle` paragraph (`:161-169`) gains "and background model work" after "in-flight operations"; line 171 "The next client starts a service again" → "The next client attaches while the service is still running, otherwise starts one"; the status field sentence at `:307-312` lists `lifetime` as additive.

**7.2** `README.md:65` and `:128`, `docs/platforms/macos-support.md:5-6` and `:207-208`, `services/inference/README.md:51`, `docs/validation/issue-142-functional-followups.md:15` and `:49`: the replacement sentences are quoted in ADR Changes item 6; apply them exactly.

**7.3** (workstream A) `docs/architecture/service-lifecycle-tests.md`: under "Closing" for Desktop ↔ service (`:63`) and MCP/CLI ↔ service (`:78`), add the step 3 tests by file abbreviation (new abbreviation `SLT` for `service_lifetime_test.dart`) and the Python idle tests under MCP Closed (`:79`); update `:100` for C10; add `SID`'s refusal tests under Service ↔ helper Closing (`:110`). C's Python test names are fixed by step 6.1, so A can cite them.

**7.4** (workstream A) `docs/adr/0007-…md`: revision 7 (section 0). The measurement (6.3) is the final commit on `codex/pr159`.

## 3. Existing tests: verdicts to record in the PR description

| Test | Verdict |
|---|---|
| `service_agent_access_test.dart`: the seven desktop-only tests named in ADR Tests item 9 (`:225-360`) | Unchanged. No agent work happens in them, so the shortcut arms exactly as today. `desktopShutdownScheduled` keeps its meaning (C11). |
| `service_agent_access_test.dart:361` headless agent connections | Unchanged, plus the new variant (step 3.9). |
| `service_idle_shutdown_test.dart:192` unverified adopted helper | Changed: `busy` refusal before teardown (step 2.3). |
| `service_idle_shutdown_test.dart` other five | Unchanged in their assertions; the `setUp` (`:26-33`) also removes `FORESIGHT_MODEL_MANIFEST`, as `service_closing_protocol_test.dart:250-258` does, because a manifest would make `initializationPending` hold `:56`'s immediate `stop_if_idle`. `starting` is false in the no-helper fixture because no probe or launch is pending. |
| `service_isolate_test.dart:300` isolated idle acknowledgement | Unchanged. |
| `service_closing_protocol_test.dart:285` | Changed trigger (C10). |
| `service_closing_protocol_test.dart:417` wire compatibility | Changed: waits for the helper-startup barrier before `stop_if_idle` (step 3.9). |
| `service_ownership_test.dart:234-243` `--stop-if-idle` against a launched owner (`FORESIGHT_HELPER=''`, `:52-58`) | Same shape as `:417`, practically closed because spawning the CLI VM outlasts the probe's fast failure; apply the same `Helper startup:` barrier anyway so the determinism loop cannot meet a `'still starting'` refusal. |
| `service_closing_protocol_test.dart:676` (fix-plan 7), `:745` (fix-plan 8), `:1065` (status `outcomeUnknown` at SIGTERM), `:1110`, `:1449` | Unchanged; `:745` has no agent work so the grace shortcut arms, now synchronously in the handler (section 1.3); `:1065` keeps its frame (C2). |
| `service_lifecycle_test.dart:274` SIGTERM path | Unchanged. |
| `rpc_error_test.dart:67` reason round-trip | Unchanged. |
| `mcp_protocol_test.dart:406`, `:505` exact `error` maps | Unchanged (they cover `outcomeUnknown`). |
| `Domain` subclasses overriding `index`/`waitForSourceWork` (step 1.3) | Signature updated, behavior unchanged. |
| `tests/service/test_service_process.py` (step 6.1) | Three changed, one commented, two new, fixture extended. |
| `tests/test_macos_tools.py:463`, `:789` | `:463` extended; `:789` unchanged (an attached graph peer still pins). |
| `apps/desktop/test/desktop_parity_audit_test.dart:17` | Changed finder, extended (step 5). |

Run every suite and fill the table with pass counts; do not report a verdict from reasoning alone.

## 4. Verification before the PR

Follow `AGENTS.md` and the execution plan's recipes (`docs/plans/2026-10-19-service-lifecycle-execution.md`, "Linux verification" and "Mac verification"). Use a private, disk-backed temporary root with a short path (`install -d -m 700 /var/tmp/ofs-adr7/{tmp,t}`; `export TMPDIR=/var/tmp/ofs-adr7/tmp FORESIGHT_TEST_TEMP_ROOT=/var/tmp/ofs-adr7/t`).

The lifecycle and commit-safety files, from the matrix's abbreviation table (`service-lifecycle-tests.md:11-41`), plus the new one: `service_shutdown_handoff_test.dart`, `service_connection_test.dart`, `service_ownership_test.dart`, `service_isolate_test.dart`, `service_idle_shutdown_test.dart`, `service_failure_isolation_test.dart`, `service_socket_test.dart`, `service_endpoint_record_test.dart`, `service_startup_recovery_test.dart`, `service_agent_access_test.dart`, `service_lifecycle_test.dart`, `service_closing_protocol_test.dart`, `service_gate_test.dart`, `service_profile_identity_test.dart`, `commit_safety_test.dart`, `lost_reply_test.dart`, and `service_lifetime_test.dart`.

**Linux**, from the branch worktree:
1. `dart analyze` in `packages/foresight_core` and `apps/desktop`; `ruff`, `mypy` and the subprocess-timeout guard from `quality.yml` for the Python changes.
2. Full `dart test` in `packages/foresight_core`, then `tools/coverage_core.sh` with its threshold.
3. Hook-enabled lifecycle files: `dart -DFORESIGHT_ENABLE_TEST_HOOKS=true test --compiler=source` over the files above, and the hook-free check against the release binary.
4. Determinism: those files 20 times at `--concurrency=1` and 5 times at `--concurrency=8`.
5. Built service/MCP suite: compile `packages/foresight_core/bin/service.dart` and `packages/foresight_core/bin/mcp.dart`, reuse the verified `ForesightHelper`, `model_worker_fixture` and `libforesight_native.so` (provenance as in the execution plan), run `pytest tests/service` with the variables from `tools/build_service_gate.sh`. Confirm no leftover `foresight-service` processes after the run, and run the leftover-service loop 20 times on the new idle tests.
6. Desktop: `flutter analyze`, `flutter test --dart-define=FORESIGHT_ENABLE_TEST_HOOKS=true`, and the real desktop/service integration on an isolated display (`test_native_desktop_and_mcp_share_service`).
7. Repository Python tests (`tests/`), for `test_macos_tools.py`.
8. Compare test counts and skip reasons with the base.

**macOS** (HanSolo, per the execution plan's request format): the Dart core suite; the hook-enabled lifecycle files once and 3 times at concurrency 1; the built service/MCP suite; `tools/install_macos.py --stop-services --profile <p>` against a running idle service (acknowledged) and against one with background work executing (deferred with the new message); `tools/smoke_macos_bundle.py --desktop`; the cold-start measurement (6.3). Report in the `MAC-RESULT` format. If the Mac cannot run a check, the PR says which, and the hosted check must pass before merge.

**PR description** carries: the step list, the ADR corrections (section 0), the verdict table (section 3) with counts, the measurement numbers, and the "Verify changes before pushing" evidence per `AGENTS.md`. End it with the attribution line this repository's reminders require.

## 5. Not in this PR

Everything under the ADR's "Not in this change". In addition: making `preferences.set` an MCP tool (the ADR accepts that an agent-only install cannot tune the period); `DropdownButton` hardening for the `inactivity` row (same latent assert, separate change); replacing the raw `Timer.periodic` instances (`application.dart:539`, `:2265`; `service.dart:999`) with injected timers; a `preferences.get` operation; a deadline on `Domain._delete` shorter than the client default; the pre-existing hold when sources are paused after a recording's finalizer passed its pause check (step 1.3, last paragraph).

## 6. Risks the implementer should watch

- **Async gaps in the exit decision.** `_shouldExit` and `_busy` are synchronous by construction; any `await` added before `close()` reopens the race `stop_if_idle` guards against. Step 2.3's one `await` is followed by the full re-check.
- **Settle hooks that never fire.** Every term of `backgroundBusy` must decrement on every exit path (`finally`), or the service leaks exactly as before. The 30 s tick only bounds the delay; it cannot fix a stuck counter. The counter assertion at the end of every step 3 test exists for this.
- **Cancellation watchers.** `whenCancelled` registrations must be disposed when the awaiting operation settles, on every path, or they accumulate for the life of the process.
- **Stamping.** `lease.agent` is decided at lease creation; `_dispatch` never stamps a cancelled lease.
- **FakeAsync.** Do not drive the service with `FakeAsync`; its sockets are real. Inject only the clock, keep real timers, and trigger evaluations with `status`.

## 7. Open questions for the repository owner

None block the implementation; each has a default the plan applies.

1. C15 (an agent lease waiting on helper readiness holds the desktop branch) deviates from the ADR's "dispatched" wording. Default: apply C15.
2. C17: the 30-minute default stays unless the owner changes it after reading the measurement. Default: keep 30.
3. Threading cancellation through `google.import_file` and `google.import_folder` (step 1.3) is in scope because C7 names them. Default: in scope.
