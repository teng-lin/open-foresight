# Application service and MCP

Open Foresight uses one application service per profile. The Flutter desktop and MCP adapter share that service, its database writer, local models, retrieval helper, and recording session. The desktop opens a read-only SQLite WAL connection for rendering queries. All mutations go through named application operations on a private Unix socket.

```mermaid
flowchart LR
  Desktop[Flutter desktop] --> Service[Local Dart application service]
  MCP[MCP stdio adapter] --> Service
  Desktop -. read-only snapshots .-> DB[(application.db)]
  Service --> DB
  Service --> Helper[C++ retrieval helper]
  Service --> Workers[Native generation and speech workers]
```

The Flutter-independent package is `packages/foresight_core`. Desktop files such as `domain.dart` and `store.dart` remain compatibility exports for existing callers. Application operations, imports, source recovery, Google sync, model configuration, capture persistence, inactivity shutdown, and note enhancement live in the core. The desktop retains dialogs, browser interaction entrypoints, shortcuts, presentation, and graph layout/rendering; graph publications are validated and committed by the service.

## Desktop and core boundaries

The desktop accepts `DesktopConnection`; production connects `RemoteDomain` to the service. Generation, recording, Google account, and connected-source proxies implement narrow capability interfaces instead of inheriting worker implementations. Widget fixtures provide an explicit test adapter for that same connection contract.

`_WorkspaceState` coordinates navigation, lifecycle, and the shared update boundary. Sources and graph, chat, meetings, settings and models, and integrations each have a controller that owns their mutable state and screen widgets. SQL lives behind named core `Store` queries. Saved output statistics cache their text scan by database revision and are labelled as words because historical records do not contain tokenizer usage.

`labels.auto_assign` acquires any missing embeddings, validates the source snapshot, then plans propagation and publishes all associations, the label cluster, and graph invalidation in one write transaction. A failed label write rolls back the entire publication. `Application` owns answer orchestration and delegates retrieval, conversation memory, generation, and persistence to a per-request `ConversationAnswer`. `Domain` owns lower-level source and model services and receives a `ModelGate`; it never constructs an `Application`.

## Build

Use the root build requirements and commands. Dart must be on PATH (the Flutter SDK supplies it). `tools/build.sh` builds the native components, checks/tests the core, compiles the service and MCP executables, and checks/tests/builds Flutter. `tools/package.py` includes all three entrypoints and their runtime libraries:

- `dist/open-foresight/open-foresight`: desktop.
- `dist/open-foresight/open-foresight-mcp`: MCP stdio server.
- `dist/open-foresight/open-foresight-service`: foreground service and administration commands.

For just the Dart executables after native compilation:

```sh
cd packages/foresight_core
dart pub get --enforce-lockfile
dart analyze
dart test
cd ../..
mkdir -p build/application
dart compile exe packages/foresight_core/bin/service.dart -o build/application/foresight-service
dart compile exe packages/foresight_core/bin/mcp.dart -o build/application/foresight-mcp
```

A packaged service or MCP adapter requires no Flutter SDK or Dart SDK. Reads work without an open desktop window; protected operations need the visible desktop approval flow. The existing native runtime and model prerequisites still apply. No model downloads occur merely because an MCP client connects.

## Configure an MCP client

Use the packaged stdio launcher:

```json
{
  "mcpServers": {
    "open-foresight": {
      "command": "/absolute/path/to/dist/open-foresight/open-foresight-mcp"
    }
  }
}
```

The default profile is `$XDG_DATA_HOME/open-foresight`, normally `~/.local/share/open-foresight`. Desktop and MCP must resolve the same profile and runtime directory. To choose an isolated profile, set both `FORESIGHT_DATA` and `FORESIGHT_RUNTIME` in the launcher environment:

```json
{
  "mcpServers": {
    "open-foresight": {
      "command": "/absolute/path/to/dist/open-foresight/open-foresight-mcp",
      "env": {
        "FORESIGHT_DATA": "/absolute/private/profile",
        "FORESIGHT_RUNTIME": "/absolute/private/runtime"
      }
    }
  }
}
```

Both directories must be owned by the current user and inaccessible to other users. The launcher creates missing directories with mode 0700, and the service socket uses mode 0600. It opens no TCP listener. The adapter uses the pinned `mcp_dart` SDK for protocol negotiation, validation, stdio framing, progress, and cancellation. Stdout contains only MCP messages; diagnostics go to stderr.

## Agent approval and file access

Notes, source reads, local search, and local answers remain available to same-user clients. Agent requests to import, delete, clear the workspace, configure models/accounts, or send a question to web search require an **Allow once** decision in the desktop. Without a connected desktop they fail. The desktop uses a random private capability to register its connection; approval IDs are bound to the requesting operation and expire after two minutes. A client cannot approve its own request by declaring a desktop role.

Direct desktop Start/Resume controls provide user consent without a second dialog. External recording start or resume requests require a visible desktop confirmation. The persistent recording controls show elapsed time, waveform, pause/resume and **Stop transcribing**. Hiding or closing the desktop stops capture and finishes transcription. Disconnecting just the MCP client leaves capture running while the desktop indicator remains visible.

Import folders start empty. Selecting a local file or folder through the desktop adds its containing folder to the profile's import roots. Agents can then request imports within those roots, subject to approval. Canonical paths reject symlink escapes and always deny the application profile, including Google tokens and the desktop capability. Only regular files up to 10 MiB are accepted. Directory imports inspect at most 10,000 entries, import at most 1,000 supported files, and accept at most 100 MiB in total. Extraction output is bounded and external extractors have a 30-second deadline. These checks also apply when refreshing previously imported files.

The capability file is not a sandbox against arbitrary malicious programs running as the same OS user. It separates normal agent RPC access and imported untrusted content from the desktop approval connection; private OS profile permissions remain required.

## Tools

| Tools | Behavior |
| --- | --- |
| `audio_capabilities` | Inspect audio backend, permissions, and system settings guidance without capturing. |
| `audio_request_microphone`, `audio_request_system` | Explicitly request microphone or system audio consent in an interactive session. |
| `get_status` | Model/helper readiness, index state, service PID, active capture, profile revision, and Google connection status. |
| `list_sources`, `get_source`, `search` | Source metadata/full text and relevant passages with IDs, titles, revisions, and scores. Search limit is 1–100. |
| `import_text`, `import_file`, `import_url`, `import_directory`, `refresh_sources` | Import/update sources and index them using the application's workflows. Supported local files: UTF-8 text/Markdown, PDF, RTF. |
| `delete_source` | Tombstone the source, remove indexed evidence, and preserve retry/recovery behavior. |
| `list_notes`, `save_note` | Read/create/edit personal notes. |
| `list_meetings`, `create_meeting`, `get_meeting` | Meeting metadata, original notes, transcript segments, generated artifacts, and edits. |
| `save_meeting_notes`, `import_transcript` | Save original notes or append final transcript evidence; index transcripts. |
| `generate_meeting_artifact`, `enhance_meeting_notes`, `edit_artifact` | Generate summaries/actions, enrich notes using evidence, or retain edits separately from generated originals. |
| `start_recording`, `pause_recording`, `resume_recording`, `stop_recording` | Use the shared microphone/playback capture and transcription lifecycle. Pause releases capture devices and retains queued pre-pause speech; Resume reacquires the same routes. |
| `ask` | Generate a grounded answer with checked citations using the configured local generator. |

Tool failures return `isError: true` with a useful message and a structured `error` containing a stable `code` and `message`. Codes distinguish invalid arguments, missing resources, busy workers, cancellation, unavailable services, denied access, and internal failures. An `unavailable` error may also carry a `reason`: `closing` (the service refused the request before running it, so retrying is safe), `outcomeUnknown` (the request was sent and may have committed), or `notSent` (it never reached the service). Invalid protocol requests are handled by the SDK. Tools expose their input schemas and effect annotations. Clients may supply a progress token for started/ongoing/completed notifications. `ask` returns the final checked answer; provisional generation remains internal to the service/desktop stream.

The operation identities, tool schemas, descriptions, annotations, and helper readiness policy live in `packages/foresight_core/lib/src/operations.dart`. Application dispatch switches exhaustively over that enum; desktop command interfaces and remote facades accept those identities and convert them to wire names at the transport. The RPC contracts CI job checks dispatch coverage, rejects raw desktop operation names, and invokes every MCP tool over stdio against a controlled service socket.

The owned helper API is `foresight.helper.v1.RagService`; all failures use non-OK gRPC statuses. Legacy success acknowledgement fields retain their wire tags, but carry no error channel. The immutable recovered descriptor preserves historical message presence and edition features. `tools/generate_bindings.py` versions its package and source name for production. To regenerate Dart bindings, activate `protoc_plugin 24.0.0` and run `python tools/check_dart_bindings.py --write`. CI regenerates all three schemas and rejects drift; descriptor snapshots also check the control and web-content RPC shapes, defaults, and reserved tags.

## Shared operation and lifecycle

Launching either client attaches to an existing service or starts one. A per-profile OS lock prevents two launchers from creating competing owners. Clients can disconnect independently. Closing or hiding the desktop stops capture because its on-screen indicator is no longer available. Closing the MCP adapter leaves the meeting running while the desktop remains visible; neither client disconnect unloads the generator.

There is one recording and one active generation per profile. A second recording or simultaneous generation returns a busy error. Model configuration is rejected while another configuration, generation, or recording is active. Clients receive change events; the desktop observes content written through MCP and reconnects after a service restart. MCP reconnects on its next request after a lost connection. An in-flight mutation that loses its connection fails visibly and is not replayed automatically.

A closing service answers every request it will not run with a closing refusal (`unavailable`, reason `closing`, and the unchanged text "Application service is shutting down; retry after it exits."), including requests on new connections while it drains. Requests already in flight get `unavailable` with reason `outcomeUnknown` before their connection closes. A bare EOF means the service crashed. The desktop and MCP send a refused request once more to the next owner, after the startup handoff; they never resend one whose outcome is unknown. The owner removes its sockets before its endpoint record and releases its profile lock last, so a record always names a live, draining or crashed owner. A replacement that fails to start records why in a per-launch status file, and the launcher reports that cause at once.

Cancellation belongs to the connection and request that started an operation. Canceling one answer cannot cancel another client's generation. Canceled model setup cannot replace the previous registration. Bulk import cancellation stops further files; already committed content and accepted indexing work are retained. Stopping a recording finishes transcription even if the requesting client disconnects. Source indexing/deletion are serialized, source revisions gate index publication and citations, and changed original notes invalidate in-flight enhancement output.

Content is shared: editing/deleting an existing source or note is visible to both clients. Supplying an existing ID to an edit operation replaces its current text; the service does not merge concurrent edits. General desktop Ask uses its own answer conversation; meeting Chat uses a separate `meeting:<id>` conversation for each meeting. Each MCP connection gets a separate follow-up/history context, with saved answers still retained in the shared profile.

Internal answer commands and streams accept an optional `meeting_id`. The service validates that meeting, chooses its canonical conversation, and atomically saves each answer with its meeting association. The desktop does not infer ownership from the latest global answer row. This isolates follow-up questions and generated-answer history; retrieval still searches the shared indexed knowledge sources. Previously saved answer conversations are preserved.

URL imports accept globally routable HTTP/HTTPS text pages by default. Every redirect is checked, HTTPS downgrades are refused, and DNS results are pinned for the connection. In the desktop URL dialog, enable **Allow private network addresses** only for a page you intend to read from your local network. MCP `import_url` and `refresh_sources` (service `sources.import_url` and `sources.refresh`) accept `allow_private_network: true` for an explicit per-request opt-in; it is false by default and is not retained for later refreshes. Downloads are limited to 5 MB and 30 seconds; decoding and HTML parsing run in a disposable isolate with a three-second deadline. The response charset controls decoding, including GBK, Big5, and Shift_JIS.

Google credentials and refreshes belong to the service. The service streams a sign-in URL to the desktop, which opens the browser even when MCP started the service without a graphical environment. Browser sign-in and consent are started explicitly from the desktop; MCP does not expose credentials or authentication tools. Google reminders and refresh timers run in the service, independent of an open desktop window.

Inspect or stop the service explicitly:

```sh
dist/open-foresight/open-foresight-service --status
dist/open-foresight/open-foresight-service --stop
```

`--stop` gracefully finalizes active recording, and returns only once the
service has released its profile (its lock is free or its process is gone),
failing if that takes more than 30 s after the service closed its
connections. It can therefore take as long as the helper's shutdown plus
30 s, so scripts should allow it at least 60 s. If the service stopped
without a clean shutdown, `--stop` still succeeds and prints a warning; the
next start recovers its runtime. For installers,
`--stop-if-idle[=PID]` uses the private `service.stop_if_idle` operation. It
atomically refuses active/finalizing recording and in-flight operations, then
blocks new calls before shutdown begins. It acknowledges success only after
resource cleanup; EOF, a failed close, or unverified helper ownership fails the
command. The optional PID and packaged installation/revision identity pin the
owner authenticated by the installer. Normal `--stop` behavior is unchanged.
Older services that lack idle-only shutdown must be stopped explicitly before
upgrading; installers never fall back to an unverified signal/EOF shutdown.

 The next client starts a service again. An unexpected service crash marks unfinished recordings interrupted on restart and resumes pending source work. Stop an older, pre-service version of the desktop before upgrading a profile; that version does not participate in service ownership. Schema additions retain existing source, note, transcript, artifact, and model records.

## Verification

```sh
cd packages/foresight_core && dart analyze && dart test
cd ../../apps/desktop && flutter analyze && flutter test
cd ../..
.venv/bin/python -m pytest
ctest --test-dir build --output-on-failure
python3 -m pytest tests/service -v
```

`tests/service` runs actual service/helper/MCP subprocesses with controlled embedding, generation, speech, and capture fixtures. It checks shared writes/search, launch races, cancellation ownership, capture surviving disconnection, stale socket recovery, canceled model registration, desktop facade reconnection, browser invitation forwarding, and early OAuth cancellation. Set `FORESIGHT_DART_EXECUTABLE` if Dart is not on PATH.

The native UI gate requires a separately created private Agent Desktop session:

```sh
FORESIGHT_DESKTOP_SESSION=<owned-private-session> \
FORESIGHT_FLUTTER_EXECUTABLE=/absolute/path/to/flutter \
python3 -m pytest tests/service/test_service_process.py::test_native_desktop_and_mcp_share_service -v
```

This launches the actual Flutter app alongside MCP and checks visible meeting updates, shared capture, desktop teardown/restart, transcription, summary persistence, and the read-only desktop connection. Its evidence is written to `test-results/desktop-service-integration.json`. Controlled fixtures verify ownership and data flow; they do not measure real-model accuracy or physical microphone quality. `tools/test_meeting_workflow.py` launches `apps/desktop/integration_test/meeting_workflow_test.dart` on an owned Agent Desktop display. The virtual-audio acceptance gate runs that same test in its private PipeWire session and skips window capture there.

## macOS runtime and profile ownership

On macOS the default profile is `~/Library/Application Support/Open Foresight`.
Existing profile ancestors are canonicalized, so a symlink alias identifies the
same profile. `FORESIGHT_DATA` and `FORESIGHT_RUNTIME` remain explicit overrides.
The default runtime is a short private `$TMPDIR/of-<first 12 characters of profile hash>`
directory under the per-user macOS temporary directory. Long explicit paths are
rejected before attempting to bind a Unix socket.

The service takes a nonblocking POSIX advisory lock on
`<canonical profile>/.application.lock`, independent of runtime overrides. Its
private `.application-endpoint.json` records the active runtime directory. Clients
validate that directory and attach to the recorded endpoint. A service launched
with another runtime cannot acquire a competing profile writer. An unclean shutdown retains its runtime endpoint so a replacement service can adopt surviving helpers even when launched with a different runtime override. A clean shutdown closes workers and removes the endpoint record, allowing the next launch to relocate its runtime. Endpoint records are published only after acquiring the profile lock and binding a socket. Disconnected mutations with unknown commit state are still never replayed.

Installed executables discover `Contents/Resources/runtime.json` in the nearest
enclosing `.app`. It maps `FORESIGHT_*` resource-path keys to paths relative to that
Resources directory. For bundled executables, this manifest owns resource and
code paths, the runtime revision, and the query terms URL; environment values or
a startup handoff cannot override them. Profile/runtime paths and allowlisted
scalar settings, such as backend/device choices and distribution API keys, remain
overridable. Development executables may use explicit resource and code paths.
Nested service bundles can refer to the outer app through relative `../` paths.
This map must contain the service, helper, native library, model runners,
audio-device adapter, and notification adapter as applicable. All resolved values propagate to detached
service launches and helper subprocesses. Packaged Mac services launch through
LaunchServices with a single `FORESIGHT_STARTUP_ENV` path in argv. Runtime and
profile overrides, including distribution keys, travel through a private 0600
file that the service reads and deletes before resolving its resources. macOS
default sockets live under its private per-user `TMPDIR`. This lets the service own its app
identity without a Flutter window. Plain development executables launch directly.
Service startup stderr is retained in the private runtime directory as
`service-startup.log`. The installed app must still verify the actual TCC
attribution. Profile content and downloaded models
remain outside the bundle. With no HOME environment variable on macOS, the system
user directory is obtained from Directory Services.

The Mac audio discovery adapter uses `FORESIGHT_AUDIO_DEVICES --list-devices` and
returns a JSON array of `{ "id": "stable-device-id", "label": "Device", "playback": false }`.
The Mac notification adapter uses `FORESIGHT_NOTIFICATIONS --title TITLE --message MESSAGE`;
errors are surfaced rather than treated as successful delivery. Discovery and
configuration do not request capture permission. Real TCC identity, recording,
model execution, and signed installed-bundle behavior require separate integration
gates; these interfaces alone do not prove those workflows.

`audio.capabilities` (MCP: `audio_capabilities`) inspects the service's audio
backend and permission state without prompting. `audio.request_microphone`
(MCP: `audio_request_microphone`) explicitly requests microphone authorization in
the service process; the blocking native request runs on another Dart isolate.
An improperly packaged service with no microphone purpose string receives an
actionable setup failure before entering the OS permission API.
`audio.request_system` (MCP: `audio_request_system`) explicitly exercises a short
system-audio tap consent request in the service, also off the event loop and
requiring the system-audio purpose string. Its JSON preserves `system_audio`
(`unknown`, `pending`, `denied`, `unavailable`), `system_audio_request`,
`permission_verified: false`, and native code/message/settings guidance. There is
no public CoreAudio permission preflight: a completed request or a successfully
started silent tap does not prove permission. Connecting, listing MCP tools, or
querying capabilities never invokes either permission request. User consent and
actual captured audio remain separate installed-app checks.

Configured generation and speech models retain runner provenance when an explicit
registration selects the current `FORESIGHT_LITERT_RUNNER` or
`FORESIGHT_WHISPER_RUNTIME` executable inside the canonical installation root.
The model row and its `modelRuntimeResource.<kind>` preference are committed
atomically. Metadata records the resource key, original runtime path, model
digest, and backend. After the app moves, model restoration, recording, readiness
checks, and setup UI resolve that resource from the current bundle without
rewriting the original row. A missing/non-executable resource or one pointing
outside the current installation is not substituted. External registrations,
legacy rows without provenance, and mismatched/corrupt metadata retain their
original runner paths. Re-register a legacy bundled runner explicitly through
model setup after backing up the profile; no automatic legacy migration guesses
ownership from a filename or an `.app` directory name.

Before native workers start, the shared runtime adapter copies its supported
settings into native process state using `fs_set_runtime_environment`. A Dart
configuration map alone cannot configure C/C++ `getenv` consumers. LiteRT and
Python bytecode caches default to `<profile>/cache/litert` and
`<profile>/cache/python` when an installed native runtime is configured.

Packaged runtimes also set `FORESIGHT_INSTALL_ROOT` to the canonical outer `.app`
and `FORESIGHT_RUNTIME_REVISION` to their build revision. Before loading native
code, opening the database, or starting workers, the service takes a shared,
nonblocking POSIX lock at
`/tmp/of-install-<uid>-<sha256(canonical app path) first 24 hex digits>/lock`.
The private directory is 0700 and the lock is 0600. The descriptor remains open
for the service lifetime. The installer takes the exclusive version of that
same lock after explicitly stopping services and holds it through revalidation
and replacement. A service launched during replacement fails with an actionable
update-in-progress message before it opens profile state or native components.

Status includes additive `application_api_version` (currently 1),
`installation_root`, and `runtime_revision` fields. Clients carrying a packaged
revision validate all three before attaching, including an already-running
service from another app copy or revision. Canonical aliases of the same app
remain compatible. Mismatches require the user to explicitly stop the existing
service; clients neither stop it automatically nor replay mutations. Development
clients without a packaged revision keep the existing attachment behavior.

macOS PDF and RTF imports use the bundled `FORESIGHT_FILE_PARSER` executable,
backed by PDFKit and AppKit's attributed-string RTF reader. The CLI accepts
`--pdf PATH` or `--rtf PATH`, writes extracted UTF-8 text only to stdout, and
writes errors to stderr. It opens no Flutter window or permission dialog. A
locked PDF requires an explicitly unlocked copy; scanned PDFs without selectable
text report that OCR is needed. Empty or invalid documents fail before source
creation. File-access failures direct the user to Files and Folders permissions
or a readable copy. Linux retains its existing `pdftotext`/`unrtf` adapters and
existing stored provenance remains readable.

The actual Mac extractor can be checked with:

```sh
swiftc -O native/file_parser.swift -o /tmp/foresight-file-parser
python3 tests/integration/test_file_parser.py /tmp/foresight-file-parser
```

These developer tests generate real Unicode PDF/RTF, password-protected, empty,
malformed, and unreadable fixtures. The installed extractor itself requires no
SDK, Python interpreter, or external document-processing tools.

## Meeting and worker recovery

Committed transcript segments remain indexed when a later speech segment fails or finalization times out. The meeting becomes `interrupted` and retains its transcript instead of becoming a failed, unindexed meeting. Speech segments have a 60-second deadline and Stop allows at most 90 seconds for queued speech work before terminating it; already committed rows remain available. Startup marks meetings left recording, transcribing, or paused as interrupted.

Whisper retries a failed GPU invocation once with `-ng` on CPU, preserving the original audio and discarding the failed attempt's output. A LiteRT GPU failure rebuilds the generation worker on CPU for the next answer. The current answer fails visibly; tool calls are not replayed automatically. Native capture queue overflow emits an interruption with discarded-byte accounting, which is stored alongside the meeting transcript.

Linux installers with PipeWire outside `/usr/bin` configure the native library
with `-DFORESIGHT_PW_RECORD_EXECUTABLE=/absolute/installation/path/pw-record`.
This trusted build-time path defaults to `/usr/bin/pw-record`; native capture never
searches the process `PATH`. An explicit absolute executable supplied through
`FORESIGHT_CAPTURE_RUNTIME` still takes precedence for controlled deployments.

`application.resume` explicitly resets an exhausted helper restart budget and starts the helper again. It preserves a healthy helper. An incompatible helper transport requires an application-service restart instead of retrying a terminated connection. Shortcut IPC acknowledges that a command was queued; failures appear in the desktop workspace and shortcut status.

New `models.generation` registrations default to `litert_lm` when `backend` is omitted. Explicit `llama_cpp` registrations and previously stored registrations retain their selected backend.


Automatic question-model downloads require a genuine publisher terms URL in the
`FORESIGHT_QUERY_TERMS_URL` distribution setting (the same repository Actions
variable populates macOS packages). Acknowledgment is scoped to the authenticated
model digest and enforced by the service before acquisition. Distributions that
have not supplied terms cannot download this opaque model automatically.

Local source links reveal their file in Finder or the Linux file manager instead
of invoking a default application. Opening allowlisted files under revocable
import grants remains deferred with the typed import-grant architecture. Approval
dialogs label peer identity as unverified, highlight risky options and limit
repeated identical requests; OS-verified requester attribution and distinct local
capture gestures remain deferred with the desktop peer-verification design.
