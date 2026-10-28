# Agent instructions

Use [CONTRIBUTING.md](CONTRIBUTING.md) for setup, conventions and required checks.

- Before every push run `.venv/bin/python -m tools.check_local_validation`, then
  the applicable language/platform checks in CONTRIBUTING.
- Integrate small, independently verified batches, even when delivering one PR.
- Audit direct and transitive consumers of shared fixtures. After Python or
  tooling changes, focused tests and shared guards do not replace the full suite.
- Reproduce the exact failed CI entrypoint. Match OS, pinned tools, UID/GID,
  NSS account/home, caches, network isolation and source/JIT mode. Record gaps.
- Match the declared test concurrency separately from build parallelism;
  `FORESIGHT_BUILD_JOBS` does not limit Dart test fan-out.
- Check C++ library availability on the minimum supported Apple toolchain;
  selecting a language standard does not enable missing library features.
- Exercise the actual consumer; metadata checks and quiet component replays
  prove only their own scope.
- Make prerequisites part of the checked-in entrypoint, not a private shell.
  When changing native/build inputs, verify root/standalone CMake and sanitizer
  paths with their declared inputs; installed packages or a private exported
  temp root can hide CI failures.
- Require backends needed by shipped features at configure time. Verify the
  packaged library's actual capture routes; a legacy capture pass does not
  establish that durable recording was compiled in.
- Check feature-specific test prerequisites in each platform entrypoint. A built
  native library does not enable real codec tests without the fixed worker's
  verified build identity and hash; inspect skips before accepting coverage.
- Audit composite setup actions and slim artifact handoffs as well as workflow
  jobs. Required test executables must reach the stage that runs their tests.
- Exercise restored consumers offline with their actual UID and empty optional
  environment. Select validated handed-off products before attempting downloads.
- After changing Dart skips, run `python tools/check_integration_inventory.py`
  and review the matching inventory entries.
- After adding or moving core Dart libraries, regenerate the diagnostic source
  catalog with `dart tool/generate_diagnostics_catalog.dart` from the core package.
- Give each failure an owner, a bounded investigation and a concrete exit
  criterion. Confirm delegated agents are active and exchange source revisions,
  commands, evidence paths and blockers, not just pass/fail summaries.
- Stream long-running gates through every wrapper layer, retaining raw logs and
  command/log-writer failures. A heartbeat with a byte count is not test output.
- After finding a fixture error, audit equivalent call sites and verify one
  batch before freezing the candidate. Do not discover siblings one full run
  at a time. Repeat full gates after relevant fixes, not until a run turns green.
- Keep unset PIDs out of wait/signal calls. Publish fixture readiness only after
  its payload is complete, and observe process exit and resource release as
  separate fences within one deadline.
- Cleanup may find an already-exited child. Require the exact kernel exit and
  resource-release fences; successful signaling alone is not the exit proof.
- Retain closed subprocess status and query-shape metadata on ownership refusal.
  A generic ownership warning does not establish incorrect directory permissions.
- Probe injected fixtures through their actual parent boundary. An arm64 fixture
  must retire its insertion before launching protected arm64e system utilities;
  prove both pre-main insertion and the descendant environment.
- Join control readers before closing or reusing their descriptors. Keep the
  receipt write channel alive until completion is published.
- After observing worker exit, drain its output again before classifying open
  pipes as descendant ownership. Test exit between a nonblocking read and exit
  observation, retaining a real descendant-held-pipe refusal control.
- Positive owner restarts must use bounded production admission; keep immediate
  refusal tests synchronous. Retry only checked kernel contention, never an
  arbitrary error or a stale lock-file observation.
- Prove the intended phase was reached before asserting a timing outcome.
  Separate fixture setup from the measured phase without changing production
  deadlines; retain independent cold-start coverage.
- Place negative-control oracles in the layer being tested. An outer output
  limit must not satisfy an inner worker's overflow assertion.
- Check process-wide runtime overrides when substituting a test worker. An
  owned entry witness must prove the registered fixture actually executed.
- Observe already-started Futures before admission/deadline checks can throw.
  Keep regression operations and their uncaught-error observer in the same Dart
  error zone unless zone crossing is the behavior under test; prove the old code
  fails the controlled regression.
- Close and join held fixture operations before an entry failure escapes. An
  outstanding `expectLater` can prevent its closing teardown from running.
- Own fixture listeners and accepted RPC sockets. Graceful server shutdown can
  await unfinished peer streams; let HTTP/2 own its bound socket writer.
- Apply lazy logging thresholds only before sink admission. Prove that an
  admitted sink retains a small normal suffix after a summary has flushed.
- Capture the first failing shutdown stage before a terminal ownership warning
  obscures it. Use bounded stage/error-type diagnostics, never private payloads.
- Check native audio timestamps against the actual database span, including
  resume. A synced WAV can still violate publication bounds.
- Capture Stop seals audio; saved transcription continues. Before tests require
  a stable summary, observe drained saved-audio backlog and the expected final
  transcript sources, rather than only a closed recording or an indexed snapshot.
- Verify the actual macOS console is unlocked before GUI qualification. Report
  authorized local desktop execution separately from isolated-session evidence.
- Before another push, fetch the PR head, reviews and CI output; batch fixes
  against current code. Rerun failed jobs first.
- Distinguish implemented, locally verified and CI-passed. Report source
  revisions, test counts, skips and unexecuted environments. Retain failed output.
- A passing exact replay does not explain a failed concurrent suite. Keep its
  cause unconfirmed until controlled evidence establishes it; report subsets,
  deselections and missing UI prerequisites separately from full acceptance.
- Bind build and test evidence to source revisions and product hashes. Reuse
  verified unchanged products truthfully; rebuild affected executables after
  production changes and recheck packaged bytes after actual consumers run.
- Preserve tests, deadlines, coverage and integrity gates. Reuse verified SDKs;
  avoid unrelated cache deletion, clean builds and successful-job reruns.
- Use short, private `/var/tmp` directories with `TMPDIR` and
  `FORESIGHT_TEST_TEMP_ROOT` set. For macOS core boundary fixtures keep the
  canonical root at most 26 bytes, counting the `/private` prefix.
- Interpret status using the callee's contract: native negative errno values
  are not process signals.
- Follow [CI integrity](docs/platforms/ci-integrity.md), including owner review
  for workflow permissions, publishing and artifact-trust changes.

See [failure investigation and qualification](docs/testing.md#failure-investigation-and-qualification)
for the evidence and fixture contracts behind these rules.
