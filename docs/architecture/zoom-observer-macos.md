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
| `native/zoom_observer_core.{h,cpp}`, `zoom_ref_table.h` | Platform-neutral protocol: NDJSON framing, `seq`, bounded reader, polling session, reference table, stop deadline. Links no parser and no OS framework: the platform passes its parse function and parser version through `ObserverConfig`, and supplies a `Source`. A Linux helper reuses this library and the snapshot types in `zoom_ax_parser.h`. `ObserverConfig` has no macOS defaults; `run_observer` refuses to start (exit 64) without `parse`, `helper`, `platform` and `parser_version`. In this branch the target sits inside `if(APPLE)` with the macOS-only targets; the Linux change hoists `foresight_zoom_observer_core` to `APPLE OR Linux`, so the CMake move is deliberately not made here. |
| `native/zoom_ax_convert.{h,mm}` | Attribute values to plain types (string, error wrapper, status mapping), testable with ordinary CoreFoundation objects. |
| `native/zoom_collector.{h,cpp}` | Bounded traversal behind an `AxReader` interface: limits, absence versus failure, identity registry, cancellation. |
| `native/zoom_mac_source.{h,cpp}` | The macOS `Source`: the gate order and trust transitions, over an `Environment` and an `AxReader`. Tested with fakes. |
| `native/zoom_observer_macos.mm` | Only the OS bindings (`NSRunningApplication`, Info.plist, `AXUIElement`) and `main`. |
| `native/zoom_observer_macos_info.plist` | Embedded `__info_plist` giving the helper the stable identifier `org.openforesight.zoom-observer`. |
| `tests/fixtures/zoom_ax/` | Synthetic scenarios (81) and the 17-locale phrase set; controlled names only. |
| `tests/native/zoom_ax_parser.cpp`, `zoom_ax_convert.cpp`, `zoom_observer_core.cpp`, `zoom_mac_source.cpp`, `zoom_observer_protocol.py` | CTest `zoom_ax_parser`, `zoom_ax_convert`, `zoom_observer_core`, `zoom_mac_source`, `zoom_observer_protocol`. The core test links the real parser for realistic observations rather than a fake. |

The helper is built only on macOS and installed to `bin/` like `foresight-audio`
(arm64, deployment target from the build, `-fobjc-arc`). Packaging is not wired.

## Parser rules as implemented

Input is an `AXApplication` whose children are `AXWindow` nodes (or one
`AXWindow`). Each node carries role, description, value, identifier and an
optional collector-assigned element id.

- **Tile.** Role exactly `AXTabGroup`; the description is
  `<name>, <audio status>[, <active marker>][, other details]`. The audio status
  anchors on its LAST occurrence (the research rule took the earliest). If the
  text before it still contains any locale's status or marker phrase, the name is
  ambiguous (`Mallory, Computer audio unmuted, Active speaker, <real status>`): the
  tile is dropped, the read is incomplete, and it is never locale evidence. A
  description made entirely of attacker-controlled text with no real status is
  structurally identical to a genuine tile and cannot be detected. Trailing whitespace and ASCII, fullwidth and ideographic
  commas are removed from the name. A matched tile's descendants are not
  searched; an unmatched `AXTabGroup` is searched through.
- **Unnamed and marker-only tiles.** A status with a name that is empty or only
  whitespace, control or invisible format characters (zero-width space, joiners,
  bidi marks, BOM) is an unnamed tile: it is dropped and the read is
  `complete: false`. A description that ends in an active-speaker marker but has
  no audio status is not accepted as a tile either (that structure is not
  validated, and a participant named `Eve, Active speaker` would otherwise
  become a speaker); it also makes the read incomplete.
- **Active.** The marker must be the last item after the status and preceded by
  a comma, so `Alice, Computer audio unmuted, Not Active speaker` is not active
  (the research rule matched it by suffix alone) and neither is
  `Mallory, Active speaker, Computer audio muted`. An unmuted microphone alone is
  not a speaker. Several marked tiles are all reported.
- **Names.** Display spelling is kept (only edge whitespace, including no-break
  spaces, is trimmed; commas, punctuation, right-to-left text, emoji and ZWJ
  sequences survive). The comparison key folds case and whitespace and
  canonicalizes Unicode composition but keeps diacritics, so distinct people do
  not merge. Equal names with different elements stay separate participants.
- **Compact window.** Only when no ordinary tile exists anywhere and the snapshot
  is complete: an `AXWindow` whose direct `AXButton` children include both
  localized controls, then exactly one direct `AXStaticText` whose value begins
  with the locale's `Talking:` form. Zero labels is an observed absence; two
  labels, a label containing a comma (a list of names), an invisible-only name, or
  a direct static text whose value is empty or undecodable (it could have been
  the label) makes the read `complete: false` with no speaker. The two-child `Show video render` shape is
  not supported.
- **Self.** An `AXOutline` whose description is the Participants-list label of
  the meeting's locale, then descendant `AXStaticText` values ending in a
  parenthetical that lists that locale's self word (`Alice (me)`,
  `Alice (host, me)`, `Alice (Host) (me)`). Self is set only for a single
  distinct self name that matches exactly one tile.
- **Ordered-tile fallback.** Not implemented and not compiled. A fixture asserts
  that an ordered gallery layout without markers yields no speaker.
- **Locales.** The 17 phrase sets are data in `zoom_ax_parser.mm`, copied from the
  `Localizable.strings` of the installed Zoom 7.2.2 (88465). English and
  Simplified Chinese are the intended first live targets; the rest are
  fixture-covered only. The meeting locale comes only from tile statuses and the
  compact controls. If tiles disagree, a locale held by more tiles than all the
  others together wins and the outliers are dropped (incomplete read); with no
  such majority the result is `locale_conflict`, so one participant can blank a
  two-person meeting but not a larger one. The
  Participants-list label is shared by Spanish and Portuguese, so it never
  contributes locale evidence: the self word of the already established locale
  decides (`Joao (eu)` in a Spanish meeting is not self and not a conflict). An
  unrecognized locale produces no evidence (`no_participant_evidence`, reported as
  `no_meeting`); when the installed Zoom's preferred localization has no phrase
  set the helper reports `unavailable`/`unsupported_locale` instead.
- **Compact after dropped tiles.** Compact inference does not run when any
  tile-like node was dropped (unnamed, marker-only, ambiguous): it is only a
  fallback for a snapshot that really has no tile.
- **Windows.** Tiles in two windows, or two compact windows, are
  `ambiguous_windows`; nothing is combined. Self evidence is read from any window.
- **Versions.** Only `7.2.x` bundle versions pass `zoom_version_supported`; others
  report `unsupported_version` until validated.
- **Bounds.** Depth 64, 20000 nodes, 256 participants, 512-byte names; the parser
  re-enforces them. Invalid UTF-8, oversized names, and a repeated element are
  dropped and make the result incomplete.
- **Failed reads are not quiet meetings.** When no evidence is found but the
  snapshot was truncated, or a tile was dropped, the result is
  `incomplete_read` (reported as `unavailable`), never `no_meeting`.

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
- Zoom's version is read from `Info.plist` on disk at every poll
  (`CFBundleCopyInfoDictionaryInDirectory`); `NSBundle` caches its dictionary, so
  an in-place update would otherwise bypass the version gate.
- Passive reads: one `AXUIElementCopyMultipleAttributeValues` per node (role,
  description, value, identifier, children) and `AXWindows` on the application.
  The helper never sets attributes, performs actions, posts events, activates
  Zoom, or opens panels (a test greps the sources for those APIs).
- Messaging timeout 0.25 s on the system-wide element and the Zoom element; a read
  budget of 1.5 s. A missing attribute (`NoValue`, `AttributeUnsupported`,
  `NotImplemented`) is an observed absence, except for `AXWindows`, where only
  `NoValue` is (anything else is a failed window list). A node whose role is empty
  or whose whole read fails, an oversize or unencodable string (including one cut
  at an embedded NUL), and a non-element child all mark the snapshot incomplete;
  `APIDisabled` becomes `permission_denied`. Once a limit or cancellation is hit,
  no further node is created or read. If a messaging timeout cannot be set, no
  read is made (`ax_timeout_unavailable`). A missing `AXValue` on a `AXStaticText`
  or `AXDescription` on an `AXTabGroup` is not itself treated as incomplete
  (containers legitimately lack them); the parser covers the consequential cases
  (an empty direct static text in a compact window, an unnamed tile).
- Polling every `poll_ms` (default 500 ms), reads never overlap, stop abandons an
  in-flight read. `AXObserver` notifications are not used; polling is the only
  collection path.
- Clock: `mach_continuous_time` in milliseconds for all frames; `clock` also
  returns `uptime_ms` (`mach_absolute_time`). Native capture currently maps host
  time through `std::chrono::steady_clock`; the service must measure that
  offset with `clock` rather than assume equality across system sleep.
- References: keyed by (element, comparison key) when an element id exists
  (`CFEqual`), so a screen element that later shows another name gets a new ref;
  scoped to a window label, so refs change if the meeting window is replaced.
  Without element identity the key is (name, ordinal), trusted only while the
  count of that name is unchanged. Equal names mark the read `complete: false`
  in both cases: with element identity two tiles that trade places would swap
  refs silently. A full identity table (4096) or reference table, or
  dropping departed people to make room (people still present are never
  evicted), also marks the read incomplete. The identity table is pruned only
  after a complete read.
- Shutdown and I/O: after `stop`, end of input, a fatal error or a broken stdout,
  queued `capabilities`/`setup`/`start` requests are answered `error`/`cancelled`.
  A broken stdout (failed write, or a hang-up the reader notices while idle) exits
  3 with `stdout_closed` on stderr. The request queue holds 64 requests; beyond
  that a request is refused `busy` and the reader keeps reading, and one request
  is handled per loop turn so polling continues. The reader thread and the stop
  guard write with a bounded wait (about 100 ms for the writer lock and for the
  pipe to become writable) so a consumer that stopped reading cannot delay a
  `stop` or the exit; only the polling thread's ordinary writes may block.
- Memory: the helper loop is plain C++, so `parse_snapshot`, `comparison_key`,
  the AX reader calls and the attribute conversion each drain their own
  autorelease pool; tests bound heap growth for the parser (20000 parses) and
  the conversion (200000 calls).

## Build and packaging notes

`native/CMakeLists.txt` (macOS only) adds `foresight_zoom_ax_parser`,
`foresight_zoom_observer_core`, `foresight_zoom_mac_source`, `zoom_observer_macos` and, for tests only,
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
   multi-speaker views, whether a tile without an audio status ever carries the
   marker (such tiles are rejected today), and whether the compact window shape
   matches.
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
