# Distribution asset and vision startup lifecycle

This implements the inspected original Foresight asset/startup policies in the
port's existing model management. The reference binary identity is
`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`.
Only public model metadata, the bundled model configuration asset and bounded
IDA Pro functions were read. No original profile, cache, credential pool entry
PP9019 or complete application configuration map was read or modified.

## Discovery and refresh

`AssetManager._refreshServerConfigInternal` (`0x100670444`) preserves server
metadata order and constructs `models/<type>/<version>/<name>` under application
support. Empty versions use `1.0`. ARM64 call arguments at `0x1006706d4–700`
establish the five path components. Refresh publishes an immutable asset list,
awaits obsolete cleanup, then emits update events for files found during refresh.
Concurrent refresh callers share the pending operation; later refreshes can retry
a failed operation. The original full initialization/disposed state machine is
not claimed by the catalog's narrower refresh adapter.

`_getLocalModelPath` (`0x1006452b8`) first checks matching metadata in order,
returning the first existing file. Its fallback recursively lists the type's
model directory and excludes `.downloading` and `.tmp` suffixes. The shared named
argument descriptor PP2027 binds `recursive: true` for discovery and cleanup.
`_getLocalOnDeviceModel` (`0x1008f0b54`) instead returns the first matching
metadata, without equating metadata existence with an installed file.
`insightInferenceModel` (`0x1008f0834`) tries a selected supported type first,
then types **16, 15, 14, 12, 8, 9**. Unsupported selections are ignored.

`ModelAssetLifecycle` keeps these lookup operations distinct. The existing query
download action still uses the separately recovered **last duplicate per type**
plan; discovery does not substitute an older file for an explicit download.
Distribution acquisition refreshes this catalog and publishes its authenticated
encrypted candidate into the metadata layout. Readiness/lease cleanup precede
registration. Failed adoption restores the previous file; failed restoration
retains the backup with an actionable recovery error. Obsolete-backup cleanup
after successful adoption is best effort.

When a port registry entry is absent, generation readiness/resume and the query
detector use the owned directory fallback. Generation is probed before
registration; the dedicated detector is decrypted, authenticated against its
fixed identity and probed before registration. Existing registrations, including
registrations installed while discovery is awaiting a worker, win. This fallback
needs no metadata RPC, download or new user project configuration.

## Obsolete cleanup and ownership

`cleanupObsoleteModels` (`0x100670c4c`) protects advertised paths for types
**1, 2, 3, 4, 14, 15, 16, 17**. For each advertised file that is absent, it also
protects paths containing that type's decimal string. This deliberately preserves
the original broad **String.contains on the complete path**, rather than replacing
it with a type-directory or version comparison. For example a missing type4 can
protect an otherwise unrelated filename containing `4`.

The recursive scan skips temporary suffixes and deletes other obsolete files.
The exception handler at `0x100671648–6c0` warns and continues after an individual
file deletion failure. The outer handler cancels the iterator and rethrows a
listing failure. No directory trees are recursively deleted by obsolete cleanup.

The port confines this policy to its own profile's `distribution-assets/models`
tree, excludes symlinks and symlink directory ancestors, rejects path traversal
in metadata, and additionally protects registered/active assets. These are port
ownership rules; they do not imply the original applies the same safety checks.
Imported models and temporary plaintext leases are outside the cleanup tree.

## Model-specific startup

The public bundled `lib/assets/on_device_model_configure.json` has SHA-256
`c487e534262f81fedd0f55a4846dce201b023917d6ecefb31c116b8f7adf3679`.
`ModelConfigureManager.getModelConfig` (`0x1008e3794`) maps aliases 9→14,
8/10→15 and 12→16, then selects the first matching bundled entry before its
fallback. Its inspected entries configure:

| Distribution type | Vision backend | Audio backend | Maximum vision tokens/image |
| --- | --- | --- | --- |
| 14 (E2B), 15 (E4B) | GPU | CPU | 280 |
| 16 (12B) | GPU | GPU | 560 |

All three explicitly enable speculative decoding, vision and audio with a
4096-token context. Initializer `0x1008ef6d8` binds config +23 to the speculative
argument (public log label PP14186), +31 to vision (PP14187), +39 to audio
(PP14188), and +47/+55 to audio/vision backends. The small-model CPU override at
`0x1008efc58–d14` applies to **audio**, while vision uses the configured GPU.
The later LiteRT service initializer serializes those native engine settings.

Registration persists its internal distribution model type. Existing installed
manifests can supply `model_type`; the already supported public E2B digest
`181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` is identified
automatically, including migrated registry rows. Unknown imports retain the
existing text-only policy. The additive native ABI carries the type through
probe, one-shot and persistent execution; no separate project file is needed.

Both workers retry a failed initialization with identical settings after owned
cache cleanup/shutdown. When the second attempt fails and vision was enabled,
the third attempt disables vision and its visual budget while preserving text
backend, audio backend, context and cache. Final failure closes the last engine
and propagates an unavailable result through the worker. Inference/close failures
do not enter this startup retry. The dedicated query detector bypasses it.

The pinned Python 0.18 wrapper omits the native visual-budget option. A bounded
initializer subclass calls the existing public C settings API, owns the settings
handle in `finally`, and reuses the SDK's tokenizer/conversation/close methods.
Partially created engines remain owned until the recovered shutdown boundary,
including an injected settings-delete failure. No SDK library or global factory
is patched or rebuilt. The three affected model setup widget tests also pass.

## Verification and limits

Evidence is retained under the ignored `test-results/reference-functions/ida/`:
`vision-functions-index-v2.json`, `vision-obsolete-cleanup.json`,
`vision-refresh-shared-future.json`, `vision-inference-asset-selection.json`,
`vision-model-config-selection.json`, `vision-config-json-fields.json`,
`vision-refresh-path-arguments.json`, `vision-directory-list-arguments.json`,
`vision-cleanup-delete-handler.json`, `vision-cleanup-exception-tail.json`,
`vision-public-config-labels.txt` and `vision-public-config-descriptor.txt`.
The owned direct IDA batches closed with exit0. REA's IDA provider reported
unavailable; these captures are direct IDA evidence, not successful REA analyses.

The final full core suite passes **462 tests with 7 skipped**, including the native fixture suite; static analysis is clean. The focused discovery/readiness group passes 22 tests, startup/protocol Python passes 44 tests, and all 7 fresh native CTest groups pass. All 4 opt-in actual-detector tests pass, including catalog publication to the metadata path, restoration after deleting only its disposable registry entry, encrypted lease reopening and failure cleanup with framing-only vault fixtures (no Keychain access).

The new filesystem tests exercise refresh ordering, pending sharing/failure,
first metadata versus first existing file, temporary exclusion, the missing-file
contains quirk, active/imported preservation, traversal/symlink containment,
individual delete failures, listing failure propagation and adoption/rollback.
Native ABI fixtures verify model type reaches probe, one-shot and persistent
workers. Startup fixtures cover identical retry settings, third-attempt success
and failure, query bypass and partial native ownership after settings cleanup
fails. Native worker syntax is checked with the pinned vendored headers.

`tools/test_vision_model_runtime.py` uses the existing PR9 accepted ABI-aligned
SDK in a disposable profile with a synthetic 128×128 red image. On Apple M4,
CPU-text/GPU-vision and GPU-text/GPU-vision both answered `Red`, requested native
stream cancellation after a delta, closed that conversation, reused the same
engine to answer `4` for 2+2, and closed its native engine. Logs select the actual
Metal/WebGPU adapter and vision_280 encoder. Reports are
`vision-real-image-cpu-lifecycle-report.json` and
`vision-real-image-gpu-lifecycle-v2-report.json`. This runs this branch's owned
initializer with the existing accepted SDK; it is not a newly signed complete
application or a new original-app visual oracle.

Earlier negative reports used the superseded pre-GPU-closure package; the final
accepted ABI-aligned package passes. No shared SDK or cache was modified. Linux
vision GPU, the 12B/560-token asset, E4B, live remote model metadata, complete
original initialization state transitions and signed/minimum-OS release acceptance
remain separate gates. The recovered policies are implemented without claiming
those unavailable platform/model checks passed.
