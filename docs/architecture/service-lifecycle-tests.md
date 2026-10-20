# Service lifecycle test coverage

This matrix records which tests cover each service boundary through each lifecycle transition. Rows are boundaries and columns are transitions. It was seeded from the 2026-10-19 lifecycle audit and updated through step 2 of the [service lifecycle fix plan](../plans/2026-10-19-service-lifecycle-fix-plan.md). Each later step updates the cells it closes, in the same change as its tests.

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
| SG | `packages/foresight_core/test/service_gate_test.dart` |
| RD | `packages/foresight_core/test/remote_domain_test.dart` |
| MCP | `packages/foresight_core/test/mcp_protocol_test.dart` |
| HPR | `packages/foresight_core/test/helper_process_recovery_test.dart` (a fixture gRPC helper) |
| HC | `packages/foresight_core/test/helper_close_test.dart` |
| HT | `packages/foresight_core/test/helper_transport_test.dart` |
| HCH | `packages/foresight_core/test/helper_channel_test.dart` |
| HPU | `packages/foresight_core/test/helper_purge_retry_test.dart` |
| PY | `tests/service/test_service_process.py` (built service, MCP and helper) |
| WR | `tests/service/test_worker_recovery.py` (built service, MCP and helper) |

## Summary

**P**: production on both sides. **F**: fixture only. **G**: gap. **–**: n/a. A cell with both P and G covers some cases and misses others; the detail tables below say which.

| Boundary | Start/ready | Closing | Closed | Crash | Replacement | Reconnect | EOF before reply | Malformed or partial frame | Slow reply | Duplicate launch |
|---|---|---|---|---|---|---|---|---|---|---|
| Desktop ↔ service | P | F, G | P | G | P | P, G | F | F, G | G | G |
| MCP/CLI ↔ service | P | G | P | G | P | P | F | G | G | P |
| Frontend isolate ↔ worker isolate | P | P, G | P | F, G | – | – | P | F | G | P |
| Service ↔ helper | P | F | P | P | P | F | F | G | F | G |
| Launcher ↔ spawned service | P | F | P | G | P | – | P | F, G | F | P, G |
| Lock and record handoff | P | P | P | P | P | – | F | P | G | P, G |

## Desktop ↔ service

The desktop reaches the service through `RemoteDomain`, which connects with `ensureService`.

| Transition | Coverage |
|---|---|
| Start/ready | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations`. PY: `test_native_desktop_and_mcp_share_service` runs only with a configured display. |
| Closing | **fixture** HO: `desktop startup joins the closing owner before one replacement launch`, and its separate-owner-runtime variant (startup only). An already connected `RemoteDomain` meeting a closing owner is a **GAP** (PR 3 test 7). |
| Closed | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations` (SIGTERM). |
| Crash | **GAP** for an attached `RemoteDomain`. Startup after a crash goes through `ensureService`, which SL: `a killed owner is replaced once and its recorded runtime is adopted` covers. |
| Replacement | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations`. |
| Reconnect | PY: `test_desktop_facade_reads_changes_and_reconnects_without_replaying_mutations`. **fixture** RD: `abrupt service loss reconnects and refreshes snapshots without replaying a write`. **fixture** SC: `connection coalesces concurrent opens and reconnects without replaying uncertain writes`. **fixture** SAA: `desktop reconnect during grace period keeps service alive` (a raw socket stands in for the desktop). Re-attaching approvals is a **GAP** (PR 3 test 8, PR 5). |
| EOF before reply | **fixture** RD: `abrupt service loss reconnects and refreshes snapshots without replaying a write`. |
| Malformed or partial frame | **fixture** SC: `json service frames fail pending operations and close the client`, with its `utf8` and `oversized` variants. **fixture** SAA: `an oversized reply fails its request without dropping the desktop or its recording` and SAA: `an oversized reply is the last frame of its request` (SL-1; a raw socket stands in for the desktop). A partial frame then EOF is a **GAP** (PR 3 test 5; the fault proxy can now cut a frame). |
| Slow reply | **GAP**. |
| Duplicate launch | **GAP** for the desktop and MCP launching together; PY: `test_native_desktop_and_mcp_share_service` needs a display. |

## MCP/CLI ↔ service

| Transition | Coverage |
|---|---|
| Start/ready | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. PY: `test_shared_owner_concurrent_writes_search_and_mcp`. |
| Closing | **GAP** (PR 3 tests 1, 2 and 6). |
| Closed | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner` (SIGTERM). PY: `test_service_stop_waits_for_active_capture_and_finalizes_transcript` (`--stop`). PY: `test_idle_upgrade_shutdown_defers_capture_and_requires_verified_ack` (`--stop-if-idle`). SO: `two runtimes and canonical aliases share a profile owner and committed writes`. |
| Crash | **GAP**. |
| Replacement | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. |
| Reconnect | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. **fixture** MCP: `service disconnect fails pending tool and next call reconnects without replay`. |
| EOF before reply | **fixture** MCP: `service disconnect fails pending tool and next call reconnects without replay`. **fixture** SO: `two runtimes and canonical aliases share a profile owner and committed writes` (a fake peer's EOF is not an idle-stop acknowledgement). |
| Malformed or partial frame | **GAP** for a malformed service frame reaching MCP (PR 3 test 6). |
| Slow reply | **GAP**. |
| Duplicate launch | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. |

## Frontend isolate ↔ worker isolate

`IsolatedApplicationService` relays each public connection to the worker's private socket.

| Transition | Coverage |
|---|---|
| Start/ready | SI: `startup handoff reaches the real worker and custom profile controls`. SI: `concurrent isolated startup protects both sockets before the first RPC`. |
| Closing | SG: `the isolated worker stops at every close gate in order` (SIGTERM, real child, gate order and file state). SI: `explicit shutdown disconnects clients before the worker finishes cleanup` (frontend-initiated; clients get EOF). SI: `isolated domain preserves multiplexing, committed writes and idle shutdown acknowledgement` (worker-initiated; acknowledgement through the bridge). A client arriving during a worker-initiated close is a **GAP** (PR 3 test 2). |
| Closed | SI: `private worker preserves the public Unix socket path limit`. SI: `isolated domain preserves multiplexing, committed writes and idle shutdown acknowledgement`. |
| Crash | **fixture** SI: `fatal isolate failures retain their separate error channel` (diagnostic worker only). A real worker exiting unexpectedly is a **GAP** (PR 3 test 10). |
| Replacement | n/a: a worker is never replaced inside its process. |
| Reconnect | n/a: each client connection gets its own bridge. |
| EOF before reply | SL: `PINNED (SL-3, reordered by PR 3): at close.before_record_delete the record and public socket remain, new clients get EOF and no launch`. SL: `PINNED (D3, changed by PR 3): during a SIGTERM close a new client gets EOF or a broken pipe, never the closing reply`. |
| Malformed or partial frame | **fixture** SFI: `malformed requests and security errors are scoped to one frame` (in-process `ApplicationService`, no bridge). |
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
| Closing | **fixture** HO: `a closing post-launch owner remains bounded without another launch`. |
| Closed | PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner` (the launched owner is stopped, and MCP launches again). |
| Crash | **GAP** for a replacement that dies right after launch (L3; PR 3 test 12). |
| Replacement | SL: `a killed owner is replaced once and its recorded runtime is adopted`. PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. **fixture** HO: `unclean owner shutdown hands off to one adopting replacement (closing-observed)`, its `eof-observed` variant and their separate-owner-runtime variants. |
| Reconnect | n/a: a launcher only attaches; reconnecting is the client rows' transition. |
| EOF before reply | SL: `PINNED (SL-3, reordered by PR 3): at close.before_record_delete the record and public socket remain, new clients get EOF and no launch`. **fixture** HO: `EOF before status waits for the real owner lock before one launch`, and its separate-owner-runtime variant. |
| Malformed or partial frame | **fixture** HO: `malformed startup status is fatal without a replacement`. A partial frame then EOF is a **GAP** (PR 3 test 5). |
| Slow reply | **fixture** HO: `a stalled startup status probe times out and closes its client`. |
| Duplicate launch | SL: `two launchers converge on one owner when none is running`. PY: `test_two_headless_mcp_launchers_share_one_automatically_started_owner`. **fixture** HO: `concurrent launchers after an unclean shutdown converge on one owner`. Two launcher processes joining one live closing owner is a **GAP** (PR 3 test 9). The macOS `/usr/bin/open` launch path runs only on hosted macOS. |

## Lock and record handoff

| Transition | Coverage |
|---|---|
| Start/ready | SO: `two runtimes and canonical aliases share a profile owner and committed writes`. SFI: `startup replaces a stale endpoint and retains interrupted work after indexing fails`. SS: `closing a retired listener preserves its replacement endpoint`. SER: `an endpoint record that is empty lets clients attach and a new owner start`, with its other invalid-record variants. |
| Closing | SG: `the isolated worker stops at every close gate in order` (record, sockets and lock at each gate). HO: `a local closing owner retains its process lock (isolated: false)`. HO: `a local closing owner retains its process lock (isolated: true)`. |
| Closed | SID: `idle shutdown acknowledges only after cleanup and rejects a following mutation`. |
| Crash | SL: `a killed owner is replaced once and its recorded runtime is adopted`. SO: `two runtimes and canonical aliases share a profile owner and committed writes`. PY: `test_unexpected_service_death_interrupts_capture_and_reuses_profile`. |
| Replacement | SO: `two runtimes and canonical aliases share a profile owner and committed writes`. SS: `cancelled publication cannot replace a newer owner after a pause`. SSR: `failed startup keeps an adopted endpoint record before releasing ownership`. SSR: `failed startup removes its own endpoint record before releasing ownership`. |
| Reconnect | n/a. |
| EOF before reply | Read as "the record vanishes during a read": **fixture** HO: `a deleted endpoint record falls back only after the real lookup race`. |
| Malformed or partial frame | Read as "the record is stale, invalid or a symbolic link": **fixture** SC: `endpoint records ignore stale data identities and symbolic links`. SER: `an owner keeps only the three newest invalid records, never link targets`. SER: `an owner sweeps temporary records left by earlier owners`. |
| Slow reply | **GAP** (a slow lock release; PR 3's `--stop` waits for the lock, 3.7). |
| Duplicate launch | SO: `two runtimes and canonical aliases share a profile owner and committed writes` (a contending owner exits). SL: `two launchers converge on one owner when none is running`. A lock probe colliding with a starting replacement is a **GAP**. |

## Harness

Step 2 added the tools that later steps use to close these gaps deterministically:

- **`ServiceFaultProxy`** (`foresight_test_support/service_fault_proxy.dart`) relays a test isolate's connects to service endpoints and can hold, truncate, drop, inject and observe frames, and observe refused connects. It covers client-side boundaries.
- **Service gates** (`serviceGate` in `service.dart`) hold the real service at named points in `ApplicationService._close` and after a request commits. `FORESIGHT_SERVICE_GATES` is a test hook, kept only in builds compiled with `-DFORESIGHT_ENABLE_TEST_HOOKS=true`. PY: `test_release_service_ignores_lifecycle_gates` checks that the release binary ignores it.
- **`HookedServiceProcess`** (`foresight_test_support/hooked_service.dart`) runs `bin/service.dart` compiled with test hooks, so the ordinary `dart test` run exercises gates in a real child process.
- **`GatedHelper`** (`foresight_test_support/gated_helper.dart`) holds a closing service inside its helper shutdown. The built-service suite runs a byte-identical copy, `tests/service/gated_helper.py`.
