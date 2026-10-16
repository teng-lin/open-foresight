# Application service and MCP implementation plan

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
- [ ] Plain Dart core has no Flutter dependency.
- [ ] Application operations extracted and tested.
- [ ] Local service owns application lifecycle and writes.
- [ ] Desktop uses service; workflows preserved.
- [ ] MCP works headlessly and alongside desktop.
- [ ] Packaging and setup documentation complete.
- [ ] Verification gates and completion audit recorded.
