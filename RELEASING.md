# Releasing Open Foresight

Publish Linux and macOS packages through the `Prepare and publish release`
workflow. First package verified application candidates and automatically test a
draft release, then test those
exact installers on real GPU hardware and publish the same bytes. The examples
below use release `v0.1.2` and release PR `129`; change both for future releases.

## Prerequisites

- Git and an authenticated GitHub CLI with access to `teng-lin/open-foresight`.
- Repository administrator access to create the protected `v*` release tag.
- A reviewed release PR with required CI checks passing, synchronized application
  versions, and a dated changelog entry.
- Working distribution configuration in repository secrets, including
  `FORESIGHT_GOOGLE_CLIENT_JSON`. Optional web mode uses the search and web-content
  API secrets together. Keep credentials out of commands, logs, and Git.
- Linux and Apple Silicon macOS hardware for the release-day GPU checks.

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

Normal main CI produces source-bound Linux and macOS application candidates.
Release preparation discovers those existing outputs and waits for active
producers; it never dispatches another application build. The two platforms may
come from different successful producer jobs, but their source, version and
distribution build number must agree. A failed sibling job does not invalidate
a successful platform's verified candidate.

If preparation reports a missing platform, inspect its artifacts, receipts and
running producers first. When no compatible output exists, build only that
platform for the reviewed product commit. For example, for a missing Linux
candidate:

```sh
gh workflow run macos.yml --ref main \
  -f source="$release_commit" -f platforms=linux
```

Use `platforms=macos` for a missing Mac candidate. The surviving candidate's build
identity is retained. Replacing an existing candidate also requires a concrete
output-affecting `rebuild_reason`; dependency SDKs and valid compiler outputs
remain reusable. Wait for the selected producer before retrying preparation.

Start the coordinator on main with no GPU evidence:

```sh
gh workflow run release.yml --ref main -f tag="$release_tag"
gh run list --workflow release.yml --branch main --limit 5
```

Open the run shown by `gh run list` in GitHub Actions to follow its progress.
The coordinator:

1. Verifies the administrator-created tag and its application version.
2. Verifies and reuses the exact tagged product's Linux and macOS candidates,
   preserving their successful producer attempts, receipts and checksums.
3. Creates or resumes the draft generation and packages missing installer formats
   with current packaging controls and the original tested application bytes.
4. Uploads Linux DEB, RPM, Arch, and portable packages, plus the Apple Silicon
   macOS DMG, with checksums, provenance, and installer attestations.
5. Downloads the draft installers and runs installed-package acceptance on
   Ubuntu, Debian, Fedora, Arch, and macOS.

The release stays a draft until physical GPU evidence is supplied. The final
publication job can fail with a manual-evidence requirement even when automated
acceptance succeeds. Confirm the earlier build and acceptance jobs passed before
continuing; another failure still needs investigation.

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

Publication requires one observed GPU result from Linux and one from macOS,
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
| Builds and automated acceptance passed; GPU evidence is pending | Complete hardware testing, then use `publish_only=true`. |
| Existing draft bytes are valid; acceptance failed transiently or evidence needs correction | Fix the cause and use `publish_only=true` to preserve the installers. |
| One application platform is missing | Preserve its successful sibling and active producers; build only the missing platform after verifying no compatible retained output exists. |
| One installer format failed | Recover that format from its original application candidate, preserving the draft generation and other verified assets. Installer bytes are retained before lifecycle tests, so inspect them before repackaging. |
| An existing asset conflicts or an artifact is corrupt/expired | Follow the verifier's recovery diagnostic. Do not overwrite different bytes or discard surviving formats. Review the exact artifact problem before requesting replacement. |
| The tagged product code needs a fix | Merge the fix through review and prepare a new version and tag. Keep the original tag fixed. |
| The release is already public | Prepare a new version. Published release assets are immutable. |

The separate `release-acceptance.yml` workflow can audit an existing draft or
public release without publishing it. Keep publication in `release.yml` so its
coordinator, installer, and manual-evidence gates remain enforced.

For an RPM-only recovery, use the Linux candidate run and package release number
reported by the existing draft's preparation job:

```sh
candidate_run=REPLACE_WITH_LINUX_CANDIDATE_RUN
package_release=REPLACE_WITH_EXISTING_DRAFT_GENERATION
gh workflow run linux-packages.yml --ref main \
  -f tag="$release_tag" -f candidate_run="$candidate_run" \
  -f package_release="$package_release" -f format=rpm
```

This reuses the original Linux application and leaves the DEB, Arch and DMG
assets intact. Use `macos-release.yml` with `tag` and the original Mac
`candidate_run` for a missing DMG. Identical verified assets are retained;
conflicting bytes fail instead of being clobbered. After recovery, run the
coordinator in publication-only mode for the unchanged installer set and its
matching hardware evidence.

## Workflow and acceptance references

- [Release coordinator](.github/workflows/release.yml)
- [Release preparation and candidate selection](tools/prepare_release.py)
- [Linux packaging](docs/platforms/linux-packaging.md)
- [macOS packaging and release gates](docs/platforms/macos-support.md)
- [Installer acceptance and hardware requirements](docs/validation/release-acceptance.md)
- [Dependency reuse and CI promotion](docs/platforms/ci-performance.md)
