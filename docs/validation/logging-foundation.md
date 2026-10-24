# Diagnostic foundation and qualification

The foundation owns no application, database, native runtime or profile lifecycle.
One entrypoint owns `LoggingSession`, keeps it across startup retries, and passes
reserved producer bootstraps to worker isolates. Workers cannot close the session
or choose files. Their owner reports isolate exit with `producerExited`; normal
producer close also reports counters. Only the entrypoint starts the session.
The core process registry is owned by that entrypoint, rather than discovered
through a database, mutable global environment or Flutter-specific name server.
B2 must install it once and pass explicit capabilities at each isolate boundary.

`DiagnosticConfiguration.fromEnvironment` resolves explicit log level first;
`off` creates no writer or ports and does not evaluate fields. Invalid explicit
levels select info with a constant invalid-configuration state. The legacy
transport trace switch applies only when no level was supplied. Registered
components, events, operations, categories and numeric fields are the complete
wire vocabulary. There is no arbitrary string or object field. Stack projection
uses registered package paths and numeric coordinates, with at most eight frames;
messages, symbols, absolute paths and caller fingerprints never cross the sink.
The generated diagnostic operation catalog avoids importing application operation
descriptors. Run `dart run tool/generate_diagnostics_catalog.dart --check` from
core after regenerating it when production paths or operations change.

Each of at most sixteen lifetime producer tickets has eleven normal record
credits and four reserved warning/error credits, with 12 KiB and 4 KiB charged
budgets. A record costs four times its encoded UTF-8 length plus 256 bytes. The
producer cap is 2 KiB, and the final JSONL cap is 16 KiB. Thus message/decoded
record charges are at most 256 KiB/240 producer records, leaving sixteen record
positions for sequential writer summaries/control and the other half of the
512 KiB process traffic budget for bounded encoding scratch, fixed control
metadata and one sequential writer summary. VM heap/RSS also includes unrelated
allocator/runtime overhead; the accounting bound is not a claim about total RSS.
No event sends before obtaining credits. Exhaustion saturates local counters;
next grants, admitted records and completion return counters without per-drop
message streams. The writer has a fixed 64-key event/category rate table,
retaining suppressed counts and monotonic first/last milliseconds. Summaries
contain registered event names only and do not recursively enqueue themselves.

The writer flushes every 250 ms and schedules immediate error flushes. Short
sessions stay in bounded bootstrap memory until a warning/error, 100 records or
five seconds. Closing does not force a cold session into storage. Service
ownership classification travels through a session control path independent of
producer credits/completion. Only an acquired decision promotes a candidate to
service. Terminal unknown remains unprotected. A pending decision can arrive
after close begins; its sender must deliver before its worker completion barrier.
No summary or priority record invents service ownership.

The fixed layout is ten slots, three segments each, each at most 2 MiB: 60 MiB of
payload and at most 1 MiB of metadata. Three slots are reserved for service, two
for desktop and five shared; MCP uses shared slots. Permanent independent flock
lease files stay held through cleanup/publication/rotation and are never renamed
or unlinked. Admissions skip explicitly registered owned slots and any slot
recorded with this PID. Corrupt/missing/unsupported manifests with data are
occupied, not empty. The newest genuinely acquired service failure is protected
for seven days, even in a shared slot. A warning alone cannot claim that status.

The shared scoped-FD extension retains all backup publication/metadata semantics.
Logging adds descriptor relocation above fd2 (minimum 10), CLOEXEC checks,
nonblocking flock, explicit replacement for bounded slot manifests, fstatfs,
single-write failure detection and child directory handles. None initializes
Store or the application native library. Failed writes disable persistence for
the session; generic safe health does not guess ENOSPC, quota or errno. Existing
segment bytes, including interrupted tails, are preserved. Retention byte limits
hold regardless of wall-clock rollback. Application shutdown does not depend on
the writer acknowledging its own failure.

The native exception barrier retains bounded fallback text without allocation or
mutex waits. Reporting, caller-buffer retrieval, legacy string retrieval and
worker callbacks cannot throw out of the failure boundary, including sustained
allocation and reporter failures. Legacy ABI error text remains an operation
result; B3 must never turn it into arbitrary persistent diagnostic text.

## Syscall and descriptor contract

| Operation | Linux x86-64 | Darwin arm64 | Lifetime and failure handling |
| --- | --- | --- | --- |
| `open` without create | separate empty `VarArgs<()>` | same declaration; Darwin varargs ABI | root walk, no-follow at every child; close on every refusal |
| `openat` with optional create | mode in nonempty `VarArgs<(Uint32,)>` | same declaration | O_NOFOLLOW/O_EXCL/O_CLOEXEC; 0700 directories/0600 files at creation |
| `fcntl` get FD flags | separate empty `VarArgs<()>` | same declaration | no invented third argument; FD_CLOEXEC verified in fixture |
| `fcntl` relocate | nonempty integer VarArgs; F_DUPFD_CLOEXEC1030 | F_DUPFD_CLOEXEC67 | immediately close temporary low FD, preserve already-closed stdio |
| `statx` / `fstatat` | statx256-byte layout and NOFOLLOW0x100 | stat144-byte layout and NOFOLLOW0x20 | validate type, UID, links, private mode; never close a second live DB descriptor |
| directory iteration | dirent name offset19 | offset21 | bounded callback/list; separate directory FD always closed |
| publish no-replace | renameat2 flag1 | renameatx_np flag4 | backup publication retained; no two-link crash state |
| `renameat` replace | four fixed arguments | same | logging manifests only; validate target/source anchored inode and no links |
| `flock` | LOCK_EX2 / LOCK_NB4 | same | permanent independent lease; failed probe means unavailable, never inferred errno |
| `fstatfs` | Linux magic at0 | APFS type string at72 | reject unknown/network filesystems; target support requires actual fixture qualification |
| `write` | one system write | same | short/error disables sink; no business-operation retries or fd2 output |
| blocked-FFI proof | poll nfds_t UintPtr | nfds_t Uint32 | synchronous infinite poll demonstrates isolate kill cannot interrupt FFI |

Only the writer isolate calls segment syscalls. A watchdog outside it grants at
most500 ms after existing application/client/child teardown and intentional
output disposition. `close` returns `requiresExplicitExit` if writer exit is not
confirmed. It never exits the process itself. Standalone entrypoints then retain
their original exit code and call `exit(code)`; B2 owns that integration and must
not exit while authority/resources or transport writes remain live.

## Output owner inventory

The checked-in [inventory](logging-output-inventory.json) identifies every match
in owned runtime Dart/C++/Swift output/error/stdio surfaces on the foundation
baseline. It is an adoption worklist, not evidence that B2/B3 migration ran.
Re-scan the final integrated source after A1/A2/A4/A6 changes; line numbers and
producer sites will move. No untracked audit document supplies acceptance.

| Owner | Disposition |
| --- | --- |
| core/bin service admin commands | Preserve requested JSON/status/progress and existing error presentation; diagnostic catches get typed events; dispose stdout/stderr independently before logger deadline |
| core/bin MCP and stdio/IPC codecs | Exact framed protocol bytes, never log or mirror result bodies; optional correlation metadata only after authentication |
| service frontend, ownership, sockets, gates, resources/startup | Closed runtime/transport/cancellation outcomes; preserve fatal chain and startup notification; no socket/profile paths or serialized RPC data |
| domain/application service and meeting/note/summary maintenance | Typed operation/category/count/duration; no entity IDs, transcript text, generated content, tool arguments or exception text |
| credential/google maintenance, parser/platform/profile/secret-store subprocesses | stdout/stderr are sensitive protocols; preserve existing bounded parsing for the operation, observe only safe parent outcome; never mirror child text |
| helper/model-vault/speech children | Keep protocol drains bounded; derive parent exit/cancel/status; raw stderr is not structured input or persistent log data |
| desktop framework/platform/zone and shortcut boundary | Install once, retain old fatal/reporting behavior, initialize Flutter and runApp in same zone; safe projected stack only |
| native process/portable-process and inference/helper/speech workers | Preserve owned protocol FDs and PCM/model result channels; B3 adds bounded metadata queue/drain rather than parsing vendor output |
| native macOS Swift audio/parser/crypto and Runner startup | Preserve CLI/self-test/protocol presentation; closed native diagnostics; parent safely observes child outcomes |
| tools/tests/build Python and development CLIs | Separate intentional tool artifacts/presentation, no profile diagnostic slot; never present their console as runtime diagnostic adoption |
| model transport worker added by A2 | EARLY protocol branch before logging/profile/bootstrap; no app/native/session handles; credential/URL stdin and framed response stdout stay private; discard stderr and log safe parent outcome only |

## Evidence boundaries

Linux btrfs compiled fixtures exercise ten concurrent writers holding more than 55 MiB across 30 segments below the 60 MiB cap, excess admission,
exact lease release after SIGKILL, child exec FD inheritance, all eight closed
stdio masks, twenty MCP launches retaining the newest genuine service failure,
no cold candidate slot, real8KiB short writes with incomplete tails, and a writer
stuck in real libc FFI. The coordinator completes prior cleanup, flushes exact
framed stdout and intentional stderr, waits roughly 500 ms, preserves exit 37 and
releases the lease on process death. The fixture can additionally load the fresh
application native library through FORESIGHT_NATIVE_LIBRARY; that path needs its
own actual run. Mock sinks do not qualify filesystem or exit behavior.

A representative compiled producer-flood run made 160,016 calls, admitted
192 before credit return, and took 994 microseconds. Reported
current RSS was 9,003,008 before and 10,919,936 after. This is a
synthetic foundation baseline, rather than application/capture latency or a
512 KiB total-RSS claim. Credit accounting, including message/encoding copies and
reserved control capacity, is separate. Eleven normal/four priority record grants
cap producer records at 240.

At this foundation checkpoint, actual ext4/XFS/overlay/APFS lease/FD semantics,
loaded application-native exit, real filesystem ENOSPC/EROFS/quota, app timing/RSS,
compiled service/MCP, Flutter, and final coverage/full integration remain external
qualification. A3's actual Darwin stat/VFS/atomic-rename results do not qualify
B1's new flock/fcntl/fstatfs or blocked-FFI behavior. No such unrun path is passing.
