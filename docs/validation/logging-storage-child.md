# Actual storage child checkpoint

The shared `runDiagnosticStorageWorker` executor now runs only diagnostic work:
native identity/parent watch, independent Dart watch acknowledgement, inherited
kernel mapping, optional bounded source verification, HELLO, serialized body
dispatch, actual file close, RETIRED and process exit. It imports no Store,
application bootstrap, RPC descriptor graph or application-native runtime.
The package-owned `bin/diagnostic_storage_worker.dart` parses the exact internal
mode before loading the selected support image. Missing identities/source
verification fail closed; this is not a production worker-ID activation.

The support image adds child-only `fs_diag_child_finish(id,status)` for closed
statuses0/65/67. A parent context cannot call it successfully; normal exit0 also
requires the native endpoint to have published RETIRED. This ends the child
without a VM teardown wait on another held isolate. The watch catches its own
callback failures and uses this native exit path. Ordinary FORCE, parent loss,
heartbeat expiry and operation expiry still use the independent native watch.
The function table has14 entries; no native context/page address crosses Dart
isolates. The child copies a borrowed receive view synchronously into its one
8192-byte assembly buffer before another endpoint call, avoiding an additional
live4KiB event copy; ordinary callers retain copied receive semantics.

Actual private JIT and AOT fixtures on **Linux and HanSolo Mac** each passed:

- HELLO/INIT/ADMIT/CLASSIFY/two schema2 APPENDs/RETIRED, verifying stored parent
  PID, session, sequence and selected fixture build ID after child retirement.
- Oversize APPEND rejection by the native boundary before publication, followed
  by independent FORCE retirement; exactly the preceding two records survive.
- A4122-byte binary INIT carrying4096 raw profile bytes through multiple chunks,
  then HEALTH/RETIRE without opening any diagnostic files.

Native strict-C11 `-DNDEBUG` eight-case owner and held-publication race fixtures
also passed on each host with the14-entry source. The12 native C/header inputs
are byte-identical between those builds and the final Dart runs; component
products are reused explicitly rather than called a second fresh build.
Codec/filesystem modules passed **25/25 each host, zero skips**, and changed-file
analysis/formatting passed. Mac's first codec command did not execute tests:
the partial private export lacked its declared public test-support dependency.
The explicit dependency link/offline locked resolution repaired that fixture;
the failed step then passed25/25. No SDK/library cache was deleted or successful
native case rerun for that dependency problem.

Commands, outputs and immutable first failures are under `/var/tmp/of-support`
and `/private/var/tmp/of-storage-child-1025`. Initial oversize test code expected
a child reply, but the existing native4KiB guard correctly rejected it earlier;
the repaired oracle requires native ERROR plus real independent retirement.
Linux observed normal exit class1 or retirement66; Darwin observes no-live-child
with unknown/unconsumed status and makes no parent-reap claim.

These are explicitly private fixture identities, native products and loaders.
They do not establish installed/compiled-service dispatch, reviewed production
source closure/SDK identity, async-session adoption, root CTest/core/desktop/
service/UI/package gates, signing/TCC, minimum-host acceptance, reverse SQLite
aliases, CPU/RSS or512KiB physical accounting. Independent whole-checkpoint
review and the remaining actual owner/application composition are still needed.
