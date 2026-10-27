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
(newline- or NUL-separated, `-` for stdin). No Git command runs. `--revision`
and `--base-revision` only label the evidence; they are never verified. The
change identity is a SHA-256 over path, class and content (plus revision and
merge base), so a dirty tree is never confused with its `HEAD`.

## How checks are selected

1. The CI selectors are reused: `ci_changes.select_gates` (authoritative required
   CI) and `ci_selection.select` (observe-only candidate). Their union is
   reported, each selected CI gate is mapped to its local equivalent in the
   inventory's `ci_gate_map`, and a selector failure broadens rather than aborts.
2. Impact rules in [`tools/boundary_inventory.json`](../tools/boundary_inventory.json)
   select downstream consumers, not only tests beside the changed file:

   | Change | Selects |
   | --- | --- |
   | Protobuf schemas and generated bindings | Wire consumers: desktop, MCP, frontend/worker bridge and helper, plus the drift check. |
   | Shared test support (`packages/foresight_test_support`, `tests/service/gated_helper.py`) | Every Dart gate. The plan lists the test files that import the changed file, following support-to-support imports, and the boundaries they exercise. |
   | Native ABI | FFI, read workers, service consumers and packaged products, plus native and sanitizer gates. |
   | Runtime configuration | Model, helper, installed-product and harness consumers. |
   | Package layout | Installer, document-sandbox, launcher and harness consumers. |
   | Toolchain inputs, orchestration | Every boundary. |

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
| `full-validation-passed` | Every selected check passed here and no needed platform is unexecuted. |

Exit status is 0 only for a full pass (or a plan), 1 for a failure, 2 for invalid
input or an inconsistent inventory, and 3 for a partial run. `--allow-partial`
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
`closed-production` only with a read test that has production on both sides. The
reconciliation found one baseline fixture-only cell already covered (service to
helper closing) and left the others open or partial, including the helper
malformed-frame gap, which has no test. Statuses are claims about registered
tests, not proof that those tests pass; CI does that.

## Scope of this batch

Implemented here: the planner, inventory and evidence summary above. Not
implemented: fixture-ownership standardization, new behavioral contract tests,
wiring `validate_change` into CI callers, failure triage of the current nightly
and reliability measurement. Those remain separate batches of
[#192](https://github.com/teng-lin/open-foresight/issues/192), and none of this
changes a workflow, deadline, coverage floor or artifact-trust control.
