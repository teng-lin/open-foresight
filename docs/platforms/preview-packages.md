# Preview installers

The **Preview packages** workflow builds installers for testing before an official
release. It never creates a release or a release tag. Its final artifact contains:

- macOS 15+ Apple Silicon `.dmg` (currently ad-hoc signed, like the existing release pipeline).
- Linux x86-64 `.deb`, `.rpm`, Arch `.pkg.tar.zst`, and portable `.tar.gz`.
- SHA-256 sidecars, installer provenance and a root `preview.json` manifest.

## Running it

After the workflow is merged onto main, use **Actions → Preview packages → Run
workflow**, select **main**, then choose:

| Input | Behavior |
| --- | --- |
| `validation: standard` | Full source/build gates, package integrity, install/startup, service/MCP, reinstall/removal and user-data preservation checks |
| `validation: full` | Standard checks plus installed inference/speech model acceptance and live cloud checks against bundled distribution configuration |
| `force: false` | Standard mode skips a main commit that already has a successful preview |
| `force: true` | Reserve a new build number and rebuild the same commit |

Full mode always rebuilds, even if a standard preview already exists. Missing
cloud configuration fails full validation; it is not treated as a pass. Standard
Linux smoke checks retain the existing small Whisper fixture, but do not run the
full inference/embedding/cloud acceptance suite. Physical-device audio, GPU,
Gatekeeper/quarantine, notarization and fresh-account checks are not established
by either automated mode.

From the CLI:

```sh
gh workflow run preview-packages.yml --ref main -f validation=standard -F force=true
gh workflow run preview-packages.yml --ref main -f validation=full
```

The nightly schedule checks main at **07:23 UTC**. It builds only if that exact
commit has no successful preview. Failed attempts do not advance the successful
commit watermark and are retried on the next scheduled run. A skip links to the
previous successful workflow run. Artifacts expire after 14 days; use `force` to
regenerate expired downloads. The schedule is best effort and can be delayed by
GitHub; manual dispatch remains available.

Only reviewed main is supported by the preview coordinator. It freezes one SHA
before starting either platform and fails if main advanced before planning. Main
may continue advancing after that point: all build and packaging jobs keep using
the frozen source. Branch/fork builds do not receive a preview publication path.

## Downloads and acceptance

Open the workflow summary and follow the **tested preview installers** download
link. The final artifact is named
`Open-Foresight-VERSION-nightly.DATE.BUILD-SOURCE_SHA`. It is created only after all
platform builds, package formats and selected acceptance jobs succeed. Individual
`preview-*` and `tested-preview-*` artifacts are intermediate job inputs/outputs;
the combined final artifact and `preview.json` are the certified download set.
Acceptance evidence is retained for 30 days.

`preview.json` records the source, target version, numeric build number, nightly
label, validation level, workflow URL and every output file's checksum. Standard
builds explicitly record full model/cloud acceptance as **not_run**. All five
installer formats must have the same source/build number and expected preview
version before the combined artifact can be produced.

## Versions and build numbers

The preview targets the checked-in version when it is newer than the latest
stable release. Otherwise it targets the next patch after the latest stable.
For example, source `0.1.1` after stable `v0.1.1` produces `0.1.2` previews; source
`0.2.0` after that release produces `0.2.0` previews. This does not commit a source
version bump or create a tag.

For target `0.1.2`, date `20261018`, build `12`:

| Format | Version |
| --- | --- |
| App/DMG | Marketing version `0.1.2`, numeric bundle build `12`; Settings displays `nightly.20261018.12` |
| Debian | `0.1.2~nightly.20261018.12-1` |
| RPM | Version `0.1.2~nightly.20261018.12`, release `1` |
| Arch | Version `0.1.2`, package release `0.12` |
| Portable archive | `0.1.2~nightly.20261018.12-1` in the filename/provenance |

Native package-manager comparators check preview ordering before packaging. All
previews sort below the intended stable package (`0.1.2-1` in this example).
Arch uses a numeric package release because its `pkgver` rules differ from
Debian/RPM tilde versions.

Normal main application candidates and previews share a compare-and-swap build
counter on the managed **`ci/build-sequence`** branch. Do not delete/reset that
branch. Allocation respects the checked-in build number as a lower bound and
never force-pushes the counter; concurrent allocators retry conflicting updates.
A failed build can leave a gap, which is expected. Both platforms receive the
same number. Local developer builds still use the checked-in pubspec number.

Identity is stamped into the build checkout before analysis, compilation and
testing. A generated `.distribution-build.json` and derived Dart constant carry
the label; they are not committed. A preview therefore reuses dependency SDKs,
but does **not** relabel an already tested stable application candidate.

## Relationship to official releases

Preview and official distribution coordinators share a concurrency group, so a
nightly cannot reserve/publish between a stable build and its publication.
Official release preparation requests a fresh, forced main build for the exact
product commit; both packagers pin to that producer run. This allocates a build
number after earlier previews and prevents fallback to older application
candidates. Historical product commits must contain the distribution build
support to be rebuilt through this path; unsupported historical builds fail
without substituting newer source or publishing a release.

Packaging code is shared: both channels use the Linux native package/lifecycle
scripts and `tools/create_dmg.py`. Standard and full previews contain the same
features/configuration; the validation level only changes acceptance depth.
Preview artifacts have separate names from `ci-macos-app-*` and `ci-linux-app-*`,
and cannot satisfy stable candidate discovery. Official releases retain their
existing mandatory model/cloud and downloaded-installer acceptance gates.
