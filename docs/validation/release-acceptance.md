# Release preparation and installer acceptance

After merging the version update, an administrator must create `vX.Y.Z` at the
reviewed intended product commit (`git tag vX.Y.Z <commit>` and
`git push origin vX.Y.Z`). The protected `v*` tag rules allow only administrators
to create, move or delete release tags; the workflow token cannot create a missing
tag. Then run `gh workflow run release.yml --ref main -f tag=vX.Y.Z`. This is the supported publication path. The coordinator requires
qualified Linux and macOS candidates for the immutable reviewed product tag.
Unavailable or incompatible candidate evidence prevents publication; follow
[release preparation](../../RELEASING.md) for the source and candidate protocol.
A failed candidate build leaves the administrator-created tag unpublished.

The release remains a draft while reusable Linux and macOS workflows check out
`refs/tags/vX.Y.Z`, package the exact tested candidate, and upload installers.
Acceptance requires all four installers plus checksum and provenance sidecars.
Missing assets, failed tests, and skipped gates fail publication. Only a completely
successful installed-package matrix publishes the draft and marks it Latest only when its stable semantic version is the highest published version.
Public releases cannot be rebuilt or overwritten; increment the app version.

Retry transient external failures with `gh run rerun ORIGINAL_RELEASE_RUN --failed`.
This retains successful sibling formats and their original receipt/upload attempts.
A rerun uses the original workflow and tooling commit; a later merged tooling fix
cannot repair that old run's code. If the original code cannot produce a qualified
evidence index, publication stays held for reviewed recovery. Preserve existing
installer bytes, logs and provenance; do not delete assets or use a fresh partial
coordinator or standalone packaging dispatch to replace original proof.
`publish_only=true` re-verifies an existing qualified index and never builds or
packages. See [release recovery](../../RELEASING.md#recover-from-a-failed-run).

The downloader rejects any installer source revision different from the tag.
`--allow-recovery-revision` is an explicit historical audit escape hatch recorded
in `installer.json`; the publication workflow never supplies it. `--allow-draft`
lets the acceptance jobs test unpublished bytes before publication.


The `Published installer acceptance` workflow tests the exact assets downloaded
from a GitHub release. It never rebuilds a package to substitute for the release
bytes. Each download requires a unique installer, its filename-bound SHA-256
sidecar, and the advertised asset size. Evidence records the release ID, asset
ID, SHA-256, tag, release-tag commit and the installer-specific source commit.
Linux `.build.json` metadata must match the installer checksum, package format,
and release version. DMGs use their published `.manifest.json`. Metadata identity
and its checksum are recorded alongside the installer identity; missing or
ambiguous provenance fails acceptance.

Acceptance is called by the coordinator after both platform builders succeed.
It can also be dispatched manually to audit an existing release. Historical
v0.1.0 Linux assets deliberately fail strict revision verification; the replacement
v0.1.1 must pass with one shared source commit.

## Automated matrix

| Download | Environment | Evidence artifact |
| --- | --- | --- |
| DEB | Ubuntu 24.04 container | published-acceptance-ubuntu-24.04 |
| Same DEB | Debian 13 container | published-acceptance-debian-13 |
| RPM | Fedora 44 container | published-acceptance-fedora-44 |
| Arch package | Current Arch container | published-acceptance-arch-rolling |
| DMG | Apple Silicon macos-15 hosted runner | published-acceptance-macos-15-arm64 |

Linux installs using apt/dnf/pacman, validates its desktop entry, and launches
`/usr/bin/open-foresight` under Xvfb/D-Bus as a non-root account. The harness does
not supply developer library paths, API keys, worker paths, or Python paths.
The installed launchers must provide their own runtime configuration. Model
fixtures are pinned to public immutable revisions and SHA-256 identities, cached
after verification, and mounted read-only into the Linux containers. Private runtime copies allow model
cache creation without modifying those fixtures.

The DMG test verifies the downloaded checksum and image, mounts it read-only,
copies its app into a new explicit destination, checks the signature and bundled
runtime, and runs the installed copy. Hosted CI uses `/Applications/Open
Foresight.app`. Existing installations are refused; only the app copy created by
the test is replaced/uninstalled. Gatekeeper results are recorded; rejection of
the current ad-hoc signature is expected and is not presented as notarization.
The harness never strips quarantine attributes to produce an artificial pass.

GUI startup uses the installed launcher's default configuration. The subsequent
Linux model-functional tests explicitly select CPU generation and CPU embeddings
for hosted CI, recording that selection and verifying the runtime adopted it.
macOS retains its packaged generation backend. This is
an explicit test setting, not an automatic GPU fallback; GPU behavior remains a
separate hardware gate.

Every target runs functional checks beyond installation:

- Actual GUI startup and MCP attachment to the same installed service, using
  private synthetic profile/runtime directories and no developer runtime overrides.
- Production EmbeddingGemma/Gemma configuration through the application RPC,
  with real embedding/tokenizer readiness required.
- Transcript-driven note enhancement and a Tuesday-to-Friday correction;
  stale primary deadlines and missing persisted artifacts fail the test.
- Source indexing and a grounded answer containing a known synthetic launch
  code and citation, using actual local models.
- A genuine service stop/restart followed by source, note and enhanced-meeting
  persistence checks.
- Installed Whisper CPU transcription of the public JFK fixture, checked for
  the expected phrase.
- Native-package reinstall/removal, real saved note/source persistence across
  the reinstall, and preservation of a per-user sentinel.
  The DMG similarly reinstalls the tested copy and removes only its owned app.

`installer.json`, `installation.json`, `functional.json`, model/Application
reports and desktop/speech logs are retained as Actions artifacts for 30 days.
Failures fail the job; the functional report stays failed until all its automated
checks complete. Passing functional reports say `automated_passed_manual_pending`.
The container OS release and Mac OS/hardware architecture are recorded. Runtime
reports require the installed app revision to match its published installer
provenance and record the app revision so a package cannot silently attach to
another installation. These reports use synthetic fixture content, not a real profile.

## Real desktop and hardware acceptance

Container X11 startup is not Wayland/Hyprland or physical hardware acceptance.
`macos-15` is a runner image label, not proof of the exact minimum supported OS
point release or a newly created OS account. Direct executable startup does not
establish Finder quarantine behavior. Model registration via RPC does not test
the complete guided-setup dialog or download UI. Native save-dialog export stays
a manual gate; no product-only testing RPC is added to fake a UI export.

Use clean VM snapshots for Ubuntu, Debian, Fedora and Arch/Omarchy desktops, and
a fresh Mac account for the downloaded DMG. No checkout, SDK, Homebrew, developer
Python, runtime overrides or preconfigured profile should be present. For each
installer, record its SHA-256, OS version, hardware, result and screenshot/log
paths using `docs/validation/release-acceptance-manual.json` as a template. Change `not_run`
only after observing the check on that environment.

1. Download and install the published asset through the normal user flow. On
   macOS, copy through Finder, eject the DMG, then launch the installed app using
   the documented first-launch procedure. Record actual Gatekeeper behavior.
2. Complete guided model setup. Index a synthetic document, ask a cited question,
   enhance a meeting note and export Markdown through the native save dialog;
   open the resulting file and verify its contents.
3. Close/reopen and restart the machine. Confirm saved content and model setup
   persist, with no extra owner/helper processes left behind.
4. Record microphone and system playback together. Check pause/resume, device
   changes, permission denial/revocation, sleep/wake and recovery. Use consented
   synthetic audio; check both transcript channels and absence of paused audio.
5. Test an advertised GPU/backend on real supported hardware. Record latency,
   peak memory and any fallback/error behavior. Test normal Wayland/global
   shortcuts and save portals where advertised, including Omarchy separately.
6. Reinstall/update, uninstall, and verify the documented data-preservation
   behavior. Confirm another application or profile was not modified.

Automated green results and completed manual records are separate evidence.
Do not label the release fully validated from an installation-only pass or an
uncompleted manual template.

Verify installer attestations after downloading the exact release asset:

```sh
gh attestation verify ./open-foresight_VERSION_amd64.deb --repo teng-lin/open-foresight
gh attestation verify ./open-foresight_VERSION_amd64.deb --repo teng-lin/open-foresight --predicate-type https://spdx.dev/Document
```

Repeat for RPM, Arch and DMG installers. Provenance and SBOM attestations bind
SHA-256 installer bytes to the release workflow; checksum and `.build.json`
verification remain mandatory for installer acceptance.

The installed functional report records `gpu_inference.status = manual_pending` and `automated_passed_manual_pending`. This requires the release-day physical GPU check above. Automated software Vulkan evidence does not complete it. Before dispatching publication, supply the `gpu_evidence` JSON input with one Linux and one macOS record, each containing `platform`, `installer_sha256`, `gpu`, `backend`, `tester`, `tested_at_utc` (UTC RFC3339 seconds) and `evidence` (the observed decode/speech result and evidence location). Use the SHA256 of an exact installer tested in this release; Linux may use any accepted native distribution installer. First dispatch the coordinator with empty GPU evidence to build and automatically test draft candidates; publication will remain blocked. Download those exact draft installers and complete the physical GPU checks, then dispatch with `publish_only=true` and the evidence JSON. This mode requires the existing qualified release evidence index, preserves the draft bytes, reruns acceptance and publishes only after the bound GPU records pass; it never builds or packages. Rebuilding would change installer hashes and require new manual checks. The separate acceptance workflow can audit the same draft without publishing.

The acceptance aggregate retains the installer identities and manual records in `release-acceptance-summary/release-acceptance.json`. Publication downloads and reads that report, checks the release tag and the GPU evidence's installer hashes, and refuses to publish while manual GPU evidence is pending. The release operator supplies the evidence; CI does not assert that it performed a physical GPU test.

Disposable Linux installer containers allow nested namespaces through their outer Docker seccomp/AppArmor configuration so the installed application's bubblewrap sandbox can run. These allowances apply only to isolated CI installer containers; extraction still uses the shipped Parser and sandbox and fails if either is unavailable.
