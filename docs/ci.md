# CI, dependency reuse and installers

CI validates the selected source, reuses verified dependency outputs and tests
the application bytes passed between jobs. The [CI integrity rules](platforms/ci-integrity.md)
define producer trust, publishing permissions and release provenance. Follow
[AGENTS.md](../AGENTS.md) when changing or retrying these checks.

## Current pull request procedure

`tools/ci_changes.py` selects platform gates from the changed paths. Documentation
and explicitly listed maintenance changes avoid native builds; unknown paths
select every platform. Mixed changes take the union. The `platform-checks` and
`acceptance-checks` aggregates report the result even when expensive jobs are
unselected. A skipped selected job is not successful execution.

The unconditional Python quality job owns the ordinary Python suite and its 95%
line/branch coverage gate. Root Python test changes do not by themselves require
an application rebuild. Explicit package, native, service and platform contracts
retain their assigned gates. `tools/platform_python_tests.py` maintains the
inventory of real compiler, filesystem, shell and platform-tool fixtures.

Workflow lint runs independently with actionlint and ShellCheck on PATH. Its
result remains required on documentation-only changes. Native/protocol/service
changes require the full root CTest and current core/desktop suites against the
fresh library and helpers; service/capture boundaries additionally require
compiled service/MCP and isolated-display integration. See [testing](testing.md)
and [native verification](../native/README.md#verifying-native-changes).

Before a follow-up push, inspect the latest PR head, review threads and failed
step output. Reproduce failures against current code, preserve captured output
and batch related fixes. Check test counts and skip reasons as well as exit codes.

## Platform check names

Display names use the same categories on both platforms. Internal job IDs,
artifact names and provenance receipts retain their existing identities.

| Display | What executes |
|---|---|
| `Linux checks / native`, `/ core`, `/ desktop`, `/ service` | Independently qualified stages in the pinned Arch container. Core, desktop and service consume the verified native prerequisite. |
| `macOS checks / contracts`, `/ native`, `/ core`, `/ desktop`, `/ service` | The equivalent independent macOS matrix stages. Each has its own outcome; the application bundle job does not rerun every stage. |
| `Linux bundle / build` | The separate Docker application producer and checksum-bound source/build handoff. |
| `Linux bundle / integration` | Verifies and restores that handoff without rebuilding the application, then runs native, core, desktop, compiled service, fast integration and host/cache checks through `linux_test_schedule.py`. This intentionally overlaps independent checks while the shadow transition remains active. |
| `macOS bundle / build and smoke` | Assembles the application, verifies its runtime and runs its installed/bundle smoke consumers after the selected macOS checks. It does not imply a second complete core/desktop run. |
| `Linux packaging / deb contracts`, `/ rpm contracts`, `/ arch contracts` | Builds installers from the verified actual application bundle, then installs, smoke-tests, reinstalls and removes those exact bytes; DEB also cross-installs on Debian 13. These are actual package consumers, not tiny application fixtures. |
| `macOS packaging / dmg contracts` | Ad hoc tiny DMG install/upgrade contract fixtures, separate from production signing or release publication. |
| `Linux acceptance / CPU models`, `/ virtual audio`, `/ deb installer` | The actual candidate/model/installer consumers selected for that lane. Physical devices and opt-in environments remain separately reported. |

Linux bundle integration is not a second name for `Linux checks / core`: it
checks the transported application and SDK boundary as well as multiple test
stages. The [integrity rules](platforms/ci-integrity.md#transitional-mechanisms)
require preserving these transitional routes until hosted qualification permits
retirement. Renaming does not remove work, change dependencies or reuse test
results.

Evidence consumers recognize a closed exact-label table in
`tools/ci_producer_trust.py`, including the existing preview/release caller
prefixes. Raw GitHub job rows, original IDs, attempts and upload windows are not
rewritten. Historical names remain valid only with the same independent
workflow/source/receipt proofs; spelling variants and arbitrary prefixes do not
become aliases. Frozen historical fixtures remain unchanged. The aggregate
required checks `platform-checks` and `acceptance-checks` keep their names. Any
external branch-protection rule pinning an individual old display name must be
reviewed by the repository owner; repository code does not update those settings.

## Dependency and compiler reuse

Dependency consumers select the PR head, so an advancing main does not request
an identity that its producer never built. Consumers try qualified artifacts
first, then wait up to 1,800 seconds for a compatible authorized producer. Missing
or invalid evidence fails with the identity and producer diagnostic; it does not
authorize an implicit replacement SDK compilation. Explicit fork validation may
build pinned dependencies locally without publishing shared outputs.

Build compatibility and producer trust are separate checks. Component identities
bind consumed recipes, source, pins, build settings and parent identities.
Consumers also verify repository, workflow/event, source, successful original
uploader/job attempt, upload window, receipt and archive checksums. A mutable tag
or matching cache key alone proves neither compatibility nor authorization.

Approved merged-PR outputs retain their original provenance. Reuse requires the
verified original-to-final relationship, reviewed-main reachability, compatible
component inputs and matching producer-control bytes/modes. The scoped SDK
compatibility rules do not waive compiler-work or sanitizer source requirements.
See the integrity guide and `tools/ci_producer_trust.py` for enforced policy.

Preserve successful SDKs and application outputs when an unrelated consumer
fails. Retry the failed consumer against the same qualified bytes. Investigate
transport, permissions and receipt errors before changing dependency recipes.
An incompatible dependency/compiler/ABI input requires an explicit justification
and a rebuild of the affected component. A miss or expiry can require one normal
authorized build; neither permits accepting incompatible bytes.

## Application stages

The Linux driver builds once and exports a checksum-bound source/build archive;
a separate test container verifies and consumes those outputs. Dependency-only
FlatBuffers/SentencePiece outputs remain separate from application sources.
Fresh configure and backend checks must prove that retained dependencies need no
compilation or relinking. A failed dry-run is not permission to rebuild them.

Core and desktop analysis/tests, root native CTest, compiled service/MCP and
installed-package checks remain distinct gates. Applicable core and desktop line
coverage gates are 90%; Python quality retains 95% combined line/branch coverage.
Compiler objects can be reused, but test results cannot be treated as new runs.
The media worker is a pinned application component with source/license/relink
materials and final executable identity; see [audio codecs](architecture/audio-codecs.md).

Only authorized main jobs write shared registries and caches. PR consumers are
read-only. Cache transport or registry failure must keep its diagnostic rather
than silently starting a cold SDK build. Narrowed selection, main receipt reuse
and retirement of broader routes require independently verified hosted
qualification; a committed example index or local fixture cannot activate them.
Missing or expired qualification retains the broader validation route.

## Preview installers

The **Preview packages** workflow produces development installers without
creating a stable release or tag. It freezes one reviewed main SHA for Linux and
macOS. It does not publish branch/fork previews. The nightly schedule is 07:23 UTC;
GitHub scheduling is best effort, and manual dispatch remains available.

```sh
gh workflow run preview-packages.yml --ref main -f validation=standard
gh workflow run preview-packages.yml --ref main -f validation=full
gh run rerun REPLACE_WITH_PREVIEW_RUN_ID --failed
```

`standard` runs source/build, package-integrity, installed startup/service/MCP,
reinstall/removal and data-preservation checks. It does not establish full model
or cloud acceptance. `full` adds installed model/speech and live cloud checks;
missing required configuration fails that mode. Neither mode establishes
physical audio/GPU, fresh-account, Gatekeeper or notarization acceptance.

An existing qualified green `nightly-checks` aggregate can suppress an unchanged
preview; original-run recovery preserves its validation mode and distribution
identity. Failed producers retry only their failed jobs, retaining successful
siblings. `force=true` requires a concrete output-affecting `rebuild_reason` for
an intentional new identity. The exercise inputs test isolated issue tracking
without building or publishing installers.

Download the final **tested preview installers** artifact from the workflow
summary. It contains the macOS DMG, Linux DEB/RPM/Arch/portable formats, checksum
sidecars, provenance and `preview.json`. Intermediate `preview-*` artifacts do not
replace that final certified set. All formats must share source, build number
and expected preview version. Standard manifests record full model/cloud gates
as `not_run`. Application intermediates last 14 days, final installers 90 days and
acceptance evidence 30 days.

## Distribution candidates and releases

The `release.yml` coordinator resolves a reviewed source and reuses an exact-source
fully tested candidate index when available. Otherwise it builds both candidate
platforms and runs their required gates. `candidates_only=true` prepares that
index without drafting or packaging. Both platforms retain original successful
producer attempts from one tested candidate run. Sources below the configured
release floor fail closed. Preview and ordinary PR bundles are not release bytes.

Release packaging consumes the verified completed candidate run; it does not
compile applications or SDKs. Version/tag checks and one distribution build
number bind the package formats. Installer upload and installed acceptance are
separate, so a failed lifecycle check preserves the installer and original
application candidate. Publication verifies the accepted bytes again.

Recover transient failures through failed jobs in the original coordinator.
Its retry uses the original tooling revision; a later fix does not repair that
historical code. Publication-only requires an existing qualified evidence index
and performs no builds. Preserve successful formats and receipts rather than
reconstructing proof in a fresh partial run. See [release recovery](../RELEASING.md#recover-from-a-failed-run)
and [installer acceptance](release-acceptance.md).

## Monthly dependency maintenance

The monthly job proposes a reviewed Ubuntu snapshot update as a draft PR. It
does not silently change live dependency identities. Review the pin and resulting
dependency, application, package and integration checks before merging. Weekly
Dependabot proposals use the hash-lock regeneration procedure in CONTRIBUTING.
OSV scans report dependency vulnerabilities separately.

Record actual source, artifact identities, commands, counts, skips and limitations
with validation results. Local mocks, stamped metadata, cached bytes and a
development bundle do not establish hosted execution or release acceptance.
