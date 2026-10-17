# Controlled original detector oracle preparation

This tool targets only Foresight executable SHA-256
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`,
identifier `com.google.AIEdgeForesight`, and already-decrypted dedicated model
SHA-256 `889306301a8817c22de9631087896780762ce7985b3012e42debfc239a62193f`
(179,437,568 bytes). It contains no keychain, configuration discovery or model
decryption code. The installed application is read only. All generated artifacts
use a private directory, by default under ignored `test-results`.

Initial preparation compiled the harness and passed isolation checks. A later
coordinated REA experiment prepared and attempted to load a signed owned copy in
`test-results/reference-functions/oracle-runtime-v1`. It failed with SIGBUS during
dyld rebase processing, before original initializers or C API inference. The
failed receipt, stderr, answer and run report remain preserved. The corrected
owned-copy loader then succeeded in a fresh `oracle-runtime-v2` root and executed
the original dedicated GPU model with exit 0. Both roots remain frozen.

```sh
python3 tools/original_query_oracle/prepare.py build
python3 tools/original_query_oracle/prepare.py check-isolation
```

The latter installs `isolation.sb` with `sandbox-exec` **before** starting the
harness. It verifies actual denial of read/write opens on an existing public
canary outside its private root, denial of IPv4 and IPv6 loopback connections,
and permission to write inside its private root. It then compiles and executes
a Metal shader and checks its result. This self-test never loads the original.
The final checked profile passed all these checks on this host with exit 0 and
empty stderr. Its report binds the profile and harness digests.

The profile uses default denial, explicit network denial, private-root writes,
system framework reads/mapping, Metal IOKit access and only the Metal compiler
Mach service. It grants no general preferences, securityd or application service
lookup. `HOME` is not overridden. `CFFIXED_USER_HOME` and `TMPDIR` point to the
private root. The direct process cannot write outside that root. This does not
assert that macOS GPU services never update their own managed shader caches.
Sandbox profiles are deprecated Apple private interfaces; the tool reruns the
actual canaries for each preparation/run instead of assuming portability.

A later, separately coordinated experiment can explicitly invoke:

```sh
python3 tools/original_query_oracle/prepare.py prepare --model ALREADY_DECRYPTED_MODEL
python3 tools/original_query_oracle/prepare.py run
```

`prepare` first repeats isolation checks, verifies pinned source/model digests,
then copies the executable and Flutter framework into the private root. It
converts only the owned executable to `MH_BUNDLE`, removes executable-only load
commands and `__PAGEZERO`, clears `MH_PIE`, adds an explicit owned framework
rpath and applies an ad hoc signature. Removing `__PAGEZERO` also shifts the
segment ordinals embedded in legacy dyld rebase/bind/weak/lazy opcode streams.
The corrected converter parses those streams and remaps only segment-selection
opcodes; it preserves ULEB/SLEB payloads, symbol strings, VM addresses, export
offsets, section ordinals and stream lengths. It rejects chained/threaded
fixups, split-segment info and relocation tables rather than guessing. This
corrected conversion successfully loaded and ran the dedicated GPU model in
the scoped fixtures below. It remains an experimental diagnostic tool. The exact source application remains unchanged. A receipt
binds the resulting image, model, harness and profile. Existing preparation is
preserved; choose a new root for a replacement.

`run` repeats isolation tests and validates the receipt before entering the
sandboxed harness. The harness rechecks file/network denial before `dlopen`,
validates owned input paths and fixed model digest, and resolves only the six
TextCache C exports. It does not invoke Dart, Flutter main or application main.
It uses the recovered 64-byte options and 16-byte input structs with compile-time
offset checks. The original zero temperature option is retained: recovered
`CreateSession` at `0x101b7a0dc` substitutes 0.3 for nonpositive temperatures.
Output pointers are copied while valid and released by `FreeTextOutput`;
error pointers use `FreeTextCacheTaskErrorMessage`. Empty output with no error
is valid. Cleanup calls Close, frees its optional error, then Destroy. Successful
Close marks the handle invalid, so the destructor does not cancel it twice.
The process keeps the image loaded until exit because original C++ registries
and threads have process lifetime. An external 90-second timeout bounds the
original generator's internal 60-second wait.

The v1 failure was a conversion defect: removing `__PAGEZERO` without remapping
opcode segment ordinals made original segment 3 (`__DATA`) refer to converted
segment 3 (`__LINKEDIT`). The owned crash report identifies dyld
`applyFixupsGeneric`/`forEachRebase_Opcodes` writing to the read-only LINKEDIT
mapping at offset 0x10. This is distinct from a sandbox denial. Static validation
of the pinned image now remaps 2 rebase, 42 bind, 52 weak and 1353 lazy segment
selections. Outside the load-command header, only these parsed opcode bytes
change. Reports for the corrected parser and fresh canary-only build are in
`test-results/reference-functions/oracle-preparation-v2`. Frozen v1 artifacts
were not modified.

The corrected image loaded and its mandatory original C++ and Objective-C
initializers survived the unchanged strict profile. Four public fixture cases
were compared against the reconstructed NumPy float32 CPU executor using the
same dedicated model weights: a contextual launch question, a meeting-start
statement, standalone `What is the deadline?`, and a contextual budget question.
All four matched after trimming surrounding whitespace. The two contextual
questions produced the extracted question; the statement and standalone question
produced empty output. Original GPU positive outputs included a leading space,
including ` What risks could delay the launch?`, while the CPU diagnostic
returned the same text without that leading space. The three additional paired
case reports plus archived launch output are preserved in frozen
`test-results/reference-functions/oracle-runtime-v2`.

This establishes loader/inference success and normalized output agreement for
those four fixtures. It does not establish equal logits, token probabilities,
rounding, latency, or behavior on broader transcripts. Numerical comparison
beyond these text outputs remains open. The packaged implementation is the
reconstructed CPU executor; neither the original executable nor model weights
are packaged. There are 238 native
initializers and nine Objective-C `+load` hooks, including analytics/messaging.
The observed execution used the same sandbox installed before load and did not
broaden network, original-state or service permissions. Preserve failed
experiments as explicit results and keep any broader equivalence claim tied to
new evidence.

ABI evidence is retained under `test-results/reference-functions/ida/oracle-*`.
The read-only inspection report is
`test-results/reference-functions/streaming/original-oracle-macho-readonly.json`.
