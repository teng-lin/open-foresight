# Native owned lifetime protocol

This describes the C1 native checkpoint, not completed C1 acceptance. The Dart
consumer conversion and full application qualification are separate work.

The published synchronous C ABI remains version1. Its engine/conversation
failure sentinels, drain rules and local stop/join behavior remain available to
serialized Python/C++ callers. These callers allocate no asynchronous completion
records or execution groups. Abandoned asynchronous acknowledgements therefore
cannot make a legacy create or speech finish fail at an unrelated queue limit.

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
only the32 owner groups. Idle executor threads retain no application, profile,
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
normal cleanup path. Unconfirmed owners remain quarantined for explicit retry
or OS process cleanup; process finalization never reports them successfully
closed. One exact-image loader reference and bounded executor infrastructure
remain until process exit after use of the owned capability. Mac capture and
explicit consent also pin callback code. A legacy cleanup exception preserves
its failure sentinel and retained authority; a serialized retry can complete
that original cleanup.

The root native controls cover independent held speech/probe work, speech reuse
through actual exported finish, held API/poll/worker ownership, final PCM, child
cleanup exception and retry, actual child reaping after stdout closes, forced
resource-address reuse, repeated probes,32/4096 admission, legacy independence,
allocation/reporter/thread rollback and exact-image lifetime after pathname
replacement. Host controls and sanitizers are supporting evidence only. Fresh
repository-root Linux/Mac CTest, the final Dart consumers, full core/desktop
coverage, compiled service/MCP, isolated display, real models, physical audio and
latency lanes require their own exact-source qualification.
