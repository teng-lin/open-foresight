# SQLite read-worker checkpoint

The service owns one lazy read isolate per `SqliteReadWorker`. Only that
isolate opens and uses its read-only SQLite connection. The parent retains at
most 16 requests including the running request, dispatches only one at a time,
and refuses excess requests with `busy`. An internal constructor can lower or
raise that count within 1–64; it is not a production RPC setting.

Each owned query has a five-second monotonic execution budget, configurable
internally within (0, 30 seconds]. SQLite's progress handler checks every 1,000
VM instructions. It also covers preparation on SQLite versions supporting
preparation callbacks. This bounds ordinary SQLite VM execution, not arbitrary
blocked filesystem calls, native extensions, or Dart projection work. The
existing 50ms SQLite busy timeout remains separate.

The application runtime retains the original `DynamicLibrary` supplied to
`package:sqlite3` at initialization. A budget never reopens a path or resolves a
new mapping. If another caller initialized the package before the application
loader could retain its actual mapping, owner-local controls refuse to proceed.
The pinned sqlite3 2.9.4 public `Database.handle` is used only in its owning
isolate. Its generated step/preparation calls are non-leaf, allowing a
`NativeCallable.isolateLocal` synchronous callback. No connection pointer,
callback pointer, or borrowed database travels through a port.

The handler returns an interrupt after the monotonic budget expires. The
statement unwinds before its actual reply is published. A `finally` unregisters
the handler before closing the callback and before the snapshot owner performs
rollback. A previous deadline has no timer or interrupt left to affect the next
job or a different connection.

Subscriber cancellation and subscriber timeouts are not SQL cancellation. The
coordinator continues retaining its actual future/reservation until the current
job settles. Cancellation latency can therefore include the current job's
remaining execution budget. The coordinator withdraws an undispatched queued
request when its last subscriber cancels, its subscriber deadline expires, or
the coordinator closes. Withdrawal matches the exact owner-local request object,
not a copied sequence or later job. Running requests cannot be withdrawn by
that interface and remain tracked. Undispatched queued reads are also cancelled
on worker close; the running read is not killed. Close sends shutdown only after its actual
reply, then joins actual worker EOF. Its execution-budget-plus-five-second
join bound reports a failure if the worker does not retire; it does not clear
physical work or claim success on that timeout.

Worker generation identity includes a fresh inbox, command port, queue, active
request and exit completer. Error notifications latch a failure, but requests
remain reserved until actual EOF. A subsequent read may then start a new
generation; old-port messages and unmatched request IDs cannot complete it.

Owner-exit monitoring is installed before dispatch. The owner self-pings after
the exit-listener request to acknowledge the SDK's ordered control-message
processing. The child accepts work only after attachment; a five-second attach
deadline closes a child whose owner disappeared during startup. Owner-exit
shutdown uses the command inbox, so it cannot dispose a live SQL callback.

## Executed evidence and remaining limitation

Linux fixtures execute a real billion-row recursive query through both a direct
connection-local budget and a private synthetic preference view used by the
existing typed read projection. They cover deadline interruption, following
job/other-connection independence, queue refusal, real startup EOF/restart,
startup/close races, unsendable-request reservation cleanup, and retention after
subscriber cancellation/timeout. A subprocess proves owner-isolate exit while
the supervising VM remains running retires its reader after settlement.

The supervising main-isolate/whole-VM teardown case remains **open**. An
immediate-main-return negative control printed owner exit but stopped making
Dart callback progress while native `sqlite3_step` remained active; the process
required the private harness's bounded kill. Keeping the main event loop alive
allowed the identical statement to interrupt, unregister its callback, consume
owner exit and close normally. Native stacks and complete failed output are
retained under `/var/tmp/of-sql-worker`. The fixture's
`immediate-main-return` mode preserves this separate negative control. Normal
application shutdown must await reader close before terminating the VM. This
checkpoint does not establish a native-independent deadline during VM teardown
or close the whole F23 lifetime requirement.

Mac execution, full package/desktop gates and integration review remain pending
for this checkpoint. No minimum-macOS or full-product acceptance is implied.
