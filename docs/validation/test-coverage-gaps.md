# Test coverage gaps and integration priorities

Assessment date: 2026-10-19. Initial baseline source: `da39f98d`;
synchronized base: `a739c640` (#140).

The repository has substantial service, native, model, and meeting integration
tests. The initial baseline predated #140, which raised the Python gate to 95%,
enabled subprocess measurement, and expanded its scope to native Python tools.
The separate percentages do not establish 90% repository-wide coverage.
Prioritize first-run setup through the real service, ordinary packaged
startup, and platform acceptance. Raising unit coverage alone cannot establish
those user journeys.

## Coverage measurements and gates

| Surface | Configured gate | Evidence and scope |
| --- | --- | --- |
| Python | 95% combined statements and branches after #140 | Synchronized full-suite measurement: **95.94%**, 2,426 passed, 32 skipped, in both the worktree and Git-free export. Historical pre-#140 baseline: **60.98%** on its narrower scope. |
| Dart core | 90% lines when the coverage gate is enabled | Fresh full-suite measurement: **90.56%**, 8,959/9,893 lines; 980 passed, 10 skipped. `tools/coverage_core.sh` filters generated files and measures `lib`. |
| Flutter desktop | 90% lines on Linux | Fresh full-suite measurement after the improvements below: **92.10%**, 5,546/6,022 lines; 240 passed, 17 skipped. The previous Linux minimum was 76.35%. The macOS path collects coverage without that desktop minimum check. |
| Native and helper | No numerical coverage gate found in the reviewed build/workflow paths | CTest and sanitizer suites exercise these components; their passing results do not supply a line or branch percentage. |

Python's [configuration](../../.coveragerc) measures `tools` and `packaging`,
enables branches, and omits `tools/test_*.py` and oracle test files. After #140 it
also measures native Python tools and child processes. It does not
measure the Dart application or native C++. The default
[pytest configuration](../../pytest.ini) excludes `tests/integration` and
`tests/service`, plus four inference CLI harnesses. Their reasons are recorded
in [pytest-exclusions.json](../../pytest-exclusions.json). Ordinary Python passes
therefore cannot establish that those integration suites executed.

The 32 local skips comprise five missing SentencePiece dependency cases, two
restricted detector cases, six CTest-only native loader cases, sixteen macOS
toolchain cases, and three Linux package-tool cases. Preserve those distinctions
when comparing this result with hosted CI.

The historical offline report below did not include execution inside child
Python processes. #140 now instruments subprocesses. Compare measurements only
when their source scope and instrumentation match.

## Existing integration coverage to retain

| Boundary | Existing tests and execution path |
| --- | --- |
| Service, MCP, helper, native, SQLite | `tests/service/test_service_process.py` and `test_worker_recovery.py`, invoked by `tools/build_service_gate.sh`. Covers concurrent clients, cancellation scope, service restart, profile isolation, shutdown, worker recovery, and imports. The onboarding import test preserves pending text before embedding configuration and verifies subsequent indexing. |
| Real desktop and compiled service | `apps/desktop/integration_test/service_mcp_test.dart`, driven by the service subprocess suite on an isolated display. Checks shared ownership, MCP changes visible in the desktop, recording ownership, persisted artifacts, and desktop restart. |
| Real models | `tools/integration_gates.py --suite models`: five desktop tests and one core test, including grounding, helper restart/deletion, Google loopback fixtures, Gemma cancellation, and web-tool memory. |
| Virtual audio and meeting journey | `--suite virtual-audio`: three desktop tests and one core test. The meeting workflow also exercises imports, URL refresh, source pause/resume, notes, citations, graph persistence, export, and workspace clearing. Public model fixtures and private PipeWire avoid personal data and host audio. |
| Document sandbox and installed packages | `tests/integration/test_linux_documents.py` and installed-package probes exercise the real PDF/RTF parser. Package acceptance is separate from the offline unit gate. |
| Skip and probe accounting | `tools/check_integration_inventory.py`, `integration_skips.json`, and `integration_probes.json` track explicit validation paths. The scanner recognizes named Dart `skip:` registrations; arbitrary early returns require review. |

See [integration gates](integration-gates.md) for workflow selection, isolation,
restricted assets, and the exact executed-test counts. The initial audit inspected
this wiring. Subsequent desktop validation ran native, core, service, and UI
checks as recorded below; real-model and installed-package acceptance remain
separate.

## Prioritized gaps and acceptance criteria

### First run through the real desktop and service

**Priority 1.** The existing native UI and meeting tests call
`apps/desktop/test_support/onboarding.dart`, which advances through setup using
the skip actions. `apps/desktop/test/onboarding_workflow_test.dart` covers richer
interactions with `SetupDomain`, `OfflineHelper`, and test desktop connections.
The service onboarding-import test covers one backend boundary, but these checks
do not establish the complete first-run journey across independent processes.

Add a dedicated native UI case with a fresh profile and compiled service. Save
progress at each setup step, close and reopen the desktop, and restart the
service at a partial step. Verify the persisted step, accepted model terms, and
completion through a separate service client/read-only store. Attempt quick
recording during incomplete setup and verify that no meeting/capture starts.
Import a document before model setup, configure a verified fixture through the
UI, and observe pending to indexed state after restart. Exercise setup failures
and retries without falsely marking onboarding complete.

Use deterministic local download fixtures for transport failures and the
existing verified model fixtures for native adoption. Keep OS permission prompts
in dedicated platform acceptance.

### Model acquisition through setup and process restart

**Priority 1.** Download and setup tests already exist, including fixture
downloaders and read-only preference tests. The main E2E journeys install models
separately from onboarding, leaving the combined acquisition/adoption path weak.

Add a loopback HTTP fixture to the real desktop/service setup case: interrupt a
download after observing partial bytes, restart the owning process, and verify
the downloader's intended retry/resume behavior. Supply a checksum mismatch and
an unavailable endpoint; assert visible errors, no invalid model registration,
and successful retry. Verify a previously usable model stays registered after
cancellation. Keep a separate checksum-pinned public-model adoption case so a
transport fixture cannot stand in for real inference.

### Ordinary packaged launch and upgrade

**Priority 1.** The probe inventory classifies
`tools/test_default_model_startup.py` as manual. Model manifests and preconfigured
fixtures in integration tests can bypass default model discovery. Existing
package and profile-migration tests should remain in place.

Automate ordinary startup from a relocated installed bundle with no developer
model/runtime overrides, then check the resolved runtime identity and a useful
service operation. Add an upgrade journey using a frozen synthetic older
profile: stop an active prior service safely, upgrade, reopen notes and sources,
and verify migrations, helper identity, and continued indexing. Preserve profile
data on a failed upgrade and assert the documented recovery behavior. Run this
with an already compatible SDK and package payload; no dependency rebuild is
required by a test-only change.

### Permissions and desktop integration

**Priority 2.** The native UI fixtures provide controlled capture/inference.
They cannot establish real macOS permission prompts, denial/regrant behavior,
or OS notification delivery. The inventory also marks the global-shortcut
probes as manual.

Retain deterministic failure tests in PR CI. Add platform acceptance for first
request, denial, grant, revocation, and relaunch, verifying both visible state and
whether capture starts. Exercise the registered global shortcut on an owned
isolated desktop while onboarding is incomplete and after completion. Run real
macOS permission checks on a disposable macOS account/session and report them
separately from mocked capability tests.

### Physical audio and GPU behavior

**Priority 2.** Virtual microphone loss/recovery is already automated. Physical
microphone/system audio, sleep/wake, hardware removal, and physical GPU fidelity
remain separate acceptance gaps documented in `integration-gates.md`.

Use an opt-in hardware matrix with explicit device/backend identity, transcript
checks, bounded recovery, and retained logs. Verify a software or CPU fallback
is reported accurately. Never turn unsupported hardware or missing fixtures into
a passing coverage result.

### Coverage visibility and test isolation

**Priority 2.** The large meeting workflow contains many scenarios in one
`testWidgets` registration. Exact test counts detect skips, but do not identify
which scenario was reached before an early failure. Split independent import,
graph, and workspace-clear journeys into focused integration cases where setup
cost permits; retain one full meeting journey. Update expected executed counts
and preserve all current assertions.

Publish separate Python, core, desktop, native, and integration evidence with
source revision and executed/skip counts. Consider native C++ instrumentation
in a separate reusable build configuration. Preserve the Python 95% gate and
subprocess collection introduced by #140. Do not combine these percentages into
a repository-wide number.

## Python hotspots

The initial baseline's largest missed statement counts included the following
production scripts. These historical percentages predate #140's additional tests
and measurement scope; they are not current gaps. Reassess remaining missed lines
from the synchronized report. Percentages include branches.

| File | Coverage | Missed statements | Next useful check |
| --- | --- | --- | --- |
| `tools/smoke_macos_bundle.py` | 31.72% | 280 | Packaged macOS runtime failures and retained diagnostics on macOS. |
| `tools/legacy_query_executor.py` | 0% | 179 | Verify the seven skipped dependency tests and separately instrument subprocess execution. |
| `tools/integration_gates.py` | 41.07% | 137 | Real reporter subprocess failures; private audio startup/cleanup; CLI failed summaries. |
| `tools/macos_bundle.py` | 22.78% | 134 | Bundle-layout and missing-runtime fixtures plus actual macOS acceptance. |
| `tools/package_macos.py` | 16.42% | 131 | Packaging failure paths using fixture tools, with hosted macOS validation. |
| `tools/smoke_bundle.py` | 0% | 130 | CLI fixture execution and separate real-bundle acceptance. |
| `tools/ci_artifacts.py` | 76.99% | 106 | Remaining provenance, malformed receipt, and artifact selection branches without compiling SDKs. |

## Improvements in this worktree

`tests/test_integration_runner_process.py` adds 15 checks using a real reporter
child process and the real integration CLI. They verify desktop/core invocation,
working directory, temporary integration aliases, log retention, rejection of
skipped/hidden/failed/extra tests, missing or unsuccessful final events, malformed
reports, nonzero exits, stale success removal, and failed summaries for missing
CLI prerequisites. These are integration-runner tests, not product E2E tests.

The initial audit reused the existing Python environment and left coverage
configuration unchanged. The desktop improvements below subsequently raise its
Linux gate; Python coverage configuration remains unchanged.

Historical validation before synchronization: **1,303 passed, 32 skipped** in the
worktree and a complete source export outside any Git repository. Python's
combined coverage increased from **60.98% to 61.03%**; the integration runner
increased from **41.07% to 43.15%**. Ruff, mypy (118 production source files),
subprocess-timeout checks, and the integration inventory check passed. These
results validate the runner changes. The product E2E priorities above remain
separate from the desktop line-coverage target.

## Desktop coverage improvements

The full desktop suite now executes 240 passing tests and 17 explicit skips,
with **92.10% line coverage** on the unchanged source scope. Sixty-three additional
tests cover private D-Bus shortcut registration and denial, Hyprland conflict
checks and rollback, audio capability errors, notification and shortcut
preferences, model registration and adoption, source editing with retry, editable
notes, meeting formatting and enhancement, transcript-file dispatch, startup
ownership, file discovery, and setup surfaces.

The speech installer now checks cancellation and mounting after its injected
service installer returns. A regression test demonstrated that closing setup
while adoption was pending previously invoked the installed callback afterward.
Small injectable dependencies for speech downloads, Hyprland commands, and
startup device discovery preserve their existing production defaults and keep
tests independent of network downloads and the host desktop. Installer fixtures
exercise UI lifecycle behavior; real model bytes remain the responsibility of
the checksum and model acceptance suites.

`tools/build_dart_gates.sh` now enforces 90% desktop line coverage on Linux, and
the desktop coverage CLI tests accept exactly 90% and reject 89%. No coverage
exclusion or denominator filter was added. Flutter 3.35.7 was reused at the
CI-pinned commit `adc901062556672b4138e18a4dc62a4be8f4b3c2`; package resolution
used the existing cache offline with the lockfile enforced. No SDK or native
dependency rebuild was needed.

The CI minimum remains **90%**. A follow-up adds 13 workflow regressions to
provide a buffer above that gate: keyboard navigation, Google refresh/disconnect,
partial batch imports, source retry/delete actions, summary history, detection
retry, meeting-scoped questions, live transcript display, answer presentation,
custom export-date boundaries, and graph embedding failure. This follow-up changes
only tests and their fixtures; production code and coverage scope are unchanged.

Validation also passed all 29 root CTest cases using the existing native/helper
build, the complete desktop suite from a Git-free source export with development
hooks disabled (240 passed, 17 skipped), and 59 related Python gate tests both in
the worktree and source export. Flutter analysis, Dart formatting, ShellCheck
0.11.0 with external sources enabled, and integration-inventory checks passed.
The core suite passed with current native-library/helper paths and its 90% gate;
the explicit source-compiler test with development hooks enabled also passed.

The real desktop/service/MCP integration ran on a private guarded Agent Desktop
display and verified 40 passing observations. The compiled subprocess suite
initially passed 19 cases and failed crash recovery because the cached helper
advertised application version 0.1.1 rather than 0.1.2. Regenerating only the
helper identity unit and relinking existing implementation/protocol objects and
libraries corrected that input mismatch. The failed recovery case and real UI
integration then passed with the matching helper. Its release-hook check passed,
and the owned display was destroyed afterward. Service and MCP AOT executables
were compiled from current sources; native dependencies were retained.

Initial core runs also exposed an excessive temporary path and a 30-second CLI
test timeout during concurrent local workloads. The final passing core coverage
run used the short private disk-backed directory `/home/blackmyth/fc-tmp`, four
workers, and a two-minute default test timeout. Failed-run output was retained;
no assertions or coverage filters were removed.

Synchronization with #140 exposed a host-dependent assumption in its private
audio daemon fixture: the fixture mocked daemon processes but still inspected
the real `/dev/snd`. The fixture now models the required device-free host for
that one path; all other filesystem checks remain real. The separate regression
that rejects host sound devices is retained. The 65 integration-runner and
orchestration tests pass together with this correction.

After synchronization, both full Python coverage runs passed: **2,426 passed,
32 skipped**, with **95.94% combined statement/branch coverage** and the inherited
95% minimum enforced. The post-rebase desktop run again passed **240 tests,
17 skips**, at **92.10%**, and Flutter analysis and Python lint checks passed.
Logs are `coverage/python/rebased-verified.log`,
`coverage/python/rebased-export-verified.log`, and
`coverage/desktop/rebased-full.log`. The synchronized changes do not alter core,
native, service, or desktop source relative to their previously recorded runs,
apart from this worktree's existing desktop changes; those build outputs were
reused.

The initial hosted macOS desktop run exposed two portability assumptions in the
new fixtures: D-Bus's automatic authentication identity lookup supports Linux
and Windows only, and discovery returns canonical `/private/tmp` paths for
macOS `/tmp` inputs. Private D-Bus clients now supply an explicit fixture identity;
file discovery tests use canonical expected paths and select symlinked folders
on every host. No tests are skipped and production authentication/discovery
behavior is unchanged. Native/core artifacts and SDK inputs are unchanged, so
the follow-up can reuse their completed verified artifacts. Actual macOS runtime
validation still requires the hosted desktop job.
Both corrected full desktop suites passed locally (240 passed, 17 skipped,
92.10%), including the Git-free export with development hooks disabled. Analysis
and formatting passed. Logs are `coverage/desktop/ci-portability-fix.log` and
`coverage/desktop/ci-portability-export.log`.

## Reproducing the baseline

From the worktree root, with the pinned Python dependencies already installed:

```sh
FORESIGHT_PYTHON=/path/to/existing/venv/bin/python tools/coverage.sh -ra
python tools/check_integration_inventory.py
```

Local raw results are retained under `coverage/python/`: `baseline.log` and
`baseline.json`, followed by `final.log`, `final.json`, and `source-export.log`.
Generated coverage files are ignored by Git. The source-export run used a full
`git archive` plus the new test file, without `.git`. Keep both the export and
disk-backed `TMPDIR` outside any Git worktree: an initial rerun with a nested
temporary directory failed the existing exported-build identity test because Git
discovered the parent repository. Both failed logs were retained with
`nested-tmp-failed` suffixes; both suites passed after moving the fixtures.
Desktop validation logs are retained under `coverage/desktop/`, including the
full coverage runs in `final.log`, `final-confirmed.log`, and
`buffer-final.log`. `buffer-export.log` records the full Git-free run with
development hooks disabled; both buffer runs measured 92.10%. The first environment-only failures are
retained separately. The cached Flutter SDK was located after the initial audit;
Apple execution still requires a macOS host. Docker/package and real-model
acceptance remain separate from these line-coverage results.
