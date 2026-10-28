# macOS Zoom speaker observer helper

Implementation notes for `zoom_observer_macos`, the macOS half of
[Zoom speaker attribution](zoom-speaker-attribution.md). The wire contract is
[speaker-observer-protocol.md](speaker-observer-protocol.md).

**Live feasibility: not executed.** Everything below was verified against
synthetic snapshots and the protocol only. No Zoom meeting, no real Zoom
accessibility tree, and no Accessibility permission transition was observed.
The Zoom structures are hypotheses taken from the
parsing-rule investigation (`docs/research/granola-zoom-parsing-rules.md`, not part of this branch), which
itself did not read a live tree. Treat support as unclaimed until the checklist
at the end passes on a real Zoom 7.2.2 (88465) call.

## Components

| File | Role |
| --- | --- |
| `native/zoom_ax_parser.{h,mm}` | Pure parser. Snapshot tree in, participants and speakers out. Uses Foundation string folding only; no Accessibility API, no permission. |
| `native/zoom_observer_core.{h,cpp}` | Platform-neutral protocol: NDJSON framing, `seq`, bounded line reader, polling session, reference assignment, stop deadline. Talks to the OS through an abstract `Source`. |
| `native/zoom_observer_macos.mm` | `Source` implementation over `AXUIElement`, and `main`. |
| `native/zoom_observer_macos_info.plist` | Embedded `__info_plist` giving the helper the stable identifier `org.openforesight.zoom-observer`. |
| `tests/fixtures/zoom_ax/` | Synthetic scenarios (59) and the 17-locale phrase set; controlled names only. |
| `tests/native/zoom_ax_parser.cpp`, `zoom_observer_core.cpp`, `zoom_observer_protocol.py` | CTest `zoom_ax_parser`, `zoom_observer_core`, `zoom_observer_protocol`. |

The helper is built only on macOS and installed to `bin/` like `foresight-audio`
(arm64, deployment target from the build, `-fobjc-arc`). Packaging is not wired.

## Parser rules as implemented

Input is an `AXApplication` whose children are `AXWindow` nodes (or one
`AXWindow`). Each node carries role, description, value, identifier and an
optional collector-assigned element id.

- **Tile.** Role exactly `AXTabGroup`. The name is the text before the earliest
  recognized computer-audio phrase (an equal position prefers the longer phrase);
  trailing whitespace and ASCII, fullwidth and ideographic commas are removed.
  Without an audio phrase the description must end with a locale's active-speaker
  marker. A matched tile's descendants are not searched; an unmatched
  `AXTabGroup` is searched through.
- **Active.** The marker must be the last item and preceded by a comma, so
  `Alice, Computer audio unmuted, Not Active speaker` is not active (the research
  rule matched it by suffix alone). An unmuted microphone alone is not a speaker.
  Several marked tiles are all reported.
- **Names.** Display spelling is kept (only edge whitespace is trimmed; commas and
  punctuation inside survive). The comparison key folds case and whitespace and
  canonicalizes Unicode composition but keeps diacritics, so distinct people do
  not merge. Equal names with different elements stay separate participants.
- **Compact window.** Only when no ordinary tile exists anywhere and the snapshot
  is complete: an `AXWindow` whose direct `AXButton` children include both
  localized controls, then exactly one direct `AXStaticText` whose value begins
  with the locale's `Talking:` form. Zero labels is an observed absence; two
  labels, or a label containing a comma (a list of names), makes the read
  `complete: false` with no speaker. The two-child `Show video render` shape is
  not supported.
- **Self.** An `AXOutline` whose description is a localized `Participants list`,
  then descendant `AXStaticText` values ending in a parenthetical that lists the
  locale's self word (`Alice (me)`, `Alice (host, me)`, `Alice (Host) (me)`).
  Self is set only for a single distinct self name that matches exactly one tile.
- **Ordered-tile fallback.** Not implemented and not compiled. A fixture asserts
  that an ordered gallery layout without markers yields no speaker.
- **Locales.** The 17 phrase sets are data in `zoom_ax_parser.mm`, copied from the
  `Localizable.strings` of the installed Zoom 7.2.2 (88465). English and
  Simplified Chinese are the intended first live targets; the rest are
  fixture-covered only. Evidence from two locales in one snapshot is
  `locale_conflict`. Spanish and Portuguese share the `Participants list` label,
  so the self word decides. An unrecognized locale produces no evidence
  (`no_participant_evidence`, reported as `no_meeting`); when the installed Zoom's
  preferred localization has no phrase set the helper reports
  `unavailable`/`unsupported_locale` instead.
- **Windows.** Tiles in two windows, or two compact windows, are
  `ambiguous_windows`; nothing is combined. Self evidence is read from any window.
- **Versions.** Only `7.2.x` bundle versions pass `zoom_version_supported`; others
  report `unsupported_version` until validated.
- **Bounds.** Depth 64, 20000 nodes, 256 participants, 512-byte names; the parser
  re-enforces them. Invalid UTF-8, oversized names, and a repeated element are
  dropped and make the result incomplete.

## Helper behavior

- `zoom_observer_macos --protocol 1`; NDJSON on stdin/stdout, bounded static
  diagnostics on stderr (at most 32 lines, never names or text). Exits on stdin
  close, `stop`, or a protocol error (exit 2). SIGPIPE is ignored.
- Zoom is identified by bundle id `us.zoom.xos` through `NSRunningApplication`
  (the main run loop is turned briefly each read so the list is current in a
  command-line process). Several matching processes are `ambiguous_processes`.
- Capability order: macOS 15+, Zoom running, version, Accessibility trust,
  then one bounded read. `capabilities` uses
  `AXIsProcessTrustedWithOptions` with the prompt option off; only `setup` turns
  it on. `needs_setup` becomes `permission_denied` once setup was requested or
  trust was seen and lost.
- Passive reads: one `AXUIElementCopyMultipleAttributeValues` per node (role,
  description, value, identifier, children) and `AXWindows` on the application.
  The helper never sets attributes, performs actions, posts events, activates
  Zoom, or opens panels (a test greps the sources for those APIs).
- Messaging timeout 0.25 s on the system-wide element and the Zoom element; a read
  budget of 1.5 s. A missing attribute (`NoValue`, `AttributeUnsupported`,
  `NotImplemented`) is an observed absence; any other error marks the snapshot
  incomplete, and `APIDisabled` becomes `permission_denied`.
- Polling every `poll_ms` (default 500 ms), reads never overlap, stop abandons an
  in-flight read. `AXObserver` notifications are not used; polling is the only
  collection path.
- Clock: `mach_continuous_time` in milliseconds for all frames; `clock` also
  returns `uptime_ms` (`mach_absolute_time`). Native capture currently maps host
  time through `std::chrono::steady_clock`; the service must measure that
  offset with `clock` rather than assume equality across system sleep.
- References: element identity (`CFEqual`) when available, else name plus
  ordinal; scoped to a window label, so refs change if the meeting window is
  replaced.

## Build and packaging notes

`native/CMakeLists.txt` (macOS only) adds `foresight_zoom_ax_parser`,
`foresight_zoom_observer_core`, `zoom_observer_macos` and, for tests only,
`zoom_observer_macos_absent` (the same source with bundle id
`org.openforesight.test.absent-zoom`, so the protocol test holds on a machine
running Zoom). The helper links AppKit, ApplicationServices and Foundation.
Packaging must add the executable to nested-bundle assembly, signature and
architecture audits, and decide the signing identity under which Accessibility
trust is granted. The embedded plist identifier is fixed, but how System
Settings names a command-line helper launched by the service is unverified.

## Must be validated on a real Zoom 7.2.2 (88465) call

1. The real tree: roles and descriptions of participant tiles, the active-speaker
   marker, the compact window, and the Participants list, in English and
   Simplified Chinese, with muted and unmuted people, commas in names, and
   duplicate names. Capture a sanitized diagnostic tree to replace the guessed
   fixtures.
2. Whether tile descriptions carry the marker at all in gallery, speaker, and
   multi-speaker views, and whether the compact window shape matches.
3. Whether Zoom's elements keep identity across polls (refs and rename
   continuity), and whether the participants list lives in a separate window.
4. Traversal cost and failure rate. Probing a Finder window (not Zoom) with the
   same collector read roughly 700 to 1300 nodes inside the 1.5 s budget and
   about 3600 to 4200 nodes when the budget was lifted (about 0.7 ms per node),
   and 323 of 3624 nodes answered `kAXErrorFailure`. Because any non-absence
   error marks the snapshot incomplete, `complete` may rarely be true on a busy
   tree. The budget, pruning of irrelevant subtrees, which failures should count
   as incomplete, and the poll cadence need a measured choice against Zoom's real
   node count and error behavior, plus CPU and memory. These Finder numbers are
   an observation on one machine, not a Zoom result.
5. Speaker-switch delay and alignment against capture timestamps (ground-truth
   turn schedule, 100 transitions, 30-minute run).
6. Permission transitions: first run, denial, grant, revocation mid-meeting,
   regrant (whether a running helper recovers or needs a restart), app restart and
   update; the identity System Settings shows for the packaged helper under the
   shipped signing mode (ad-hoc is not Developer ID or notarized).
7. Hidden, minimized, background, screen-sharing, and layout-switch states;
   process or window replacement; a stalled Zoom (messaging timeout and stop
   deadline against a real hang).
8. Version gating (`7.2.x` only) and the unsupported-locale report.
9. That Zoom's behavior is unchanged by passive reads (no activation, no
   accessibility-triggered mode changes).
