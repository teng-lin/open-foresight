# Native teardown responsiveness follow-up

The core checkpoint retained a measured P2-4 residual: its
`NativeRuntime.close()` called synchronous conversation and engine destruction
on the Dart isolate, with warmed real-model holds around0.3 seconds. Those
historical measurements remain below. The current implementation introduces
[native-owned asynchronous cleanup](../validation/native-retirement.md);
repair acceptance still requires the actual matrices and measurements listed
here. Implementing tokens alone does not close P2-4.

This is the separately scoped follow-up required by
[the core plan's native ownership follow-up](2026-10-20-core-desktop-refactor-plan.md#core-follow-ups).
The existing asynchronous 20 ms polling remains; its presence alone is not
evidence of blocking. The observed synchronous destruction is a distinct path.

## Measurements

Baseline source: `c28a1561b5091645718462169bc6c0cfd0040943`.
Core source: `405e13f7fddca2369e35162c98ecf13b81416a89`.
The native implementation, portable process supervisor, persistent-generation
implementation and Dart native wrapper are byte-identical between these sources.
Current project binaries were compiled independently; verified SDK/runtime bytes
and pinned Gemma4 E2B weights were reused with their original provenance.

The host used pinned Dart 3.9.2, GCC 16.2.1 project builds, LiteRT CPU,
`OMP_NUM_THREADS=2` and `OPENBLAS_NUM_THREADS=2`. One-minute host load was
1.33 before/1.35 after baseline and
0.26 before/0.53 after core. Each row is one diagnostic observation, not a
percentile estimate or statistical equivalence claim.

| Synchronous operation | Baseline ms | Core ms |
| --- | ---: | ---: |
| Idle `fs_conversation_destroy` | 0.102 | 0.145 |
| Idle `fs_engine_destroy` | 290.880 | 282.322 |
| Runtime close after cancelling native-active generation | 313.018 | 300.975 |
| Close runtime during native-active generation | 326.695 | 344.295 |

Active cases require the real engine state to remain `loading` before teardown,
in addition to Dart's owned stream being active. Waiting for the first Dart
delta was insufficient: this backend can buffer it until native completion.
Those earlier diagnostics remain retained but are not native-active evidence.
The active cases settle their Dart streams as cancelled, and the wrapper reports
no loaded engine or generation owner. Those flags do not independently prove
native destruction or worker reaping; the idle direct calls check C ABI return
values. Active rows time close only; cancellation separately took 0.400/0.433 ms
for baseline/core. The idle breakdown attributes the large observed hold to
engine destruction; it does not establish which internal shutdown action
dominates. Status responsiveness during warmed streaming/capture is measured
separately with 100 requests per workload under the core checkpoint.

Raw reports, frozen measurement programs, binary digests, model/runtime checksums
and load samples remain under `/var/tmp/foresight-core-desktop/`:
`baseline/native-destroy-active/` and
`core-checkpoint/405e13f7fddc/logs/native-destroy-active/`.
These characterize the core implementation; they are not final combined-head
Linux/Mac acceptance or evidence of physical audio/GPU operation.

## Required design before a repair

Keep the C ABI stable or version it deliberately. Define one destruction owner
for every conversation and engine, detach handles synchronously from new work,
and expose actual asynchronous completion to configuration and service shutdown.
Cancellation acknowledgement must not release a reservation before native
cleanup settles. No poll, callback, request or replacement owner may use a
retired handle; repeated close must join the same completion.

Audit every Dart, C++, Python and runner consumer before changing synchronous
close contracts. Preserve service/frontend refusal and helper shutdown ordering,
including model replacement, cancelled loading and partially initialized engines.
Moving a blocking FFI call to another isolate alone is not an ownership design.

Require held-worker cancellation/shutdown tests, late-poll and repeated-close
tests, sanitizer matrices, both libc++/libstdc++ stream-error paths, real-model
teardown measurements and warmed RPC comparisons on Linux and Mac. Reuse
qualified SDKs and weights. Do not replace caches or rebuild dependency SDKs to
address this application/native lifetime change.
