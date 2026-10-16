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
Later packaging and integration changes are still under validation.

## Executed checks

| Check | Observed result | Scope / limits |
| --- | --- | --- |
| Mac native CTest | 5/5 passed | Helper contract, model worker lifetime, audio buffer/cancellation, native lifecycle, process identity; initial development build used newer Homebrew dependencies |
| Mac service subprocess suite | 10 passed, 1 UI opt-in skipped | Real AOT service/MCP/helper, controlled capture process fixture; no physical audio claim |
| Mac contract/grounding/migration suite | 17 passed, 9 subtests | Includes offline migration's actual open-profile guard |
| Mach-O and installation tools | 21 passed before final recording/OS-floor checks | Actual Mach-O relocation/run, missing dependency rejection, Darwin directory exchange, rollback, metadata and lock behavior; final expanded suite recorded separately |
| Flutter release runner | Built successfully | Unsigned/ad-hoc development, not installed-release validation |
| Mac full Flutter suite with `2fb6445` | 135 passed, 10 skipped | Complete unit/widget suite, 104 s on this host |
| Mac native desktop/service/MCP integration | Passed in 94 s | Actual Mac Flutter runner, read-only desktop DB, shared ownership, note propagation, recording survives Flutter state destruction/restart, final transcript/artifact persistence; capture/inference use controlled fixtures |
| PDFKit/AppKit extraction | 5/5 passed | Actual generated Unicode PDF/RTF, spaced paths, encrypted PDF, empty/scanned documents, read failures, stderr-only usage errors |
| Updated Mac application core | 17/17 passed | Includes Mac importer argv/error handling; analyses clean |
| Linux native CTest on isolated MSI checkout | 4/4 passed | Integrated native/core changes; no edits to active MSI worktrees |
| Linux application core | 14 passed | Includes concurrent helper shutdown and private profile/installation paths |
| Linux service subprocess suite | 10 passed, 1 UI opt-in skipped | Actual service/MCP subprocesses |
| Linux full Flutter suite with `2fb6445` | 135 passed, 10 skipped | Real-I/O widget disposal fixed; opt-in models/UI remain separate |
| AOT installation maintenance exclusion | Passed | Installer exclusive lock blocks startup before DB creation; two profile services coexist with shared locks and exclude replacement until both stop |
| Standalone Python deployment metadata | 19 Mach-O files checked; none above 15.0 | Full relocated bundle execution and signing still separate |

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

## Outstanding acceptance evidence

The source-built target-15 SDK and complete relocated bundle are being validated.
Installed runtime, imports, desktop-first ownership, and update tests must pass
before the packaging phase is merged. The separate physical/release gates remain:

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
- Final integrated Linux packaging and desktop workflow verification.

The local keychain currently has no valid code-signing identities; this is an
external release prerequisite. Development signatures cannot close these gates.
