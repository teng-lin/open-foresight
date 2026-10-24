# Open Foresight repository review (agent team)

Review date: 2026-10-24. Source: `2f26d8fc9d1ef83e7df2d709fa776c55c8c01ace`
(`Allow users to rename meetings`, #177) on `main`.

Seven independent reviewers each assessed one area of the repository. Each worked
read-only and was not shown any earlier audit. The areas were:

- architecture
- security and privacy
- code quality and maintainability
- testing
- deployment and supply chain
- reliability and performance
- documentation, developer experience and observability

The coordinating reviewer re-checked every high-severity finding and the headline
medium findings against current source before including them. Section 13 lists what
was executed and what was not. Scores are engineering judgments, not coverage
percentages or release certification.

## 1. Summary

Open Foresight is engineered with unusual care in several areas:

- a single service that owns mutations and native resources;
- boundary and registry invariants enforced by tests;
- exact-count, zero-skip test gates;
- sandboxed document parsing and DNS-pinned SSRF defences;
- SHA-pinned CI, digest-pinned SDK images and hash-locked Python dependencies;
- release publication gated on installed acceptance across four Linux distributions
  and macOS.

The most serious problem is not code quality. Release builds embed Google OAuth
client credentials and two Google API keys that
`tools/reference_distribution_config.py` extracts from Google's proprietary AI Edge
Foresight binary. This is a consent, terms-of-service and availability risk for every
installed copy, and it should be resolved before the next release.

The most serious code defect is in recording stop. A failed database write before
capture teardown can leave the microphone running after the desktop hides or
disconnects, which undermines ADR 0006. Live meetings also grow content history
quadratically, with no retention.

Secondary themes:

- Linux service and worker diagnostics are discarded.
- Release authority is enforced by workflow text, not by GitHub protections.
- Vulnerability scanning never blocks and does not cover native components.
- Several high-traffic documents have drifted from the code.

**Overall: 6.1/10** (unweighted mean of eleven aspect scores).

## 2. Ratings

Rubric: 1–2 fundamental deficiencies · 3–4 substantial weaknesses · 5–6 adequate but
uneven · 7 strong with material gaps · 8 strong with enforced controls · 9 highly
mature, few gaps · 10 exemplary.

| Aspect | Score | One-line assessment |
| --- | ---: | --- |
| Architecture | **7** | Coherent single-owner service and analyzer-checked desktop boundary. The boundary hides names, not code. `Domain` is a service locator, and model setup lives in widgets. |
| Security and privacy | **6** | Strong peer verification, SSRF and sandbox controls. Weighed down by redistributed third-party credentials and a capture-stop failure path that weakens the consent guarantee. |
| Reliability and data integrity | **7** | Atomic migrations, crash recovery and supervised workers. The stop path, request ledger and history retention assume writes never fail and IDs never collide. |
| Performance and responsiveness | **5** | Good isolate offloading and read worker. Live meetings rewrite, re-embed and snapshot the full transcript per segment, on the same isolate that drains capture. |
| Code quality | **7** | Every configured analyzer passes, with few suppressions and almost no TODO debt. Python is largely unannotated, the C ABI duplicates exception barriers, and smoke-check failure messages are opaque. |
| Maintainability | **6** | Good compile-time exhaustiveness and architecture tests. Python CI tooling is about 41k lines against about 70k lines of product code. PRs exceed the repository's own size rule, and the import mechanisms are inconsistent. |
| Testing and verification | **8** | Exact-count, zero-skip gates, three coverage gates, sanitizers with positive controls, and real-model containers. One load-sensitive flake was observed. Coverage is gated on Linux only, and GPU, physical audio and macOS prompts are untested. |
| Deployment and release | **6** | Exact-commit candidates, multi-distribution installed acceptance, N-1→N upgrade testing and attestations. No platform-enforced approval, unsigned Linux packages, a non-notarized DMG, no update channel and no rollback. |
| Dependencies and supply chain | **5** | Excellent pinning discipline. Vulnerability scanning is non-blocking and Python/Dart only. Updates have stalled, and release credentials come from another vendor's binary. |
| Documentation and developer experience | **6** | Extensive, mostly accurate docs and clear agent and contributor rules. Coverage gates, migration table, MCP tool list, OAuth import and release steps are wrong in the most-read files. There are 12 broken links. |
| Observability and supportability | **4** | Typed errors and a bounded opt-in trace. Linux service stderr is never captured, worker stderr goes to `/dev/null`, logging is free-form, and there is no troubleshooting or bug-report guide. |

**Score adjustment.** The security reviewer scored Security 7/10 without the
reliability reviewer's capture-stop finding (§5.1). The coordinator lowered it to 6
because that defect directly contradicts the visible-desktop recording guarantee that
the security score credited.

## 3. Priority findings

Ranked across all aspects. ✔ = re-verified by the coordinator against current source.

| # | Finding | Severity | Aspects |
| --- | --- | --- | --- |
| P1 | Release OAuth client and API keys are extracted from Google's proprietary binary and shipped in installers ✔ | **Critical** | Security, Supply chain, Deployment |
| P2 | Recording stop writes state before tearing down capture; a write failure leaves the microphone running ✔ | **High** | Reliability, Security |
| P3 | `content_revisions` grows quadratically during live meetings, with no retention ✔ | **High** | Reliability, Performance |
| P4 | Live indexing re-embeds the entire transcript after every segment | High | Performance |
| P5 | Linux service and native worker diagnostics are discarded ✔ | High | Observability |
| P6 | Release authority is not enforced by GitHub: 0 required approvals, no CODEOWNERS, no protected environment | Medium | Deployment |
| P7 | OSV scan is `continue-on-error` and covers only Python and Dart lockfiles ✔ | Medium | Supply chain |
| P8 | MCP clients read every transcript and note without approval, with no provenance tagging (prompt-injection exfiltration path) | Medium | Security |
| P9 | Stop waits behind the source-mutation queue, blocking the next recording for minutes ✔ | Medium | Reliability |
| P10 | Duplicate in-flight request IDs overwrite the lease and subscription ledger ✔ | Medium | Reliability |
| P11 | Docs misstate coverage gates, migration version, MCP tools, OAuth import and the release procedure ✔ | Medium | Documentation, Testing |
| P12 | Load-sensitive failure in `proactive_application_test.dart:405` (observed once in a full run) | Medium | Testing |
| P13 | Desktop and MCP compile in the whole service graph; the boundary test asserts that coupling ✔ | Medium | Architecture |
| P14 | The `/tmp/of-install-<uid>-<hash>` lock path can be pre-created by another local user ✔ | Low–Medium | Security |

## 4. Architecture — 7/10

**Strengths**

- **One wire registry.** `Operation` (`packages/foresight_core/lib/src/operations.dart:6`) is the only registry. A test asserts that application and service handler sets are exhaustive and disjoint (`test/typed_operation_registry_test.dart:25-50`).
- **MCP is a projection of the operations.** Tools are generated from operation descriptors (`lib/src/mcp/rpc_tools.dart:30-52`). `bin/mcp.dart` imports only the client stack.
- **The desktop boundary is checked by the analyzer.** Imports are limited to `desktop.dart` and `desktop_bootstrap.dart`. grpc, sqlite3, ffi and protobuf are banned, and `Store`, `Domain` and `NativeRuntime` are forbidden symbols (`test/desktop_boundary_test.dart:58-161`).
- **SQL is confined to the persistence layer.** Raw SQL appears only in `persistence/`, `store.dart` and `graph_persistence.dart`, with hash-pinned migrations enforced in CI (`.github/workflows/quality.yml:27`).
- **One source for the helper protocol version.** `proto/helper_protocol_version.json` generates both the Dart and C++ constants, a test catches drift, and the version is checked when the helper is adopted (`lib/src/helper.dart:22-29`).
- **The core import graph is nearly acyclic.** It has 206 modules and a single six-module cycle.

**Findings**

| Finding | Sev. | Evidence | Recommendation |
| --- | --- | --- | --- |
| The boundary hides names, not code. The closure of `desktop.dart` plus bootstrap reaches 206 modules, including `application_service.dart`, `domain.dart`, `store.dart` and `recording.dart`. The test *expects* this ✔ | Med | `remote_domain.dart:18`; `service.dart:5,10`; `desktop_boundary_test.dart:41-42` | Split `service.dart` into client and server barrels. Invert the assertion so service modules must be absent from the desktop and MCP closures. |
| `Domain` is a service locator. 15 of 17 coordinators take all of it. The generator handle is replaced at six sites after `await`, with no compare-and-swap and no close of the prior value. | Med | `domain.dart:406,412,432,502,507`; `model_registry.dart:242`; `application.dart:136-137` | Add a single-owner `GenerationRuntimeSlot`. Pass coordinators narrow ports instead of `Domain`. |
| The desktop command API is untyped. `command(Operation, Map<String,dynamic>) → Object?` has 72 call sites and about 40 casts, while the service side decodes typed requests ✔ | Med | `desktop_connection.dart:114-132`; `operation_requests/request_context.dart:22-55` | Add `encode()` to request types and typed result decoders. |
| Model acquisition is orchestrated in desktop widgets, and there are two downloaders. Audio device discovery also runs in the desktop process. | Med | `gemma_setup_view.dart:231-296`; `gemma_download.dart:119`; `model_acquisition.dart:145`; `audio_devices.dart:20-45` | Make acquisition a service operation with streamed progress. Merge the downloaders. |
| The native ABI version is exported but never checked by Dart ✔. The helper version uses exact string match only. | Low | `native/foresight_native.cpp:563`; `helper.dart:24` | Check `fs_abi_version` when the library is opened. Require a version bump when the descriptor changes. |
| One import cycle runs persistence → answer logic → desktop reader → persistence. | Low | `persistence/conversation_queries.dart:3` → `answer_retrieval.dart` → `sqlite_store_reader.dart` | Move shared value types into a leaf module. |
| Ambient `runtimeConfiguration` global is read at 52 sites in 26 files. | Low | `platform_services.dart:187-197` | Inject a typed configuration object at composition. |
| Per-entity data is kept in the `preferences` table under string prefixes, with no foreign keys. | Low | `conversation_queries.dart:67,88,146`; `application_queries.dart:71` | Move it into columns or side tables in a future migration. |
| Docs and ADRs drift: handler counts 75/8 versus the asserted 76/9; ADR 0007 is "Proposed" in the index but "Accepted" in the record ✔; `toRow()` adapters are documented but removed. | Low | `application-service.md:174`; `docs/adr/README.md:13` | Derive counts from tests or drop them. Fix the ADR index. |

## 5. Security and privacy — 6/10

**Strengths**

- **DNS-pinned SSRF defences.** Web import allows only global addresses, including mapped IPv4 and transition ranges. Every redirect hop is re-checked, HTTPS cannot downgrade, proxies are disabled, responses are capped at 5 MB and must be `text/*`, and parsing runs in an isolate with a deadline (`lib/src/web_import.dart:16-59,116-130,191-205,246-260`).
- **Sandboxed extractors.**
  - Linux: `bwrap --unshare-all --cap-drop ALL --clearenv`, with only the single input file bound in (`document_parser.dart:139-187`).
  - macOS: `sandbox_init` with a deny probe (`native/file_parser.swift:8-33,144-165`).
- **Verified approval.** Desktop approval requires the `SO_PEERCRED`/`LOCAL_PEERCRED` peer plus a canonical-executable check that rejects interpreters. Approval IDs expire after two minutes, are rate-limited, and are cancelled when the window hides (`unix_peer_identity.dart:24-160`; `agent_access.dart:122-330`).
- **Packaged builds ignore code-path environment overrides** (`platform_services.dart:86-103,164-168`).
- **No external fetches from generated content.** Generated Markdown never fetches images, and links are limited to http(s) (`apps/desktop/lib/generated_content.dart:33-41`). Web search sends only the question (`answer_retrieval_phase.dart:191-203`).
- **Verified binaries and models.** Model downloads are size- and SHA-256-checked with an atomic rename. LiteRT's digest is checked on the same open file before `dlopen` (`services/inference/litert.h:147-167`).

### 5.1 Findings

**S1. Redistributed third-party credentials — Critical, confirmed ✔**

`tools/reference_distribution_config.py:17-23,38-78` hash-pins Google's
`Foresight.app` executable and reads values at fixed offsets. The comment says they
are "bound to IDA call sites". The values are:

- the production OAuth `client_id` and `GOCSPX-` secret;
- two `AIza…` API keys, one for search and one for the internal
  `odml.pa.googleapis.com` web-content endpoint (`web_content.dart:6-38`).

The tool pipes these into repository secrets. Packaging then writes them in
plaintext to `runtime.json` (`tools/package.py:36-50`, `tools/package_macos.py:161,272`).
The README says the reference app is Google's (`README.md:15-31`).

Consequences:

- Users grant `drive.readonly` and `calendar.events.readonly` on a consent screen
  owned by another publisher.
- Their refresh tokens belong to that publisher's client.
- Web-mode queries use an internal endpoint under keys and terms the user never
  accepted.
- Revocation breaks sign-in and web mode in every installation, and only a new
  release can fix it.

`README.md:353` says "Packaging does not inspect other applications". That is
technically true of the packaging scripts but misleading for the release as a whole.
`granola_calendar_auth.dart:1-8` uses a third party's private API in a similar way.

Remediation:

1. Register a project-owned Google Cloud project with a verified consent screen, or
   make Drive, Calendar and web mode bring-your-own-client.
2. Remove the ODML and Granola dependencies, or make them opt-in with the user's own
   credentials.
3. Delete the extraction tool and stop using the extracted secrets.
4. Correct the README.

The coordinator did not verify whether the current repository secrets were in fact
populated by this tool.

**S2. Capture can outlive a failed stop — High, confirmed ✔.** See §6, finding R1.
ADR 0006 promises that recording stops when the host desktop disconnects. That
promise depends on `setState` succeeding before `active.stop()` runs.

**S3. Unapproved MCP reads — Medium, by design.** Source, note, meeting and search
reads are `readOnly: true, approval: ApprovalPolicy.never`
(`operation_descriptors/sources.dart:7,24`; `application-service.md:141`). An
imported web page or Drive file carrying agent-directed instructions can lead a
connected agent to read all transcripts headlessly. The untrusted-content labels
exist only in Ask prompts, not in MCP output.

Recommendation: an opt-in approval or time-boxed grant for transcript, note and
Drive reads, plus provenance and trust tags on MCP results.

**S4. Shared-`/tmp` install lock — Low–Medium, confirmed ✔.** The lock lives at
`/tmp/of-install-$uid-$sha256(root)[:24]/lock` (`platform_services.dart:606`), and
`privateDirectory` refuses a directory owned by someone else. Two consequences:

- Another local user can pre-create the predictable directory and permanently block
  the victim's packaged service. The sticky bit prevents the victim from deleting it.
- Any user holding their own lock file blocks root's package upgrade
  (`packaging/upgrade_lock.sh:44-68`).

Recommendation: move the lock to `$XDG_RUNTIME_DIR` or a per-user cache directory.

**S5. Check/use race on file import — Low, likely.** `ImportPolicy.validate` checks
the canonical path (`agent_access.dart:26-48`). The file is then re-opened by name
(`source_operations.dart:184-189`; `document_parser.dart:117-135`). A same-user
writer inside an approved root could swap in a symlink to
`<profile>/google/tokens.json`.

Recommendation: open from the root's descriptor with `O_NOFOLLOW`, run `fstat` on
the descriptor, and pass the descriptor to bwrap.

**S6. Helper liveness after upgrade — Low–Medium, confirmed by reading ✔.** On Linux,
`/proc/<pid>/exe` gains a ` (deleted)` suffix after the binary is replaced. The exact
filename compare at `native/foresight_native.cpp:1918-1923` therefore reports a live
helper as gone while it still holds the storage lock. There is also no PID-reuse check
on Linux.

Recommendation: compare device and inode, or strip the suffix, and check the process
start time.

**S7. Approval dialog spoofing — Low.** Argument values are joined with newlines and
shown unescaped (`apps/desktop/lib/agent_approval_surface.dart:138-181`).

Recommendation: render a key/value table with control characters escaped.

**S8. Native robustness — Low.**

- Child output is buffered without limit (`foresight_native.cpp:1047-1057,1489`).
- `posix_spawn_file_actions_*` return values are unchecked
  (`foresight_native.cpp:283-301`).
- `posix_spawnp` falls back to a bare name, so it searches `PATH`
  (`native/portable_process.h:175,224`).

**S9. Credential handling — Low.**

- The first `.desktop-capability` file is written before it is `chmod`ed
  (`application_service.dart:189-190`).
- The access token stays in `tokens.json` even when a secret store is used.
- A failed secret-store write silently falls back to a plaintext refresh token
  (`google_auth.dart:333-339`).

**Recommendations:** (1) resolve S1 before the next release; (2) fix R1 so S2 closes;
(3) add consent and provenance for MCP reads; (4) move the install lock and switch to
descriptor-based imports.

## 6. Reliability and data integrity — 7/10 · Performance and responsiveness — 5/10

**Strengths**

- **Workers cannot be orphaned.** An ownership pipe makes the supervisor SIGKILL the worker's process group within about 50 ms of the owner dying (`native/portable_process.h:96-155`). Every child is reaped on teardown.
- **Migrations are atomic.** The whole migration runs in one transaction and newer profiles are refused (`lib/src/store.dart:69-101`). The manifest covers steps 1–19.
- **Startup recovers in-progress state.** Meetings left recording, transcribing or paused become interrupted. Sources in `indexing` or `pending` are re-queued. Stale speech WAV files are swept (`meeting_store.dart:81-89`; `domain_queries.dart:102-108`; `application_service.dart:326`).
- **Helper indexing is atomic.** Embeddings are computed outside the lock and written in one `BEGIN IMMEDIATE` transaction. The search snapshot is published only after commit (`services/helper/main.cpp:591-684`).
- **External work has deadlines.** gRPC has a 45 s deadline. Downloads have a 30 s per-chunk idle timeout and a SHA-256 check. Native cancel escalates to a kill after 2 s. Reads have a 30 s deadline.
- **Capture memory is bounded.** A 20 s channel flush, a 4-segment speech queue, and a 255-event native queue. Graph layout runs in `Isolate.run`, and broadcasts are coalesced to 100 ms.

**Findings**

| # | Finding | Sev. | Evidence | Recommendation |
| --- | --- | --- | --- | --- |
| R1 | **Stop writes state before tearing down capture.** `queries.setState(id,'transcribing')` runs outside the `try`, before `active.stop()`. Disconnect and hide handlers only log the error, and nothing retries. Start has the mirror problem: `recording = active` is set before the state write. ✔ | High | `application_services/recording_controller.dart:246-250,175-182`; `application_service.dart:636-643` | Stop native capture first and unconditionally. Make state writes best-effort, retried in `finally`. On start, dispose if the write fails. |
| R2 | **History grows quadratically.** A `BEFORE UPDATE` trigger copies the full `OLD.content` into `content_revisions` ✔. Live indexing rewrites the whole `meeting-$id` source after each segment, and nothing prunes. A synthetic replay of the trigger and upsert SQL produced 36 MB of history for a 120 KB transcript (600 appends). | High | `persistence/schema_migrations.dart:183-190`; `meeting_indexer.dart:45-56`; `recording_controller.dart:124-133` | Exclude system-generated sources such as transcripts from history. Add count- or age-based retention, or store diffs. |
| R3 | **Live re-embedding of the full transcript.** Each segment re-chunks and re-embeds the whole transcript, so total work grows with the square of meeting length and competes with whisper for CPU. | High | `meeting_indexer.dart:37-56`; `domain.dart:300-312`; `services/helper/main.cpp:621-622` | Use append-only chunk indexing, or throttle live indexing and run the full index once at stop. |
| R4 | **Stop blocks on the index queue.** `await indexer.indexMeeting` sits behind a FIFO queue whose entries may take up to 30 minutes each. `recording` is cleared only in `finally`, so the next start is refused. ✔ | Med | `recording_controller.dart:258,265,93`; `domain.dart:219-275,311` | Publish the final state and release `recording` first, then index in the background. |
| R5 | **Duplicate request IDs.** `_leases[client]![id]` and `_subscriptions[client]![id]` overwrite existing entries with no check ✔. When the first request finishes it removes the second's entries, which escapes cancel, the 32-request cap, idle-exit accounting and terminal frames. | Med | `application_service.dart:683,716,729-741,647,987-995` | Reject an ID that is already in flight. |
| R6 | **Capture can be starved.** The 20 ms drain timer shares an isolate with synchronous `listSync`, per-file `queries.documents` (which loads every source's content) and synchronous native joins. The native queue drops audio after 255 frames. | Med | `recording.dart:258`; `source_operations.dart:200,258`; `foresight_native.cpp:551-554` | Look sources up by URI in SQL, move listing off the isolate, and consider a dedicated capture isolate. |
| R7 | **The speech deadline includes queue wait.** Two channels share one worker behind a `timed_mutex`. The 60 s deadline starts before the job acquires the worker. A timeout discards the segment and kills the shared worker, forcing a model reload. | Med | `recording.dart:569-623`; `foresight_native.cpp:1458-1463` | Start the deadline when the job runs, or report queue wait separately. |
| R8 | **A failed transcript write loses text.** A throw from the synchronous write re-enters `interruption`, which writes again. The second throw escapes into an unhandled zone error, and the text and PCM are lost. | Med-Low | `recording_controller.dart:110-118`; `recording.dart:520-526,613-624` | Keep the last N segments in memory and retry. Guard error-path callbacks. |
| R9 | **The read worker has no recovery.** The `_starting` future is cached permanently, so after the worker exits all reads fail. Reads run serially, and SQL is not interrupted when a deadline passes. | Low-Med | `sqlite_read_worker.dart:28,85-87,138-156` | Respawn on exit and call `sqlite3_interrupt` on deadline. |
| R10 | **Other risks.** No `busy_timeout` on Dart connections. Socket writes ignore backpressure. `importText` runs two statements without a transaction. Audio frames are base64-encoded twice. The helper's reconfiguration guard is held for the whole embedding step. | Low | `service_message_writer.dart:64-66`; `source_store.dart:52-66`; `foresight_native.cpp:533-545`; `services/helper/main.cpp:594-597` | Address alongside R1–R6. |

**Recommendations:** (1) make stop infallible: tear down first, retry writes, release
before indexing (R1, R4, R8); (2) fix live-meeting cost with append-only indexing and
history exclusion or retention (R2, R3); (3) reject duplicate request IDs, bound send
queues, and isolate capture (R5, R6).

## 7. Code quality — 7/10 · Maintainability — 6/10

**Strengths**

- **Clean, strict analysis.** `dart analyze` (core), `flutter analyze` (desktop), `ruff` and `mypy` are all clean, and `dart format` reports 0 diffs across 718 files. The core package enables `unawaited_futures`, `discarded_futures`, `cancel_subscriptions` and `close_sinks`. Turning on Dart's strict modes finds only 4 issues across about 63k lines.
- **Little debt.** There are 62 Dart ignores, 150 `noqa`, 0 `type: ignore` and 0 NOLINT, almost all with a reason. There is one TODO, from the Flutter template.
- **Safe C++ resource handling.** RAII via `ScopeExit`, 116 scoped locks and only 3 raw `new`. The helper builds with `-Werror`.
- **The compiler enforces completeness.** Sealed `Operation` types and exhaustive switches mean a new operation that misses a case fails to compile.
- **Architecture is tested.** Architecture and feature-isolation tests cover the desktop features.

**Findings**

| Finding | Sev. | Evidence | Recommendation |
| --- | --- | --- | --- |
| **Python is largely untyped.** mypy uses only `check_untyped_defs` with global `ignore_missing_imports`. `--disallow-untyped-defs` reports 964 errors in 160 of 166 files. `tests/` (67k lines) is not type-checked at all (574 errors when probed). | Med-High | `pyproject.toml:17-27` | Ratchet annotations per module with mypy overrides, starting with the shared `ci_*` modules. |
| **The C ABI duplicates its exception barrier.** 31 exports carry 35 hand-written `catch (...)` blocks, while `ffi_barrier` in `exception_barrier.h:47` has 0 uses in the file ✔. A missed branch means `std::terminate` in the host. | Med | `native/foresight_native.cpp:562+` | Route all exports through `ffi_barrier`, and add a test that rejects unguarded `extern "C"` bodies. |
| **CI tooling is large relative to the product.** 46 `tools/ci_*.py` modules (14.6k lines), 43 CI test modules (20.1k lines) and 6.2k workflow lines, together about 41k lines, against about 70k lines of product code. A 14.7 MB evidence tarball is committed in git ✔. | Med | `tools/ci_*`; `tests/fixtures/ci-acceptance-failures-20261020.evidence.tar.gz` | Freeze growth: retire before adding. Move large fixtures to LFS or a release asset with a checksum. |
| **Three Python import mechanisms.** `from tools.` imports without a `tools/__init__.py` (400 uses), `sys.path.insert` in 84 files, and 38 `spec_from_file_location`/`runpy` loads. These force 108 `noqa: E402`. | Med | repository-wide | Make `tools` a package, run scripts with `python -m`, and remove the path hacks. |
| **Duplicated helpers.** `def digest` is defined 9 times and `def run` 14 times, with differing timeout, check and echo behaviour. | Low-Med | `tools/ci_artifacts.py:196`; `tools/ci_git.py:86`; `tools/build_macos_sdk.py:26` | Create a shared `tools/_common.py`. |
| **Opaque smoke failures.** 32 sites raise a bare `"Verification failed"`, with 75 `if not (…)` guards that look converted from asserts. | Low-Med | `packaging/smoke_installed.py:136-226`; `tools/smoke_macos_bundle.py:690-757` | Use a `require(cond, msg, **observed)` helper that reports the observed values. |
| **Long, complex functions.** `inference/main.cpp:313 generate()` is about 250 lines with 8 parameters; `tools/package.py:66 main` is 359 lines; `application_service.dart:472 _accept` is 162 lines. 111 functions exceed ruff C901 complexity 10. | Low-Med | as listed | Add a C901 ratchet and extract the framing logic from `_accept`. |
| **Uneven strictness.** `avoid_dynamic_calls` is enabled in the desktop but not core (11 sites in core). `-Werror` is set only on the helper target. There is no clang-tidy. | Low | `analysis_options.yaml`; `native/CMakeLists.txt:23` | Align the lint rules, and add `-Werror` and clang-tidy on changed files. |
| **Change size.** `75898380` changed 504 files ✔ and `294b2b03` changed 411, against the about-100-file rule in AGENTS.md. Adding one operation touched 26 files. A hard-coded `hasLength(76)` breaks whenever an operation is added. | Low-Med | `git show --stat`; `test/typed_operation_registry_test.dart:34` | Enforce PR size in CI, generate the per-operation boilerplate, and derive counts from the registry. |

**Key metrics**

| Metric | Value |
| --- | --- |
| Product code (Dart lib/bin, native, services, excluding generated code) | 70,265 lines |
| Python total / `tools/` / `tests/` | 105,552 / 37,455 / 66,906 lines |
| Largest production files | `native/foresight_native.cpp` 1,962; `tools/ci_artifacts.py` 1,311; `tools/measure_service_rpc.py` 1,206; `application_service.dart` 1,068; `remote_domain.dart` 1,027 |
| Suppressions | Dart ignores 62; `noqa` 150 (108 E402); `type: ignore` 0; NOLINT 0 |
| Python functions over 50 / over 100 lines | 164 / 46 of 967 |

**Recommendations:** (1) ratchet Python typing and the Dart strict modes; (2) remove
duplication: `ffi_barrier` everywhere, shared tool helpers, `tools` as a package;
(3) contain growth with a PR-size gate, a complexity ratchet and an evidence fixture
moved out of git.

## 8. Testing and verification — 8/10

**Strengths**

- **Exact-count, zero-skip gates.** Integration gates reject a wrong count, any skip, or a missing final event (`tools/integration_gates.py:24-45`). The compiled service suite must have zero skips (`tools/linux_container_test.sh:44-48`). The skip inventory and collection hygiene are themselves tested (`tests/test_integration_gates.py:117`; `tests/test_test_hygiene.py:152-167`).
- **Skips cannot hide in CI.** Native-backed Dart tests skip only when the library path is unset, and CI always sets it (`tools/build_dart_gates.sh:31-32`).
- **Real models and audio on Linux PRs.** `acceptance-cpu` and `acceptance-audio` run with checksum-pinned public models in containers without network access. The virtual-audio job refuses to run if `/dev/snd` exists.
- **Sanitizers with positive controls.** ASan, UBSan and TSan run the full CTest suite after a step proves the runtimes catch real faults (`tools/run_native_sanitizers.sh`; `native-sanitizers.yml`).
- **Behaviour-focused tests.** No mock frameworks: tests use fakes, real subprocesses and real SQLite. About 7,300 core and 2,900 desktop `expect(` calls, 569 `throwsA(`, and no retries.
- **Three coverage gates.** Python 95% line+branch with subprocess instrumentation, core 90%, desktop 90%. Desktop measured 93.70% in this review.

**Inventory**

| Suite | Size | CI | Gate |
| --- | --- | --- | --- |
| Python offline (`tests/`) | 5,595 cases + 1,395 subtests (2,089 CI-tooling) | `quality.yml`, every PR | 95% line+branch |
| Dart core | 2,143 tests, 246 files | Linux container, macOS | 90% lines (Linux only) |
| Flutter desktop | 573 tests, 123 files | Linux, macOS | 90% lines (Linux only) |
| Desktop `integration_test` | 3 files | Xvfb service gate; macOS UI | exact counts |
| CTest (native, helper, inference) | 34 registrations | both platforms | pass/fail |
| Compiled service/MCP | 2 modules | `build_service_gate.sh` | zero skips |
| Integration gates (models, virtual audio) | 2 + 6 + 4 | Linux PR and main | exact count, no skips |
| ASan/UBSan, TSan | full CTest | nightly, path-filtered PRs, release | fatal reports; TSan on probation until 2026-10-25 |
| Manual probes | 18 of 24 in `tools/integration_probes.json` | none | none |

**Findings**

| Finding | Sev. | Evidence | Recommendation |
| --- | --- | --- | --- |
| **Load-sensitive failure.** `proactive_application_test.dart:405` ("model configuration yields retrieval and preserves queued answer (cancel caller: false)") reported `completed` expected, `failed` actual during a full run that shared the CPU. It passed 3/3 in isolation. | Med | review run | Replace the wall-clock dependency with `fake_async` or explicit completers. Run a scheduled CPU-stress pass. |
| **Coverage is Linux-only and misdocumented.** macOS sets `FORESIGHT_CORE_COVERAGE_MIN: '0'` and disables coverage on PRs ✔. README and CONTRIBUTING claim 76.35% for desktop, but the code enforces 90%. README claims macOS enforces 90% core. | Med | `macos.yml:23-24`; `build_dart_gates.sh:105-106`; `README.md:376`; `CONTRIBUTING.md:33` | Correct the docs. Add a macOS floor, or state explicitly that macOS coverage is not gated. |
| **Tests never executed, with misleading exclusion reasons.** `tests/inference/test_raw_query_model.py` has no `add_test`. `test_model_crypto_keychain.py` needs an env var that nothing sets. 18 of 24 probes are manual. Software-GPU acceptance allows LiteRT to be unavailable. | Med | `pytest-exclusions.json`; `test_model_crypto_keychain.py:22-26`; `linux_acceptance.sh:54` | Fix the exclusion reasons, wire the Keychain test into macOS CI, and automate `test_default_model_startup`. |
| **Sanitizer gaps.** `detect_leaks=0` globally. TSan is `continue-on-error` until 2026-10-25. Linux only. | Low-Med | `run_native_sanitizers.sh:14`; `native-sanitizers.yml:207,214` | Enable LSan with a CPython suppression file. Confirm the TSan probation expires tomorrow. |
| **No native C++ coverage measurement.** | Low-Med | `docs/validation/test-coverage-gaps.md:21` | Add a report-only llvm-cov build. |
| **Inconsistent tool-missing handling.** Without `cmake`, 27 Python tests fail or error, while sibling tests skip. CI has no gate on "tool unavailable" skips. | Low | review run; `test_app_dependency_cmake.py:22` | Handle missing tools one way, and fail CI on tool-unavailable skips. |
| **Stage-cache hits restore prior test results.** | Low | `tools/run_ci_stage.py:79` | Document the always-re-executing container path as the authoritative one. |

## 9. Deployment and release — 6/10 · Dependencies and supply chain — 5/10

**Strengths**

- **Pinning.** Every third-party action is SHA-pinned, and the repository enforces `sha_pinning_required: true` with read-only default token permissions. All 79 checkouts use `persist-credentials: false`. There is no `pull_request_target`.
- **Reproducible SDK inputs.**
  - The base image is digest-pinned (`packaging/sdk-core.Dockerfile:4`), the CA bundle is fetched with `ADD --checksum` (`:12`), Ubuntu packages come from an `apt-get --snapshot` (`:13`), and gRPC is pinned to a commit (`:19-22`).
  - Bazel is pinned by sha256, SQLite by `EXPECTED_HASH`, and FetchContent dependencies by commit.
  - Python locks are hash-pinned, and pub runs with `--enforce-lockfile`.
- **Release integrity.** Releases are built from an exact-commit candidate. Each installer gets a syft SBOM plus build-provenance and SBOM attestations. Publication re-verifies candidate, packaging and acceptance evidence (`release.yml:242-307`). Release tags are protected by a ruleset.
- **Lifecycle testing.** N-1→N upgrade with data persistence, reinstall and remove (`packaging/ci/test-release-package.sh:42-88`). The upgrade lock refuses a package change while the service or a recording is running.
- **actionlint with ShellCheck is a required gate** (`macos.yml:344-355`).

**Findings**

| Finding | Sev. | Evidence | Recommendation |
| --- | --- | --- | --- |
| **Third-party release credentials** (see §5.1 S1) ✔ | Critical | `tools/reference_distribution_config.py`; `tools/package.py:36-50,356` | Use project-owned or bring-your-own credentials, and retire the extraction tool. |
| **Release authority is policy, not enforcement.** The main ruleset requires 0 approvals and no code-owner review. There is no CODEOWNERS file and no protected `release` environment. `release.yml` is a plain `workflow_dispatch`, and its `main` checks live in the file itself. The attestation verification instructions pin only `--repo`. | Med | ruleset via `gh api`; `release.yml:2-3,83`; `RELEASING.md:165-167` | Add a `release` environment with a required reviewer and main-only deployment, and environment-scoped secrets. Add CODEOWNERS for `.github/**`, `tools/ci_*` and `packaging/**`. Verify with `--signer-workflow` and `--source-ref`. |
| **Vulnerability scanning is non-blocking and narrow.** The job and step are both `continue-on-error` ✔. The only run (2026-10-19) found GHSA-6w46-j5rx-g56g in pytest 9.0.2 and reported success. Scanning covers only 3 Python and 2 pub locks, not gRPC/abseil/boringssl, whisper.cpp, LiteRT, SQLite, bundled CPython or Homebrew ICU. | Med | `osv-scan.yml:12,18,22-26`; `requirements-dev.lock:592` | Scan the release SBOMs, or a manifest generated from `tools/pins.json`. Open issues for High/Critical findings and decide on a release gate. |
| **Updates have stalled.** Dependabot PRs #113–#116 were closed unmerged. `upload-artifact` is at v4.6.2 in 94 places and v7.0.2 in one. No ignore rules for Ubuntu majors. Digests and `ARG *_COMMIT` pins are not covered by any updater. The gRPC commit is duplicated in two files. Bot PRs opened with `GITHUB_TOKEN` don't trigger CI. | Med | `.github/dependabot.yml`; `linux-packages.yml:126`; `ci-dependencies.yml:64-86` | Add ignore rules and merge the grouped updates. Centralise native pins in `pins.json` with a consistency test. Use a GitHub App token for bot PRs. |
| **No end-user trust or update channel.** Linux packages are unsigned and there is no repository. The DMG is ad-hoc signed and not notarized. The app has no update check. | Med | `docs/platforms/linux-packaging.md:215-216`; `docs/platforms/macos-support.md:77-78` | Developer ID signing plus notarization, signed packages or a signed repository, and a minimal update notice. |
| **Unpinned release packaging inputs.** `rpm-build`, `makepkg` and `pacman -Syu` come from live mirrors, and `brew install icu4c` is unpinned while ICU is linked into `foresight-model`. | Med-Low | `packaging/ci/package-and-test.sh:13-19`; `.github/actions/setup-macos-stage/action.yml:44` | Use snapshot or archive repositories, pin or build ICU, and add a periodic reproducibility diff. |
| **No downgrade or rollback path.** The store refuses newer schemas (correctly), but no backup is taken before migrating. | Low-Med | `store.dart:196-200` | Take a `VACUUM INTO` snapshot before migrating and document rollback. |
| **Distribution secrets reach same-repo PR artifacts.** | Low | `macos.yml:72-75,497-500` | Inject secrets only for release and preview builds on `main`. |
| **The CI system's own weight.** About 16k lines of CI Python, about 23k lines of CI tests, three 30-minute crons (136 runs in about 2.5 days), intricate recovery rules, and leftover transitional triggers. | Low (structural) | `RELEASING.md:243-305`; `arch-drift.yml:5-8` | Freeze scope, retire transitional mechanisms, and reduce cron frequency. |

## 10. Documentation and developer experience — 6/10

**Strengths**

- **Large, mostly accurate documentation.** 51 docs, about 13.6k lines. 10 of 16 spot-checked claims were correct, including env vars, binary paths, CMake targets, toolchain pins, the profile ID format and the Python gate.
- **Enforceable contributor rules.** AGENTS.md and CONTRIBUTING.md give per-change check lists and rules against weakening gates.
- **Hash-locked setup.** Pinned Flutter 3.35.7 and clang-format 22.1.8 match CI. There is a single `tools/build.sh` entry point.
- **ADRs and threat notes.** The ADRs and architecture notes explain the design decisions.

**Claims checked against code**

| Claim | Source | Result |
| --- | --- | --- |
| Desktop coverage gate 76.35% | `README.md:376`, `CONTRIBUTING.md:33` | **Wrong**: 90%, Linux only ✔ |
| macOS PR CI enforces 90% core coverage | `README.md:376` | **Wrong**: minimum is 0, and coverage is off on PRs ✔ |
| Migrations end at v17 | `schema-migrations.md:40-58` | **Stale**: code is v19 ✔ |
| MCP tool list complete | `application-service.md:159-170` | **4 tools missing** |
| "Advanced OAuth configuration" import exists | `README.md:80,353` | **Removed**: a test asserts it is absent |
| Release by pushing to main | `README.md:390-395` | **Contradicts** `RELEASING.md` |
| Desktop runner is Linux only | `apps/desktop/README.md:3` | **Stale**: macOS runner exists |
| Python gate 95%, build env vars, binary paths, toolchain pins, profile ID, native env vars | various | Correct |

**Further findings**

- **12 broken relative links.** 9 point into the git-ignored `.granola-analysis/`, 2 are wrong-path self-links in `docs/plans/2026-10-19-ci-restructure-plan.md:170-171`, and 1 has a missing anchor.
- **7 docs are linked from nowhere.** They include `validation/test-coverage-gaps.md` and `platforms/ci-main-evidence.md`. The ADRs are not linked from README, CONTRIBUTING or `docs/README.md`.
- **Historical plans sit alongside current docs.** `docs/plans/` holds 15 files (7.6k lines) with no status markers, and 5 of them contain machine-local paths. This contradicts `docs/README.md:5`, which says such material lives in git history.
- **Heavy inner loop.** 194 files in `tools/` with no index. The documented `flutter test` differs from the gate invocation, which adds `--dart-define=FORESIGHT_ENABLE_TEST_HOOKS=true` and `run_core_tests.sh`.

**Recommendations:** (1) fix the six wrong claims and link RELEASING.md and the ADRs
from the docs index; (2) generate or CI-check drift-prone facts (gates, migration
table, MCP tool table) and run a link checker in `quality.yml`; (3) archive
`docs/plans/` or mark each plan with its status.

## 11. Observability and supportability — 4/10

**Strengths**

- **Typed errors.** `RpcErrorCode` errors carry `outcomeUnknown` and `closing`, and stack traces stay off the wire (`service_diagnostics.dart:17-25`). The desktop explains an unknown outcome in plain language (`apps/desktop/lib/failure_text.dart:5-15`).
- **Bounded, content-free trace.** The opt-in transport trace logs IDs and method names only and is capped at 16 KiB (`service_diagnostics.dart:7-15`).
- **Status tooling.** A `--status` command, a copyable helper-monitor dialog, and per-launch startup status files.

**Findings**

| Finding | Sev. | Evidence | Recommendation |
| --- | --- | --- | --- |
| **Linux diagnostics are discarded.** The Linux service starts `ProcessStartMode.detached` with no log redirect; only macOS gets `--stderr service-startup.log` ✔. Worker stderr goes to `/dev/null` ✔. Helper stdout and stderr are drained and dropped, leaving only "helper exited ($code)". | High | `service_startup.dart:688-715`; `native/foresight_native.cpp:290`; `services/helper/child_process.h:45`; `helper.dart:242-266` | Write a private (0600), size-capped, rotated service log on both platforms. Keep an in-memory tail of helper and worker stderr and surface it in `--status` and the helper monitor. |
| **Unstructured logging.** About 50 free-form `stderr.writeln` calls, with no levels or structure. | Med | `service_diagnostics.dart:23` and others | Add a minimal leveled, structured logger with redaction. |
| **No user-facing support path.** No troubleshooting doc, no `ISSUE_TEMPLATE`, and no mention of `FORESIGHT_SERVICE_TRACE` or log locations in any markdown. | Med | `.github/` | Add a "Troubleshooting and bug reports" guide and an issue form. |
| **Error text can carry user content.** `RpcError.from` sends `error.toString()`, which for `FormatException` includes the source text. The invalid-frame trace dumps raw frames. | Low | `rpc_error.dart:100-109`; `service_client.dart:95-97` | Use fixed messages for internal and format errors, and hash or truncate traced frames. |
| **The macOS `service-startup.log` is append-only and never truncated.** | Low | `service_startup.dart:697` | Rotate or truncate it on launch. |

## 12. Remediation roadmap

**Before the next release**

1. Replace the extracted Google credentials with project-owned or bring-your-own credentials. Remove the ODML and Granola dependencies or make them opt-in. Retire `tools/reference_distribution_config.py` and correct `README.md:353` (S1).
2. Make recording stop infallible: tear down capture first, retry state writes, dispose on a failed start, and release before indexing (R1, R4, R8).
3. Add a protected `release` environment and CODEOWNERS, and require one approval for workflow, trust and packaging paths.

**Next (weeks)**

4. Exclude transcripts from `content_revisions`, add retention, and switch live indexing to append-only chunks (R2, R3).
5. Reject duplicate request IDs and bound per-client send buffers (R5, R10).
6. Add a persistent, bounded service log on Linux, keep stderr tails, and write the troubleshooting guide and issue form.
7. Make OSV scanning cover the release SBOMs and native pins, open issues on High/Critical findings, and merge the stalled dependency updates.
8. Fix documentation drift and add drift checks for gates, migrations and MCP tools, plus a link checker.
9. De-flake `proactive_application_test.dart` and fix the misleading `pytest-exclusions.json` reasons.

**Later (structural)**

10. Split the client and server barrels so the desktop and MCP stop compiling in the service. Replace `Domain` as a locator with narrow ports and a single-owner generator slot.
11. Move model acquisition and device discovery into the service, and type the desktop command API.
12. Python typing ratchet, `tools` as a package, shared helpers, `ffi_barrier` in all C exports, and a complexity ratchet.
13. Developer ID signing and notarization, signed Linux packages, a pre-migration backup, and an update notice.
14. LSan with suppressions, native coverage reporting, and a macOS coverage floor.
15. Freeze CI tooling growth and retire transitional workflows.

## 13. Verification record

**Executed during this review.** Toolchain: Python 3.14.8 (CI uses 3.13) and
Flutter 3.35.7. Runs used a private `/var/tmp` root as `TMPDIR` and
`FORESIGHT_TEST_TEMP_ROOT`.

| Check | Result |
| --- | --- |
| `pytest -q -rs` | 5,511 passed, 57 skipped, 3 failed, 24 errors, 1,395 subtests passed. All 27 failures and errors were `FileNotFoundError: 'cmake'`, because no CMake is installed on the review host. |
| Dart core (`tools/run_core_tests.sh`, no native library) | 2,101 passed, 41 skipped, 1 failed (load-sensitive; see §8). 28 skips are for the missing native library or helper, 9 are macOS-only. |
| Flutter desktop (`flutter test --coverage` with test hooks) | 556 passed, 17 skipped, 0 failed. 93.70% line coverage (8,280 of 8,837), above the 90% gate. |
| `ruff check .`, `mypy` | Pass (166 files) |
| `dart analyze` (core), `flutter analyze` (desktop) | No issues |
| `dart format --set-exit-if-changed` | 0 of 718 files changed |
| Strictness probes (Dart strict modes, mypy strict flags, ruff C901) | Metrics only; reported in §7 |
| Repository settings via `gh api` (rulesets, environments, Actions permissions), OSV run log, Dependabot PR history | Read-only; reported in §9 |
| Markdown link checker (71 files, 217 relative links) | 12 broken |
| SQLite simulation of the history trigger and upsert SQL (synthetic, outside the app) | 600 rewrites → 120 KB transcript, 36.3 MB history |

**Coordinator re-verification.** The coordinator re-read current source for every
finding marked ✔ in §3, plus findings S6, the history trigger and the OSV
configuration.

**Not executed.** None of the following should be read as passing:

- Native CMake build and CTest, sanitizers, the compiled service/MCP suite, and the
  integration gates (models, virtual audio).
- Docker and package acceptance, actionlint, ShellCheck, zizmor and clang-tidy.
- Anything on macOS: Core Audio, Keychain, TCC prompts, signing, Gatekeeper.
- Real GPU and physical audio.
- Disk-full fault injection for R1.
- Any performance profiling. No latency or throughput numbers were measured.
- `gh attestation verify` against released assets.
- Whether the current repository secrets came from the extraction tool.
- Native-backed Dart tests. These stayed skipped rather than being pointed at
  installed `/opt/open-foresight` binaries, which are not a fresh build.
