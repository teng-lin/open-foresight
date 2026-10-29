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

`evidence.json` is versioned (`schema` 2, `kind` `foresight-validation-evidence`;
schema 1 packets stay readable). It records revision and change identity,
entrypoint, arguments and working directory, OS and architecture, tool versions,
per-check status and reason, JUnit counts written during the run, raw-log paths,
real and effective UID/GID, supplementary groups, the NSS account and whether
`HOME` agrees with it, the temp-root policy (canonical, private, owned, short),
allowlisted environment and unexecuted platforms. The environment is read through
an allowlist of exact names. Credentials, profiles, transcripts and model assets
are never collected.

Schema 2 adds, all derived from what the run observed and never from the full
environment:

- `tool_pins`: each pinned tool (Flutter, Dart, protoc from `tools/pins.json`;
  actionlint and ShellCheck from the shared guards) beside what was observed and
  whether the pinned version is a whole token of the version line of its output
  (ShellCheck prints a banner first; the line that names a version is kept). An
  unobserved tool matches nothing and, in a run that probed tools, is the gap
  `pin-unobserved:<tool>`; a failed probe never matches and records only its exit
  status, never its output.
- `phases` per check: setup (could the entrypoint start here: `ok`, `unavailable`
  or `failed` when it never started or was interrupted before it did), body (the
  entrypoint's own outcome from its exit: `passed`, `failed`, `timed-out`,
  `interrupted`; unsupported JUnit evidence fails the check, not the body) and
  teardown. Teardown is observed, not assumed: after the entrypoint exits the tool
  lists the members of its process group before killing the group. `clean` means
  none remained; `group-survivors-killed` means some did and were killed;
  `leaked-descendants` and `killed-after-timeout` are the tool's own findings;
  `unknown` means it could not tell (an interrupted run, a process that survived
  SIGKILL or was never reaped, a failed probe). Only structured flags decide, never
  the wording of a reason. `clean` says nothing about descendants that left the
  group (a double fork with its own session). A phase the tool did not run is
  `not-run`, never inferred.
- `concurrency` (CPU count and the allowlisted parallelism settings), `cache`
  (reused outputs and whether each was present at planning and at execution) and
  `artifacts` (digests of reused products); paths under the account home are
  written with `~`, and a parallelism setting that is not a small integer is
  recorded as `invalid`. The producer of an artifact is `null`: only the
  entrypoint verifies provenance, and the gaps say so.
- `image`: the runner image variables (`ImageOS`, `ImageVersion`, when set) and
  the operating-system identity (os-release `ID` and `VERSION_ID`, or the macOS
  version). A field that cannot be observed is `null`.
- `reproduction_gaps`: what stands between a reader and an exact reproduction,
  derived from the packet (a plan that executed nothing, pin mismatches and
  unobserved pins, a non-compliant temp root, `HOME` differing from the NSS home,
  a dirty or unknown dirty state, a declared and unverified revision, unexecuted
  platforms, checks that did not pass, checks subsumed by another rather than run, an
  unidentified image, an unrecorded revision, unrecorded artifact provenance).
  Redaction has a deliberately narrow scope. Gap prose, a check's recorded
  `reason` and the `cache`/`artifacts` paths are redacted: absolute paths (bare,
  after a colon, quoted, or under an account directory containing spaces) become
  `<path>` (an account or volume path under `/Users`, `/home` or `/Volumes` is
  replaced up to the next sentence boundary, so a name with spaces leaves no
  fragment, at the price of swallowing a few following words), and cache/artifact paths under the account home start with `~`. A
  packet is **not anonymized**: it still carries the account name and home, the
  working directory, checkout root, interpreter path and retained log paths,
  because a replay needs them. Treat it as a local diagnostic, not as something to
  publish. An explicit file list records no revision (`revision-unrecorded`); only
  the change identity names its content. The environment allowlist concerns
  environment variables only; reasons and notes are bounded text written by the tool.

`python -m tools.validation_replay PACKET [--check] [--json]` reads a packet and
prints the recorded invocation, each failed check, the packet's gaps and the
differences between the recorded host and this one (operating system and
release, image identity, architecture, Python, tool versions, root versus
non-root, NSS account name, temp roots, and whether this checkout is at the
recorded revision and clean). A packet is untrusted input and the report says so:
everything printed is labelled "recorded, unverified", and every string from the
packet is reduced to printable ASCII (a backslash and every other character is
escaped, so invisible characters, look-alikes and literal `\x1b` text cannot pass
as plain text) with its length bounded. That includes the validation errors, which
quote packet strings. A packet cannot forge report lines or terminal sequences. A reproduction
command is offered only for `tools.validate_change`, the one entrypoint that
records packets, and a failed check's entrypoint only when it matches that gate's
definition in the boundary inventory (`{python}` must be an interpreter named
python or python3.N given as an absolute path (no `~`, no spaces or shell
metacharacters) or exactly `.venv/bin/python`, never a relative path or a bare
name, and outside the temporary directories (including `/var/folders` and the packet's own recorded `TMPDIR` and
test temp root); `{platform}` linux or macos; other placeholders printable paths of
bounded length without whitespace, shell metacharacters, `..` or a leading
`/tmp`); otherwise the report says "unrecorded". The packet must be a regular file under 8 MiB with correctly typed
fields; a FIFO, an oversized, deeply nested or wrongly typed packet is refused.
The replay never runs a recorded command and reads only `TMPDIR`, `FORESIGHT_TEST_TEMP_ROOT` (to judge this shell's temp roots) and `PATH` (to find tools) from its environment; on this host
it runs only `git status` and `git rev-parse` (without optional locks) and the
tools' `--version` probes (`flutter --version` may touch the Flutter SDK cache),
each with a 10 second limit. A failed probe on either side, an unreadable
revision or dirty state here, and an unidentified image are gaps, never matches. The
recorded arguments must parse as `tools.validate_change`'s own (no abbreviations,
unknown flags or parse errors: those print "unrecorded"), `--skip-inventory-check`
is never offered, and each path-valued flag (`--bundle`, `--models`, `--output`,
`--files-from`) is called out with a warning, because it points the run at a
location the packet's author chose. A packet cannot hide a gap by omitting it: the gaps its contents imply are
added to the ones it recorded. A replay that lists no gap still does not prove a
hosted failure reproduces; the recorded conditions are the ones this tool could
observe. `--check` exits 1 while any gap remains and 2 for an unreadable or
corrupt packet.

`python -m tools.check_entrypoint_parity` (part of the shared guards) reads the
workflows without changing them and checks that every command gate's script is
reached by some workflow step, or that the gate declares `local_only` with a
reason, and that a `local_only` claim no workflow contradicts. The `run:` text
is split into commands the way a shell would (comments stripped, quotes honored,
`;`, `&&`, `||`, pipes and newlines separate commands). A script is called when it
is a whole token in an executing position: the command itself (after keywords,
assignments and wrappers such as `env`, `time`, `timeout`, `xvfb-run`,
`dbus-run-session`), or the argument of `bash`, `sh`, `source`, `.`, `exec` or a
`python` interpreter that has no flag stopping it from running the script (`-n`,
`-c`). The segment must also *start* with something that executes: an interpreter,
a wrapper, a container launcher (`docker run`, `podman run`) or a repository script
that passes its tail on (`tools/run_ci_user.py ... -- bash tools/build.sh`), so
`echo use bash tools/build.sh`, `grep`, `git commit -m x ...` and `command -v`
never count. Anything else is not a call: `shellcheck tools/build.sh`, `bash -n`,
`python -m py_compile`, `ruff check`, `xargs`, `find -exec`, `cat`, `cp`, `chmod`,
`git add`, a quoted string, a comment, or a here-document body. A path with `..`
is never a script. A workflow job or step whose YAML `if:` is literally false
never runs and calls nothing; a workflow counts only if something can trigger it
(a `workflow_call`-only workflow counts only when a triggered workflow calls it),
and a composite action only if a reachable workflow or action `uses:` it. A gate
with a `--stage` or `--suite` is satisfied by a call with that value (`build.sh`
defaults to `--stage all`, so a call without `--stage` satisfies every stage); a
`--build-only` call builds and runs no tests, so it satisfies no gate that does
not ask for it. A gate that passes `--platform {platform}` needs a call for each
platform it lists. A call is exact for platform P only when its literal
`--platform` is P and its job's `runs-on` (`macos-*`, `ubuntu-*`) is P or unknown
(an expression or a label list stays unknown); with no flag the runner decides.
When the flag and a known runner disagree (`--platform macos` on an Ubuntu job)
the call is evidence for neither platform and is `may_call`. Removing the Linux
build step therefore cannot hide a missing macOS stage, or the reverse, and
switching a macOS job to an Ubuntu runner fails the guard.

**Two tiers; nothing is dropped by shell reasoning.** `called_by` lists steps that
make the call as a *top-level unconditional simple command* of the step's own
text: not inside an `if`, `case`, loop, function, subshell or conditional group,
not part of an and-or list (`a && b`, `a || b`), and not after a top-level `exit`
(an unconditional `{ ...; }` group, a pipeline and a closed block do not count
against it). An operator ending the previous line (`a &&` then a newline) joins
the two commands. Block nesting counts `if`, `while`, `for`, `case` and `until` at
every command position, including after `then`, `else`, `do` and `!`; if it ever
cannot be trusted (a `fi`, `done` or `esac` that nothing opened) everything after
that point is `may_call`. A top-level `exit` or `exec` makes later commands
`may_call`. After a wrapper (`env`, `timeout`, `xvfb-run`) the next word must itself
be an interpreter, a wrapper or a repository script, and a container launcher
(`docker run`, whose options and image have unknown arity) always gives `may_call`;
a token beyond the 512th of one command is `may_call` without a walk. Classification is linear in the text: separator runs are scanned once, and groups nested deeper than 64 make the whole text `may_call`. **Everything else that mentions the script in an executing position
is `may_call`**: conditional or chained calls, calls after an `exit`, calls made
by a repository shell script (shown as `via <script>`), a here-document fed to a
shell (`via <heredoc>`), and a call whose stage or suite comes from a variable
the guard cannot resolve. The guard never evaluates `if false`, `true || x`,
`exit` or a test, because each such shortcut dropped a call that bash really runs;
a call is exact or `may_call`, never absent. Script-mediated calls are
over-approximated, not evaluated: every command in a called script counts
whatever branch it sits in, so a dispatcher script credits every branch to every
step that calls it, and each script is read once per step. The one thing the guard
resolves is a GitHub matrix: a variable the step or job binds to
`${{ matrix.key }}` (or that expression written in the text) is replaced by each
value of a literal scalar list, when no `include` or `exclude` touches that key,
and the call becomes exact once per listed value. The size of the product is
computed first: more than 64 combinations for one step, or more than 2000
expanded steps in a run, is not expanded at all (a problem line, and the call
stays `may_call`). A step's `if:` of the form `matrix.key == 'v'` or `!= 'v'`
(optionally wrapped in `${{ }}`) is read against each expanded value, or against
every listed value for a step the matrix does not bind: a value that fails it
produces no call, so excluding `service` from the condition makes `service-stage`
unverified on macOS. Any other `if:` that mentions `matrix.` makes the calls under
it `may_call`; an `if:` that does not mention the matrix is not evaluated.

A gate (on a platform) with only `may_call` evidence is **wiring unverified**: it
is listed in the default output and in `--json` as `wiring_unverified`, it is
never counted as a pass, and it must be acknowledged with a
`wiring_unverified_reason` on the gate in the inventory, together with
`wiring_unverified_relies_on`: the `workflow:job` entries the acknowledgement rests
on. The guard fails if one of them no longer reaches the gate. A new unverified gate
therefore fails the guard, and an acknowledged gate that gains an exact caller is
a stale declaration. On the current tree that is `integration-virtual-audio`
alone (a test pins the set): it runs only through `bash tools/linux_acceptance.sh
audio` (the `acceptance-audio` job and the weekly audit), inside a container and
only when the audio selection variable allows it, and the guard cannot confirm
which branch runs. The four stage gates are verified on both platforms: Linux by
the `arch-drift.yml` build (`build.sh --platform linux`, whose missing `--stage`
is `all`) and macOS by the literal matrix in `macos.yml`. Gates that also have a
direct caller print their `may_call` entries as "May also run (not verified)".

**Stop rule.** This guard is a drift detector for a repository whose workflow
authors are trusted, not a defense against a hostile one. What blocks a change to
it is a fail-open verdict reachable in the current workflows, a denial of service
(time, memory or a crash), or a security finding in the replay or the evidence. A
contrived shell shape that merely over-credits an `exact` call is a documented
static limit, as are `if:` expressions that do not mention the matrix, the
contents of `case` arms and functions that are never called.

Hard limits (256 KiB and 5000 lines per script, 200 scripts and 5000 calls per
step, 1 MiB per workflow, 4 MiB of text lexed in total) are problems when hit,
never silent truncation. Each text is tokenized once, a script is lexed once per
run however many steps reach it, and only the first 64 arguments of a call are
kept: a longer call is marked so that its stage, suite and platform count as
unknown. A here-document is skipped only when it is plain and terminated (`<<EOF`,
`<<'EOF'`, `<<\EOF`, `<<END-OF`, several on one line); a body fed to a shell, with
a delimiter mixing quotes, or never terminated is read as `may_call`. A gate that
states a literal `--platform` is satisfied only by a call for that platform. A
workflow file that cannot be read (a broken symlink, binary or unreadable file) or
an unhashable key is a problem line, never a traceback.

The check also rejects a workflow that calls a repository script that no longer
exists and fails on any workflow shape it does not understand. It reads only
`.yml` and `.yaml` files, and refuses YAML anchors, aliases and duplicate keys (a
pull request controls these files; an alias expansion could exhaust the guard,
and a repeated `steps:` key would let the last one silently win). It is
script-level: it does not tell whether a conditional call runs, does not compare
arguments other than `--stage`, `--suite`, `--platform` and `--build-only`, and
lists inline `dart test`, `flutter test`, `ctest` or `pytest` invocations in its
`--json` output for information only.

## Reliability report

`python -m tools.reliability_report DIRECTORY [--minimum-sample N] [--json]
[--write-baseline FILE [--replace]]` aggregates the `evidence.json` packets in a
directory (local runs, or artifacts downloaded from CI) into a descriptive report:
outcomes per check, platform, hosted or local origin, selection (conservative or
narrowed), cache state (reused, fresh, none) and attempt, plus a rollup per
boundary. It reuses `ci_stats.failure_rate` and `ci_stats.percentile`.

What it refuses to do is the point:

- **Inputs are unauthenticated.** The report cannot tell a real packet from a forged
  one: it describes the packets it was given and is only as trustworthy as the
  directory. Do not point it at artifacts from pull requests you did not collect
  yourself. The report says so in its header and `trust` field, and counts (never
  shows) the distinct hosted runs and local origins behind its window. A
  `created_utc` before 2026-01-01 or more than a day in the future is rejected as
  implausible, so a back-dated forgery cannot take a real failure's first-run slot;
  that is a cheap check, not authentication, and a plausibly dated forgery still
  counts. Packet provenance (`created_utc`, `identity_sha256`, the revision) is
  self-reported and not authenticated. A change identity is used only if it is a
  lowercase SHA-256 hex digest. A check id listed twice in one packet counts once
  (the first listing; the excess is the `duplicate-check` rejection), so a packet
  cannot inflate its own denominator. A change identity seen at more than one
  revision on the same platform and origin is reported as an anomaly and its runs
  are labelled `contested`, carry the marker "identity collision: first-run attribution unreliable" and are shown as their own scope instead of in the first-run totals, so they cannot decide which run is first; the same
  identity on two platforms is normal and is keyed apart. A duration beyond the
  gate's own `timeout_seconds` plus 60 seconds (6 hours for a gate with none) is
  left out of the percentiles and counted as `seconds_excluded`.
- **Packets are untrusted.** Only regular files (never symlinks) up to 8 MiB are
  read, to a depth of 6 directories (a `gh run download` layout nests an artifact
  four deep), with caps of 5000 files, 500 directories and 256 MiB in total. Each
  packet must pass the evidence validation. Rejections are counted by class (not a
  regular file, too large, unreadable, not JSON, not an evidence summary, invalid,
  bad or implausible timestamp, duplicate, depth cap, file cap, byte budget, too many
  checks, observation cap) and never shown. Data
  that exists but was not read makes the report incomplete: a directory deeper than
  the cap, an unlistable directory, an unreadable or oversized file, a hit file,
  directory or byte cap, a packet with more than 256 checks, and more than 200,000
  observations in all. Each packet is reduced to its observations at once and
  dropped, so memory is bounded by the observation cap, not by the bytes read. An
  incomplete report is printed with that marked, the exit
  status is 3, and no baseline is written from it. A baseline is written without
  clobbering: a fresh file is hard-linked into place (it fails if the destination
  exists at that moment), and only `--replace` renames over an existing one. Packet
  files are opened without following a final symbolic link, so a link swapped in
  after the scan is refused. Content that is invalid, a
  duplicate, a symlink or a pipe loses nothing and leaves it complete.
- **Nothing a packet wrote is printed.** Groups use gate ids (of any kind, so manual
  and CI-only gates are attributed and excluded from rates) and boundary ids from
  this checkout's inventory and closed vocabularies; an unknown check id is
  counted as `unknown-check`. No path, user name, host, revision or reason can
  appear.
- **No invented rates.** A rate is shown only at or above the minimum sample of
  eligible (passed or failed) runs, default 20; below it the report says
  `insufficient sample (n eligible, m needed)` and shows counts alone. The
  denominator, excluded outcomes and cancellations sit beside every rate.
  Cancelled checks, checks that never started (setup failed), checks failed
  because their subsuming check failed, and unavailable, not-run, manual, CI-only,
  subsumed and planned checks are excluded and counted.
- **A rerun is not a sample.** Only the first *executed* run (passed or failed) of
  a change identity (per check, platform and origin) is an independent sample;
  later executed runs are reported separately as qualification repeats, so a green
  rerun never offsets a failed first run. An attempt that never executed (not run,
  unavailable, cancelled, never started, planned, manual, subsumed) is its own
  `excluded` row and consumes no slot, so a failure after a skipped attempt is
  still the first run. A packet with no change identity is labelled `unidentified`.
  Packets created in the same second are ordered by their recorded start time
  (`invocation.started_epoch`) when present, else by content digest.
- **Descriptive, with a fresh baseline.** Plan-only packets execute nothing and are
  not counted. Local and hosted runs are never mixed: the overall totals are
  keyed by origin and platform. The report states its own
  window, is a fresh baseline and is never compared with an earlier or frozen
  window; it makes no improvement, regression or flakiness claim. A check counts
  toward every boundary it serves, so boundary rows overlap, and boundary names
  come from the current inventory. The execution mode (source or compiled) is not
  recorded in a packet, so it is not a dimension. Recurring first-run failures
  list a check that failed on at least two distinct change identities.

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
input, an inconsistent inventory, or evidence that cannot be built or written (a
completed run still prints every result first and says the evidence failed on
stderr; a failed check still exits 1), 3 for a partial run and
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
both and the cell lists no missing coverage; the guard enforces both. Each cell
names its `boundary_id`, and the test must be listed as production-both-sides
evidence by that boundary, not by an unrelated one; a closed cell's note may not
name a gap ("not covered", "no coverage", "lacks coverage", "without coverage"
and similar). Of the 14
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
| Service to helper: malformed or partial frame | fixture-only | `helper_malformed_frame_test.dart` drives the production Helper, channel and transport against hostile raw-byte peers and a fixture HTTP/2 server with malformed gRPC messages, over a real Unix socket. Every call ends as a `GrpcError` (promptly when the peer closes with the request in flight, at its deadline otherwise), a second call settles (promptly for a closing peer, at its own deadline for a stalled one, which does not by itself rule out a wedged connection), nothing reaches the error zone even after teardown, and the same channel serves a replacement within ten seconds, which is the evidence it recovers. Verified on macOS and on Linux x86-64 (CI image options, uid/gid 1000, JIT): both test files passed 20 of 20 serial and 40 of 40 four-way concurrent runs, and the "peer closes before any frame" characterization settled at `DEADLINE_EXCEEDED` there too, so no `ECONNRESET`/`UNAVAILABLE` divergence was observed. The hosted macOS and Linux runs are the authority. Two known deficiencies are characterized in separate tests: bytes that are not HTTP/2, and a peer closing before any frame, are reported only at the call deadline (45 s by default, 30 minutes for `indexDocument`). It shows client-side settlement only, not the real helper's reception, and it does not pin `HelperChannel`: replacing it with grpc's stock channel changes no result, because the "Cannot add event after closing" race was not reproduced through a socket peer (240 racing calls) and is pinned only at transport-stream level by `helper_channel_test.dart`. |
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
