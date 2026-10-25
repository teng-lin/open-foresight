# Storage worker body protocol checkpoint

The native owner/FFI boundary through `7c01dfc2` has converged independent peer
and repeated Claude reviews. This checkpoint adds body codecs and synchronous
child dispatch state. It is not yet the executable child, async writer adoption,
application startup gate or packaged product.

INIT is a closed versioned binary payload with schema2, role, raw16-byte session
and a u16BE-length UTF8 profile of at most4096 bytes. It grants no file authority;
ADMIT separately invokes storage, with at most five attempts. CLASSIFY uses three
closed scalar bytes, and replies use four. An accepted child retains one sink,
requires classification ACK before appending, protects warning/error records
before writes and prevents a service role downgrade. It acknowledges retirement
only after actual close returns; an uncertain close cannot be retried into a
false RETIRED acknowledgement.

APPEND carries the final schema2 JSONL, including newline, at most4096 bytes.
Validation checks the selected worker build ID, session, logical parent PID,
strictly increasing positive sequence, closed event/body fields, timestamp,
version/revision, severity and producer kind/slot/generation snapshot. Writer
records use `writer:0:0`. Legacy schema1 remains outside this worker sink.
The original public record ceiling is reduced to4096; producer records remain
at2048 and no queue, priority, traffic or retention cap is increased.

A shared preflight precedes JSON decoding. Records allow at most four container
levels,256 tokens,64 keys and128 ASCII bytes per string; eight-key scalar
manifests allow one level,64 tokens,8 keys and64 bytes per string. Escapes,
non-ASCII record/manifest strings and duplicate keys are refused. INIT alone
supports arbitrary valid profile UTF8/control characters without JSON expansion.
A duplicate-key manifest remains occupied and its existing segment survives
admission into another slot. No malformed payload enters the file sink.

Linux pinned-Dart3.9.2 whole diagnostics passed **82/82, zero skips**, including
13 new codec/dispatch tests and all69 preceding diagnostics tests. Whole core
analysis passed. Evidence `/var/tmp/of-support/diagnostics-codec-final.jsonl`
records actual terminal success and per-test outcomes; preceding failures remain
in `diagnostics-all-codec.log` and `protocol-*.log`. The4KiB ceiling first exposed
old oversized physical fill/quota fixtures. Rotation now writes more than four
segments using bounded records; compiled ten-slot fill still verifies over55MiB
of retained data and the same30-segment/descriptor/lease oracles. The partial
write fixture uses exact4096-byte records under the unchanged8192-byte real
file-size limit: first succeeds, second is partial, third is refused; the same
incomplete-tail/newline assertions remain. Failed-first rotation, lease, quota
and regenerated-catalog checks passed before the whole suite.

These are pure codec/child-state and explicit filesystem/process fixtures. They
do not prove an exec child handles these bodies through the native channel,
application-native interop on an unexecuted path, full core coverage/desktop/
compiled-service suites, Mac qualification of this checkpoint or512KiB physical
accounting. Repeat independent review and actual child/owner composition remain
required. New health reasons append to existing enum indices; callers may report
only a cause they actually observed.
