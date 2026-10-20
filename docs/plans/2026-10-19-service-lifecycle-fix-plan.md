# Service lifecycle fix plan

This plan fixes the defects that a five-reviewer audit found on 2026-10-19 in service shutdown, reconnect and handoff. The audit covered three failure classes: connecting to a closing owner, losing the connection before a reply, and reading the endpoint record while it disappears. It also mapped how well the boundaries between processes and isolates are tested.

It is written for an agent working without other context. It is carried out as local steps on the `open-foresight-services` integration branch, verified on Linux and macOS, and lands as one PR; see the [execution plan](2026-10-19-service-lifecycle-execution.md). Locate code by symbol name. Line numbers are given at `5e098cf2`, the head of `codex/ci-service-handoff-fixtures`, whose `packages/` tree is identical to PR #150 (`codex/ci-restructure`).

| PR | Scope | Findings | Estimate |
|---|---|---|---|
| PR 0 `fix/service-handoff` | The seven service commits split out of the paused PR #150, plus the unclean-shutdown policy that reverses one of their behaviors | SL-8 | S (1–2 days) |
| PR 1 `fix/service-wedges` | Small fixes for the two high-severity findings | SL-1, SL-2, L7 | S–M (2–3 days) |
| PR 2 `test/service-lifecycle-harness` | A fault proxy, service gate hooks and fixture fixes, so later PRs can test both sides of a boundary deterministically | T1–T3, L10 | M (3–5 days) |
| PR 3 `fix/service-closing-protocol` | Structured error reasons, client framing, server drain, isolated-frontend shutdown order, handoff for attached clients | SL-3, SL-6, SL-9, L1, L2, L3, L6 | L (1–1.5 weeks) |
| PR 4 `fix/service-profile-identity` | Profile identity in status, no attaching to or deleting another profile's socket, one endpoint read per connection | SL-7, L9 | M (3–4 days) |
| PR 5 `fix/service-commit-safety` | Stale-ID protection, idempotency keys, honest lost-reply UX on the desktop and in MCP | SL-4, SL-5, L4, L5 | M–L (1 week) |

Land them in order, starting with PR 0. PR 4 may run in parallel with PR 3 only if the authors coordinate edits to `_connectCompatibleService` and `ApplicationService._start`, because both PRs change those functions.

## Decisions

On 2026-10-19 the owner accepted every recommendation (D1–D6) and paused PR #150. The steps run on the `open-foresight-services` integration branch and land as one PR, per the [execution plan](2026-10-19-service-lifecycle-execution.md).

| # | Decision | Status | Chosen or recommended | Alternative | Affects |
|---|---|---|---|---|---|
| D1 | Where the seven service commits on PR #150 land | **Superseded** | **Landed with #150.** PR #150 was ready before step 0 finished. Its service files were byte-identical to the seven picks, so it was squash-merged into `main` as `1d28c0fa` on 2026-10-20. The integration branch was rebased onto it, and step 0 now holds only item 0.2 and its review fixes. The original recommendation was to **split them out** as PR 0 off current `main`, together with only the D2 policy change (0.2). A CI PR should not carry service lifecycle behavior, and merging the unclean-shutdown `StateError` only to reverse it in the next PR wastes a review. Keep PR 1's other fixes separate, so PR 0 stays under the ~1,500-line review guideline. The `invalidArgument` classification for malformed status is pre-existing client behavior and stays with PR 3. | Rejected: resume #150 as is, then land the fixes as follow-ups | Sequencing |
| D2 | Policy after an unclean shutdown (record kept, lock free) | **Decided** | **Always recover.** The replacement adopts the recorded runtime, which `_start` already does ("An unclean predecessor can leave a healthy helper at this endpoint"). The current error is one-shot anyway: the reconnect 1 s later launches. | Rejected: fail every launcher consistently, with a manual recovery step | PR 1 |
| D3 | What clients see while an owner closes | **Decided** | **A structured closing refusal** for requests that were not dispatched, and a structured "outcome unknown" error for requests that were. A bare EOF happens only on a crash. Callers need "refused, safe to retry" to differ from "lost, may have committed". | Rejected: declare EOF the protocol and drop the closing-reply special case | PR 3, PR 5 |
| D4 | Protecting editor-held IDs after a workspace clear | **Decided** | **A persistent workspace epoch**, sent with ID-based mutations. No table rebuild is needed. | Rejected: `AUTOINCREMENT` on `notes`/`meetings` through a table-rebuild migration | PR 5 |
| D5 | Linux default runtime directory | **Decided** | **Per profile** (`$XDG_RUNTIME_DIR/open-foresight/<id12>`), as on macOS, plus the identity check | Rejected: identity check only, keeping the shared default | PR 4 |
| D6 | Stopping recording when the host desktop disconnects | **Decided** | **Keep the immediate stop** (privacy). Fix the causes of spurious disconnects instead (SL-1). | Rejected: give it the 1 s reattach grace | None |
| D7 | Service lifetime and the desktop/agent boundary | **Proposed** | Recorded in [ADR 0007](../adr/0007-service-lifetime-and-desktop-agent-boundary.md): the desktop keeps the service running; with no desktop, the service exits after `serviceIdleMinutes` without agent activity. | Rejected in the ADR: a resident service that unloads its models when idle | A follow-up PR after this plan's PR |

Overlap with [plan 3](../audit/2026-10-18-implementation-plan-3.md):
- **6.1 (typed RPC boundary):** the `reason` field added in PR 3 is additive and consistent with 6.1's split between caller errors and internal errors.
- **6.3 (isolate relay):** `IsolatedApplicationService` is still a byte relay at `5e098cf2`. PR 3 assumes it stays. If the owner decides under 6.3 to collapse the relay, do that before PR 3 and drop PR 3's frontend steps (3.4).

## Findings

Severity follows the audit. "Reproduced" means a reviewer wrote a deterministic test that shows the defect. "Verified" means the code was read and confirmed during consolidation.

| ID | Sev. | Defect | Where (at `5e098cf2`) | Evidence | PR |
|---|---|---|---|---|---|
| SL-1 | High | One reply over 16 MiB drops the desktop's only socket. The service treats that as the host leaving and stops an active recording. Opening the graph with about 1,000 or more indexed sources triggers it. | `ApplicationService._send` (`service.dart:512`) has no cap; `ServiceClient` limit (`:101-108`); host `onDone` → `stopRecording` (`:714-724`); `sources_controller.dart:1601` sends every missing source in one `graphEmbeddings` call | Reproduced against the real service; verified | 1 |
| SL-2 | High | Any endpoint record other than a missing file blocks every client and every new owner until it is deleted by hand: empty, truncated, non-object, directory, mode 000, stale data path, or an uncreatable recorded runtime. The writer never flushes, so a power cut can leave an empty record. | `serviceEndpoint` (`:56-78`); writer in `_start` (`:459-468`) | Reproduced (8 variants) | 1 |
| SL-3 | Med | The handoff tests' fake owner sends a closing reply, but the production `IsolatedApplicationService` destroys peers at once on SIGTERM/`--stop` and drops new connections while closing. The worker deletes the endpoint record before the frontend removes the public socket. | `IsolatedApplicationService.close` (`:1183-1197`), `_bridge` (`:1116`), record deletion in `_close` (`:944-956`) before `_beforeReleaseOwnership` (`:957-959`, `:1318`) | Reproduced; verified | 3 |
| SL-4 | Med | A lost reply and a refused request are both just `unavailable`. Retrying non-idempotent operations duplicates them: `notes.save` without an ID committed twice. Requests in flight at close get a bare EOF even after committing. | `_close` cancels leases with no terminal frame (`:911-920`); MCP and desktop error paths | Reproduced | 3 (frames), 5 (keys) |
| SL-5 | Med | `notes.save` with an ID that no longer exists reports success and writes nothing. After a clear, `INTEGER PRIMARY KEY` reuses IDs, so a stale editor overwrites an unrelated new note. | `Store.saveNote` (`store.dart:599-614`); desktop clear flow (`settings_controller.dart:706-725`) | Reproduced; verified | 5 |
| SL-6 | Med | Transport failures are reported as caller errors. A reply cut off by EOF becomes `FormatException` → `invalidArgument`, and MCP tells the agent its arguments were invalid. In-flight requests get the raw error while later ones get a normalized one. `ensureService` treats a truncated status reply as fatal. | `ServiceClient` framing (`LineSplitter`, `:111`), `_fail` (`:158-172`); `RpcError.from` (`rpc_error.dart:46-53`) | Reproduced; verified | 3 |
| SL-7 | Med | On Linux every profile defaults to the same runtime directory, and status does not say which profile answered. A client can attach to another profile's service, `--stop` can SIGTERM it, and a second owner deletes the first owner's live socket as stale. | `profile_paths.dart:74-82`; fallback in `serviceEndpoint`; `_start` stale delete (`service.dart:431-434`); frontend `_listen` (`:1097-1101`) | Reproduced; verified | 4 |
| SL-8 | Med | After an unclean shutdown, a launcher that saw the closing reply throws "released ownership without clean shutdown" while one that saw EOF launches a replacement. A startup failure after the record is published leaves the same state. | `_profileOwnerAvailable` (`:1388-1430`); `_start` catch (`:495-505`) | Reproduced by four reviewers; verified | 0 |
| SL-9 | Med | Once a client has passed the status probe, a later closing refusal reaches the caller unchanged, and `connect()` keeps returning the same client. Desktop startup fails if the 1 s detach timer fires between `RemoteDomain.connect`'s two status calls. | `ServiceConnection` (`:258-292`); `RemoteDomain.command`/`connect` (`remote_domain.dart:150-200`) | Reproduced | 3 |
| L1 | Low | A stalled owner holds startup for the whole 3-minute budget, because the status probe timeout is `remaining()`. | `_connectCompatibleService` (`:1346-1386`) | Reproduced | 3 |
| L2 | Low | There are two closing texts. `_execute` sends "Application service is shutting down" without the suffix, and only the full text is matched. | `_execute` (`:851-870`) | Reproduced (client side) | 3 |
| L3 | Low | A replacement that dies right after launch makes `ensureService` wait out the whole deadline. Startup errors are lost on Linux (detached, no stdio). | `ensureService` `launched` guard | Reasoned | 3 |
| L4 | Low | `RemoteDomain._reconnect` leaks the new client when attach or status fails, so two sockets end up applying events. | `remote_domain.dart:119-151` | Reasoned | 5 |
| L5 | Low | An approval dialog stays open after a reconnect, because `approval_closed` never arrives for the dropped connection. | `agent_approval_surface.dart` | Reasoned | 5 |
| L6 | Low | `--stop` reports success at EOF, before the helper stops and the locks are released, and it never sees a cleanup failure. | `bin/service.dart` stop path | Reasoned | 3 |
| L7 | Low | Stale `.application-endpoint.json.<pid>` temp files are never removed. | `_start` writer and catch | Reasoned | 1 |
| L8 | Low, latent | The `_localServiceOwners` guard is per isolate, but POSIX locks are per process. An `ensureService` call from another isolate of an owning process drops the owner's lock. No shipped binary does this. | `_retainLocalServiceOwner` (`:25-41`) | Reproduced | Backlog |
| L9 | Low | `RemoteDomain.connect` reads the record a second time to build `helper.sock`, which can disagree with the connected endpoint. If that read throws, the client and the read-only store leak. | `remote_domain.dart:155-161` | Reasoned | 4 |
| L10 | Low | The Python diagnostics read the record with check-then-read, so `FileNotFoundError` hides the original failure. | `tests/service/test_service_process.py:1161` | Reasoned | 2 |
| T1 | Test | Timing-sensitive handoff assertions. HO:345 and HO:518 need `closing-observed` within a 500 ms deadline. HO:288 and HO:319 can pass without testing anything. HO:365 burns a real 15 s deadline (about 65% of the file's run time). | `service_shutdown_handoff_test.dart` (HO) | Measured: 5/5 passes, durations recorded | 2 |
| T2 | Test | The handoff fixture writes its record non-atomically (49 of 99 reads were half-written under continuous rewrites), always uses the client's runtime, and never replays production's teardown order. | HO fixture (`:19-100`) | Reproduced | 2 |
| T3 | Test | The built service/MCP suite (`tests/service`) restarts only with SIGTERM, so the closing handoff is never exercised end to end with production code on both sides. | `tools/build_service_gate.sh` | Verified | 2, 3 |

The reviewers' reproduction tests are on the audit host only and are not in the repository. Use them as starting points, then copy the cases into the test files named below:
- `/var/tmp/ofhc/handoff-client/packages/foresight_core/test/handoff_client_review_test.dart`
- `/var/tmp/ofr/shutdown-server/packages/foresight_core/test/shutdown_server_audit_test.dart`
- `/var/tmp/ofr/lost-reply/packages/foresight_core/test/lost_reply_test.dart` (and LR-M1 to LR-M3 appended to that copy's `mcp_protocol_test.dart`)
- `/var/tmp/claude-endpoint-record.qp87aT/endpoint-record/packages/foresight_core/test/endpoint_record_audit_test.dart`
- `/var/tmp/ofr/boundary/packages/foresight_core/test/boundary_probe_test.dart`

## Ground rules

1. **Regression test first.** For every finding a PR closes, add a test that fails on the parent commit and passes after the fix. Run it against the parent to confirm the failure, and say so in the PR description with the finding ID.
2. **No sleeps for ordering.** Force interleavings with Completers, fixture control files, the PR 2 fault proxy or service gates. A timeout may bound a wait, but no assertion may depend on how long something took. A test that asserts "still pending" must anchor on an observed event, not on a time window.
3. **Production on both sides where the boundary is the point.** Fixtures are fine for unit cases. Each boundary listed in PR 2's matrix needs at least one test that runs production code on both sides.
4. **Wire compatibility.** The desktop, service and MCP ship together, but an old owner can still be running during an upgrade. Every wire change must be additive: new fields are optional, old messages are unchanged, and the closing text stays byte-identical. Unknown error codes already map to `internal` on old clients (`RpcError.from`).
5. **No SDK or native rebuilds.** These PRs change Dart and Python only. Reuse the verified native library, helper and SDK artifacts (AGENTS.md).
6. **Coordinate on `service.dart`.** Codex is active on the PR #150 branch. Agree who edits `service.dart` before starting each PR.

---

## PR 0: Split out the service handoff commits (D1)

**Status:** the seven commits reached `main` through #150 (`1d28c0fa`), so 0.1 and 0.3 are no longer needed. Step 0 consists of 0.2 and its review fixes.

Branch: `fix/service-handoff`, from current `origin/main` (`18b67da9` at the time of writing). PR #150 stays paused until this merges.

### 0.1 Cherry-pick the seven commits

1. Cherry-pick these seven pushed PR #150 commits **by hash, in this order**: `2250d0ba 21f9ef06 a7ece8cc 9c2c7f5c b7680cda a643fabe 151878f1`. Do not cherry-pick the range `2250d0ba^..151878f1`, because it also contains `93a15837` (a CI progress doc). Their combined `packages/` diff is identical to the local-only `codex/ci-service-handoff-fixtures` commits `68890b2b`..`5e098cf2`. Recorded check: they touch only `packages/foresight_core/lib/src/service.dart`, `test/service_shutdown_handoff_test.dart`, `test/service_connection_test.dart` and `test/mcp_protocol_test.dart`. Those four files, plus `foresight_test_support`'s `poll.dart` and `test_paths.dart` and both pubspecs, are byte-identical between the commits' base and `origin/main`, so the picks apply without conflicts.
2. `origin/main` gained #151 (Granola calendar) after the commits' base. It changes other `foresight_core` files, so the full Dart core suite must still be run (see Verification). A clean apply does not prove compatibility.
3. Stop adding service commits to `codex/ci-service-handoff-fixtures` and PR #150. Any further service work goes to this branch or to the later PRs in this plan.

### 0.2 One policy after an unclean shutdown (SL-8, D2)

**Change:**
1. In `_profileOwnerAvailable`, once the lock is acquired, return `true` whether or not the record exists. Delete the `closingOwner` `StateError`, and drop the `closingOwner` parameter if nothing else uses it. When the record exists, log "previous owner left its endpoint record; the replacement adopts its runtime".
2. In `ApplicationService._start`, record whether the endpoint record existed before this attempt. If startup fails after this attempt published a record that did not exist before, delete it in the catch **before** `lock.closeSync()`. If it existed before (adoption), leave it: it points at the adopted runtime.

**Tests:**
- Change HO's `unclean owner shutdown remains an actionable failure without a replacement` to expect exactly one launch and an attach to the replacement.
- Add the EOF variant and assert the same outcome.
- Two concurrent `ensureService` calls gated on `closing-observed` produce one owner, both attach to the same pid, and neither gets a `StateError`.
- Startup fails after the record is published (for example, a planted `.desktop-capability` symlink). Assert that no record is left behind and the lock is free.

### 0.3 Resuming PR #150

After PR 0 merges, rebase #150 onto `main`. Its seven service commits are patch-identical to PR 0's picks, so `git rebase` should drop them automatically. Confirm with `git cherry -v origin/main codex/ci-restructure` before the rebase: each of the seven should be listed with `-`. If any service hunk remains after the rebase, drop it rather than resolve it, because `main` is now the source of truth for `service.dart`. Then rerun #150's CI only for the jobs that the rebase affects (AGENTS.md).

---

## PR 1: Service wedges

Branch: `fix/service-wedges`, after PR 0 merges. Item 1.2 builds on PR 0's change to `serviceEndpoint`.

### 1.1 Cap reply frames and batch graph embeddings (SL-1)

**Change:**
1. In `ApplicationService._send`, encode once to bytes (`utf8.encode(jsonEncode(message))`), then check that `bytes.length + 1 <= maxServiceMessage`.
   - If the frame is too large and has an `id`, send `{'id': id, 'error': RpcError(RpcErrorCode.internal, 'Reply exceeds 16 MiB; request fewer items.').toJson(), 'done': true}` instead, and cancel that request's subscription so no later frame follows.
   - If it is an event (no `id`), drop it and trace it. Events are snapshots, and the next one supersedes it.
   - Write the bytes with `client.add`. Do not encode twice.
2. In `sources_controller.dart` (the `graphEmbeddings` call near line 1601), request missing sources in chunks of at most 128. Merge each chunk into `graphVectorCache` as it arrives, so partial progress survives a failure.
3. Leave the client's 16 MiB limit as a safety net, and leave the host-disconnect recording stop in place (D6).

**Tests:**
- Real `ApplicationService`, a desktop connection attached as host, and a recording stub. Request a reply over the limit. Assert that the request fails with the cap error, the connection stays open, and recording continues.
- A desktop controller test: 1,500 missing sources produce at least 12 requests, each under the limit.

### 1.2 Recover from an invalid endpoint record (SL-2, L7)

**Change:**
1. Replace the body of `serviceEndpoint` with `readEndpointRecord(ProfilePaths) → EndpointRecord`, a sealed type with three cases:
   - `EndpointAbsent`
   - `EndpointValid(runtime)`
   - `EndpointInvalid(reason)`: decode errors, a non-`Map` value or wrong types, a data-path mismatch, a directory, `EACCES`, a symlink, or a recorded runtime that `privateDirectory` rejects.

   `PathNotFoundException` during the read stays `EndpointAbsent`. Keep `serviceEndpoint(profile)` as a thin wrapper that returns `'$runtime/application.sock'` for valid records and `'${profile.runtime}/application.sock'` otherwise, so it never throws for record content.
2. **Clients** (`ensureService`) treat `EndpointInvalid` like `EndpointAbsent`, and include the reason in the deadline message.
3. **Owners** (`ApplicationService._start`, which already holds the profile lock):
   - On `EndpointInvalid`, rename the record to `.application-endpoint.json.invalid-<epochMs>`, log the reason to stderr, and use the owner's own runtime. Renaming moves a symlink itself, not its target.
   - Keep at most three quarantined records.
4. **Writer:**
   - Write the temp file with `flush: true`.
   - Delete the temp file in `_start`'s catch.
   - At startup, under the lock, sweep stale `.application-endpoint.json.<digits>` temp files.

   `dart:io` has no directory `fsync`. That is acceptable now that readers recover.

**Tests:** the eight `WEDGE:` cases from the endpoint review, rewritten so that `ensureService` (with a fixture owner) attaches and `ApplicationService.start` succeeds within `startupTimeout`. Also assert that the record is quarantined, with no more than three kept, and that temp files are swept.

---

## PR 2: Lifecycle test harness

Branch: `test/service-lifecycle-harness`. This PR changes no production behavior except hook plumbing that compiles out.

### 2.1 Fault proxy for client-side boundaries

Add `packages/foresight_test_support/lib/service_fault_proxy.dart`.
- `ServiceFaultProxy.run(body)` runs `body` inside `IOOverrides.runZoned(socketConnect: …)`. Every Unix-socket connect to a service endpoint is routed through an in-process relay that parses frames in both directions.
- **Controls** (each returns a Future or gate, never a timer):
  - `hold(direction, where)` returns a gate that releases the matching frame
  - `truncate(direction, where, keepBytes)` followed by a half-close
  - `drop(direction, where)` followed by destroy
  - `inject(direction, frame)`
  - `seen(direction, where)` returns a Future that completes when a matching frame passes
- Matching is by `method`, `id`, `event` or a predicate.
- This covers `ensureService`, `ServiceClient`, `ServiceConnection` and `RemoteDomain`, because they all connect in the test's isolate.

### 2.2 Service gates for server-side boundaries

1. Add `FORESIGHT_SERVICE_GATES` to `_testHookKeys` in `platform_services.dart`, so it is stripped unless the binary was compiled with `-DFORESIGHT_ENABLE_TEST_HOOKS=true`.
2. Add `serviceGate(String point)` in `service.dart`. When the key is set, it writes `<dir>/<point>.reached` (containing the pid) and waits for `<dir>/<point>.release`. It is a no-op otherwise.
3. Gate points:
   - `close.begin`
   - `close.leases_terminated` (used from PR 3)
   - `close.helper_closed`
   - `close.listener_closed`
   - `close.before_frontend_release`
   - `close.before_record_delete`
   - `close.before_lock_release`
   - `frontend.draining` (PR 3)
   - `request.committed.<method>`, after `Application.call` returns and before the reply frame is sent
4. Polling the release file is allowed, because it affects latency only, not ordering.
5. Dart lifecycle tests start `bin/service.dart` from source with `dart -DFORESIGHT_ENABLE_TEST_HOOKS=true run`. Add a CI step next to the existing "core enabled-hook regression" in `tools/build_dart_gates.sh` that runs the lifecycle test files with the define and `--compiler=source`.
6. **Hook-free release:** a `tests/service` case runs the built `foresight-service` with `FORESIGHT_SERVICE_GATES` set and asserts that no `.reached` file appears (AGENTS.md: test hooks disabled by default and enabled).

### 2.3 Shared fixtures

1. Move the gated helper fixture (a Python helper that holds SIGTERM until a control file appears) out of HO into `foresight_test_support`, with a Python twin under `tests/service`, so Dart and the built-binary suite share one behavior.
2. Fix the HO fixture (T2):
   - write the record with temp-then-rename and chmod 600
   - bind under a private name and rename, like `ServiceSocketBinding`
   - tear down in production order: public socket, then record, then lock
   - add `separateOwnerRuntime` variants of the closing-owner tests
3. Fix the timing (T1):
   - HO:345 and HO:518: start the deadline after the `closing-observed` gate, not before
   - HO:288 and HO:319: replace "still pending after N ms" with an assertion anchored on an observed event, such as the fixture logging a second status probe or the proxy seeing the lock-probe retry
   - HO:365: use a short `startupTimeout` and a gate, removing the 15 s wall-clock wait
4. Fix the Python diagnostics race (L10) with `try/except FileNotFoundError` around the record read.

### 2.4 Coverage matrix as a living document

Add `docs/architecture/service-lifecycle-tests.md`, a matrix with boundaries as rows and transitions as columns:
- **Rows:** desktop↔service, MCP/CLI↔service, frontend isolate↔worker isolate, service↔helper, launcher↔spawned service, lock and record handoff
- **Columns:** start/ready, closing, closed, crash, replacement, reconnect, EOF before reply, malformed or partial frame, slow reply, duplicate launch

Each cell names its test or says **GAP**. Each later PR updates the cells it closes. Seed it from the audit matrix.

### 2.5 Characterization tests that pass today

Using production code on both sides, add tests that pin behavior PR 3 does not change:
- crash (SIGKILL) recovery with adoption
- two launchers converging on one owner when the owner is absent
- a record deleted mid-read falling back correctly

**Determinism gate for this PR and every later one:** run the lifecycle files 20 times with `--concurrency=1` and 5 times with `--concurrency=8`, with zero failures. Report the durations in the PR description.

---

## PR 3: Closing protocol

Branch: `fix/service-closing-protocol`. Depends on PR 2.

### 3.1 Error reasons on the wire (SL-4 groundwork, L2)

1. Add `enum RpcErrorReason { closing, outcomeUnknown, notSent }` and an optional `reason` field on `RpcError`.
   - `toJson` writes `'reason': reason.name` when it is set.
   - `RpcError.from(Map)` parses `reason`, treating unknown values as `null`.
   - The meanings:
     - **`closing`:** the service refused before dispatch. It is safe to retry after handoff.
     - **`outcomeUnknown`:** the request was dispatched, or written to the socket, and no terminal frame arrived. It may have committed.
     - **`notSent`:** client-local. The request never reached a live socket. It is safe to retry.
2. **Server:**
   - Both closing paths (the `_accept` refusal at `:579-588` and `_execute` at `:857-861`) send `unavailable` with `reason: closing` and the same message, `_serviceClosingMessage`.
   - Keep the text byte-identical, because v0.1.0–v0.1.2 clients match on it.
3. **Clients:** an `unavailable` error without `reason` whose message equals either legacy closing text is treated as `closing`. That covers old owners during an upgrade. Put this in one helper, `isClosingRefusal(RpcError)`, used by `_connectCompatibleService`, `ServiceConnection` and `RemoteDomain`.

### 3.2 Client framing and one failure classification (SL-6)

1. Replace `LineSplitter` in `ServiceClient` with a framer that emits only newline-terminated lines and counts bytes exactly per frame.
   - **Trailing partial frame at EOF:** treated as transport loss.
   - **Frame over the limit:** transport loss.
   - **Complete frame that is not a JSON object:** a protocol error.
2. `_fail(cause)` computes the error once:
   - **Transport loss** (EOF, `SocketException`, truncation, oversize): in-flight requests get `RpcError(unavailable, 'Application service disconnected', reason: outcomeUnknown)`, and later `stream()` calls get the same with `reason: notSent`.
   - **Protocol error:** every caller gets `RpcError(internal, 'Application service sent an invalid reply')`.
   - **Local `close()`:** later calls keep the contract from `5e098cf2` (`unavailable`, "Application service disconnected", now with `reason: notSent`). In-flight calls get `reason: outcomeUnknown`.
   - Callers never receive a raw `FormatException`, `SocketException` or `StateError`.
3. Keep `_ServiceTransportLost` as the local marker that `ensureService` retries on. A status probe hit by `outcomeUnknown` may be retried, because status is read-only.
4. In `ensureService`:
   - a partial status frame followed by EOF is retried
   - a complete malformed status frame stays fatal without a replacement, which keeps the intent of HO:638. Change that test's expected classification from `invalidArgument` to the protocol error.
5. MCP (`bin/mcp.dart:138-143`) puts `reason` into `structuredContent.error`. Because the client now always delivers an `RpcError`, `RpcError.from` no longer turns transport failures into `invalidArgument`.

### 3.3 Server drain at close (SL-4 frames)

In `ApplicationService._close`:
1. After `_closing = true` and before `_cancel` runs over the leases, send each in-flight lease a terminal frame: `{'id': id, 'error': RpcError(unavailable, 'Application service stopped before this request finished; it may or may not have completed.', reason: outcomeUnknown).toJson(), 'done': true}`. Then cancel it. This loop is synchronous at the start of `_close`, so no request can complete in between.
2. Before destroying clients (`:939-941`), flush each non-acknowledgement client, with a 2 s bound in total.
3. Add `serviceGate('close.leases_terminated')`.

### 3.4 Isolated frontend: drain, refuse, then release (SL-3)

1. **New handshake message.** The worker sends `['draining']` at the start of `_close`, before any await. On `draining` (and on its own `close()`), the frontend sets `_draining = true`.
2. **New connections while draining** are not bridged. `_refuse(client)` serves them instead:
   - it reads newline-terminated frames under the same byte limit
   - it answers every `{"id": int, …}` with the closing refusal and `done: true`
   - it ignores cancels
   - it destroys the connection on malformed input
   - the connection stays open until `_removePublicSocket` runs, then is destroyed
3. **Frontend-initiated close** (SIGTERM, `--stop`, `host.close()`) no longer destroys `_peers` at once.
   - It sets `_draining`, sends `'close'`, and lets the existing bridges relay the worker's terminal frames and refusals.
   - Peers still open when `_finish` runs are destroyed then.
   - Update the comment at `:1187-1189` and the expectation in `service_isolate_test.dart` (around line 404, which currently requires EOF).
4. **Ordering.** Move endpoint-record deletion in `_close` to **after** `_beforeReleaseOwnership` completes, so the order is: worker socket, then public socket (frontend), then record, then lock. "Record present" then always means the owner is live, is draining, or crashed. The non-isolated service keeps its current order, because its hook is null.
5. **Worker dies unexpectedly** (`_exits` without `close`): the frontend enters `_draining`, so new connections get the closing refusal and existing peers get EOF. `_removePublicSocket(workerOwnsLock: false)` must not delete a socket path that a replacement now owns. Check that the inode is the one it bound before unlinking.

### 3.5 Handoff for attached clients (SL-9)

1. In `ServiceConnection.stream`, if the first error arrives before any result frame and is a closing refusal or `notSent`: close the client, clear `_client`, `connect()` again (which runs `ensureService`'s handoff), and resend once. Never resend on `outcomeUnknown`.
2. In `RemoteDomain`:
   - add `Future<void> _awaitReconnect()`
   - `command()` applies the same rule: on a closing refusal or `notSent` before any result, await the reconnect (which re-attaches approvals and refreshes status), then resend once
   - route `connect()`'s second status call through the same path
3. `cancelAnswers` and stream cancellation must not resend.

### 3.6 Startup probe and launch failures (L1, L3)

1. Cap the status probe at `min(remaining(), 30 s)`. On timeout, close the client and throw `TimeoutException('Application service at <path> accepted the connection but did not answer status within 30 s; it may be busy or hung.')`, without launching. The long-term fix for a slow status during generation is plan 3, 6.3.
2. **Fast failure for a dead replacement.** `launchOnce` passes `FORESIGHT_STARTUP_STATUS=<runtime>/startup-<launchId>.json` (on macOS through the existing startup-environment handoff). `bin/service.dart` writes `{"state":"failed","error":…}` there if `IsolatedApplicationService.start` throws. The `ensureService` loop checks the file on each 100 ms tick and fails at once with the recorded cause. Delete the file in `finally`.

### 3.7 `--stop` waits for release (L6)

After SIGTERM and EOF, `bin/service.dart --stop`:
- waits until it can acquire the profile lock (the CLI is never an owner, so the probe is safe) or the pid is gone, for at most 30 s
- exits non-zero with a message if neither happens
- verifies the status `profile_id` before signaling, once PR 4 has landed

### Tests for PR 3

Production code on both sides unless noted:
1. **Real closing owner against real `ensureService`.** `bin/service.dart` from source with gates, the gated helper, and `stop_if_idle`. Assert no launch while the `close.helper_closed` gate holds. Release it, then assert exactly one launch and that the client attaches to the replacement's pid. Add a built-binary twin in `tests/service` that uses only the helper gate (T3).
2. **SIGTERM path.** A new client during `close.helper_closed` gets the closing refusal, not EOF. An in-flight request gets `outcomeUnknown` (SL-3, SL-4).
3. **Committed write loses its reply.** At the `request.committed.notes.save` gate, close the owner. The client gets `outcomeUnknown`, and the row exists.
4. **Record gone while the public socket is alive.** This window no longer exists. Gate `close.before_record_delete` and assert the public socket is already gone and the record still exists.
5. **Partial frame then EOF.** The fault proxy truncates the real status reply. `ensureService` retries and attaches (SL-6).
6. **Malformed complete frame.** The fault proxy injects `not-json`. Assert a protocol error, no replacement, and that MCP reports `internal` with no `invalidArgument`.
7. **Attached client meets a closing owner.** A `ServiceConnection` and a `RemoteDomain` each attach, then the owner closes (gate). The next `notes.list` succeeds on the replacement and was sent to the closing owner exactly once (SL-9).
8. **Desktop reconnect racing the detach timer.** Inject the 1 s timer: add a `Duration desktopDetachGrace` parameter to `ApplicationService`, defaulting to 1 s. Assert that `RemoteDomain` reconnects, re-attaches approvals once and replays nothing.
9. **Two launchers in different processes** join one closing owner. Assert one owner and the same pid for both.
10. **Worker exits unexpectedly** (a hook that throws in the worker). New clients get the closing refusal. The old frontend never deletes the replacement's socket.
11. **Stalled owner** (the fixture's `stall` mode with a 3-minute budget). Fails with the probe message in about 30 s. Use a test-only probe cap parameter so the test takes under 1 s.
12. **Dead replacement.** A launcher wrapper that writes a failed startup status. `ensureService` fails at once with the cause.
13. **Wire compatibility.** A legacy owner fixture that sends the closing text without `reason` is handed off. An old-client simulation that ignores `reason` still matches the text.

---

## PR 4: Profile identity

Branch: `fix/service-profile-identity`.

### 4.1 Identity in status (SL-7)

1. Expose `ProfilePaths.identity`, the 24-hex SHA-256 of the canonical data path that `profile_paths.dart:74-77` already computes. Add `'profile_id': profile.identity` to the `Operation.status` result in `application.dart` (`:613-638`).
2. `_connectCompatibleService(path, profile)`: if `profile_id` is present and differs from the client's identity, close the client and treat the endpoint as "not our owner". Continue the loop like a `SocketException`, but never launch over it. If it persists to the deadline, fail with: "Another Open Foresight profile is serving <path>. Set FORESIGHT_RUNTIME for this profile." A missing `profile_id` (an owner older than this change) is accepted.
3. `bin/service.dart` `--status`, `--stop` and `--stop-if-idle` check `profile_id` before acting. `--stop` never signals another profile's pid.

### 4.2 Never delete a live socket

In `ApplicationService._start` (`:431-434`) and the frontend's `_listen` (`:1097-1101`), before deleting an existing socket path, try to connect with a 200 ms bound. If the connect succeeds, the path belongs to a live process while this process holds the profile lock, so it must be another profile's owner: fail with the message from 4.1 instead of deleting it.

### 4.3 Per-profile Linux runtime (D5)

1. Change the Linux default in `profile_paths.dart` from `$XDG_RUNTIME_DIR/open-foresight` to `$XDG_RUNTIME_DIR/open-foresight/<identity12>`. Use `$data/runtime/<identity12>` when `XDG_RUNTIME_DIR` is unset.
2. **Migration:** an owner started by an older version records its runtime in the endpoint record, so new clients still find it. After it exits, the next owner uses the new path. Helper adoption follows the record.
3. Audit every consumer of the old default and update it or confirm that it passes an explicit runtime. Known consumers: `tools/installed_runtime.py`, `tools/integration_gates.py`, `tools/test_global_shortcut.py` and `tools/test_global_shortcut_private.py`. Also check `packaging/` and `docs/`.

### 4.4 One endpoint read per connection (L9)

1. `ServiceClient` records `final String endpoint` (the socket path it connected to). `ensureService` returns it.
2. `RemoteDomain.connect` builds `helper.sock` from `File(client.endpoint).parent.path`. On reconnect, it updates the helper path if the endpoint changed.
3. If `connect` fails after `ensureService`, close the client and the read-only `Store`.

### Tests for PR 4

- The three `WRONG SOCKET:` cases from the endpoint review: `ensureService` and `--status` refuse another profile's owner, and `--stop` never signals it.
- `_start` refuses to delete a live socket of another profile.
- The default runtimes of two profiles differ on Linux.
- Upgrade path: an owner whose record points at the old shared runtime is still found and attached.
- `RemoteDomain` uses the connected endpoint for `helper.sock`, and closes the client and store when `connect` fails.

---

## PR 5: Commit safety

Branch: `fix/service-commit-safety`. Depends on PR 3's reasons.

### 5.1 Stale IDs (SL-5, D4)

1. `Store.saveNote` with an `id` requires `db.updatedRows == 1`; otherwise it throws `RpcError(notFound, 'This note no longer exists.')`. Audit every RPC that mutates an existing row by ID and apply the same existence check: `meetings.notes`, `meetings.transcript`, `artifacts.edit`, `labels.*`, `meetings.link_answer`, and any others found in the `Operation` registry.
2. **Workspace epoch:**
   - Store a random 128-bit token in `preferences` under `workspaceEpoch`, created on first start and regenerated inside the `workspace.clear` transaction. No schema change is needed.
   - Status returns `workspace_epoch`.
   - The desktop sends `workspace_epoch` with every ID-based mutation, and the service rejects a mismatch with `notFound` ("This item was removed when the workspace was cleared.").
   - MCP tools accept it as an optional argument.

### 5.2 Idempotency keys for creates and appends (SL-4)

1. **Schema.** Add schema version 13 (check `Store.schemaVersion`, currently 12). It creates `request_keys(key TEXT PRIMARY KEY, operation TEXT NOT NULL, result TEXT NOT NULL, created INTEGER NOT NULL)`. Prune rows older than 24 hours (`Store.requestKeyLifetime`) at startup and before each keyed write. `workspace.clear` empties the table.
2. **Scope.** Audit `Operation` for non-idempotent operations. At least these are in scope: `notes.save` without an ID, `meetings.create`, `sources.import` without an ID, and `meetings.transcript` (it appends). Check `sources.import_url`, `sources.import_file` and the `google.import_*` operations: if they already deduplicate by URL, path or Drive ID, say so in the PR description and exclude them.
3. **Service.** An optional `idempotency_key` argument. The handler checks the key, then writes the row and the key **in one transaction**. A repeated key returns the stored result without writing. Wrap handlers that are not transactional today.
4. **MCP.**
   - Add an optional `idempotency_key` to those tools' schemas, with a description such as: "If a call fails with reason outcomeUnknown, retry with the same idempotency_key."
   - `structuredContent.error` carries `reason`.
   - The MCP server never retries on its own.
5. **Desktop.**
   - Each create action (new note save, New meeting, Quick start) keeps a pending key from the first attempt until success, so a user's retry reuses it.
   - On `outcomeUnknown`, refresh from the read-only store and show "The service stopped before confirming. Check whether it was saved." Do not show the plain "disconnected" text.

### 5.3 Desktop recovery paths (L4, L5)

1. **`workspace.clear` with `outcomeUnknown`:** refresh status. If `workspace_epoch` changed, run the UI reset (`settings_controller.dart:706-725`).
2. **`RemoteDomain._reconnect`:** if attach or status fails after `ensureService` returned, close `next`, cancel `_events`, and restore the previous state before retrying.
3. **Approval dialogs:** on a successful reconnect, `RemoteDomain` sends a synthetic `approval_closed` for every approval ID still outstanding, so open dialogs close. Track the outstanding IDs from `approval` and `approval_closed` events.

### Tests for PR 5

- **Lost reply after commit.** The fault proxy drops the `notes.save` reply after `request.committed.notes.save`. A retry with the same key commits once and returns the same ID. Without a key, the error is `outcomeUnknown`. Cover MCP too (LR-M1).
- **Stale editor after a lost clear reply.** The editor's save gets `notFound`, and after new notes exist it does not overwrite note 3 (R7).
- **Epoch mismatch** after a clear and a service restart.
- **Reconnect cleanup.** A fake service rejects the first attach with `busy`: exactly one live socket remains, and an open approval dialog closes after reconnect (widget test).
- **Schema 13** migration up from 12, and key pruning.

---

## Verification for every PR

Follow AGENTS.md ("Verify changes before pushing"). In particular:

1. **Dart core.** Run the full `dart test` in `packages/foresight_core`, then `tools/coverage_core.sh` with its threshold enforced.
2. **Hook-enabled lifecycle files.** `dart -DFORESIGHT_ENABLE_TEST_HOOKS=true test --compiler=source <lifecycle files>`.
3. **Desktop.** The Flutter test suite, plus the real desktop/service integration on an isolated display.
4. **Built service/MCP suite.** `dart compile exe` for `bin/service.dart` and `bin/mcp.dart`, then `pytest tests/service` with `FORESIGHT_SERVICE_EXECUTABLE`, `FORESIGHT_MCP_EXECUTABLE`, `FORESIGHT_HELPER_EXECUTABLE` and `FORESIGHT_NATIVE_LIBRARY`, as `tools/build_service_gate.sh` does. Reuse the verified helper and native library; no native rebuild is justified by these PRs.
5. **Determinism gate.** Run the lifecycle files 20 times with `--concurrency=1` and 5 times with `--concurrency=8`, with zero failures. Report the durations.
6. **Test counts.** Compare test counts and skip reasons with the parent commit. A new skip needs a reason in `tools/integration_skips.json`.
7. **Storage.** Use a disk-backed `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT` with short paths (for example `/var/tmp/of-<task>`). During the audit, `/tmp` hit its per-user quota (`EDQUOT`, errno 122) while `df` still showed free space, and scratchpad-length paths exceeded the 108-byte Unix socket limit (104 on macOS). Treat either failure as infrastructure and rerun.
8. **macOS.** The LaunchServices path (3.6 startup status, the startup-environment handoff) can only be verified on hosted macOS CI. State that limit in the PR.

## Backlog (not scheduled here)

- **L8, the per-process lock guard.** Either run the lock probe in a short-lived subprocess, or move ownership to `flock(2)` through FFI. `flock` locks belong to the open file description, so closing another descriptor does not drop them. Until then, document that `ensureService` must not be called from a process that hosts a service.
- **Helper lifecycle** (audit test 10). Duplicate helper launch on the same storage (the flock path), a crash of an adopted helper (there is no exit watcher today), and the helper↔service rows of the coverage matrix. Give these their own plan, together with plan 3's PR 8 if it resumes.
- **RPC latency** (plan 3, 6.3). Status can block behind native joins during generation, which is why 3.6 uses a 30 s probe cap rather than a few seconds.
