# Replicating Foresight with REA on Linux and herdr on Mac

Use Linux to inspect the shipped Mac application with REA and implement the Linux version. Use herdr to reach the Mac terminal, establish what the installed app actually does, and collect observations for comparison. Work one feature at a time: identify its contract, inspect relevant code and resources, observe the Mac workflow, implement it here, and compare the results with the same inputs.

The reference is the original macOS Foresight app. This repository is the Linux reconstruction: Flutter UI, a C++ gRPC retrieval helper, SQLite persistence, and native/model workers. Behavioral parity requires matching state changes, outputs, persistence, errors, and cancellation as well as appearance.

## Tools and host responsibilities

| Host or tool | Responsibility | Boundary |
| --- | --- | --- |
| Linux and REA | Inspect copied bundles, Mach-O code, packaged assets, schemas, strings, and decompiled functions | Static analysis does not run the Mac app or establish runtime behavior |
| herdr | Forward terminal API commands to a saved Mac machine and read terminal output | herdr manages terminals; GUI interaction needs a separate Mac tool |
| Mac and its observation tools | Run Foresight and inspect its windows, dialogs, interactions, and resulting state | Accessibility, Screen Recording, and Apple Events access depend on the tool and host permissions |
| This repository | Implement and test the corresponding Linux behavior | Platform replacements and design choices must be distinguished from recovered behavior |

## Example environment and reference identity

The paths and machine label below are examples. Replace them with your project directory, copied bundle, analysis installation, and saved herdr profile. Check the reference app identity again when resuming an investigation.

| Item | Location or value |
| --- | --- |
| Linux project | `/workspace/foresight` |
| Copied reference bundle on Linux | `/reference/Foresight.app` |
| Installed reference bundle on Mac | `/Applications/Foresight.app` |
| Saved herdr Mac profile | `reference-mac` |
| herdr version used for these command examples | `0.9.3` |
| Existing Linux IDA installation | `/opt/ida` |
| Earlier investigation workspace | `/workspace/foresight-investigation` |

The earlier Mac inspection recorded bundle identifier `com.google.AIEdgeForesight`, build `1.0.0.28.20261005`, and main executable SHA-256:

```text
fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326
```

Treat these as historical identity checks. A changed build or hash needs new evidence; addresses from an older executable cannot simply be reused. Hash the main executable on Linux with:

```sh
sha256sum /reference/Foresight.app/Contents/MacOS/Foresight
```

The earlier workspace contains private investigation reports and captures that were deliberately excluded from this repository. Its `evidence/README.md`, `evidence/notes/feature-map.md`, and `evidence/ui/foresight-macos/observations.md` are useful starting points when present. Follow each report's references to the actual raw evidence before adopting a claim.

## REA workflow on Linux

REA project and setup documentation: [REA on GitHub](https://github.com/morluto/rea).

### Select the artifact and provider

Use the connected REA MCP tools and their active schemas. An absent `rea` shell command does not imply that MCP is unavailable; its server can use a launcher outside the shell PATH.

1. Call `binary_session` with `{}` to inspect any existing target and provider. Reuse matching state and inspect the returned operation availability before choosing a provider-specific operation.
2. Inventory the copied `.app` with `open_binary` and `inspect_artifact` when bundle structure is relevant. Inspect the listed plists and resources to identify the main executable, helpers, frameworks, model configuration, and service boundaries.
3. Open the exact executable needed for the question using REA's IDA provider. A Linux IDA provider has successfully analyzed the reference arm64 Mach-O. Further native investigation for this project uses IDA Pro, as requested by the user.

These are MCP argument examples, sent to the named tools in sequence:

```text
open_binary
{"path":"/reference/Foresight.app"}

inspect_artifact
{}

open_binary
{"path":"/reference/Foresight.app/Contents/MacOS/Foresight","provider_id":"ida"}
```

REA paths belong to the machine running its server. A `/Users/...` path visible through herdr is not automatically accessible to the Linux REA server. Copy required artifacts through the configured SSH connection when needed, preserve the bundle structure, and compare hashes on both machines. Inventory an extracted bundle or ZIP if DMG traversal is unavailable on Linux.

### Trace a specific behavior

Start with a question such as “Which values does Stop save?” or “How does graph selection affect the inspector?” Search literal UI text, service names, or known symbols, then follow references into relevant functions.

```text
search_strings
{"pattern":"Start transcribing","mode":"literal"}

search_procedures
{"pattern":"FinishStream","mode":"literal"}

analyze_function
{"procedure":"<symbol or address returned by this provider>"}
```

Use `xrefs`, callers, callees, and referenced strings where the selected provider supports them. For Flutter AOT code, recovered strings and pseudocode can expose contracts without recovering original Dart source. A string identifies a lead; it does not prove reachability, defaults, or call order. Missing provider facets and incomplete decompilation remain unresolved.

An earlier REA 6.4.0 run with IDA Pro 9.3 successfully analyzed graph force layout at `0x100980480` for the historical executable hash above. Its evidence ID was `ev_bc56d704f98fc634a06bb3952fb2d8dcf99c26359acc47b68fc72f1d35c364b9`; the complete response is retained in the earlier workspace under `evidence/notes/graph-reference/rea-ida/home-storage-20261014/`. This provides a reusable starting point for that build, not a universal entry address. Earlier direct IDA reports are separate evidence and must not be relabeled as REA output.

### Save evidence and close the session

Retain evidence IDs, target hash, provider/version, function or file locations, limitations, and the conclusion they support. Use `inspect_analysis_view` to page retained results when available; do not repeat a costly analysis just because the client truncated its display.

Export the bundle before closing, using a new absolute output filename:

```text
export_evidence_bundle
{"path":"/workspace/foresight/test-results/reference-investigation/rea-evidence.json"}

close_binary
{}
```

Create the parent output directory first. This repository ignores `test-results/`; put raw reports and captures there or in a chosen private evidence directory. Commit only curated documentation and suitable fixtures.

If a long IDA run fails, inspect the provider diagnostics and available workspace/temporary storage before retrying. The successful historical run used home-backed provider storage and `TMPDIR`; that observation did not prove temporary-storage pressure caused earlier failures.

## Mac terminal control through herdr

### Set up the Mac connection

Enable Remote Login on the Mac and confirm that you can connect from Linux with `ssh user@mac-host`. Replace `user` with your Mac account name and `mac-host` with its hostname, IP address, or SSH configuration alias.

From your Linux terminal, add the Mac as a saved herdr machine:

```sh
herdr machine add user@mac-host --label reference-mac
```

The option is `--label`. This command prepares the remote herdr server and saves the connection as `reference-mac`, which subsequent `--machine` commands use. Complete SSH authentication and any setup prompts in your terminal. If multiple remote sessions are available, select the intended session interactively, or specify it explicitly:

```sh
herdr machine add user@mac-host --label reference-mac --remote-session default
```

Use one of these commands when first configuring the connection. Once the profile exists, continue with discovery below. Setting up terminal access does not grant GUI automation permissions; those belong to the Mac observation tool.

### Discover the remote session

For agent control, first verify that the caller is inside a herdr-managed pane:

```sh
test "${HERDR_ENV:-}" = 1
```

If this fails, stop herdr control and resume from a managed pane. Consult `herdr --skill` for the installed control instructions and `herdr --help` for current syntax. The following commands discover the saved profile and its live panes:

```sh
herdr machine list --json
herdr machine status reference-mac --json
herdr --machine reference-mac pane list
```

`reference-mac` stands for your saved profile label, not necessarily an SSH hostname. Forwarding requires a running, API-compatible remote herdr server. It does not install or start one. A reachable machine status does not establish Foresight window access.

Read pane IDs from the remote response. Keep `--machine reference-mac` on every remote command: local and remote servers can have identical pane IDs, and `--current` identifies the local caller rather than a Mac pane.

### Run bounded commands in an available shell pane

Inspect the chosen remote pane and its process state before sending commands. Use an available shell at its prompt, rather than a pane occupied by an editor, running command, or agent. Substitute the returned pane ID for `<remote-pane-id>` below:

```sh
herdr --machine reference-mac pane get <remote-pane-id>
herdr --machine reference-mac pane process-info <remote-pane-id>
herdr --machine reference-mac pane read <remote-pane-id> --source recent-unwrapped --lines 80

herdr --machine reference-mac pane run <remote-pane-id> 'sw_vers'
herdr --machine reference-mac pane run <remote-pane-id> 'shasum -a 256 /Applications/Foresight.app/Contents/MacOS/Foresight'
herdr --machine reference-mac pane read <remote-pane-id> --source recent-unwrapped --lines 120
```

`pane run` submits text and Enter; its return does not prove command completion. Read the result and wait for the shell prompt before submitting the next command. For longer commands, use `pane wait-output` with a unique completion marker and a bounded timeout, then check the exit result. Keep an explicit record of which commands ran on which host.

If no available shell exists, inspect the installed `pane split` options and create a suitable pane in the intended remote workspace with `--no-focus`. Use the returned ID. Do not send terminal commands through an agent prompt or create another agent just to run shell commands.

### Observe and interact with Foresight

herdr supplies the terminal transport. From that terminal, use the Mac's available GUI tooling, such as an accessibility automation tool, AppleScript, or `screencapture`. Discover its actual interface and permissions before prescribing automation commands. If using REA native UI observation, it must run on the Mac with the required host access; Linux static analysis does not provide that access.

For each scenario:

1. Confirm the installed app's build/hash and the current Foresight process/window. Record whether the profile is fresh or contains existing data.
2. Capture the relevant initial screen and state with the available Mac tool. Avoid unrelated windows and personal account contents.
3. Perform one deliberate action with controlled files, meeting text, or audio. Record inputs, visible changes, timing, errors, and resulting persisted state where accessible.
4. Capture the result, dismiss temporary dialogs, and record any settings or data changes needed to reproduce the scenario.
5. Save the captures and observation notes on the Mac, then transfer selected evidence to the Linux investigation directory through the configured SSH transport. Mac paths returned in terminal output are not Linux files.

Historical captures show the sources list and graph, Add source menu, meetings, Ask, settings, inactivity choices, and hotkey instructions. They do not establish all corresponding interactions. Earlier attempts encountered `cgWindowNotFound` and REA Accessibility/Screen Recording limitations; capture failure does not prove that the app stopped or that a feature is absent. Diagnose the specific observer failure before retrying. Record required permission changes rather than silently changing system access or restarting an active recording.

## Turn evidence into Linux behavior

Maintain a small feature ledger. Each entry should include the reference build/hash, preconditions, exact inputs, Mac observations, static evidence IDs or raw-file references, implementation location, parity check, and remaining questions. Label conclusions as observed behavior, static findings, inferred behavior, or Linux design choices.

| Feature | Reference questions | Main Linux locations |
| --- | --- | --- |
| Source ingestion | Which formats and import modes work? How do duplicates, updates, failures, and removal behave? | `apps/desktop/lib`, `services/helper` |
| Search and cited answers | What is indexed, retrieved, cited, streamed, canceled, and saved? | `proto/rag`, `services/helper`, `native` |
| Meetings and transcription | How do Start, interim text, Stop, flush, failure, notes, summaries, and reopening behave? | `apps/desktop/lib`, `native` |
| Source graph and labels | How do layout, selection, zoom, labels, scene scope, and restoration behave? | `apps/desktop/lib`, graph tests in `apps/desktop/test` |
| Model setup | Which choices, eligibility rules, progress, cancellation, and recovery states appear? | `apps/desktop/lib`, `models`, `native` |
| Drive and Calendar | Which import/refresh/error states are visible? What authorization does the Linux integration require? | `apps/desktop/lib`, `tools/package.py` |
| Desktop integration | What do shortcuts, quick meeting, window activation, and settings persistence do? | `apps/desktop/lib`, `apps/desktop/linux` |

Use the same controlled scenario on both systems. Compare semantic outputs, transitions, citations, persistence after reopening, and failure/cancel behavior. Compare screenshots at a recorded window size for visual work. Generated wording may vary; define content and grounding checks rather than assuming identical prose. A model configuration or protobuf schema match alone does not establish functional parity.

Map platform behavior to Linux explicitly: PipeWire for audio capture, Linux window/shortcut integration, supported local model artifacts, and configured OAuth credentials. Do not treat a shipped Mac framework, encrypted model package, or service endpoint as a working Linux dependency. Keep credentials and account profiles out of evidence committed here.

For a transcription scenario, for example, use a short controlled recording, observe provisional versus final text, press Stop, measure finalization, reopen the meeting, and compare retained transcript and generated artifacts. Static evidence for a native flush function supports the API's existence; Mac observation is still needed to establish the app's Stop-to-flush sequence.

Run checks appropriate to the implementation: relevant Flutter tests and analysis for UI/domain changes, helper/contract tests for service changes, and native CTest checks for worker lifecycle changes. Real audio, model, OAuth, and desktop checks require their corresponding environment; deterministic fixture tests establish only the fixture contract. See the root [README](../README.md#verification) for commands.

A feature is ready when its declared scenario passes on Linux, the comparison has traceable reference evidence, and unresolved differences are recorded. Screenshot similarity, successful compilation, and an incomplete negative search are insufficient to claim complete parity.
