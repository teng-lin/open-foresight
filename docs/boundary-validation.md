# Boundary validation

A focused local test can pass while CI exercises a different boundary: Dart and
native code, desktop and service, service and helper, persistence and read
workers, source and compiled execution, restored build outputs, or the installed
application and operating system. `tools.validate_change` makes that assembly a
reproducible workflow. It tells you which consumers a change reaches, calls the
existing entrypoints that exercise them, and records what ran and what did not.

It is not a second test framework or a second authoritative selector. It unions
the current CI selectors with local boundary rules and calls the checked-in
entrypoints. It never narrows or retires a required CI check; that remains
subject to the [CI integrity](platforms/ci-integrity.md) qualification rules.

```sh
.venv/bin/python -m tools.validate_change --base origin/main --plan   # explain only
.venv/bin/python -m tools.validate_change --base origin/main          # run what is runnable
.venv/bin/python -m tools.validate_change --boundary service-helper   # one boundary, no change set
.venv/bin/python -m tools.validate_change --files tools/build.sh --plan --json
```

Use `TMPDIR` and `FORESIGHT_TEST_TEMP_ROOT` as described in
[CONTRIBUTING](../CONTRIBUTING.md). A run keeps its logs, `plan.json` and
`evidence.json` in a private directory under `/var/tmp` and prints its path.

## What counts as the change

With Git, the change is the union of four classes, each reported per path:

| Class | Definition |
| --- | --- |
| committed | `merge-base(--base, HEAD)` to `HEAD`. Empty without `--base`. |
| staged | The index against `HEAD`. |
| unstaged | The working tree against the index. |
| untracked | Files Git does not ignore. |

`--include` selects a subset. Renames appear as a delete plus an add, so both the
old and new locations select their consumers. The merge base keeps commits that
landed on the base branch after you branched out of the change.

For a source export without `.git`, pass `--files PATH...` or `--files-from FILE`
(newline- or NUL-separated, `-` for stdin). No Git command runs. Plans and runs both work from an export: the shared
workflow-lint guard names the workflow files for actionlint when no Git root
exists, since actionlint otherwise refuses to run outside a repository. `--revision`
and `--base-revision` only label the evidence; they are never verified. The
change identity is a SHA-256 over path, class and content (plus revision and
merge base), so a dirty tree is never confused with its `HEAD`.

## How checks are selected

1. The CI selectors are reused: `ci_changes.select_gates` (authoritative required
   CI) and `ci_selection.select` (observe-only candidate). Their union is
   reported after `ci_selection.closure` adds prerequisites and mandatory in-run consumers, each selected CI gate is mapped to its local equivalent in the
   inventory's `ci_gate_map`, and a selector failure broadens rather than aborts.
   The other required jobs from `ci_selection.required_jobs` (the CPU, audio and
   DEB acceptance jobs and the Arch/native job) map through `ci_job_map` to a
   local gate or a CI-only gate, so a run cannot pass while they never ran. When
   the sanitizer workflow's path filter (read by `ci_selection`) matches, the
   CI-only `native-sanitizers` gate is selected. The inventory guard fails if a
   required job has no mapping.
2. Impact rules in [`tools/boundary_inventory.json`](../tools/boundary_inventory.json)
   select downstream consumers, not only tests beside the changed file:

   | Change | Selects |
   | --- | --- |
   | Protobuf schemas and generated bindings | Wire consumers: desktop, MCP, frontend/worker bridge and helper, plus the drift check. |
   | Shared test support (`packages/foresight_test_support`, `packages/foresight_core/test/support`, `tests/service/gated_helper.py`) | Every Dart gate. The plan lists the test files that import the changed file (following support-to-support imports, `part` directives and conditional imports) and the Python tests that name it, such as the fixture-hygiene guard and the Dart/Python twin of a fixture, and the boundaries they exercise. A file the scan cannot read is kept as a consumer and makes the plan conservative. |
   | Native ABI | FFI, read workers, service consumers and packaged products, plus native and sanitizer gates. |
   | Runtime configuration | Model, helper, installed-product and harness consumers. |
   | Package layout | Installer, document-sandbox, launcher and harness consumers. |
   | Toolchain inputs, orchestration | Every boundary. |

Documentation is `docs/**` and top-level Markdown only. Markdown under a source
or test tree may be a fixture a test reads, so it stays unknown.

3. Direct triggers and cited tests select their own boundary. A `*_test.dart`
   selects its package's Dart gate. Documentation selects only the shared guards.
4. Anything no rule recognizes, and any path that is absolute, upward-traversing
   or not POSIX, is **unknown** and selects every boundary and gate. The plan
   lists these paths. To make one precise, add a trigger to its boundary; do not
   remove the fallback.

The shared guards are always selected.

## Reading a plan

Each selected check lists why it was selected, its real entrypoint, its
prerequisites and whether each is met, reuse decisions, and why it cannot run on
this host. Each selected boundary names its owning gate, its owner
responsibility and an `unverified` list: its documented gaps, any gate that is
unavailable here, and its manual probes.

Every boundary resolves to one of three kinds. An **executable** gate calls an
existing entrypoint (`check_local_validation`, `build.sh` stages,
`build_service_gate.sh` through the service stage, `build_dart_gates.sh` through
the core and desktop stages, the document sandbox, `integration_gates.py`,
`platform_python_tests.py`). A **CI-only** or **manual** gate states the
requirement that cannot be satisfied from a source tree, such as the hosted
installer matrix or installed-product acceptance.

Reused SDKs, build trees, bundles and model fixtures are shown as reused existing
outputs, with SHA-256 for key files. `validate_change` neither rebuilds nor
verifies their provenance; the entrypoint does. A reused output is never
presented as a fresh build, and a check is only ever a fresh execution of its
entrypoint. Long-running checks (full native build, Dart gates, integration
groups, full Python coverage) are listed as deferred until `--include-long`.

## Evidence and exit status

`evidence.json` is versioned (`schema` 1, `kind` `foresight-validation-evidence`).
It records revision and change identity, entrypoint, arguments and working
directory, OS and architecture, tool versions, per-check status and reason,
JUnit counts written during the run, raw-log paths, real and effective UID/GID,
supplementary groups, the NSS account and whether `HOME` agrees with it, the
temp-root policy (canonical, private, owned, short), allowlisted environment and
unexecuted platforms. The environment is read through an allowlist of exact
names. Credentials, profiles, transcripts and model assets are never collected.

| Overall status | Meaning |
| --- | --- |
| `plan-only` | Nothing executed. |
| `failed` | At least one executed check failed or timed out. |
| `partial` | Nothing failed, but a selected check was unavailable, deferred, manual or CI-only, or a needed platform did not execute. |
| `full-validation-passed` | Every selected check passed here, no needed platform is unexecuted, and nothing in `incomplete_reasons` applies. |

A check that declares JUnit reports passes only if each report exists, was
written during the run, parses, executed at least one test and records no
failures or errors. An empty change set (no `--base` on a clean tree, or
`--boundary` alone) is `partial` with a "nothing selected" reason unless you pass
`--baseline-only`; `--files-from` rejects empty input. `--skip-inventory-check`,
unreadable change content and a non-compliant temp root also prevent a full
claim (the last is refused with exit 2). `dirty` is always computed from the
staged, unstaged and untracked classes even when `--include` narrows the paths;
the change identity binds every dirty path, and a dirty path in an excluded class
is an incomplete reason. It is `null` for an explicit file list, which never
inspects the tree. A source
export inside another Git checkout is refused; pass `--files`.

Exit status is 0 only for a full pass (or a plan), 1 for a failure, 2 for invalid
input, an inconsistent inventory or unwritable evidence, 3 for a partial run and
128 plus the signal number after an interruption (130 for Ctrl-C, 143 for SIGTERM,
129 for SIGHUP). SIGTERM and SIGHUP are routed like Ctrl-C: the entrypoint's
process group is killed, the results so far and the evidence are written, and
the signal handlers are restored. That holds while checks run, including their
reuse observation and JUnit parsing, and while results are published (signals are
held until the evidence is written). An interruption during argument handling or
planning happens before any check ran, so it exits the same way but writes no
evidence. `--allow-partial`
turns 3 into 0 without changing the recorded status. A missing prerequisite or
unexecuted platform cannot produce a full-validation claim.

## Assurance states

`validate_change` can establish only the second state. The others come from other
evidence and must be reported separately; one never implies the next.

| State | Established by |
| --- | --- |
| Implemented | The change exists in the tree. |
| Locally verified | A selected check passed on this host; recorded in `evidence.json` with source identity. |
| CI-passed | Hosted jobs passed at the final head, including platforms the host cannot run. |
| Installed-accepted | Release or preview acceptance exercised the exact installer bytes. |
| Unexecuted | Listed in `unexecuted_platforms`, `unverified` or a non-passed check. |

## The boundary inventory

`tools/boundary_inventory.json` records, per boundary: producer, consumer,
invariants, tests by kind, execution modes, platforms, prerequisites, owning
gate, owner responsibility, and gaps. Evidence kinds keep their meaning:
`production-both-sides` runs production code on both sides, `fixture` replaces
one side, `static-guard` checks source or metadata, and `manual` needs an owned
machine or authorization.

`python -m tools.boundary_inventory` (part of the shared guards) fails when the
inventory drifts from:

- `tools/integration_probes.json`: every probe is mapped and its mode agrees
  with the evidence kind.
- `tools/integration_skips.json`: evidence in a skip-inventoried file carries its
  skip gate, because a skipped test is not evidence.
- `pytest-exclusions.json`: explicitly run modules are flagged and mapped.
- Registered tests: every cited name must still be registered (Dart names may
  be wrapped, concatenated or interpolated; Python parametrization is ignored).
- Entrypoints: every gate's script or module exists.

A boundary with no production-both-sides test must state its gap. Adding a gate,
test or boundary is a data edit in the same change as the test.

### The lifecycle matrix

The consolidation removed `docs/architecture/service-lifecycle-tests.md`; its last
content is `git show f7c06383:docs/architecture/service-lifecycle-tests.md`. The
inventory's `lifecycle_reconciliation` re-checks each baseline gap against
currently registered tests, with evidence and what remains missing. A cell is
`closed-production` only with a read test whose recorded sides say production on
both and the cell lists no missing coverage; the guard enforces both. Of the 14
baseline gaps **none is closed**. Two (desktop crash, and desktop EOF before reply)
are now substantially proven by contract tests that kill a real service under a
real `RemoteDomain`, but they stay partial because the remaining gaps are
listed in each cell's `missing`, not in a note. All verdicts are pinned in a test.

| Cell | Verdict | Why |
| --- | --- | --- |
| Desktop to service: crash | partial | `service_crash_contract_test.dart` attaches the production `RemoteDomain`, with its approval window visible, to the real service entrypoint (test-hook build) and SIGKILLs it (exit `-9` is asserted). With no command issued, the desktop reconnects on its own (`RemoteDomain` listens for its connection ending) and starts one replacement; the committed note survived, and an agent's overwrite is approved through the re-attached window. A control shows a request issued after the loss was seen is sent once and succeeds. Not proven: several requests in flight, a crash before the commit or during startup, a service with its helper or a recording active, the macOS launch path and a real desktop launcher (the replacement is started by a `/bin/sh` launcher). |
| Desktop to service: EOF before reply | partial | The same test holds the service after the commit and before the reply and kills it: the pending `notes.save` ends `outcomeUnknown`, is not resent, and the replacement holds the note exactly once. One request at one instant; the same unproven list applies. |
| Desktop to service: slow reply | fixture-only | Only a fixture service holds a non-attach reply for `RemoteDomain`. |
| Desktop to service: reconnect, duplicate launch | partial | Reconnect after an unclean loss is now proven against a real service, but the baseline's other gap is unspecified and backoff, attach-timeout and epoch behavior are fixture-only. The older facade test SIGTERMs with no mutation in flight and its `no_mutation_replay` field is a literal `true`; the SIGKILL test above, not that field, is what proves non-replay. |
| MCP to service: slow reply | fixture-only | Real MCP binary against a fixture service. |
| Frontend to worker isolate: slow reply | open | The nearest test is a service commit/reply gate, not a bridge assertion. |
| Service to helper: closing | partial | The gate test proves graceful release with a stand-in helper; the real-helper stop test proves only that the pid is gone, which a SIGKILL fallback also satisfies. An adopted real helper does exit with SIGTERM. This was first recorded as closed and was downgraded. |
| Service to helper: reconnect, EOF before reply | partial, fixture-only | One real-helper crash test has no RPC in flight, so it supports restart and recovery, not channel reuse or a lost reply. |
| Service to helper: slow reply, duplicate launch | fixture-only, partial | No real helper answers slowly; adoption is covered but two helpers on one storage are not. |
| Service to helper: malformed or partial frame | fixture-only | `helper_malformed_frame_test.dart` drives the production Helper, channel and transport against hostile raw-byte peers and a fixture HTTP/2 server with malformed gRPC messages, over a real Unix socket. Every call ends as a `GrpcError` (promptly when the peer closes with the request in flight, at its deadline otherwise), a second call settles (promptly for a closing peer, at its own deadline for a stalled one, which does not by itself rule out a wedged connection), nothing reaches the error zone even after teardown, and the same channel serves a replacement within ten seconds, which is the evidence it recovers. Verified on macOS only: the "peer closes before any frame" characterization expects `DEADLINE_EXCEEDED` and may be `ECONNRESET`/`UNAVAILABLE` on Linux, so the fixture-only verdict is not claimed for Linux until it has run there. Two known deficiencies are characterized in separate tests: bytes that are not HTTP/2, and a peer closing before any frame, are reported only at the call deadline (45 s by default, 30 minutes for `indexDocument`). It shows client-side settlement only, not the real helper's reception, and it does not pin `HelperChannel`: replacing it with grpc's stock channel changes no result, because the "Cannot add event after closing" race was not reproduced through a socket peer (240 racing calls) and is pinned only at transport-stream level by `helper_channel_test.dart`. |
| Lock and record handoff: duplicate launch | partial | The baseline's gap is not specified. |

Two citation corrections follow the same review: the MCP boundary's
`ServiceConnection` closing test is labeled a fixture, because the MCP process and
protocol layer are replaced by the harness, and the launcher boundary no longer
cites the release-build gate-stripping control. Statuses are claims about
registered tests, not proof that those tests pass; CI does that.

## Scope of this batch

Implemented here: the planner, inventory and evidence summary above, and the
first contract tests (desktop crash and EOF before reply against a real service;
helper malformed frames against a hostile peer). Not implemented: fixture-ownership
standardization, the remaining lifecycle cells, wiring `validate_change` into CI callers, failure triage of the current nightly
and reliability measurement. Those remain separate batches of
[#192](https://github.com/teng-lin/open-foresight/issues/192), and none of this
changes a workflow, deadline, coverage floor or artifact-trust control.
