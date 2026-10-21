# Releasing Open Foresight

Publish Linux and macOS packages through the `Prepare and publish release`
workflow. First package verified application candidates and automatically test a
draft release, then test those
exact installers on real GPU hardware (unless explicitly waived) and publish the same bytes. The examples
below use release `v0.1.2` and release PR `129`; change both for future releases.

## Prerequisites

- Git and an authenticated GitHub CLI with access to `teng-lin/open-foresight`.
- Repository administrator access to create the protected `v*` release tag.
- A reviewed release PR with required CI checks passing, synchronized application
  versions, and a dated changelog entry.
- Working distribution configuration in repository secrets, including
  `FORESIGHT_GOOGLE_CLIENT_JSON`. Optional web mode uses the search and web-content
  API secrets together. Keep credentials out of commands, logs, and Git.
- Linux and Apple Silicon macOS hardware when release-day GPU checks are required.

Run the commands from a repository checkout. They do not require changing your
current branch or discarding local edits:

```sh
export GH_REPO=teng-lin/open-foresight
release_tag=v0.1.2
release_pr=129
```

## Prepare and merge the release PR

The release version lives in `apps/desktop/pubspec.yaml`. For a future version,
use the repository tool in the preparation branch:

```sh
python3 tools/app_version.py --set 0.1.2
python3 tools/app_version.py --check
```

The setter increments the internal build number and updates the core package,
desktop lockfile, and generated Dart constants. For example, `0.1.2+3` is release
`0.1.2`, build `3`; its release tag is `v0.1.2`. If the release PR already contains
the intended version, skip `--set` so the build number is not incremented again.

Move notable `Unreleased` changelog entries into a dated section for the new
version and update the changelog links. Commit the release changes, open a PR,
address valid review findings, and merge after required checks pass. Check the
release PR with:

```sh
gh pr checks "$release_pr"
gh pr view "$release_pr" --json state,mergeCommit,url
```

## Tag the reviewed product commit

After the PR is merged, resolve its merge commit and confirm it belongs to main:

```sh
git fetch origin main
release_commit=$(gh pr view "$release_pr" --json mergeCommit --jq '.mergeCommit.oid')
test -n "$release_commit" && test "$release_commit" != null
git merge-base --is-ancestor "$release_commit" origin/main
git show "$release_commit:apps/desktop/pubspec.yaml"
```

Confirm that the displayed version matches the intended tag. An administrator
then creates and pushes the tag at that exact commit:

```sh
git tag "$release_tag" "$release_commit"
git push origin "refs/tags/$release_tag"
```

The workflow token cannot create a missing protected release tag. A tag push
alone does not build installers. Keep the product tag fixed throughout release
preparation and publication.

## Reuse application candidates and test the draft packages

Release-tier runs of `release.yml` produce the Linux and macOS candidates on
demand. The coordinator first looks for a fully tested index for the exact
reviewed product source. If none exists, it produces both platforms and requires
all candidate gates before recording the index. PR and preview bundles cannot
satisfy release lookup. Sources below `RELEASE_SOURCE_FLOOR` are refused; choose a
reviewed source at or above that floor.

To prepare candidates before drafting or packaging a release, run:

```sh
gh workflow run release.yml --ref main \
  -f candidates_only=true -f source="$release_commit"
```

This run creates or reuses the tested index without creating a release draft.
Inspect failed candidate gates and rerun only failed jobs first, preserving
successful outputs and their original producer attempts. An existing tested
index retains its source, version, distribution number and byte checksums. Pass
its original run as `candidate_run` when selecting a specific verified index.
Packaging consumes that exact completed index without polling for application
producers or compiling applications or SDKs.

Start the coordinator on main with no GPU evidence:

```sh
gh workflow run release.yml --ref main -f tag="$release_tag"
gh run list --workflow release.yml --branch main --limit 5
```

Open the run shown by `gh run list` in GitHub Actions to follow its progress.
The coordinator:

1. Verifies the administrator-created tag and its application version.
2. Verifies an existing fully tested release-tier index for the tagged product,
   or produces and tests both candidates before packaging, preserving their
   original successful attempts, receipts and checksums.
3. Creates or resumes the draft generation and packages missing installer formats
   with current packaging controls and the original tested application bytes.
4. Uploads Linux DEB, RPM, Arch, and portable packages, plus the Apple Silicon
   macOS DMG, with checksums, provenance, and installer attestations.
5. Downloads the draft installers and runs installed-package acceptance on
   Ubuntu, Debian, Fedora, Arch, and macOS.

By default, the release stays a draft until physical GPU evidence is supplied. The final
publication job can fail with a manual-evidence requirement even when automated
acceptance succeeds. Confirm the earlier build and acceptance jobs passed before
continuing; another failure still needs investigation.

Physical GPU validation can be explicitly waived for an individual release with
`-f skip_gpu_validation=true`. This option defaults to `false` and applies to
both the initial coordinator run and publication-only runs. It preserves all
automated installer, upgrade, checksum, provenance, and attestation gates. The
acceptance report retains its manual-pending status, and the published release
notes record that physical Linux and macOS GPU validation was waived. To prepare
and publish without physical GPU validation:

```sh
gh workflow run release.yml --ref main -f tag="$release_tag" \
  -f skip_gpu_validation=true
```

Inspect the draft and its assets:

```sh
gh release view "$release_tag" --json isDraft,url,assets
```

## Test the exact draft installers on hardware

Download the installers and their sidecars into a private validation directory:

```sh
release_dir="$PWD/test-results/releases/$release_tag"
mkdir -p "$release_dir"
gh release download "$release_tag" --dir "$release_dir" \
  --pattern '*.deb*' --pattern '*.rpm*' \
  --pattern '*.pkg.tar.zst*' --pattern '*.dmg*'
```

Verify checksums and provenance before installing. Compute the installer hashes
with `sha256sum` on Linux or `shasum -a 256` on macOS, and compare them with the
downloaded checksum sidecars. Verify build and SBOM attestations for each tested
installer, substituting its actual filename:

```sh
gh attestation verify /path/to/installer --repo "$GH_REPO"
gh attestation verify /path/to/installer --repo "$GH_REPO" \
  --predicate-type https://spdx.dev/Document
```

Install through the normal user flow and follow the
[desktop and hardware acceptance procedure](docs/validation/release-acceptance.md#real-desktop-and-hardware-acceptance).
Use its [manual results template](docs/validation/release-acceptance-manual.json)
to record setup, model workflows, persistence, microphone/system audio, recovery,
desktop integration, and upgrade results. The macOS DMG currently has an ad-hoc
signature; record actual Gatekeeper behavior and the remaining signing limits.

Unless physical GPU validation is explicitly waived, publication requires one observed GPU result from Linux and one from macOS,
each tied to an installer accepted by CI. Linux can use any one of the accepted
DEB, RPM, or Arch installers. Software Vulkan CI does not replace physical GPU
testing. Record the GPU, backend, model/decode or speech result, and locations of
supporting logs or screenshots.

Create `gpu-evidence.json` inside `release_dir` with the following structure.
Replace every placeholder with the observed values; the timestamp must be UTC
RFC3339 with seconds, such as the format `YYYY-MM-DDTHH:MM:SSZ`:

```json
[
  {
    "platform": "linux",
    "installer_sha256": "REPLACE_WITH_TESTED_LINUX_INSTALLER_SHA256",
    "gpu": "REPLACE_WITH_GPU_MODEL",
    "backend": "REPLACE_WITH_OBSERVED_BACKEND",
    "tester": "REPLACE_WITH_TESTER",
    "tested_at_utc": "YYYY-MM-DDTHH:MM:SSZ",
    "evidence": "REPLACE_WITH_OBSERVED_RESULT_AND_EVIDENCE_LOCATION"
  },
  {
    "platform": "macos",
    "installer_sha256": "REPLACE_WITH_TESTED_DMG_SHA256",
    "gpu": "REPLACE_WITH_APPLE_SILICON_GPU",
    "backend": "REPLACE_WITH_OBSERVED_BACKEND",
    "tester": "REPLACE_WITH_TESTER",
    "tested_at_utc": "YYYY-MM-DDTHH:MM:SSZ",
    "evidence": "REPLACE_WITH_OBSERVED_RESULT_AND_EVIDENCE_LOCATION"
  }
]
```

Keep the evidence with the validation reports. Repackaging changes installer
hashes and requires hardware testing again for the new bytes.

## Publish the tested draft

Run the coordinator again with publication-only mode and the completed evidence:

```sh
acceptance_run=REPLACE_WITH_SUCCESSFUL_ACCEPTANCE_RUN
gh workflow run release.yml --ref main \
  -f tag="$release_tag" \
  -f publish_only=true \
  -f acceptance_run="$acceptance_run" \
  -f gpu_evidence="$(cat "$release_dir/gpu-evidence.json")"
```

Set `acceptance_run` to the original run with a successful installed-acceptance
aggregate. Its source, successful job/attempt, artifact digest and all four
current installer hashes are reverified before that result is reused with the
new hardware evidence. Use `0` when no valid matching report exists; this runs
installed acceptance again against the existing installers. Candidate production
and packaging remain skipped in publication-only mode. When
all required gates pass, the coordinator publishes the draft. It marks the
release Latest only if it has the highest published stable semantic version.

Confirm that publication completed and review the final release assets:

```sh
gh release view "$release_tag" --json isDraft,isPrerelease,url,assets
```

The expected final values are `isDraft: false` and `isPrerelease: false`.

## Recover from a failed run

Read the failed step and preserve its logs before choosing a retry. Retain
successful dependency builds and compatible verified artifacts. Investigate
cache restoration, transport, receipt, and image-loading failures before
considering recompilation. A version bump or new commit alone does not require
rebuilding SDKs.

| Situation | Next action |
| --- | --- |
| Builds and automated acceptance passed with a qualified evidence index; GPU evidence is pending | Complete hardware testing, then use `publish_only=true`. |
| Existing draft bytes are valid; acceptance failed from a transient external cause before a qualified evidence index was retained | Resolve that external cause, then re-run failed jobs in the original release coordinator using its original tooling revision. Use `publish_only=true` only after the original candidate, packaging and acceptance evidence index verifies. |
| One application platform is missing | Preserve successful outputs and retry failed jobs in the original candidate run. If no qualifying candidate run exists, dispatch `release.yml` with `candidates_only=true` for the reviewed source; the coordinator produces both platforms with one tested index. |
| One installer format failed | Inspect retained bytes and retry failed jobs in the original release coordinator. Its successful sibling formats and original candidates remain qualified; do not start a separate packaging workflow to replace coordinator-bound evidence. |
| An existing asset conflicts or an artifact is corrupt/expired | Follow the verifier's recovery diagnostic. Do not overwrite different bytes or discard surviving formats. Review the exact artifact problem before requesting replacement. |
| The tagged product code needs a fix | Merge the fix through review and prepare a new version and tag. Keep the original tag fixed. |
| The release is already public | Prepare a new version. Published release assets are immutable. |

The separate `release-acceptance.yml` workflow can audit an existing draft or
public release without publishing it. Keep publication in `release.yml` so its
coordinator, installer, and manual-evidence gates remain enforced.

For a failed format or transient installed-acceptance failure, retain the original
release coordinator run ID and re-run its failed jobs and dependents:

```sh
original_release_run=REPLACE_WITH_ORIGINAL_RELEASE_COORDINATOR_RUN
gh run rerun "$original_release_run" --failed
```

For a newly created DMG, the packager can recover a transient verification lock
by normally detaching its own exact image attachment once, within the bounded
recovery window. It requires the current owner and an unambiguous outer GUID
device, then verifies the original SHA256-identical bytes. It never detaches
unrelated images or treats cleanup as successful checksum verification.

A retry uses the original workflow and tooling commit. It can recover transient
external failures when no conflicting or partial upload exists for the failed
format; it cannot apply a subsequently merged tooling fix. If that
original code cannot produce a valid evidence index, keep publication held for
reviewed recovery. A partially attached DMG requires reviewed recovery: the DMG
preflight stops before regenerating the disk image or replacing retained
packaging evidence when its installer or associated sidecars already exist.
Preserve existing installers, original logs and provenance;
do not delete assets, rebuild accepted bytes, or invent a replacement locator.

This preserves successful sibling jobs, installer hashes and their original
upload attempts. GitHub may repeat untouched job records under the new API
attempt; evidence verification requires their exact original execution, including
all steps and authoritative attempt start times. A genuinely executed newer
failure or skip remains authoritative and cannot be replaced by an older pass.
After the original run finishes acceptance and retains its qualified evidence
index, use `publish_only=true` with matching hardware evidence. Publication-only
re-verifies that index and the current installer bytes; it never builds or packages.

Do not use **Re-run all jobs**, a new partial coordinator run, or standalone
`linux-packages.yml`/`macos-release.yml` dispatches to repair publication evidence.
Those paths can skip already attached installers or produce attestations naming
a different coordinator invocation. They cannot replace missing original proof.
Keep the original run and surviving assets intact; inspect any expiry or changed
bytes diagnostic before requesting replacement. The standalone packaging
workflows remain available for their separate diagnostic uses, not as a source
of replacement publication authority.

## Workflow and acceptance references

- [Release coordinator](.github/workflows/release.yml)
- [Release preparation and candidate selection](tools/prepare_release.py)
- [Linux packaging](docs/platforms/linux-packaging.md)
- [macOS packaging and release gates](docs/platforms/macos-support.md)
- [Installer acceptance and hardware requirements](docs/validation/release-acceptance.md)
- [Dependency reuse and CI promotion](docs/platforms/ci-performance.md)
