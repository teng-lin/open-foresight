# macOS implementation validation

This is an evidence ledger, not a release approval. The implementation plan's
unchecked release gates remain required. Automated fixture capture is never
evidence of microphone or system-audio permission attribution.

## Environment and baseline

Development host: MacBook Air, Apple M4, 24 GB memory, macOS 26.6.2,
Xcode 27.0 / AppleClang 21, Flutter 3.35.7 / Dart 3.9.2, Python 3.13.
The deployment target is 15.0; execution on 26.6 does not prove the OS floor.

The committed application-service baseline is `3195e04`; the Mac plan is
`c609a0a`. Work is isolated from the active MSI service and packaging worktrees.
Reviewed native/core/audio changes were merged to main in `0d1aba7`.
The integration branch now includes packaging, guided audio/model setup, and
configured-model relocation; release acceptance remains separate.

## Executed checks

| Check | Observed result | Scope / limits |
| --- | --- | --- |
| Mac native CTest | 5/5 passed | Helper contract, model worker lifetime, audio buffer/cancellation, native lifecycle, process identity; initial development build used newer Homebrew dependencies |
| Mac native CTest with source SDK | 6/6 passed | Fresh `build/macos15`, arm64/15.0, system SQLite/zlib, pinned static gRPC dependencies, document parser included; no Homebrew runtime libraries |
| Mac service subprocess suite | 14/14 passed, including native UI | Real AOT service/MCP/helper, controlled capture process fixture; no physical audio claim |
| Mac contract/grounding/migration suite | 17 passed, 9 subtests | Includes offline migration's actual open-profile guard |
| Mach-O and installation tools | 33 passed, 6 subtests | Actual Mach-O relocation/run, missing/newer-OS dependency rejection, Darwin directory exchange, rollback, metadata, active-recording deferral, locks, actual AOT source/graph persistence, and Swift document extraction |
| Flutter release runner | Built successfully | Unsigned/ad-hoc development, not installed-release validation |
| Mac full Flutter suite | 143 passed, 10 skipped | Complete unit/widget suite, including embedding-download consent and guided quick-start; analysis clean |
| Mac native desktop/service/MCP integration | Passed in 94 s | Actual Mac Flutter runner, read-only desktop DB, shared ownership, note propagation, recording survives Flutter state destruction/restart, final transcript/artifact persistence; capture/inference use controlled fixtures |
| PDFKit/AppKit extraction | 5/5 passed | Actual generated Unicode PDF/RTF, spaced paths, encrypted PDF, empty/scanned documents, read failures, stderr-only usage errors |
| Updated Mac application core | 29/29 passed | Includes importer contracts, permission actions, atomic idle shutdown and configured runner relocation; analysis clean |
| Linux native CTest on isolated MSI checkout | 4/4 passed | Integrated native/core changes; no edits to active MSI worktrees |
| Linux application core | 29/29 passed | Includes shared-service shutdown and configured runner relocation; analysis clean |
| Linux service/workflow suite | 12/12 passed | Includes actual native Flutter desktop/MCP capture/restart integration with controlled inference/audio; restart awaits restored model readiness |
| Linux full Flutter suite | 140 passed, 13 skipped | Analysis clean; Mac-only widget cases skipped on Linux |
| Linux prototype packaging and relocation at `bf22d50` | Passed | Release runner, 130-file folder bundle, paths with spaces, cwd `/`, native desktop/MCP shared owner, independent headless profile and note writes; same host glibc 2.44, no distro ABI/clean-machine or model-runtime claim |
| AOT installation maintenance exclusion | Passed | Installer exclusive lock blocks startup before DB creation; two profile services coexist with shared locks and exclude replacement until both stop |
| Standalone Python deployment metadata | 19 Mach-O files checked; none above 15.0 | Full relocated bundle execution and signing still separate |
| Complete relocated development app | Passed MCP-first and desktop-first | Minimal HOME/PATH/profile environment, paths with spaces, two MCP clients, shared AOT service, notes/source revisions/labels/graph persistence, native PDF/RTF extraction, maintenance exclusion; desktop process termination tested, actual window-close/reopen still separate |
| Real models using bundled runtime paths | Passed | Full Gemma GPU grounded/citation/cancellation/reuse workflow in 73 s, actual EmbeddingGemma GPU retrieval, and bundled Whisper JFK transcription; outer Flutter test harness remains a development tool |

| Reviewed assembled app at `c87514c` | Passed desktop-first smoke | 31 Mach-O files audited; two MCP clients, idle-only atomic upgrade, injected post-swap verification failure and inode/signature rollback; data survives restart |
| Configured real models after bundle move | Passed | Private profile registered real embedding/generation/speech models, indexed a source, stopped the owner, moved the app, restored generation and answered with a correct citation; raw registrations retained, runtime projection resolves the new paths; signature remains valid |

## Pinned model probes

The following tests ran against actual public model weights and LiteRT-LM 0.18.0
on the development host, outside a completed release bundle.

| Model / operation | Result |
| --- | --- |
| EmbeddingGemma 2, CPU | 768 dimensions, L2 norm 0.99999975; measured request 0.638 s |
| EmbeddingGemma 2, GPU | 768 dimensions, L2 norm 0.99999973; measured request 0.911 s |
| Gemma 4 E2B, CPU and GPU direct runner | Both returned the requested `ready` response |
| Full native/helper Gemma GPU workflow | Passed in 153 s: factual citations, three-step instructions, numeric fidelity, insufficient context, native cancellation/reuse and grounded-pipeline cancellation/reuse |
| Whisper multilingual tiny, Metal | Correct JFK fixture transcript; 11 s audio, reported total inference 1.211 s and model load 88.85 ms |

Embedding model SHA-256:
`e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c`.
Gemma model SHA-256:
`181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`.
Whisper model SHA-256:
`be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21`.
Whisper source: `0c7be696371069e0baa2515ed7aa08d5a5473aa6`.

These are individual probe timings, not minimum-hardware performance thresholds
or a peak-memory benchmark. They do not establish E4B/12B performance or identity
with encrypted reference-application assets. Raw local logs and JSON reports are
under the ignored `test-results/verification` directory; reproducible runners
include `tools/test_gemma_models.py` and the native/service test suites.

## PR review follow-up

Cross-area review found three concrete issues, all fixed with regression coverage:
SDK source checks now reject staged edits as well as unstaged edits; existing
meeting recording uses the same explicit permission flow as quick start; and
idle shutdown verifies adopted helpers that have exited, while preserving unknown
inspection failures and refusing to signal mismatching identities.

After these fixes: native CTest 6/6, service subprocess tests 14/14 (including
native desktop integration and two real adopted-helper cases), packaging tools
33 passed / 6 subtests, and focused setup widgets 9/9. Flutter analysis is clean.
GitHub CI results are reported on the PR separately from these local checks.

## Outstanding acceptance evidence

The source-built target-15 SDK and complete development bundle pass the checks
above. The user confirmed the guided setup flow works; this does not establish
physical audio transcription or signed permission attribution. The separate
physical/release gates remain:

- Developer ID signing, notarization, stapling, and Gatekeeper assessment.
- Signed installed-service microphone/system capture attribution, desktop-first
  and MCP-first recording, final transcripts, device changes, sleep/wake, and
  permission denial/revocation.
- Release GUI interactions, notification delivery with the window closed,
  browser OAuth/Drive/Calendar against an explicitly configured account.
- A quarantined downloaded artifact in a fresh Mac account without development
  dependencies, and execution on the intended minimum OS/hardware.
- Representative latency and peak memory with explicit usable thresholds and
  defaults on that minimum hardware.
- Linux distribution packaging and clean-machine ABI verification; the isolated
  MSI prototype bundle and integrated desktop/service tests passed on the build host.

The local keychain currently has no valid code-signing identities; this is an
external release prerequisite. Development signatures cannot close these gates.
