# Windows support implementation plan

Add Windows support on the architecture the Linux and macOS builds already use. Flutter handles presentation, the Dart application core and service handle business operations, a separate helper handles retrieval, and native workers run the models and audio capture. As on the other platforms, desktop and MCP clients must share one service, one database writer, one recording session, and one model lifecycle per profile.

The port forces one choice. The native layer is POSIX-only. It can either gain Windows branches in C++, or be replaced by a Rust implementation shared by all three platforms. Phase 0 decides which. Windows support does not wait for the Rust work.

Build, bundle, and validation records will go in their own documents once work starts, following the macOS pattern.

## Baseline and scope

Reviewed on 2026-10-16:

- Local checkout: `main`, revision `d15a096`.
- macOS support is still in integration (see the [validation ledger](macos-validation.md)). Several files this plan changes are also changing for macOS: `platform_services.dart`, `profile_paths.dart`, `foresight_native.cpp`, and the service tests. Land shared changes as small commits on `main` rather than on a long-lived Windows branch.

Proposed first release target: Windows 11 on x86-64, distributed as a signed per-user installer outside the Microsoft Store. Windows 10 reached end of support on 14 October 2025 and is out of scope. Windows on Arm is follow-up work, because LiteRT-LM publishes Windows binaries for `win_amd64` only.

The release scope matches macOS:

- source import and search
- graph and notes
- local answers
- microphone and system-audio transcription
- Google connections
- desktop integration
- headless MCP

## What stays fixed

- **Ownership rules.** The application service owns:
  - every database write
  - models
  - imports
  - Google sync
  - recording

  The desktop reads SQLite read-only and sends changes through the service. MCP is a stdio adapter whose stdout carries protocol messages only. Closing a client never stops a recording.
- **Wire contracts.** Changes to these are additive only, and no channel is renamed:
  - the C ABI in `native/foresight_native.h`
  - the gRPC services in `proto/`
  - the worker JSON-lines protocol
  - the audio event channel names, including `foresight.linux/audio_state_v1`
- **Profile schema** and database namespaces.
- **Where platform differences live.** They go behind the functions in `platform_services.dart` and `profile_paths.dart`, and behind the native ABI. Do not scatter `Platform.isWindows` checks through domain code.

## Where Windows breaks current assumptions

The macOS port could reuse POSIX code from Linux. Windows has no POSIX layer, so each item below is new work:

| Area | Current implementation | Windows problem |
| --- | --- | --- |
| Service and helper transport | Unix sockets: `service.dart` for desktop/MCP to service; `helper.dart` and `services/helper/main.cpp` for service to helper over gRPC | `dart:io` supports Unix sockets on Linux, macOS, and Android only ([API docs](https://api.dart.dev/stable/3.0.0/dart-io/InternetAddressType-class.html)), and grpc-dart has no named-pipe transport |
| Worker processes | `child_process.h`, `portable_process.h`, and `foresight_native.cpp` use `fork`/`posix_spawn`, `PR_SET_PDEATHSIG`, process groups, `kill(-pgid)`, and `waitpid` | None of these exist on Windows |
| Private files | `privateDirectory` plus call sites in `service.dart`, `google_auth.dart`, and `commands.dart` run `/bin/chmod`, `/usr/bin/stat`, and `/usr/bin/id`; the helper checks `st_uid`/`st_mode` and uses `flock` | Windows uses ACLs, not POSIX mode bits |
| Shutdown | SIGTERM to the service (`bin/service.dart`) and to the helper (`helper.dart`) | Dart cannot watch SIGTERM on Windows, and `Process.kill` ends a process without sending a signal |
| Process identity | `fs_process_matches` reads `/proc/<pid>` (Linux) or uses `proc_pidpath` (macOS) | There is no `/proc`, and no stable documented API for reading another process's command line |
| Audio | `pw-record` and `pw-dump` subprocesses on Linux; Core Audio in `macos_audio.mm` | Needs WASAPI |
| Desktop integration | XDG portal over D-Bus and Hyprland (`global_shortcuts.dart`, `hypr_shortcuts.dart`), `notify-send`, `xdg-open`, autostart `.desktop` entry | Needs Win32 equivalents |
| Imports | `pdftotext` and `unrtf` on Linux; `file_parser.swift` on macOS | Needs a bundled extractor |
| Build and packaging | bash scripts, `ldd`, `.so` names, gcc-style flags, Linux package builders | Needs MSVC builds, a DLL layout, an installer, and Authenticode signing |

Inference is in better shape on Windows than it was on macOS:

- The pinned [LiteRT-LM 0.18.0](https://pypi.org/project/litert-lm-api/0.18.0/#files) release publishes a `win_amd64` wheel. It contains:
  - `litert_lm/litert-lm.dll`, the Windows build of the C runtime the Linux build extracts as `liblitert-lm.so`
  - the DirectX shader compiler (`dxcompiler.dll`, `dxil.dll`) for its GPU path
  - an Intel OpenVINO dispatch library
- ONNX Runtime and whisper.cpp, including its Vulkan backend, build on Windows.

The native `foresight-model` worker should therefore run on Windows. macOS still uses the Python adapter.

## Native-layer decision: Rust or C++

Three pieces must change in either language:

- the worker launcher: `services/helper/child_process.h` and `native/portable_process.h`
- the helper's startup and storage checks: `services/helper/main.cpp` and `model.h`
- the process, capture, and identity code in `native/foresight_native.cpp`

Together they are about 1,600 lines of dense C++.

**Rust route (preferred, subject to the Phase 0 gate).** Replace `services/helper` and `native/foresight_native.cpp` with Rust that keeps every external contract:

- **`crates/foresight-process`** owns worker processes and their piped stdio:
  - Linux keeps the parent-death signal, set from a dedicated creating thread, and process groups.
  - macOS keeps the supervisor semantics from `portable_process.h`.
  - Windows uses a [Job Object](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) with kill-on-close. The child is assigned to the job while still suspended, and only the worker's own pipe handles are inheritable.
- **`crates/foresight-native`** is a `cdylib` that exports ABI v1 from `foresight_native.h` unchanged. `macos_audio.mm` stays Objective-C++ and is compiled through the `cc` crate. Windows WASAPI capture lives in this crate.
- **`crates/foresight-helper`** is generated with tonic and prost from the existing protos and uses `rusqlite` with bundled SQLite. It keeps the same schema, revision journal, crash-injection hooks, and deterministic test model.

The Rust code replaces the C++ on Linux and macOS as well. Keeping two implementations of this layer is not an option.

Benefits of the Rust route:

- one process-lifecycle implementation instead of three
- no C++ gRPC, protobuf, or abseil build on any platform
- memory safety in the code that parses worker output and handles PIDs

**C++ route (fallback).** Add `_WIN32` implementations to `portable_process.h`, `child_process.h`, `foresight_native.cpp`, and the helper. Build gRPC and protobuf for MSVC through vcpkg.

On either route, keep `services/inference` (`foresight-model`) in C++. Its Windows changes are small:

- `LoadLibraryW` instead of `dlopen` in `litert.h` and `minilm.h`
- a handle-based `fd_stream.h`
- MSVC warning flags

It also carries the grounding and tokenizer logic that the `native_grounding` test covers. Porting it is separate follow-up work.

Neither route changes the transports. Both the service and the helper are reached by Dart clients, so Windows uses authenticated loopback TCP either way (Phase 1). Audio capture, ACLs, the installer, and signing are the same amount of work in either language.

**Decision gate** (end of Phase 0). The Rust route is chosen if both of these pass:

- A Rust helper passes the existing `helper_contract` test on Linux unchanged. That test launches `ForesightHelper` as a black box, so it needs no edits.
- `foresight-process` passes a worker-lifetime test on Linux and Windows: kill the owner, then confirm the worker exits.

If the spike misses the gate within its budget, take the C++ route.

## Phase 0: Prove feasibility and choose routes

Budget: 4–6 engineering days, plus 2–3 days for the Rust spike.

- **LiteRT-LM:**
  - Extend `tools/prepare_litert.py` to extract the Windows DLLs from the pinned `win_amd64` wheel, with SHA-256 checks.
  - Confirm the DLL exports the C API declared in `third_party/litert_lm/c`.
  - Build `foresight-model` with MSVC. Run CPU grounded generation and EmbeddingGemma 2, then the GPU backend.
  - Record which GPU path LiteRT-LM actually uses.
- **ONNX Runtime and Whisper:** fetch the pinned ONNX Runtime 1.31.0 Windows x64 archive and run the MiniLM compatibility model. Build `whisper-cli` for Windows (CPU and Vulkan) and transcribe `tests/fixtures/audio/jfk.wav`.
- **Transport:**
  - Prototype a Dart service on 127.0.0.1 with a token handshake.
  - Have grpc-dart call a helper that checks a token in call metadata.
  - Confirm Windows Firewall does not prompt for loopback-only binds.
- **Audio:** capture 3 seconds each of microphone input and WASAPI loopback, as mono 16-bit PCM at 48 kHz, in the style of `foresight-audio --probe`.
- **Installer:** check that a third-party MCP host can launch `foresight-mcp.exe` by absolute path from each candidate install location. This decides the installer technology (see Phase 5).
- **Rust spike:** run it against the decision gate above.

Exit: the native route, transport, audio route, and installer decisions are recorded, and embedding, grounded generation, and transcription probes succeed on Windows.

## Phase 1: Transport and core platform services

Budget: 4–6 engineering days. This phase needs no models, so it can start while Phase 0's inference and audio probes are still running.

| Existing assumption | Planned change |
| --- | --- |
| Desktop and MCP clients connect to `application.sock`, which the service binds in `ApplicationService._start` | On Windows, bind 127.0.0.1 on an ephemeral port. Extend the atomically written `.application-endpoint.json` with the transport, port, and a random 256-bit token. Clients send the token as their first message. The service compares it in constant time and drops connections that do not authenticate within a short deadline; this also rejects browser requests to localhost. Linux and macOS keep Unix sockets. |
| The service reaches the helper at `helper.sock` (`Helper` in `helper.dart`) | Same pattern: the helper binds 127.0.0.1:0, reports the port on its existing `ready` line, and requires the token in gRPC metadata. Pass the token through the environment, never on the command line. |
| A stale socket file is deleted before binding | Ownership already rests on the `.application.lock` file lock, which Dart supports on Windows. An endpoint record is stale if its port refuses the connection or fails authentication. |
| `privateDirectory` and other call sites run `chmod`, `stat`, and `id` | Add `protectDirectory` and `protectFile` platform functions, and route every call site through them: `platform_services.dart`, `service.dart`, `google_auth.dart`, and `commands.dart`. On Windows, create files and directories with a protected DACL that grants access only to the current user and SYSTEM. Verify the owner SID and ACEs before use. Implement this once in native code so the helper shares the same check. |
| `profile_paths.dart` uses `HOME` and XDG, and joins canonical paths with `/` | Use `%LOCALAPPDATA%\Open Foresight` for data and `%LOCALAPPDATA%\Open Foresight\runtime` for runtime state. Normalize drive-letter case, path separators, and junctions so every entry point derives the same profile identity. Keep the `FORESIGHT_DATA` and `FORESIGHT_RUNTIME` overrides. |
| `foresight-service --stop` sends SIGTERM; the helper is stopped with SIGTERM, then SIGKILL | Extend the existing `service.stop_if_idle` request with an unconditional stop that finalizes any recording first. Add an additive `Shutdown` RPC to `HelperControl`. Keep signals on Linux and macOS. |
| `fs_process_matches` reads `/proc` or calls `proc_pidpath` | On Windows, call `OpenProcess` with limited query rights, then check `QueryFullProcessImageNameW`, the token's owner SID, and `GetProcessTimes` against the helper's instance stamp, which already encodes the PID and start time. Do not read other processes' command lines. |
| `RuntimeConfiguration` finds resources through the `.app/Contents/` path marker and treats `/`-prefixed values as absolute | Add a Windows rule: `runtime.json` sits beside the installed executables, and drive-letter and UNC paths count as absolute. The native library is named `foresight_native.dll`. |
| `systemMemoryGb` reads `/proc/meminfo`; `openPlatformUri` runs `xdg-open` | Use `GlobalMemoryStatusEx` for memory and `ShellExecuteW` for links. Avoid `cmd /c start`, which mangles URLs that contain `&`. |
| The installation lock lives under `/tmp/of-install-<uid>-…` | Use a per-user lock file under `%LOCALAPPDATA%\Open Foresight\install`. |
| The Dart `sqlite3` package loads the system SQLite | Bundle a pinned `sqlite3.dll` and load it explicitly, rather than `winsqlite3.dll`, whose version changes with the OS. |

Also check that starting the service (a console program) detached from the GUI does not open a console window.

Exit: the `packages/foresight_core` tests, `service_ownership_test`, and the storage-only `tests/service` suite pass on Windows. They cover:

- launch races
- two MCP clients and the desktop sharing one service owner
- stale-endpoint recovery
- cancellation
- restart

Linux and macOS checks stay green.

## Phase 2: Native layer

Budget: 8–12 engineering days on the Rust route, including Linux and macOS parity; 5–7 on the C++ route.

Rust route:

1. Build `foresight-process` for all three platforms, with the worker-lifetime tests.
2. Build `foresight-helper`. Before it replaces the C++ helper on Linux, it must pass `helper_contract`, `helper_model_lifetime` (ported to launch the helper binary), and `tests/service`. Then validate it in macOS CI, then on Windows.
3. Build `foresight-native` with ABI v1. `tests/integration/test_native.py` and `test_native_process.py` load the library through ctypes and must pass unchanged on Linux and macOS.
4. Remove the replaced C++ once all three platforms pass.

C++ route:

- Use `CreateProcessW` with an explicit inherited-handle list and a kill-on-close Job Object in `portable_process.h` and `child_process.h`.
- Use `LockFileEx` and the ACL check in the helper, with a TCP listener that requires the token.
- Get gRPC, protobuf, OpenSSL, ICU, and nlohmann-json from a pinned vcpkg manifest.

Both routes:

- Port `foresight-model` to MSVC (the `dlopen` to `LoadLibraryW` and `fd_stream.h` changes above).
- Port `tests/helper/*.cpp`, which use `fork`/`execl` and Unix sockets.

Exit: the helper and native tests pass on Windows. Real embeddings, grounded generation, cancellation, and worker cleanup after the service is killed all pass with the Windows runtimes.

## Phase 3: Recording

Budget: 5–7 engineering days.

- **Capture.** Implement capture behind `fs_capture_start`, keeping the existing frame and event contract:
  - Microphone: shared-mode WASAPI on the capture endpoint.
  - System audio: [WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) on the render endpoint.
  - Convert the shared-mode mix format (usually 32-bit float stereo) to mono signed 16-bit at the requested rate.
  - Keep 40 ms playback frames (3,840 bytes at 48 kHz).
- **Silence during loopback.** Loopback delivers no packets while nothing is playing. Fill those gaps with silence timed from the audio clock, so frame cadence, timestamps, and inactivity auto-stop behave as they do on Linux.
- **Device selection.** Keep the distinction between following the default device and pinning a specific one:
  - For `auto`, reopen the stream when the default device changes (`IMMNotificationClient`).
  - For a pinned device, report a gap and then a failure after the existing retry policy, as PipeWire does with `node.dont-fallback`.
  - Handle `AUDCLNT_E_DEVICE_INVALIDATED`.
- **Permissions.** Report permission state through `fs_audio_capabilities`, with backend `wasapi`:
  - Microphone access for desktop apps can be turned off in Settings → Privacy & security → Microphone. Report that as denied, distinct from "no device" and from valid silence.
  - `fs_audio_request_microphone` opens that Settings page.
  - Loopback capture needs no permission.
- **`foresight-audio.exe`.** Give it the same `--list-devices`, `--capabilities`, and `--probe` contract as `macos_audio_cli.cpp`. `audio_devices.dart` uses it for device listing through `FORESIGHT_AUDIO_DEVICES`.
- **Testing.** Test these conditions:
  - default-device changes
  - USB device removal
  - Bluetooth headsets switching profiles
  - sleep and resume
  - service crashes
  - microphone access revoked during a recording

Exit criteria:

- A real meeting captures both channels and saves final transcripts.
- Either client can observe the recording.
- Closing the client that started it leaves recording active.
- Stop flushes the transcript.
- A crash leaves an interrupted state that can be recovered.

Repeat these checks from an MCP host with no desktop window open.

## Phase 4: Desktop integration, imports, and model setup

Budget: 4–6 engineering days. This can start after Phase 1, while audio work is in progress.

- **Runner.** Generate and commit `apps/desktop/windows`. In the runner, implement the `foresight/window` `activate` channel, single-instance forwarding, and restore-from-minimized.
- **Global shortcut.** Register the quick-meeting shortcut with `RegisterHotKey` in the runner, and report conflicts through the existing shortcut state. The D-Bus portal and Hyprland paths stay Linux-only.
- **Open at login.** Use a per-user `Run` registry entry, without creating a competing service owner.
- **Notifications.** Add `foresight-notifications.exe` with the same CLI and JSON contract as `notifications.swift`. Toast notifications from an app without MSIX packaging need an AppUserModelID, registered through the installer's Start Menu shortcut.
- **PDF and RTF import.** Add `foresight-file-parser.exe` with the same contract as `file_parser.swift`: `--pdf|--rtf PATH`, text on stdout, and the same exit codes.
  - Use PDFium (BSD-3-Clause) for PDF. `Windows.Data.Pdf` can render pages but cannot extract text.
  - Use windowless RichEdit or a small extractor for RTF.
  - Generalize `Parser` in `store.dart` from a macOS check to a "bundled parser available" check.
- **Google.** Verify OAuth (the loopback `HttpServer` should work unchanged), Drive and Calendar sync, and reconnecting.
- **Model setup.** Cover memory eligibility, resumable verified downloads, reporting the backend LiteRT actually uses, and Whisper Vulkan device selection on Windows GPUs.

Exit: the desktop workflow checklist passes on Windows with real local inference, alongside the same headless service operations.

## Phase 5: Build, package, and validate the installed app

Budget: 5–7 engineering days, including integration fixes.

- **Build entry point.** `tools/build.sh` is bash and supports Linux and macOS only. Make the build entry point platform-aware; a Python script fits the existing tooling. Pin the Windows dependency set the way `tools/build_macos_sdk.py` does.
- **Packaging script.** Add `tools/package_windows.py`. It bundles:
  - the desktop app, service, MCP server, helper, and model worker
  - `foresight_native.dll`
  - LiteRT-LM and its DirectX DLLs
  - ONNX Runtime and SQLite
  - `whisper-cli`
  - the adapter executables
  - licenses and `runtime.json`

  Replace the `ldd` audit with a `dumpbin /dependents` audit. Ship the MSVC runtime or link it statically.
- **Installer.** Default to a per-user Inno Setup or WiX installer into `%LOCALAPPDATA%\Programs\Open Foresight`. MSIX would give the app a package identity, but its install location and AppData virtualization make it harder for third-party MCP hosts to launch `foresight-mcp.exe`. Adopt MSIX only if the Phase 0 launch test passes.
- **Signing.** Sign every shipped executable and DLL with Authenticode, with a timestamp. Expect SmartScreen warnings until the certificate builds a reputation.
- **Updates.** Windows locks running executables and loaded DLLs. Before replacing files, the installer must ask the service to finalize any recording and stop. It then restarts compatible clients. Never leave a mix of old and new files installed.
- **CI.** Add `.github/workflows/windows.yml` to run the native, core, Flutter, service, and MCP tests and to build an unsigned package. As on macOS, keep signed-release and physical-audio checks as separate gates. Extend `tests/service` beyond its `pw-record` fixture and `.so` defaults.
- **Installed-app testing.** In a fresh Windows user account, with no developer tools and an install path containing spaces, test:
  - install
  - first launch
  - MCP launch
  - upgrade during a recording
  - uninstall

Exit: a signed installer passes the installed-app checks without any SDKs or repository files, and Linux and macOS regression checks pass on the integrated branch.

## Acceptance checklist

- [ ] Phase 0 decisions are recorded: native route, transport, audio route, and installer.
- [ ] The desktop and two MCP clients resolve the same profile and create exactly one service owner.
- [ ] The service and helper accept only authenticated loopback connections, Windows Firewall does not prompt, and tokens never appear in command lines or logs.
- [ ] Private profile directories and files have user-only ACLs, and validation refuses paths owned by another user or readable by others.
- [ ] The service and MCP server work without a desktop window, and MCP stdout carries protocol messages only.
- [ ] Source changes, revision checks, read-only desktop queries, citations, graph persistence, and restart recovery keep their contracts.
- [ ] Killing the service or helper leaves no orphaned workers.
- [ ] Real embeddings, grounded generation, Whisper, cancellation, model setup, and worker cleanup pass with the packaged runtimes.
- [ ] Microphone and system audio both work when the desktop starts first and when MCP starts first, including denied access, device changes, and closing the desktop.
- [ ] Stop flushes transcripts, and crash recovery keeps committed data and marks unfinished recordings as interrupted.
- [ ] The global shortcut, single-instance behavior, open at login, notifications, PDF/RTF import, and Google sync work in the installed build.
- [ ] A signed installer works in a fresh account, and an upgrade coordinates with a running service and recording.
- [ ] Linux and macOS checks remain green. On the Rust route, the replaced C++ code has been removed.

## Schedule and first implementation slice

The phase budgets total about 27–39 engineering days on the C++ route and 32–47 on the Rust route. For one developer, that is roughly 5½–8 weeks or 6½–9½ weeks.

The Rust route costs about a week more for this release and pays that back in later platform work: there is one process and helper implementation instead of three, and no C++ gRPC build. Elapsed time can grow with signing-certificate provisioning and with macOS integration changes to shared files.

The first slice is Phase 1's storage-only service running on Windows:

- authenticated loopback transport
- ACL-based private directories
- Windows profile paths
- explicit shutdown

Its exit test is `service_ownership_test` and `tests/service` running on a Windows CI runner. Run the Phase 0 inference, audio, and Rust probes alongside it.
