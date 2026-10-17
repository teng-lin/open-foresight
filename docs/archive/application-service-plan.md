# Application service and MCP implementation plan

Archived completed plan and revision-specific audit. Current architecture and
usage are documented in [Application service and MCP](../architecture/application-service.md).

## Intended result

A Flutter-independent Dart application core and a per-profile local application service own content writes, indexing/recovery, generation, recording/transcription, and model lifecycle. Flutter provides presentation and desktop interaction. An MCP stdio adapter uses the same application operations, works without a desktop window, and shares an existing service rather than starting competing owners. Preserve existing profiles and desktop workflows.

## Implementation sequence

1. Extract existing non-Flutter domain, storage, inference, import, model, and connection logic into a plain Dart package. Preserve compatibility exports for existing desktop imports/tests. Verify dependency boundaries and run existing tests.
2. Consolidate source imports, meeting indexing, artifact generation, note enhancement, capture persistence, and recovery into core application operations. Move lifecycle timers and ownership out of widget state. Keep dialogs, selection, rendering, and notifications in the desktop.
3. Introduce a private Unix-socket application API with typed operation dispatch, change notifications, bounded requests, error propagation, cancellation, and an OS lock per profile. Serve reads and mutations through one owner; preserve serialized source mutations and revision checks. Support headless startup, attachment, and intentional shutdown without stopping another client's work.
4. Convert the desktop to the service client. Replace direct application mutations and model/capture ownership, refresh UI on service changes, and preserve shortcuts, setup, Google connections, graph persistence, and meeting behavior. The service must survive desktop disconnection and support reconnection.
5. Add MCP stdio support for status, source search/read/list/import/edit/delete, notes, meeting content/capture/artifacts, and grounded answers. Declare tool schemas, distinguish tool failures from protocol errors, handle protocol negotiation and shutdown, and keep stdout strictly protocol-only. Reuse application operations rather than modifying databases independently.
6. Build and package the service and MCP launcher with the desktop. Document configuration, profile selection, lifecycle, supported tools, and local-only scope.
7. Verify core and desktop analysis/tests, native contracts, isolated-profile service/client integration, concurrent desktop/MCP access, restart/recovery, and MCP subprocess protocol behavior. Build a release bundle and smoke-test packaged executables.

## Plan review

- A shared library alone does not establish process ownership. Completion requires the desktop and MCP to use the service boundary, with one application writer and one capture/model owner.
- A retrieval-only MCP wrapper bypasses application revisions and recovery. All writes must use application operations.
- Do not change languages unnecessarily or rewrite the C++ retrieval engine. Reuse tested Dart/FFI workers and existing gRPC protocols.
- Database migration belongs to the owner, not a UI read connection. Existing profiles must remain compatible.
- Long operations need progress, cancellation, bounded concurrency, and clear failure states. A disconnected UI must not interrupt capture; an abandoned generation must release its worker.
- Source and meeting changes during generation must preserve pinned evidence and reject stale note enhancement.
- Graph rendering is UI logic; persisted graph state is application data. Google browser UI remains desktop interaction, while credentials and sync belong to the core.
- Launch races require an OS lock, not socket existence checks. Bind only a private local socket. No remote hosting/authentication scope is implied.
- Tests must exercise actual subprocesses and shared ownership, not just dispatch methods or generated manifests.

## Evidence checklist

- [x] Isolated worktree created; original checkout untouched.
- [x] Plan written and reviewed against current source.
- [x] Plain Dart core has no Flutter dependency.
- [x] Application operations extracted and tested.
- [x] Local service owns application lifecycle and writes.
- [x] Desktop uses service; workflows preserved.
- [x] MCP works headlessly and alongside desktop.
- [x] Packaging and setup documentation complete.
- [x] Verification gates and completion audit recorded.


## Completion audit

Verified application code revision: `202386acf26c3cb36a50b809178dc3ab0f5490b0`. This audit is recorded in a subsequent documentation-only commit. The original checkout remains clean; implementation and artifacts are in `/home/blackmyth/src/open-foresight-mcp`, branch `feature/application-service-mcp`.

| Requirement | Inspected evidence |
| --- | --- |
| Worktree, comprehensive plan, and review | Isolated Git worktree and branch; implementation sequence and review above. |
| Flutter-independent core | `packages/foresight_core/pubspec.yaml` has no Flutter dependency; source imports contain no Flutter or `dart:ui` dependency; plain Dart analysis and 6 core tests pass. |
| One application writer and lifecycle owner | `ApplicationService`, private profile lock/socket, service-owned `Application`/`Domain`/`Store`; desktop `RemoteDomain` opens `Store.readOnly`. Desktop code contains no direct application database mutations. |
| Application workflows extracted | Core application operations own file/URL/directory imports, source refresh/index/delete/recovery, notes, transcripts, artifact generation, model configuration, Google sync, capture, inactivity, and enhancement timers. UI wrappers call those operations. |
| Shared desktop/MCP operation | Actual native Flutter integration observes MCP-created content, continues capture after MCP and desktop disconnect, reattaches to the same PID, and verifies final transcript/artifact persistence. |
| MCP protocol and tools | Pinned MCP SDK; real stdio subprocess tests cover negotiation, tool discovery, schemas, errors, progress, search, mutations, independent conversation context, and clean adapter exit. |
| Concurrency, cancellation, and recovery | 11 subprocess integration tests pass, including two racing headless launchers, single recording/generation ownership, cancellation isolation, canceled model setup, stale socket recovery, desktop/MCP reconnection, graceful recording shutdown, and unexpected service death. Shutdown/restart also passed ten consecutive reproductions after fixing HTTP/2 draining. |
| Headless Google sign-in | The service streams the authorization URL to the requesting desktop callback; core tests cover request ownership and cancellation before listener binding. The real remote facade receives and cancels an OAuth invitation without opening a browser or contacting Google. |
| Existing behavior checks | Desktop analysis clean; 132 desktop tests pass, with 9 existing opt-in skips. Google connection tests separately pass after OAuth extraction. Native CTest: 3/3. Contract/grounding/profile migration checks: 15 passed plus 9 subtests. |
| Build and packaging | Full `tools/build.sh` succeeds; service and MCP AOT executables and Flutter release bundle produced; packaging includes all three launchers and runtime dependencies. |
| Relocated package | `tools/smoke_bundle.py` passes from `/` with a bundle path containing spaces: live desktop/helper, MCP sharing its PID, independent headless MCP startup, private paths, launcher/library resolution, and explicit service shutdown. Observed helper build ID matches code revision `202386a`. |
| Documentation and cleanup | Setup, tool inventory, lifecycle, shared edit semantics, and verification commands are in `docs/architecture/application-service.md`. Private desktop session destroyed after the final smoke test; original checkout unchanged. |

Local verification records are retained under ignored `test-results/verification/`, with structured reports in `test-results/desktop-service-integration.json` and `test-results/packaged-desktop-mcp-final.json`. The default bundle in this worktree is `dist/open-foresight`; its manifest identifies the verified application code revision above.

Controlled inference and audio fixtures verify orchestration, ownership, persistence, and cancellation. Physical microphone quality and real-model accuracy were not re-evaluated; the existing opt-in real meeting workflow remains available. No remote hosting or multi-user authentication was added.
