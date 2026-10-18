# Explicit integration gates

The regular Flutter suite intentionally does not load multi-GB models, start an
original application, or use a personal profile. These checks have explicit
validation paths rather than treating a skipped test as acceptance.

## Regular pull-request gates

`macos.yml` keeps the existing required platform-checks aggregation. Its Linux
job now installs pinned Flutter 3.35.7 and runs core, desktop and native tests,
including a real desktop/service/MCP session under Xvfb/D-Bus with controlled
capture and inference fixtures. The Mac job also explicitly enables that native
UI fixture. A requested UI gate without a platform runner fails rather than
skipping. Physical audio is not exercised by those fixtures.

The separate `linux-document-imports` job requires one Python contract that
imports both PDF and RTF fixtures through the production Dart parser on an
Ubuntu host. It provisions the actual extractors, requires the sandbox to start,
and fails on missing prerequisites. Its result is required by `platform-checks`;
local runs missing required executables report a skip. See the
[document sandbox](../platforms/linux-packaging.md#document-import-sandbox) for
the host-policy setup and retained evidence.

The generation-failure regression runs normally on both supported platforms.
It uses a short private `/tmp` directory for Unix sockets. After the Linux build,
`integration_gates.py --suite fast` runs that regression and the terminal capture
failure test with an owned failing pw-record executable. Neither needs a model
or physical microphone.

## Model and virtual-audio acceptance

`integration-acceptance.yml` runs on relevant main changes, on pull requests
that change `apps/desktop/**`, `packages/foresight_core/**` (including
`answer_contract.dart`, `store.dart`, and `application.dart`), `packaging/**`,
or the existing model/runtime paths, on manual dispatch, and on a weekly
schedule. It reuses the verified,
immutable Linux SDK descriptor and application build cache. It builds the same
application bundle with an extra disposable runner stage; it receives no Google
account or distribution secrets. Public model fixtures reuse the checksum-pinned
Gemma E2B, EmbeddingGemma and Whisper definitions already used by installer
acceptance, with a model cache saved independently of test success.

Runtime containers have no network, additional capabilities, host session
sockets or sound-device mounts. Virtual audio refuses to run if `/dev/snd` is
present; it creates a private runtime/home, PipeWire/Pulse/WirePlumber session,
null sink and remapped virtual source, disables hardware monitors, and stops
owned daemons on exit. LiteRT compilation caches live in a temporary directory
separate from the read-only model fixture mount.

| Group | Required executed tests | Scenarios |
| --- | --- | --- |
| Linux fast | 2 desktop | Generation failure; terminal capture failure persists through stop. |
| Models | 5 desktop + 1 core | Native load/late adoption, helper grounding/restart/deletion, meeting citation, local Google OAuth/API fixture into real retrieval, Gemma cancellation/reuse, controlled web-tool generation/memory. |
| Virtual audio | 3 desktop + 1 core | Whisper partial/final text while capturing, virtual microphone disappearance/return, overlap/pause exclusion and pinned-route recovery, and the meeting workflow (record, transcribe, summarize, cite, restart). |

That meeting workflow is `apps/desktop/integration_test/meeting_workflow_test.dart`,
run by the virtual-audio gate inside the private PipeWire session. `captureWindow`
returns immediately when `FORESIGHT_PRIVATE_PIPEWIRE=1`, so those assertions do not
use grim or an Agent Desktop display. `tools/test_meeting_workflow.py` remains the
local driver for an owned private display. Path filters that skip the job also skip
this meeting workflow; changes under the desktop app, the application service, or
packaging do not.

The three older generation tests explicitly select LiteRT by default; an
explicit `FORESIGHT_GENERATION_BACKEND` can select a legacy runtime. The load
failure fixture uses a missing model because packaged LiteRT configuration may
replace a supplied runner path. The public-model checks do not exercise live
Google consent, web services or account data.

Each selected Dart group writes expanded logs, JSON test events and a summary.
A zero exit status is insufficient: the runner requires the exact expected
number of executed passing tests, no skips, and a successful final reporter
event. Stale event files are removed before a run. Artifacts are retained even
when a gate fails; the job stays failed if either model or audio checks fail.

Run against an already prepared bundle/model directory:

```sh
python tools/integration_gates.py --suite models \
  --bundle dist/open-foresight --models build/acceptance-models --output test-results/models
# Linux, inside a disposable container without /dev/snd or host session mounts:
dbus-run-session -- python tools/integration_gates.py --suite virtual-audio \
  --bundle dist/open-foresight --models build/acceptance-models --output test-results/virtual-audio
```

These jobs supplement installed-package acceptance; they do not prove physical
microphone/system audio quality, permissions, suspend/resume, or GPU fidelity.

## Restricted/reference and diagnostic paths

The remaining core cases need inputs that ordinary CI cannot distribute:

- Four dedicated-detector acquisition/runtime tests plus the application-level
  proactive-model test require an independently authorized, authenticated local
  detector asset. The proactive test now registers that detector instead of
  assuming chat-model substitution; it retains its English/Chinese assertions.
- Tokenizer equivalence needs existing original and port helper sockets.
- `saved_answer_native_test.dart` remains a manual diagnostic over an explicit
  private database copy and existing helper socket. Synthetic grounded answers
  and persistence are exercised by the automatic model group.

Nothing extracts or uploads a reference asset or personal database. To execute
the first two groups locally, provide the existing inputs explicitly:

```sh
python tools/integration_gates.py --suite reference-models \
  --bundle '/path/to/Open Foresight.app' --query-model /authorized/local/detector.tflite \
  --output /tmp/foresight-detector-evidence
python tools/integration_gates.py --suite reference-tokenizer \
  --bundle '/path/to/Open Foresight.app' --original-socket /path/to/original.sock \
  --port-socket /path/to/port.sock --output /tmp/foresight-tokenizer-evidence
```

`tools/integration_skips.json` records all Dart skip registrations, including
platform-only cases and native-library checks already enabled by the regular
core build. `check_integration_inventory.py` fails when a registration is added,
removed or changed without reviewing its path/reason. The scanner checks named
`skip:` registrations, not arbitrary control flow inside test bodies.

## Reading validation evidence

Executed-test counts for each group are enforced by
[`tools/integration_gates.py`](../../tools/integration_gates.py). The workflow
invokes model and virtual-audio groups separately. A green offline suite does
not prove these build-dependent groups ran.

Use the retained Dart JSON reports and summaries for the source revision under
review. They distinguish executed passes, skips, and failures. The skip inventory
validates registrations; rerun `python tools/check_integration_inventory.py`
when changing tests, rather than copying an older local pass count into this guide.
Reference groups require their authorized inputs and must be reported separately.

## ThreadSanitizer probation

`native-thread-sanitizer` builds a separate Clang TSan SDK and test tree, covering
the native tests and helper vector index, contract, lifetime and adapter faults.
It cannot reuse the ASan SDK or combine address and thread sanitizers. A planted
data-race probe must be detected before a clean suite is trusted. Retained
`thread-sanitizer-evidence` contains the probe, fatal race logs and CTest results.

The first week (through 2026-10-24 UTC) is reporting-only. The workflow switches
to a failing gate automatically on 2026-10-25 UTC; repository administrators
should require the `native-thread-sanitizer` context after reviewing that week's
reports. Do not suppress a report without recording its cause and rationale.
An unsupported runtime or missing evidence is a failed probe, not a clean TSan
result.

## Probe index

`tools/integration_probes.json` records every `tools/test_*.py` and
`tools/accept_*.py` harness. Automated entries name their workflow or build script.
The manual probes below are diagnostics requiring the installed runtime, models,
a private desktop session, or physical hardware described by each script; they
are not release acceptance evidence unless actually run and recorded. Invoke a
probe only with its documented fixtures and authorization. Pure Google-client
and web-search release tests live under `tests/` and run in the offline suite.

| Manual probe | Purpose |
| --- | --- |
| `tools/test_capture_device_recovery.py` | Verify private PipeWire device loss/return without physical recording. |
| `tools/test_capture_terminal_state.py` | Exercise real native/Dart capture failure handling with a failing CLI fixture. |
| `tools/test_default_model_startup.py` | Check ordinary bundle launch on an owned desktop without a model override. |
| `tools/test_gemma_models.py` | Run real local Gemma native/helper acceptance without account data. |
| `tools/test_global_shortcut.py` | Verify the real Hyprland global key through a private microphone/profile. |
| `tools/test_global_shortcut_private.py` | Run global shortcut acceptance in a nested Hyprland on an owned headless desktop. |
| `tools/test_helper_worker.py` | Check persistent worker health/ownership through the actual helper RPCs. |
| `tools/test_litert_stop_sequences.py` | Check actual ordered-token stopping with the pinned SDK's test_lm fixture. |
| `tools/test_live_transcription_gap.py` | Verify real Whisper transcription across an owned virtual microphone outage. |
| `tools/test_meeting_workflow.py` | Exercise real meeting workflows on an owned headless desktop and private audio devices. |
| `tools/test_native_inference.py` | Exercise the shared native inference path with an empty executable PATH. |
| `tools/test_native_service.py` | Real-model acceptance through a packaged service and MCP in a private profile. |
| `tools/test_packaged_model_runtime.py` | Exercise real models through a relocated package's own inference processes. |
| `tools/test_packaged_note_enhancement.py` | Real packaged Application enhancement, including saved-transcript correction. |
| `tools/test_packaged_query_worker.py` | Relocate the native dedicated detector and test its installed protocol. |
| `tools/test_packaged_sentencepiece_coload.py` | Check both native/SentencePiece initialization orders in isolated children. |
| `tools/test_vision_model_runtime.py` | Opt-in real-model check of recovered vision startup and native ownership. |
| `tools/test_whisper_gpu.py` | Verify Vulkan Whisper and native speech events using a file, never a microphone. |

### Timing fixtures

Readiness polling in Dart tests always checks a condition and has a deadline; it does not assume readiness after a delay. The remaining nonzero polling intervals cover socket ownership, native capture/transcript readiness, search completion and process startup. Zero-duration delays only yield the event queue. The HTTP slow-stream fixture deliberately paces bytes to test the importer's wall-clock timeout, and the PipeWire pause fixture observes the full two-second no-capture window. These are measured negative assertions, not startup waits. Interrupted model downloads wait until the actual partial file has the expected bytes before breaking the socket. The PipeWire marker test waits for both owned sinks to become idle before resuming.

### Software Vulkan

The PR and weekly acceptance container installs Mesa lavapipe and selects only its ICD. The emulator explicitly opts in to CPU-type Vulkan device 0 with `GGML_VK_VISIBLE_DEVICES=0`; production launches do not set this override. CI passes `--allow-unavailable`: an absent ICD or explicitly unavailable GPU device produces a JSON `skipped` result and reason, while failures on an available backend remain fatal. After a successful Whisper Vulkan transcript, exactly one enumerated llvmpipe/lavapipe device with the pinned runtime's explicit CPU-device-type warning records LiteRT GPU coverage as skipped before model startup; this CPU adapter provides no physical GPU coverage. Unknown, mixed or contradictory adapter evidence cannot trigger this skip. The default probe remains strict. `accept_software_gpu.py` checks the shipped Vulkan Whisper runtime on two seconds of the pinned speech fixture, and otherwise attempts the shipped LiteRT GPU backend/model plus a 16-token decode. A missing OpenCL GPU API on the software driver is recorded explicitly as `unsupported_software_driver`; unexpected capability failures and every attempted decode failure fail the gate. Lavapipe implements Vulkan, so it cannot establish OpenCL delegate support or production GPU correctness. Physical GPU inference remains a release-day manual check. Full probe diagnostics are retained with integration evidence.

Workspace clear stress validation on 2026-10-18: 50 invocations at concurrency four, each running both online and offline cleanup/reopen variants (100 passing cases), with native/helper fixtures and isolated disk-backed test roots. Logs were retained in the local audit scratch directory; hosted test runs remain authoritative for runner-specific behavior.

Installed release and Preview `standard` validation both import generated PDF and RTF fixtures through the exact installed application service's Parser and sandbox, verifying persisted source URI, known extracted text and the real platform adapter. No developer Dart runtime substitutes for the installed service. Standard validation has no model fixtures, so a recorded post-parse indexing failure does not establish indexing or inference; the probe requires that extraction and storage already succeeded. Full acceptance runs the same document check alongside its model tests.

TSan triage on 2026-10-18: the first hosted run (39146727197) passed all five helper targets and 24/25 CTest targets overall. The lifecycle fixture restored Python's process environment immediately after asynchronous capture startup, racing `posix_spawnp` on the native worker. The fixture now keeps its environment override until `fs_capture_stop` joins the worker. No suppression was added. After that change, all 14 standalone native TSan targets and 50 repeated capture-tail fixture invocations passed locally without race reports. The current-head hosted rerun remains the final confirmation.
