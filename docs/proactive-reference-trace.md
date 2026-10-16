# Original proactive-question pipeline: focused IDA trace

## Scope and evidence

Reference executable: `/Applications/Foresight.app/Contents/MacOS/Foresight`,
SHA-256 `fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Analysis date: October 16, 2026. The investigation used REA process captures
of focused queries to the existing IDA Pro MCP worker. It did not use Hopper,
execute the reference application, or observe model output at runtime.

Redacted IDA responses are retained locally under ignored
`test-results/reference-functions/ida/`. The earlier REA native-adapter timeout
is separate from these successful direct IDA queries captured through REA.
Decompiler pseudocode is recovered analysis, not original Dart source.

| Evidence | Retained response files |
| --- | --- |
| `ev_678394819cd8767392a997d56eb40b41e3bd58f29a1ba679a49dee92f1346b93` | `dedup-process.json`, `dedup-normalize.json`, `dedup-hash.json`, `dedup-patterns.json` |
| `ev_e3903c10c1dbc55d073997a63bb5ee8189d1372b9771ab5ddc0b2a9233307bbe` | `query-detect.json`, `query-window.json`, `query-dispatch-internal.json` |
| `ev_6eb82a2a727bf61ad3ac7cf6c251650b5e0e0a58a4ccd1e6e173fe690ac80052` | `query-process-transcript.json`, `query-model-call.json`, `query-question-comparison.json`, `query-detector-constructor.json`, `dedup-reset.json` |
| `ev_291e4cf48a5aecbf95764d32e6acd791429e555f51cb72e6252006991083e4b2` | `query-process-tail.json`, `query-window-start-asm.json`, `query-detector-split-asm.json`, `query-result-compare-asm.json` |
| `ev_d5c4e5153c8c03bb6cea4c4ad05c060096dd723684ffc9b6d9f19346bf6030bb` | `query-cursor-advance.json`, `query-dispatch-constructor.json`, `query-init-detector.json` |
| `ev_20f3ab40e5dd18952cae5eba71858943fdc16599953204a227c895816c05c844` | `query-split-output.json`, `query-window-text-map.json`, `query-window-interim-filter.json` |
| `ev_7f079d0e384d72032da0cd13fb1c639b99d558d9787950f1a97f95fa2aa29eb0` | `query-prefix-filter.json`, `query-prefix-constructor.json` |
| `ev_72971e51334e593583c25174192c38b2f18bdda21a1a586854012969d69e2a59` | `query-prefix-isolate.json`, `query-prefix-prune.json` |
| `ev_70739e75f269090c5025d964c53c6239f5e7dcedf3463e1709b63f5b805d3c78` | `query-prefix-branches-asm.json`, `query-prefix-expiry-asm.json` |

## Detection window and cursor

`TranscriptManager.processRawTranscript` (`0x1009f0b94`) feeds the transcript
buffer and obtains a record from
`_getTranscriptAndAudioForQueryDetection` (`0x1009f3c88`). Assembly at
`0x1009f3cc4`–`0x1009f3ce0` establishes that the history list is sublisted
starting at the manager's unboxed cursor field at object offset `+407`.
The routine joins selected history text and nonempty interim-map values,
then trims the assembled text. This is a growing context window, rather than
an independent fixed batch of six final segments.

The boolean passed from the transcript record at `+31` into
`QueryDetectorParams.+23` is inferred to mean `isFinal`: its true branch
increments transcript analytics and supplies stored segment audio, while its
false branch uses current/interim audio. The original field name has not been
recovered from object metadata. Both branches can reach detection.

`detectQuery` (`0x1009f2a18`) trims and splits input using a regex loaded from
pool index `11631`. For the false/interim branch, it returns no queries when
there are at most five split units; otherwise it excludes the last five units
(`0x1009f2b1c`–`0x1009f2b50`). It then takes at most the last 200 units
(`0x1009f2b94`–`0x1009f2bb8`) and joins them. Calling these units words is an
inference until the splitting regex is bound.

After detection, `processRawTranscript` calls `onQueryDetected` only for a
nonempty returned list (`0x1009f153c`–`0x1009f1554`).
`onQueryDetected` (`0x1009f29d4`) sets cursor `+407` to the current history
length at `0x1009f29f8`. An empty detection result therefore does not advance
this cursor in this path. Buffer pruning adjusts the cursor separately
(`0x1009f11dc`–`0x1009f11fc`), and the final-segment path can move it back one
when it coincides with the history boundary (`0x1009f120c`–`0x1009f1240`).
No durable database cursor was observed in these functions.

## Two distinct five-second deduplicators

`TextDeduplicator.processText` (`0x1009f3918`) normalizes text, derives a hash,
and looks up the last timestamp for that hash in its in-memory map at `+15`.
The strict condition at `0x1009f39b4` is `timestamp - previous < 5000`.
An existing hash with a difference of exactly 5,000 ms is allowed. A suppressed
repeat updates the timestamp too (`0x1009f39d4`), so repeated input can extend
suppression. Allowed input also updates the timestamp (`0x1009f3a08`).
Empty normalized input returns the allowed boolean before hashing.
`reset` (`0x10072a4e8`) clears the map at `0x10072a504`.

The caller arguments establish two separate uses:

1. At `0x1009f137c`, `processRawTranscript` passes manager field `+215`, the
   assembled detection-window text, and the current timestamp converted from
   microseconds to milliseconds. It does not hash only the incoming ASR segment.
   The subsequent branch at `0x1009f1388` suppresses a repeated window only for
   false/interim input; final input proceeds despite the duplicate result.
2. At `0x1009f18c0`, `QueryDispatcher._dispatchQueriesInternal`
   (`0x1009f17ac`) passes its own deduplicator at dispatcher `+15`,
   `QueryEntity.+15` question text, and the entity's `+23` DateTime converted
   to milliseconds. Duplicate questions are skipped before prefix filtering.
   The dispatcher constructor (`0x1009edbec`, allocation at `0x1009edca4`)
   confirms a separate deduplicator instance with the 5,000 setting.

Hashing uses dynamic string dispatch (`_calculateHash`, `0x1009f3a24`),
consistent with string hashCode, but the dispatch target was not independently
resolved. The observed map is keyed by that hash, without an additional text
equality check in `processText`.

## Model call and generated-query processing

The closure at `0x1009f3620` concatenates pool index `24980` with the prepared
window text (`0x1009f3684`) and calls `TextGenerator.generate`
(`0x1009f3690`). Despite the local retained filename
`query-question-comparison.json`, this closure is the model-generation call.
Conversely, the closure at `0x1009f35b8` (retained as `query-model-call.json`)
compares a previously accumulated entity's question text against the current
candidate through dynamic dispatch. These filenames are labels, not evidence
of the functions' roles.

`detectQuery` sanitizes generated output, calls `splitIntoQuestions`
(`0x1009f32e8`), reverses the resulting pieces, and iterates them in that order.
The splitter trims pieces and retains a final nonempty remainder. The exact
delimiter used by its dynamic search is unresolved. Before creating an entity,
the detector requires nonempty text, excludes a prefix from pool index
`24977`, and skips a question equal to an already accumulated result.
Entities receive a current timestamp.

No check requiring generated questions to be substrings of the transcript was
found in the complete inspected detector body. Whether the unresolved prompt
requests copied wording or paraphrases remains unknown. Code-level absence
does not establish what the model will generate.

## Twenty-second prefix and similarity filter

After exact-hash deduplication, the dispatcher calls
`PrefixStreamFilter.processQuery` (`0x1009f1d80`), which uses `compute` to run
`_processQueryIsolated (#2)` (`0x1009f1ec8`) with the question, timestamp,
and a copy of prior state. It normalizes question text and retains a map keyed
by normalized text. A pruning closure (`0x1009f2870`) compares entry age with
a 20,000 ms window; expired keys are collected and removed. The context stores
the tagged integer `40000`, corresponding to 20,000. The exact inclusive
expiry boundary has not been resolved because the comparison remains dynamic.

The state iteration then behaves as follows; `new` and `old` below refer to
normalized question text:

| Condition | Observed result |
| --- | --- |
| `new == old` | Suppress new; retain old key and refresh its timestamp. |
| `new.startsWith(old)` | Collect old key for removal; continue considering other entries and accept the expanded new text if none suppress it. |
| `old.startsWith(new)` | Suppress new; no timestamp refresh for an old key is selected in this branch. |
| A similarity strategy matches and new is shorter than old | Suppress new. |
| A similarity strategy matches and new is at least as long | Collect old key for removal; continue considering other entries. |
| No entry suppresses new | Insert new text with its timestamp and token set. |

The three strategies are constructed in order: `JaccardIndexStrategy`,
`TokenSetRatioStrategy`, `PartialRatioStrategy`. The strategy loop stops on
the first true match (`0x1009f24ac`): they combine by **OR**, not AND.
Assembly at `0x1009f234c`–`0x1009f23ec` establishes the direction of both
`startsWith` calls. A longer replacement and an expired entry are different
reasons for removal, and the result carries separate removal-key lists.
The dispatcher removes corresponding stored query entities and passes removal
and addition lists to its callback. Accepted additions are followed by a
100,000-microsecond (100 ms) delay in the dispatcher.

The result is a stateful replacement/suppression pipeline. A lifetime database
unique constraint is not equivalent to either its five-second hash layer or
its twenty-second similarity layer.

## Unresolved constants and limits

Pool indices below are those shown by IDA pseudocode using `X27`/pool values;
they are not original-file offsets or recoverable string values on their own.

| Purpose | Unresolved pool entries |
| --- | --- |
| Detector prompt prefix | `24980` |
| Excluded generated-output prefix | `24977` |
| Detection splitting regex | `11631` |
| TextDeduplicator's three regex patterns | `24985`, `24986`, `11631` |
| TextDeduplicator replacement / join value | `855` (`X27 + 0x1ab8`) |
| Prefix filter's removal regex | `24954` |
| Prefix filter's removal replacement | `27` |
| Similarity thresholds, in strategy construction order | `22356`, `13118`, `11291` |

`_normalizeText` (`0x1009f3a74`) performs an initial dynamic string operation,
trims, applies the three regex replacements, and trims again. The initial
operation is consistent with lowercasing but its dispatch binding remains
unresolved. Prefix normalization has a similar dynamic operation, then removes
one regex, trims, and replaces the splitting regex. A bounded raw printable
scan found plausible regex strings including `\\s+` and
`[^\\p{L}\\p{N}\\s]+`; it did not bind them to these pool entries. They must
not be substituted as recovered constants.

The model prompt, exact regexes, hash dispatch target, similarity thresholds,
exact expiry boundary remain unknown. Similarity calculations have now been
partly resolved in the follow-up below.
Static evidence establishes call flow, not actual model quality, timing under
load, or persistence across application restarts.

## Reconstruction differences at investigation baseline

These describe `packages/foresight_core/lib/src/proactive_questions.dart`
as inspected before integration of this report. They are a baseline for the
parent implementation task, not an assertion that later revisions retain them.

| Reconstruction baseline | Observed reference behavior / gap |
| --- | --- |
| Final-only SQL batches with `LIMIT 6` | Growing history from a cursor plus interim text; capped last 200 split units and interim tail exclusion. |
| Durable cursor advanced after every successful detection, including empty results | In-memory cursor advances on nonempty detection in the inspected path. |
| Per-meeting lifetime uniqueness on normalized question text | Five-second question hash suppression plus twenty-second stateful prefix/similarity processing and replacement. |
| Punctuation-and-whitespace replacement with a known reconstruction regex | Original uses three unresolved normalization patterns; exact equivalence is unestablished. |
| Reject every detected question not contained in normalized transcript | No corresponding detector-body constraint found; unresolved prompt could still constrain wording. |
| One-second queue tick | Reference has a one-second detector delay on interim input and a 100 ms post-dispatch delay; these are different scheduling points. |
| Hard limits of 32 questions and 1,000 characters per question | Those limits were not observed in inspected detector or dispatcher code. |

Database durability and restart recovery can be intentional reconstruction
choices. They should be described separately from behavior reproduced from
the reference, especially where they change repeated-question or context
retention behavior.

## Integration: growing finalized history

The reconstruction now reads finalized history after its cursor without a
six-row cutoff. Empty detection retains that cursor; nonempty detection
advances it to the last row included in the input snapshot. A per-meeting
input version prevents repeatedly calling the model for unchanged empty
results, while allowing speech arriving during a call to trigger another pass.
The detector receives at most the final 200 whitespace units, retaining their
line breaks. The 200-unit bound is recovered; whitespace splitting and the
retained separators remain explicit approximations pending pool resolution.

Regression tests cover cross-segment completion after an empty result, more
than six segments, the 200-unit bound, concurrent speech arrival, restart with
undetected history, cancellation, and durable answer ownership. Subsequent interim integration is described below; question dispatch filters,
prefix/similarity replacement, and boundary overlap remain outstanding. These
integrations do not establish full Q&A parity.

## Integration: interim windows

Capture hypotheses are stored per meeting/channel and joined with retained
finalized history. The last five whitespace units are excluded on interim
input before the 200-unit cap, reproducing the observed counts and ordering
while retaining the previously stated regex/separator approximation. Final
callbacks remove their matching hypothesis before notifying final input;
pause/stop/reset clears remaining hypotheses.

The complete assembled window feeds a separate five-second filter. Only
interim duplicates are suppressed, every suppressed repeat refreshes its
timestamp, and exactly 5,000 ms is allowed. Final input still runs detection.
This uses normalized string keys rather than claiming the unresolved original
hash dispatch is recovered; exact normalization remains unknown. Identical
nonempty hypothesis callbacks remain eligible to refresh suppression.

An interim-only detected question has no finalized transcript origin. The
reconstruction therefore permits a null origin and migrates old NOT NULL jobs
transactionally, preserving IDs, state and answer links. Durability remains a
reconstruction extension. It does not establish the original's answer-context
assembly for provisional speech: the current retrieval path still indexes
finalized history and imported sources.

Meaningful tests cover a native capture/ASR fixture feeding an interim question
through the application without a UI detection request, plus exclusion,
suppression boundaries, two channels, final bypass, cleanup, and migration.
The dispatcher-level five-second filter and twenty-second prefix/similarity
state are separate work; lifetime database uniqueness remains pending removal.

## Follow-up: similarity calculations and stream consumer

Focused IDA decompilation through REA process capture recovered:

- JaccardIndexStrategy.isSimilar at 0x100d0fe40: both empty sets match; one
  empty set does not. Otherwise compare intersection / union against the
  strategy threshold, accepting equality.
- _LevenshteinUtils.distance at 0x100d1046c: unit insertion, deletion and
  substitution costs over Dart string indices; two working rows. String
  indexing preserves UTF-16 semantics rather than grapheme normalization.
- _LevenshteinUtils.calculateRatio at 0x100d103f4:
  (max string length - distance) / max string length, with two empty strings
  returning one.
- PartialRatioStrategy.isSimilar at 0x100d107c0: reject empty inputs; compare
  equal-length strings directly; otherwise scan every substring of the longer
  string having the shorter string's length, including the final offset, and
  keep the best edit ratio. Stop on one; accept a score equal to the threshold.
- TokenSetRatioStrategy.isSimilar at 0x100d10034: sort/join the intersection
  and each full token set. Assembly confirms the two edit-ratio calls compare
  intersection with each full set. A reduction closure in pool 26550 combines
  these scores; its exact binding and the join separator still need recovery.

Implemented the established edit distance/ratio, partial ratio, and Jaccard
calculations in question_similarity.dart. Four focused tests cover reference
edge cases, max-length normalization, unit-cost transposition behavior,
UTF-16/surrogate handling, empty inputs and the final substring offset.
Analyzer is clean. These calculations are not yet wired into the dispatcher:
thresholds, exact normalization, and remaining token-set bindings must be
resolved before replacing production behavior.

The dispatcher callback TranscriptManager._onQueryDispatched at 0x1009f0560
logs/updates analytics and forwards a record to its broadcast stream. The one
direct getter cross-reference found for queryStream at 0x100a983a0 is
AudioControlPillState._subscribeToQueryStream at 0x100a982c4. Its callback at
0x100a983d0 calls triggerQuestionDetected for nonempty additions while mounted.
This inspected consumer controls the indicator; it does not establish deletion
of saved answer cards. Other access paths have not been exhaustively traced.

Evidence:
- ev_621cb243f895a20b8b8c66beacf0a97357d1fa522c057f990f4e94d441136ef5:
  dispatcher callback decompilation.
- ev_b538075ac58d346a5f640da0474feb89880e57b91ff1bd681adb1012fab05ef6:
  three strategies and queryStream getter cross-references.
- ev_a657fb2bc8ceff19f225882b4500ee0baeb1d620a192b42b52c2edfff646e8f1:
  stream subscription/consumer and edit-ratio helper.
- ev_30fa2a263a793f734cb222a994fa47a6d873b4512d6529be253c3ea1f745aa34:
  edit-distance helper and token-set call-site assembly.

Runtime constant recovery did not succeed. macOS denied debugger launch of the
signed installed original (ev_944150e9d414ee123ef7f55253bc7c0c070d134b0878649836c68d6a3a3d5d99).
A separate temporary app copy with a debug signature and isolated HOME launched,
but timed out without hitting either selected Dart breakpoint
(ev_e0fda9d5b9b41c45c95fa9bd3d798b2b9099268ad056fcc4efe216723c8dabd1,
ev_25a9c93702bd9cda8949eeee2bfc874ad1df6e36bfb2971de71a72bf3322ed23).
No threshold values were read. This is a failed observation, not evidence of
constant values or of normal original startup. Owned processes were cleaned up
and the temporary app/data were removed; the installed original was not edited.
The matching IDA analysis cache remains retained and its scoped workers closed.

## Pool recovery supersedes the unresolved-constant baseline

A focused single-snapshot reader now binds the previously unresolved constants.
The bundled Flutter engine identifies Dart 3.14.0-294.0.dev. The matching SDK
commit is ac1a97aae47d12e81d772ad45ab6d1fe57a02cf4. Independently computing
MakeSnapshotHashString from those SDK sources returns
e3b703b387b759dc21a3cbe8aa329f7a, identical to the artifact header. Merely passing
that hash to the build helper would not have been sufficient verification.

The reader uses the Mach-O loader from greeng3/blutter commit
d3b4615c7b7bd9bc1583f15fc6bc229b6aa8d9bd plus upstream single-snapshot PR 213
(c1caafecd233ea17c3f4b6b5ff8847d59478b979) and a small local Mach-O symbol patch.
It creates a Dart isolate from the snapshot without invoking the application.
Only allowlisted pool entries are read; no search credential is selected.
The source, build instructions, pinned inputs and local patch are retained in
[tools/reference_pool_reader](../tools/reference_pool_reader/README.md).

Pool labels below are the IDA X27-relative array labels. The actual ObjectPool
index is obtained from the byte offset minus the heap-object tag. For example,
PP[22356] is offset 0x2baa0 and ObjectPool index 22354. The threshold entries are
immediate double bits, not heap-object pointers. Initial attempts to use
ObjectAt on them were invalid and crashed the reader; corrected decoding checks
the entry type and uses RawValueAt. The corrected reader exits successfully.

| IDA pool label | Recovered value |
| --- | --- |
| 22356 | Jaccard threshold 0.7, bits 0x3fe6666666666666 |
| 13118 | Token-set threshold 0.8, bits 0x3fe999999999999a |
| 11291 | Partial-ratio threshold 0.9, bits 0x3feccccccccccccd |
| 27 | Empty string |
| 855 | One space |
| 11631 | Whitespace regex: backslash-s plus |
| 24954 | Prefix removal regex: non-letter/non-number/non-whitespace characters |
| 24985 | Leading timestamp regex: bracketed HH:MM:SS plus optional whitespace |
| 24986 | ASCII punctuation runs: hyphen, dot, comma, question/exclamation mark, colon, semicolon, straight quotes, parentheses |
| 24977 | Excluded generated-output prefix: greater-than greater-than |
| 24980 | Detector generation prefix: one space followed by the ctrl1 control token |
| 26550 | Reduction closure: static max(double, double) |
| 635 | Generated-question split delimiter: ASCII question mark |

Exact regex source strings are retained in the allowlisted pool output under
test-results/reference-functions/ida/selected-pool-constants.txt and the
implemented window normalization. The prefix regex is
[^\p{L}\p{N}\s]+. Binding the string dispatch selector -4092 for OneByteString
returns image offset 0xd1ffd4, matching the native String.toLowerCase symbol;
selector -4090 returns 0xd1fdd8, matching String.indexOf. This resolves the
previous lowercasing inference. No interpretation is made of the reader's
other diagnostic selector probes on unsupported string operations.

Additional IDA assembly at 0x1009f3394 binds the question delimiter to PP[635].
The prefix RegExp call at 0x1009f2020-0x1009f2048 uses the argument descriptor
PP[566]. Its recovered named-argument indices bind caseSensitive=true,
dotAll=false, multiLine=false, unicode=true. The Unicode property pattern is
therefore active Unicode matching, rather than an assumed constructor default.

Production integration in this revision replaces the approximate transcript
window normalization with the recovered lowercasing, leading-timestamp removal,
ASCII-punctuation-to-space replacement, whitespace collapse and trim. Detector
input now joins the eligible whitespace units with one space, matching the
recovered splitter/join values. Token-set scoring is implemented as the maximum
edit ratio between the sorted intersection and either sorted full token set.

Validation: 71 core tests passed, one opt-in test skipped; the retained reader
source was rebuilt and exited zero with matching constants. Exact dispatcher
integration, five-second question filtering, twenty-second expiry/replacement,
raw ctrl1 detector output handling, and boundary overlap remain unfinished.
The live pipeline still has its earlier copied-question restriction and lifetime
database uniqueness; the recovered thresholds are not yet used by it.

Evidence:
- ev_11eede0a8827759493c37d64e5641de0a0271319ddb0c9cc060bdafd2818864f:
  successful typed pool decoding, regexes, prompt control token and max closure.
- ev_ca9c9f20819e97585ab8b545571171176c805e815e66383fd97dbafa4fcbd44d:
  successful reader with string dispatch bindings.
- ev_b662071d0c44e46dca72b3a81265aaa0b8adda647538c136eb636ff4820e4d7b:
  IDA question delimiter and prefix-RegExp constructor assembly.
- ev_3d0270907dc0d76b84270790910df49313de0539a4b06fd83782e819b538dbde:
  retained argument descriptor and ASCII-question-mark delimiter.
- ev_3d0dfbc193db313ec64083e6a70c42e4d113ebf4cf03b86bda32f80177687bff:
  repository reader source rebuilt and run successfully.
- ev_a11bd1768f9a4921030c7cfda38f80a4e11b28fd33fbab88c4be8cb52cda50f8:
  core regression suite.

A second isolated debug app copy initialized Dart but still did not produce a
usable breakpoint observation. Its owned helper PID was identified by its
temporary executable path and terminated; the app/data were removed. The SDK
checkout and reader build remain under /tmp/foresight-dart-pool for reuse.
The successful constants above come from snapshot deserialization, not from the
failed debugger attempts or normal original-app execution.

## Integration: rolling dispatcher in the service pipeline

The pipeline now uses independent transcript-window and question-level
TextDeduplicator instances, followed by MeetingQuestionDispatcher's ordered
prefix/similarity state. Its normalization, token sets and three strategy
thresholds are the recovered ones. Similarity strategies combine by OR and
accept equality. Equal prefix entries refresh timestamps only when the question
passes the separate five-second layer. Shorter prefixes/similar revisions do
not refresh the longer entry. Collected replacements still apply if a later
entry suppresses the incoming question, following the inspected control flow.
Empty prefix normalization is accepted without modifying/pruning prefix state.

The remaining dynamic calls are now bound using the deserialized dispatch table:

- TextDeduplicator._calculateHash at 0x1009f3a24 dispatches String CID + 10470.
  OneByteString CID 95 resolves to image offset 0xbce2ec (String.hashCode);
  TwoByteString CID 96 resolves to 0xbce258 (_StringBase.hashCode).
- Prefix expiry assembly at 0x1009f2924 dispatches Smi CID - 4010. The recovered
  table resolves it to image offset 0xd1a7a8, whose retained native symbol is
  int.>=. The compared value is now minus the stored timestamp, against 20,000.
  Expiry is therefore inclusive at exactly 20,000 ms.

REA Evidence ev_c3d3e0b5707183470d37951cacef15addb6233ed2b735214851a9d9649ab0b7d
captures these dispatch bindings and their original native-symbol matches.
The reader source and its reproduction notes include these probes. Both
five-second filters now use normalized String.hashCode keys, rather than the
previous string-key adaptation. Hash timestamps are retained until reset,
matching the original map behavior, including after wall-clock adjustments.
No claim is made that hash values are portable across Dart SDK builds.

The durable schema no longer has UNIQUE(meeting_id,normalized). A migration
preserves row IDs, origins, state and answer links for both earlier NOT NULL
origins and the later nullable-origin schema. Rolling filters are staged on
copies and published only after the SQL savepoint commits, so a failed write
cannot consume detection eligibility or lose an older queued question.

New transcript input is examined before queued answers. Superseded entries
cancel only the matching still-queued durable jobs; completed answers are
retained and the UI labels replaced queued questions. Expiry removes filter
tracking, without deleting saved history. This bridges ephemeral original query
tracking to the reconstruction's durable jobs; original answer-card deletion
was not established by the stream subscriber trace and is not inferred here.

The code-level copied-substring guard and the unobserved 32-question/1,000-
character limits have been removed. Empty, greater-than-greater-than-prefixed,
and exact duplicate detector results are filtered before advancing history.
The current application detector still uses its JSON/copied-wording prompt;
matching the original ctrl1 generation and raw output handling is separate work.

Verification: 91 core tests passed, one opt-in test skipped; 165 desktop tests
passed, ten existing opt-in tests skipped; both analyzers clean. Tests cover
independent threshold boundaries, exact expiry/refresh, Unicode, recurrence,
queued expansion, shorter revisions, completed history, meeting/reset isolation,
SQL rollback, both legacy migrations, failed newer detection and short interim
input. These checks do not prove original model quality or runtime timing.

Remaining Q&A work: original generation/control-token/output flow, transcript
boundary overlap/pruning, exact detection/dispatch scheduling (including 100 ms
accepted-addition delay), provisional context for answers, and original/runtime
comparisons. This integration supersedes the earlier lifetime-uniqueness and
unresolved-expiry notes; full Q&A parity is still unproven.
