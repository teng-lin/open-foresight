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

`tools/integration_skips.json` records all 27 Dart skip registrations, including
platform-only cases and native-library checks already enabled by the regular
core build. `check_integration_inventory.py` fails when a registration is added,
removed or changed without reviewing its path/reason. The scanner checks named
`skip:` registrations, not arbitrary control flow inside test bodies.

## Reading validation evidence

The table above mirrors the exact executed-test counts enforced by
[`tools/integration_gates.py`](../../tools/integration_gates.py): Linux fast 2,
models 6 (5 desktop and 1 core), virtual audio 3 (2 desktop and 1 core), authorized
reference-model checks 5, and tokenizer equivalence 1. The workflow invokes the
model and virtual-audio groups separately. A green offline suite does not prove
these build-dependent groups ran.

Use the retained Dart JSON reports and summaries for the source revision under
review. They distinguish executed passes, skips, and failures. The skip inventory
currently validates 27 registrations; rerun `python tools/check_integration_inventory.py`
when changing tests, rather than copying an older local pass count into this guide.
Reference groups require their authorized inputs and must be reported separately.
