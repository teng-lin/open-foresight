# Native owned lifetime protocol

This describes the C1 native checkpoint, not completed C1 acceptance. The Dart
consumer conversion and full application qualification are separate work.

The published synchronous C ABI remains version1. Its engine/conversation
failure sentinels, drain rules and local stop/join behavior remain available to
serialized Python/C++ callers. Legacy generation and speech allocate no
asynchronous completion records or execution groups. Mac capture has a separate
bounded pending-startup quarantine, described below. Abandoned owned API
acknowledgements cannot consume that pool or prevent legacy generation creation
or speech finish.

The separately negotiated lifetime capability is version2. Its creation and
operation exports use positive, monotonically increasing 63-bit **owner IDs**.
They never expose an Engine, Conversation, Speech or Capture address. Only the
original native mapping resolves an ID and acquires its synchronous call lease.
No borrowed native object may cross a Dart isolate. Owned result strings are
separate caller-owned buffers, freed with `fs_string_free`.

Each live owner reserves one of32 independent execution groups before physical
work starts. Each group has its own queue/thread, so a held model probe or speech
join cannot delay another owner's capture finish or retirement. Groups are
reusable only after actual resource destruction. The maximum is32 owner executor
threads plus one lazily used generic test executor; production owned work uses
only the32 owner groups. Native Mac legacy capture has up to32 additional
private group threads, so both APIs together can retain64 owner executor threads
plus that generic executor. Idle executor threads retain no application, profile,
callback, model or capture authority. Their code image stays pinned. The thread
stacks and registry metadata are infrastructure costs, not event or model data.

The registry holds at most4096 operation records, including unacknowledged
completions. Each owner reserves its retirement record before publication;
capture additionally reserves its finish record. Records and owner IDs are never
reused. At32 live groups or4096 retained records, owned admission returns0 before
starting physical work. The caller must surface unavailability or finish its
existing owners and acknowledge results; it must not spin or silently retry.
There is no tombstone eviction or unbounded completion history. Completion-only
owner metadata retains no Engine/model/profile authority.

Retirement atomically revokes new admission, sets irreversible cancellation and
submits preallocated cleanup. Cleanup joins admitted calls, polls, callbacks and
physical workers. A conversation retains its actual Engine throughout its
lifetime. Parent cleanup waits for actual child destruction and reference release;
queue ordering alone cannot authorize parent destruction. If child cleanup is
unconfirmed, the parent keeps the actual Engine and also reports unconfirmed.

`fs_operation_status(token)` reports:

| Status | Meaning |
| --- | --- |
| 0 | Pending native work. |
| 1 | Successful actual completion. |
| 2 | Known operation failure, such as a cancelled probe. |
| 3 | Cleanup unconfirmed; native ownership and execution group remain retained. |
| -1 | Unknown or explicitly released completion. |

Exceptions publish3 and wake observers before optional diagnostics. Mandatory
cleanup state is idempotent: explicit retirement retry by the same owner ID
reuses its native token and cannot destroy an unrelated object. No automatic
retry loop is permitted. Unexpected failure cannot become success through a
reporter, a lost worker acknowledgement or an implicit `noexcept` destructor.
Workers and persistent engines are explicitly joined before resource reset;
their destructors assert that no hidden join remains.

Probe/join/finish acknowledgement uses `fs_operation_release`. Retirement
acknowledgement uses `fs_owner_release`, which requires successful actual
destruction and removes its retirement/unsubmitted metadata. Already-issued
probe/join/finish results keep independent acknowledgements even if the owner
acknowledgement happens first. Generic token release cannot consume another
client's retirement. Before owner release, a
repeated retirement request recovers the same token even after object destruction.
After release, an old ID is unknown and can never alias a newly allocated owner,
including when its resource has exactly the same address.

A new probe after completion starts actual fresh work. Speech admission refuses
push or finish from acceptance of a request until that exact physical request
thread has joined; this includes idle, queued and running join states. Receiving
`done` alone does not allow reuse. Capture finish preserves final PCM for drain;
separate retirement revokes polling and destroys the resource. On Mac, Capture
owns the startup thread and Session even after startup times out or cancellation
returns from the acquisition loop. Finish/retire joins actual startup, closes
platform objects idempotently and retains status3 on unconfirmed teardown.
Microphone/system callbacks acquire an atomic fence before locking a weak PCM
ring. Revocation refuses late entry; cleanup joins admitted callbacks before
final drain and PCM release. Platform blocks retain only an inert fence and weak
ring after closure. The system IOProc never borrows Session. The standalone
capture CLI joins the same owner; unconfirmed CLI cleanup ends with explicit
failed process cleanup. Explicit consent keeps its separate single pending,
discard-only owner and does not admit another request after unconfirmed cleanup.
Consent callback code also pins its original mapping. Blocking polls
recheck revocation in at most20ms wait quanta, independently of worker joins or
condition-variable wake timing, while honoring the caller's total timeout.

Before owned admission, native code pins its **actual loaded image** with
`RTLD_NOLOAD` and verifies the resolved symbol image against its own internal
code address. It cannot load replacement pathname bytes. A replaced pathname
therefore never redirects retirement, and releasing a caller's loader reference
cannot unload executor code. Main-executable fixtures already have process
lifetime code. The launch lock and poll/speech registries use lazy process
lifetime storage inside existing admission/error boundaries so retained actors
cannot race their C++ static destruction. Explicit application close remains the
normal cleanup path. Native C/C++ owners may explicitly retry their own
unconfirmed cleanup, retaining all dependent authority until confirmed. Dart
uses the stricter restart policy below and never automatically retries status3.
Process finalization never reports unconfirmed owners successfully closed. One exact-image loader reference and bounded executor infrastructure
remain until process exit after use of the owned capability or native Mac
legacy capture. Mac capture and explicit consent also pin callback code. A legacy cleanup exception preserves
its failure sentinel and retained authority; a serialized retry can complete
that original cleanup.

The root native controls cover independent held speech/probe work, speech reuse
through actual exported finish, held API/poll/worker ownership, final PCM, child
cleanup exception and retry, actual child reaping after stdout closes, forced
resource-address reuse, repeated probes,32/4096 admission, legacy independence,
allocation/reporter/thread rollback and exact-image lifetime after pathname
replacement. A minimal module sharing the production stateless pin helper
proves actual unload without a pin and retention with it, including controlled
pin omission and a second valid replacement image. Intrinsic retention of the
full native library (GNU-unique or Objective-C/TLS) is separately observed;
it is not evidence that the explicit pin works. Host controls and sanitizers
are supporting evidence only. Fresh
repository-root Linux/Mac CTest, the final Dart consumers, full core/desktop
coverage, compiled service/MCP, isolated display, real models, physical audio and
latency lanes require their own exact-source qualification.

## Legacy pending startup and lost-owner policy

A Mac legacy capture reserves one of32 private quarantine groups and two private
completion records before starting capture. This64-record pool is independent
of the owned API's4096 records. If startup is still pending, legacy stop/finish
revokes admission immediately and queues actual cleanup there instead of joining
Core Audio on the caller. A subsequent stop coalesces with that same producer.
Retirement releases its private records automatically after actual cleanup.
At the exact capacity boundary, group release may precede record removal and
cause a transient admission refusal. Callers surface refusal without retry loops.
Already initialized legacy capture keeps its synchronous final-PCM/drain behavior.
The standalone probe reports failed pending cleanup and exits its dedicated
process instead of waiting past its deadline on a permission dialog. Clients
requiring observable physical completion use the owned v2 token API.

Unacknowledged owned results and lost owner IDs are deliberately not evicted.
The production Dart owner is the service main isolate; replacement isolates must
not adopt that mapping after its ownership state is lost. For Dart, status3, an
unknown completion or lost acknowledgement requires surfacing unconfirmed ownership,
stopping new native admissions and restarting the service/application process.
Capacity refusal must be surfaced without automatic retry loops. Normal tracked
watchers acknowledge their own probe/join/finish results independently, even if
their original subscriber cancels. This restart policy is a required Dart
consumer contract; native qualification alone does not establish its adoption.
Process exit keeps any still-live legacy registry intact for OS/ownership-pipe
cleanup rather than destructing joinable workers from a static finalizer.
Legacy callers must end API admission before process exit; exit is not a
concurrent registry-management API.
