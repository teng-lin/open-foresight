# Published installer acceptance

The `Published installer acceptance` workflow tests the exact assets downloaded
from a GitHub release. It never rebuilds a package to substitute for the release
bytes. Each download requires a unique installer, its filename-bound SHA-256
sidecar, and the advertised asset size. Evidence records the release ID, asset
ID, SHA-256, tag and resolved source commit.

The workflow runs when either release-packaging workflow completes successfully.
If the other workflow has not yet published its installers, it explicitly reports
**acceptance NOT RUN**, skips the test jobs, and waits for the other completion
event. A manual run with missing assets fails instead of silently skipping.
After this workflow lands on main, run it against an existing release with:

```sh
gh workflow run release-acceptance.yml --repo teng-lin/open-foresight -f tag=v0.1.0
```

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
reports require the installed app revision to match the release tag commit and
record the app revision so a package cannot silently attach to another
installation. These reports use synthetic fixture content, not a real profile.

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
