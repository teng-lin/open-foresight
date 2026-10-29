# Linux Zoom speaker observer helper

Implementation notes for `zoom_observer_linux`, the Linux half of
[Zoom speaker attribution](zoom-speaker-attribution.md). The wire contract is
[speaker-observer-protocol.md](speaker-observer-protocol.md); the macOS helper
is described in [zoom-observer-macos.md](zoom-observer-macos.md).

**Live feasibility: first screen only.** A pre-meeting Zoom tree was read once
(with `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`); no roster or speaker was observed. The shipped rule set enables no roster or speaker rule, so
the helper reports capabilities and `unavailable` and never a participant or an
active speaker. See [Linux live feasibility](zoom-speaker-attribution.md#linux-live-feasibility).

## Components

| File | Role |
| --- | --- |
| `native/zoom_observer_core.{h,cpp}`, `zoom_ref_table.h` | Shared with macOS: NDJSON framing, `seq`, bounded reader, polling session, reference table, shutdown. Linux passes its parser and `Source` through `ObserverConfig`. |
| `native/zoom_ax_parser.h` | Shared snapshot types. Linux uses `AxNode::states` and `attributes` (empty on macOS) and `Method::AtspiState` (wire token `atspi_state`). |
| `native/zoom_atspi_parser.{h,cpp}` | Pure Linux parser. Snapshot and data-only rules in, participants and speakers out. No AT-SPI, no desktop. |
| `native/zoom_linux_source.{h,cpp}` | The Linux `Source`: the gate order over a `LinuxDesktop` interface, plus the element-identity registry. Tested with fakes. |
| `native/zoom_observer_linux.cpp` | Only the libatspi/GDBus bindings (`AtspiDesktop`) and `main`. |
| `tests/fixtures/zoom_observer_linux/` | Synthetic fixtures with made-up roles and names. Never real trees or names. |
| `native/zoom_atspi_collect.{h,cpp}` | The bounded traversal behind a thin node interface, so limits, failures and cancellation run against a fake tree. |
| `tests/native/zoom_atspi_parser.cpp`, `zoom_atspi_collect.cpp`, `zoom_linux_source.cpp`, `zoom_linux_core.cpp`, `zoom_observer_core.cpp` (shared, with the Linux-only stand-in parser `zoom_core_test_parser.cpp`) | CTests `zoom_atspi_parser`, `zoom_atspi_collect`, `zoom_linux_source`, `zoom_linux_core`, `zoom_observer_core`. |
| `tests/native/zoom_observer_protocol.cpp`, `zoom_observer_bus.cpp`, `zoom_helper_harness.h` | CTests that drive the built helper: `zoom_observer_protocol` (scrubbed environment) and `zoom_observer_bus` (a private `dbus-daemon --session` with a fake `org.a11y.Bus`; skipped without dbus-daemon). `zoom_observer_linux_built` reports Skipped when the helper was not built. |

The AT-SPI reader builds only on Linux and only when pkg-config finds `atspi-2`
and `gio-2.0`; otherwise CMake skips it and its protocol test, and the parser,
`Source` and core tests still run. No Python is used at runtime.

## Gate order (`LinuxSource`)

Capability inspection and every poll walk the same gates, read-only. No D-Bus call
activates a service (`NO_AUTO_START`) except the one in `setup`:

1. Session bus: `DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`. Missing is
   `unavailable`/`no_session_bus`; unreachable or timing out (1 s, asynchronous connect)
   `session_bus_unreachable`. The helper never lets D-Bus autolaunch a bus.
2. Accessibility bus: `NameHasOwner("org.a11y.Bus")`. An error is
   `session_bus_unreachable`; absent is `needs_setup`/`atspi_bus_absent`, or
   `atspi_bus_lost` if libatspi was already connected.
3. `org.a11y.Status.IsEnabled`. Unreadable or not a boolean is `atspi_status_unreadable`;
   false is `needs_setup`/`accessibility_disabled`, `permission_denied`/`setup_not_effective`
   after a `setup` that did not turn it on, and `permission_denied`/`accessibility_lost`
   after a grant that was seen and then lost.
4. libatspi: the address comes from a bounded `org.a11y.Bus.GetAddress` call and is handed
   over through `AT_SPI_BUS_ADDRESS`; `atspi_init()` is checked (2 means unreachable, and
   asking libatspi for the desktop after that would abort the process). A failure is
   `unavailable`/`atspi_unreachable` with `atspi_exit()` and a retry after a growing delay
   (1 s doubling to 60 s). A registry that disappears later is `atspi_bus_lost` for one poll,
   then libatspi is re-initialized. The first attempt runs before the protocol threads start,
   because `setenv` races other threads' `getenv`; a later re-init still calls it from the
   polling thread.
5. Zoom: processes of the same user whose executable is named `zoom`
   (`/proc/<pid>/exe`, a ` (deleted)` suffix removed); none is `zoom_not_running`,
   several `ambiguous_processes`, an unreadable `/proc` (or an unexpected error reading an
   exe link) `process_scan_failed`. A process that exited or that this user may not inspect
   (`EACCES`, as for non-dumpable helpers on a real desktop) is skipped. The version
   is the first line of `version.txt` beside the executable. A Flatpak or snap Zoom runs
   in another pid namespace, so its pid never matches the registry: it is reported as
   `zoom_not_exposed` and is unsupported.
6. Rules: no validated rule gives `unsupported_version`/`no_validated_rules`; an
   unreadable version `version_unreadable`; a build outside the rule set
   `zoom_version_unsupported`.
7. One bounded traversal (`zoom_atspi_collect`): depth 64, 20000 nodes, 1.5 s, 250 ms per
   libatspi call (`atspi_set_timeout(250, -1)`; a non-negative second argument is a startup
   grace that stretches a new application's timeout), three call errors. The time and
   cancellation are checked before every remote call, and traversal stops at a limit, a
   cancellation or the error limit. Every application owned by the pid is read and their
   windows are joined; an application with no windows, a failed property call (error, a
   NULL attribute table, a state set holding only `defunct`), an unreadable child list or a
   node over the state/attribute caps makes the read incomplete (never proof of absence).
   A failure on the desktop's own child list is `ax_read_failed` (or `atspi_bus_lost` when
   the registry is gone); no application for the pid is `zoom_not_exposed`; cancellation is
   `read_cancelled`.
8. Cache: libatspi caches names, states and children per application and only keeps them
   current through event listeners, which this helper does not register. Each poll sets the
   cache mask to none and clears it, so every read is live. Whether Zoom's Qt bridge behaves
   with that is part of the live validation below.

`setup` is the only request that changes anything: it sets
`org.a11y.Status.IsEnabled` to true (the desktop-neutral switch toolkits read;
at-spi-bus-launcher mirrors it into GSettings where that exists), then reports
capabilities. Whether Zoom needs a restart afterwards is unknown. A test greps the
source for the only `Set` call and for any action, input or settings API.

## Parser

Rules are data (`RuleSet`): a window matcher, one roster container matcher, the
item role, an optional self attribute, an optional speaker state, and the Zoom
builds they were validated on. An AT-SPI accessible maps to `AxNode` as role =
role name, value = accessible name, description, states, attributes, and
`object_id` from the identity registry.

- Exactly one roster container may match; several are `ambiguous_windows`.
- A participant is the item's accessible name, kept whole (the Linux parser has no
  audio-status grammar, so a name that contains a status-like phrase stays
  intact). Edge whitespace including no-break space is trimmed. Invalid UTF-8, an
  oversize name (over 512 bytes), a name that is empty or only whitespace, control
  or invisible format characters, an item without identity and a repeated element
  are dropped and make the read `complete: false`.
- Equal names with different elements stay separate participants. References come
  from the shared table keyed by (element, comparison key), so an element that
  shows another name gets a new reference.
- A speaker is a roster item whose AT-SPI state set contains the rule's state;
  several are all reported. A helper without a validated speaker rule reports every
  observation `complete: false` with no speaker, so an empty list never means
  silence. A truncated or incomplete read lists no speaker.
- No roster found: `no_meeting_window` or `no_participant_evidence` for a complete
  read, `incomplete_read` when the read was truncated or the only items were
  dropped. Self is claimed only when exactly one participant carries the marker.
- Locale: there is no locale evidence on Linux; `target.locale` is `null`.

## Identity and clocks

`ElementRegistry` maps AT-SPI identity (bus name plus object path) to small
never-reused integers. Entries not seen are dropped only after a complete read, so a
truncated, failed or cancelled read never changes anyone's reference; at capacity (twice
the node limit) a new element is unknown and the read incomplete. The protocol clock is `CLOCK_MONOTONIC` in
milliseconds, which does not count system sleep, so `uptime_ms` is the same value.

## Not implemented

- AT-SPI change events. The shared core polls on a timer and has no wake hook;
  events would only schedule an early snapshot, never produce an observation.
  Add them behind a core wake hook once their reliability against Zoom is measured.
- Any roster or active-speaker rule, version allow-list entry, or locale handling.
- Xorg versus Wayland qualification, hidden or minimized states, screen sharing.

## Must be validated on a real Zoom on Linux

1. What a build needs to expose its tree: with the bus disabled it is exposed only
   when launched with `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` (and `DISPLAY` set; Zoom
   forces the xcb platform). Whether `org.a11y.Status.IsEnabled=true` (this helper's
   `setup`) is enough, or needs a Zoom restart, is untested, so `setup` may not
   suffice and the service may need to launch Zoom with that variable.
2. The real tree on the login, home, join and meeting screens: window roles and
   names, the participant roster, the self marker, and any speaking state or
   attribute, with controlled participant names and duplicates.
3. Identity stability across polls, traversal cost and failure rate under load, and event
   reliability if events are added. Cache freshness: that every poll sees live names and
   states with the cache disabled (the fake-tree test proves the helper re-reads, not that
   Zoom's bridge answers fresh values).
4. Wayland and Xorg sessions independently; Zoom running under Xwayland.
5. Ground-truth speaker-switch delay (100 transitions, 30-minute run).

## CI and packaging owner changes

Not done in this change (workflows and the CI image are owner-review territory,
[CI integrity](../platforms/ci-integrity.md)); without them CI silently builds no helper:

1. Add `libatspi2.0-dev` and `libglib2.0-dev` to the packages installed by
   `packaging/ci-tooling.Dockerfile`.
2. Configure CI and package builds with `-DFORESIGHT_REQUIRE_ATSPI=ON`, so a missing library
   is a configure error rather than a skipped helper. Until then a skipped helper shows as
   CTest `zoom_observer_linux_built` Skipped.
3. Add the executable and `libatspi.so.0` to package metadata, the ABI audit and
   `packaging/package_linux.py`, with an assertion that the helper is present.
4. Run `zoom_observer_bus` where `dbus-daemon` exists (the tooling image has `dbus-x11`).
