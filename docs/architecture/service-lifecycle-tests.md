# Service lifecycle test coverage

This matrix records which tests cover each service boundary through each lifecycle transition. Rows are boundaries and columns are transitions. It was seeded from the 2026-10-19 lifecycle audit and updated through step 3 of the [service lifecycle fix plan](../plans/2026-10-19-service-lifecycle-fix-plan.md). Each later step updates the cells it closes, in the same change as its tests.

## Reading the matrix

- A cell lists tests as `FILE: test name`. The file abbreviations are listed below.
- **fixture** marks coverage in which one side of the boundary is a fixture rather than production code. The fix plan requires at least one test with production code on both sides for each boundary.
- **GAP** means no test covers the transition. Where a planned test will close it, the cell names the fix-plan item, for example "PR 3 test 7".
- **n/a** means the transition does not exist at that boundary.

| Abbreviation | File |
|---|---|
| HO | `packages/foresight_core/test/service_shutdown_handoff_test.dart` |
| SC | `packages/foresight_core/test/service_connection_test.dart` |
| SO | `packages/foresight_core/test/service_ownership_test.dart` |
| SI | `packages/foresight_core/test/service_isolate_test.dart` |
| SID | `packages/foresight_core/test/service_idle_shutdown_test.dart` |
| SFI | `packages/foresight_core/test/service_failure_isolation_test.dart` |
| SS | `packages/foresight_core/test/service_socket_test.dart` |
| SER | `packages/foresight_core/test/service_endpoint_record_test.dart` |
| SSR | `packages/foresight_core/test/service_startup_recovery_test.dart` |
| SAA | `packages/foresight_core/test/service_agent_access_test.dart` |
| SL | `packages/foresight_core/test/service_lifecycle_test.dart` |
| SCP | `packages/foresight_core/test/service_closing_protocol_test.dart` |
| SG | `packages/foresight_core/test/service_gate_test.dart` |
| RD | `packages/foresight_core/test/remote_domain_test.dart` |
| MCP | `packages/foresight_core/test/mcp_protocol_test.dart` |
| HPR | `packages/foresight_core/test/helper_process_recovery_test.dart` (a fixture gRPC helper) |
| HC | `packages/foresight_core/test/helper_close_test.dart` |
| HT | `packages/foresight_core/test/helper_transport_test.dart` |
| HCH | `packages/foresight_core/test/helper_channel_test.dart` |
| HPU | `packages/foresight_core/test/helper_purge_retry_test.dart` |
| PY | `tests/service/test_service_process.py` (built service, MCP and helper) |
| PS | `packages/foresight_core/test/platform_services_test.dart` |
| WR | `tests/service/test_worker_recovery.py` (built service, MCP and helper) |

## Summary

**P**: production on both sides. **F**: fixture only. **G**: gap. **–**: n/a. A cell with both P and G covers some cases and misses others; the detail tables below say which.

| Boundary | Start/ready | Closing | Closed | Crash | Replacement | Reconnect | EOF before reply | Malformed or partial frame | Slow reply | Duplicate launch |
|---|---|---|---|---|---|---|---|---|---|---|
| Desktop ↔ service | P | P | P | F | P | P, G | F | P, F | G | G |
| MCP/CLI ↔ service | P | P | P | P | P | P | P, F | P, F | F | P |
| Frontend isolate ↔ worker isolate | P | P | P | P | – | – | P | P, F | G | P |
| Service ↔ helper | P | F | P | P | P | F | F | G | F | G |
| Launcher ↔ spawned service | P | P | P | P | P | – | P | P, F | F | P |
| Lock and record handoff | P | P | P | P | P | – | F | P | P | P, G |

## Desktop ↔ service

The desktop reaches the service through `RemoteDomain`, which connects with `ensureService`.

| Transition | Coverage |
|---|---|
| Start/ready | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations`. PY: `test_native_desktop_and_mcp_share_service` runs only with a configured display. **fixture** RD: `a failed connect closes its connection and leaves nothing running`. |
| Closing | SCP: `an attached ServiceConnection and RemoteDomain follow a closing owner and send each refused request to it only once (SL-9)`. SCP: `a desktop starting as the detach grace ends follows the owner to its replacement and attaches approvals once (held status) (SL-9)` (an in-process `ApplicationService` with an injected grace; the desktop's reserving snapshot is refused and the handoff happens inside startup). **fixture** HO: `desktop startup joins the closing owner before one replacement launch`, and its separate-owner-runtime variant (startup only). **fixture** RD: `a command refused by a closing owner is sent once more after the reconnect reattaches approvals (SL-9)`. **fixture** RD: `a cancel during the handoff stops only that answer's resend (cancel gen-3)`, and its `another-answer` variant. |
| Closed | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations` (SIGTERM). |
| Crash | **fixture** RD: `abrupt service loss reconnects and refreshes snapshots without replaying a write` (the fixture service drops the attached desktop's socket). No test crashes a real service under an attached `RemoteDomain`. Startup after a crash goes through `ensureService`, which SL: `a killed owner is replaced once and its recorded runtime is adopted` covers. |
| Replacement | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations`. |
| Reconnect | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations`. **fixture** RD: `a command refused by a closing owner is sent once more after the reconnect reattaches approvals (SL-9)` (approvals re-attached once). **fixture** RD: `abrupt service loss reconnects and refreshes snapshots without replaying a write`. **fixture** RD: `a command whose outcome is unknown is never resent`. **fixture** SC: `connection coalesces concurrent opens and reconnects without replaying uncertain writes`. **fixture** SAA: `desktop reconnect during grace period keeps service alive` (a raw socket stands in for the desktop). Closing open approval dialogs after a reconnect is a **GAP** (PR 5, L5). |
| EOF before reply | **fixture** RD: `abrupt service loss reconnects and refreshes snapshots without replaying a write`. **fixture** RD: `a command on a connection that already closed is sent once, on the next` (`notSent`). No test drops a real service under an attached `RemoteDomain` before its reply. |
| Malformed or partial frame | SCP: `a status reply cut off by EOF is retried and attaches to the live owner (SL-6)`. SCP: `a malformed status frame is a protocol error without a replacement (SL-6)`. **fixture** SC: `json service frames fail pending operations and close the client`, with its `utf8` and `oversized` variants. **fixture** SC: `a reply cut off by EOF is a lost connection, not a caller error (SL-6)`. **fixture** SC: `reply frames are counted exactly, not per socket read`. **fixture** SAA: `an oversized reply fails its request without dropping the desktop or its recording` and SAA: `an oversized reply is the last frame of its request` (SL-1; a raw socket stands in for the desktop). |
| Slow reply | **GAP**. |
| Duplicate launch | **GAP** for the desktop and MCP launching together; PY: `test_native_desktop_and_mcp_share_service` needs a display. |

## MCP/CLI ↔ service

| Transition | Coverage |
|---|---|
| Start/ready | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. PY: `test_shared_owner_concurrent_writes_search_and_mcp`. |
| Closing | PY: `test_attached_mcp_follows_a_closing_owner_to_one_replacement` (built service, MCP and gated helper; T3). SCP: `startup joins a real closing owner and attaches to its one replacement (T3, SL-3)`. SCP: `an old client recognizes a closing refusal by its unchanged text (wire compatibility)`. SCP: `an attached ServiceConnection and RemoteDomain follow a closing owner and send each refused request to it only once (SL-9)` (MCP's `ServiceConnection`). **fixture** SC: `a closing refusal before any result is sent once more after the handoff (SL-9)`, with legacy-text variants, and SC: `a request is resent at most once`. SCP: `at SIGTERM a request waiting for approval is refused and resent once to the replacement, while a dispatched one is outcomeUnknown` (MCP's `ServiceConnection`; the replacement shows a new approval). **fixture** SC: `a peer cannot make a request resendable by claiming notSent`. |
| Closed | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner` (SIGTERM). PY: `test_service_stop_waits_for_active_capture_and_finalizes_transcript` (`--stop`). SCP: `--stop returns only after the owner releases its profile lock (L6)`. SCP: `--stop succeeds but warns when the owner stops without a clean shutdown (L6)`. SCP: `--stop succeeds but warns when the owner already died without a clean shutdown, and still fails when no owner ever ran`. PY: `test_idle_upgrade_shutdown_defers_capture_and_requires_verified_ack` (`--stop-if-idle`). SO: `two runtimes and canonical aliases share a profile owner and committed writes`. |
| Crash | SCP: `after an unexpected worker exit new clients are refused and the handoff reaches one replacement (SL-3)` (the in-flight client gets `outcomeUnknown`; startup hands off). A killed MCP-attached owner is covered only through `ensureService` (SL: `a killed owner is replaced once and its recorded runtime is adopted`). |
| Replacement | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. |
| Reconnect | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. **fixture** MCP: `service disconnect fails pending tool and next call reconnects without replay`. |
| EOF before reply | SCP: `after an unexpected worker exit new clients are refused and the handoff reaches one replacement (SL-3)` (a real worker dies under an in-flight request, which gets EOF and reports `outcomeUnknown`). **fixture** MCP: `service disconnect fails pending tool and next call reconnects without replay` (the tool error carries reason `outcomeUnknown`). **fixture** SC: `a request with an unknown outcome, or one that already had a result, is never resent`. **fixture** SO: `two runtimes and canonical aliases share a profile owner and committed writes` (a fake peer's EOF is not an idle-stop acknowledgement). |
| Malformed or partial frame | SCP: `a malformed status frame is a protocol error without a replacement (SL-6)`. SCP: `a status reply cut off by EOF is retried and attaches to the live owner (SL-6)`. **fixture** MCP: `a malformed service frame is a protocol error, never invalid arguments (SL-6)` (real MCP binary, fixture service). |
| Slow reply | **fixture** HO: `a stalled owner fails startup at the probe limit, not after the whole budget (L1)`. A slow reply to an attached MCP is a **GAP** (plan 3, 6.3). |
| Duplicate launch | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. SCP: `two launcher processes join one closing owner and attach to the same replacement`. |

## Frontend isolate ↔ worker isolate

`IsolatedApplicationService` relays each public connection to the worker's private socket.

| Transition | Coverage |
|---|---|
| Start/ready | SI: `startup handoff reaches the real worker and custom profile controls`. SI: `concurrent isolated startup protects both sockets before the first RPC`. |
| Closing | SG: `the isolated worker stops at every close gate in order` (SIGTERM, real child, gate order). SG: `the isolated close removes its public socket before the record, and the record before the lock (SL-3)`. SL: `during a SIGTERM close a new client gets the closing refusal and an in-flight request outcomeUnknown, never a bare EOF (SL-3, SL-4)` (frontend-initiated). SI: `explicit shutdown refuses new requests and keeps clients until the worker closes them (SL-3)` (frontend-initiated, in process; also a refused connection ignoring cancels and dropping malformed input). SCP: `an old client recognizes a closing refusal by its unchanged text (wire compatibility)` and SCP: `startup joins a real closing owner and attaches to its one replacement (T3, SL-3)` (worker-initiated; clients arriving during the close). SI: `isolated domain preserves multiplexing, committed writes and idle shutdown acknowledgement` (worker-initiated; acknowledgement through the bridge). SCP: `at SIGTERM a request waiting for approval is refused and resent once to the replacement, while a dispatched one is outcomeUnknown`. SCP: `a desktop reservation while the owner closes is refused like any request and never cancels the close` (worker and frontend paths). |
| Closed | SI: `private worker preserves the public Unix socket path limit`. SI: `isolated domain preserves multiplexing, committed writes and idle shutdown acknowledgement`. |
| Crash | SCP: `after an unexpected worker exit new clients are refused and the handoff reaches one replacement (SL-3)` (a `.crash` gate kills the real worker; refusal and handoff). SI: `a frontend whose worker died never unlinks a socket that replaced its own (SL-3)` (in process; the only test that the old frontend never deletes a replacement's socket). **fixture** SI: `fatal isolate failures retain their separate error channel` (diagnostic worker only). |
| Replacement | n/a: a worker is never replaced inside its process. |
| Reconnect | n/a: each client connection gets its own bridge. |
| EOF before reply | SL: `during a SIGTERM close a new client gets the closing refusal and an in-flight request outcomeUnknown, never a bare EOF (SL-3, SL-4)`. SCP: `a request in flight when the worker begins closing gets a terminal outcomeUnknown frame (SL-4)` (through the bridge). SCP: `after an unexpected worker exit new clients are refused and the handoff reaches one replacement (SL-3)` (the only bare EOF). |
| Malformed or partial frame | SI: `explicit shutdown refuses new requests and keeps clients until the worker closes them (SL-3)` (the frontend's refusal path drops malformed input). **fixture** SFI: `malformed requests and security errors are scoped to one frame` (in-process `ApplicationService`, no bridge). |
| Slow reply | **GAP**. |
| Duplicate launch | SL: `two launchers converge on one owner when none is running` (a losing launch's worker fails the lock and its process exits). SO: `two runtimes and canonical aliases share a profile owner and committed writes`. |

## Service ↔ helper

| Transition | Coverage |
|---|---|
| Start/ready | WR: `test_helper_crash_preserves_committed_data_and_restores_indexing` (the built service starts the built helper and indexes). **fixture** HPR: `concurrent starts share one child and crash recovery restores RPC`. |
| Closing | **fixture** HC: `concurrent helper shutdown shares one transport termination`. **fixture** SG: `the isolated worker stops at every close gate in order` (the gated helper holds SIGTERM). |
| Closed | PY: `test_idle_shutdown_verifies_a_real_adopted_helper`. **fixture** HPR: `shutdown escalates a child ignoring SIGTERM and never restarts it`. |
| Crash | WR: `test_helper_crash_preserves_committed_data_and_restores_indexing`. **fixture** HPR: `concurrent starts share one child and crash recovery restores RPC`. |
| Replacement | WR: `test_explicit_resume_restarts_helper_after_automatic_budget_is_exhausted`. **fixture** HPR: `failed automatic relaunch stays degraded and explicit recovery retries`. |
| Reconnect | **fixture** HT: `the same helper channel reconnects to a replacement owner`. |
| EOF before reply | **fixture** HCH: `peer EOF before a queued request reports failure without escaping`. |
| Malformed or partial frame | **GAP**. |
| Slow reply | **fixture** HPU: `transport failure bounds retries (unresponsive=true)`. |
| Duplicate launch | **GAP**: two helpers on one storage (the flock path) and the crash of an adopted helper are in the fix plan's backlog. |

## Launcher ↔ spawned service

`ensureService` launching `FORESIGHT_SERVICE` and attaching to what it started.

| Transition | Coverage |
|---|---|
| Start/ready | SL: `two launchers converge on one owner when none is running`. PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. **fixture** SC: `launcher waits for model verification beyond ten seconds`. |
| Closing | SCP: `startup joins a real closing owner and attaches to its one replacement (T3, SL-3)`. PY: `test_attached_mcp_follows_a_closing_owner_to_one_replacement`. **fixture** HO: `a closing post-launch owner remains bounded without another launch`. **fixture** HO: `a legacy owner refusing with its shorter closing text is handed off (L2)`. SCP: `a startup probe that the closing owner ends with outcomeUnknown hands off to one replacement`. |
| Closed | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner` (the launched owner is stopped, and MCP launches again). |
| Crash | SCP: `a replacement that fails to start reports its cause at once (L3)` (the real service writes its startup status). SCP: `a startup status is written only inside the profile runtime`. The macOS LaunchServices handoff of the status path runs only on hosted macOS; PS: `bundled runtime rejects ambient and private-handoff code overrides` checks that a bundled service keeps it. SCP: `a launch sweeps startup status files no launcher still waits on`. |
| Replacement | SL: `a killed owner is replaced once and its recorded runtime is adopted`. PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. **fixture** HO: `unclean owner shutdown hands off to one adopting replacement (closing-observed)`, its `eof-observed` variant and their separate-owner-runtime variants. |
| Reconnect | n/a: a launcher only attaches; reconnecting is the client rows' transition. |
| EOF before reply | SL: `at close.before_record_delete the public socket is gone, the record remains, and startup waits for the lock without a launch (SL-3)`. **fixture** HO: `EOF before status waits for the real owner lock before one launch`, and its separate-owner-runtime variant. |
| Malformed or partial frame | SCP: `a status reply cut off by EOF is retried and attaches to the live owner (SL-6)`. SCP: `a malformed status frame is a protocol error without a replacement (SL-6)`. **fixture** HO: `malformed startup status is fatal without a replacement` (now the protocol error, not `invalidArgument`). |
| Slow reply | **fixture** HO: `a stalled owner fails startup at the probe limit, not after the whole budget (L1)`. **fixture** HO: `a stalled startup status probe times out and closes its client`. |
| Duplicate launch | SL: `two launchers converge on one owner when none is running`. PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. **fixture** HO: `concurrent launchers after an unclean shutdown converge on one owner`. SCP: `two launcher processes join one closing owner and attach to the same replacement`. SCP: `a replacement that loses the profile lock records contention, never a failure (L3)`. SCP: `a launch that loses the lock to a live owner attaches to it without launching again (L3)`. SCP: `a launch that loses the lock to a momentary holder is launched again (L3)`. PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner` also checks that no start that lost a race becomes a late owner after the last owner exits. The macOS `/usr/bin/open` launch path runs only on hosted macOS. |

## Lock and record handoff

| Transition | Coverage |
|---|---|
| Start/ready | SO: `two runtimes and canonical aliases share a profile owner and committed writes`. SFI: `startup replaces a stale endpoint and retains interrupted work after indexing fails`. SS: `closing a retired listener preserves its replacement endpoint`. SER: `an endpoint record that is empty lets clients attach and a new owner start`, with its other invalid-record variants. |
| Closing | SG: `the isolated worker stops at every close gate in order` (lock held until the last gate). SG: `the isolated close removes its public socket before the record, and the record before the lock (SL-3)` (worker socket, public socket, record, then lock). SL: `at close.before_record_delete the public socket is gone, the record remains, and startup waits for the lock without a launch (SL-3)`. HO: `a local closing owner retains its process lock (isolated: false)`. HO: `a local closing owner retains its process lock (isolated: true)`. |
| Closed | SID: `idle shutdown acknowledges only after cleanup and rejects a following mutation`. |
| Crash | SL: `a killed owner is replaced once and its recorded runtime is adopted`. SO: `two runtimes and canonical aliases share a profile owner and committed writes`. PY: `test_unexpected_service_death_interrupts_capture_and_reuses_profile`. |
| Replacement | SO: `two runtimes and canonical aliases share a profile owner and committed writes`. SS: `cancelled publication cannot replace a newer owner after a pause`. SSR: `failed startup keeps an adopted endpoint record before releasing ownership`. SSR: `failed startup removes its own endpoint record before releasing ownership`. |
| Reconnect | n/a. |
| EOF before reply | Read as "the record vanishes during a read": **fixture** HO: `a deleted endpoint record falls back only after the real lookup race`. |
| Malformed or partial frame | Read as "the record is stale, invalid or a symbolic link": **fixture** SC: `endpoint records ignore stale data identities and symbolic links`. SER: `an owner keeps only the three newest invalid records, never link targets`. SER: `an owner sweeps temporary records left by earlier owners`. |
| Slow reply | SCP: `--stop returns only after the owner releases its profile lock (L6)` (held at `close.before_lock_release`). SCP: `the release wait ends when the lock is free or the owner is gone, and gives up after its bound`. SCP: `--stop fails when the owner keeps its profile past the release bound (L6)`. |
| Duplicate launch | SO: `two runtimes and canonical aliases share a profile owner and committed writes` (a contending owner exits). SL: `two launchers converge on one owner when none is running`. SCP: `a start that lost the lock never becomes a later owner, even once the lock is free` (held at `start.lock_contended` while the holder exits). SCP: `a launch that loses the lock to a momentary holder is launched again (L3)` (a lock probe colliding with a starting replacement). |

## Harness

Step 2 added the tools that later steps use to close these gaps deterministically:

- **`ServiceFaultProxy`** (`foresight_test_support/service_fault_proxy.dart`) relays a test isolate's connects to service endpoints and can hold, truncate, drop, inject and observe frames, and observe refused connects. It covers client-side boundaries.
- **Service gates** (`serviceGate` in `service.dart`) hold the real service at named points in `ApplicationService._close` (`close.begin`, `close.leases_terminated`, `close.helper_closed`, `close.listener_closed`, `close.before_frontend_release`, `close.before_record_delete`, `close.before_lock_release`), in the isolated frontend once its worker has exited (`frontend.draining`), and after a request commits (`request.committed.<method>`). A `<point>.crash` file instead kills the isolate that reaches the point, standing in for a fatal worker fault. `FORESIGHT_SERVICE_GATES` is a test hook, kept only in builds compiled with `-DFORESIGHT_ENABLE_TEST_HOOKS=true`. PY: `test_release_service_ignores_lifecycle_gates` checks that the release binary ignores it.
- **`HookedServiceProcess`** (`foresight_test_support/hooked_service.dart`) runs `bin/service.dart` compiled with test hooks, so the ordinary `dart test` run exercises gates in a real child process.
- **`GatedHelper`** (`foresight_test_support/gated_helper.dart`) holds a closing service inside its helper shutdown. The built-service suite runs a byte-identical copy, `tests/service/gated_helper.py`.
