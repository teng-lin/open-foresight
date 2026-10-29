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
| `native/zoom_atspi_desktop.{h,cpp}` | The libatspi/GDBus bindings (`AtspiDesktop`): bus status, `setup`, process scan, libatspi lifecycle, the node and registry adapters. |
| `native/zoom_observer_linux.cpp` | Only `main`. |
| `tests/fixtures/zoom_observer_linux/` | Synthetic fixtures with made-up roles and names. Never real trees or names. |
| `native/zoom_atspi_collect.{h,cpp}` | The bounded traversal behind a thin node interface, so limits, failures and cancellation run against a fake tree. |
| `tests/native/zoom_atspi_parser.cpp`, `zoom_atspi_collect.cpp`, `zoom_linux_source.cpp`, `zoom_linux_core.cpp`, `zoom_observer_core.cpp` (shared, with the Linux-only stand-in parser `zoom_core_test_parser.cpp`) | CTests `zoom_atspi_parser`, `zoom_atspi_collect`, `zoom_linux_source`, `zoom_linux_core`, `zoom_observer_core`. |
| `tests/native/zoom_observer_protocol.cpp`, `zoom_observer_bus.cpp`, `zoom_helper_harness.h` | CTests that drive the built helper: `zoom_observer_protocol` (scrubbed environment) and `zoom_observer_bus` (a private `dbus-daemon --session` with a fake `org.a11y.Bus`, a second daemon as the accessibility bus with a fake registry, and an `org.a11y.Bus` service file whose activation leaves a marker, driving `zoom_observer_bus_helper`, a test-only `main` with synthetic rules and a controllable process name; skipped without dbus-daemon). `zoom_observer_linux_built` reports Skipped when the helper was not built. |

The AT-SPI reader builds only on Linux and only when pkg-config finds `atspi-2`,
`gio-2.0` and `dbus-1`; otherwise CMake skips it and its protocol test, and the parser,
`Source` and core tests still run. No Python is used at runtime.

## Gate order (`LinuxSource`)

Capability inspection and every poll walk the same gates, read-only. None of the
helper's own D-Bus calls activates a service (`NO_AUTO_START`), `setup` included.
libatspi's own calls are different: those to `org.a11y.atspi.Registry` do not set
`NO_AUTO_START` and can activate `at-spi2-registryd` through the accessibility bus.
libatspi is not initialized by the first five gates, only by gate 6, and only when a
validated rule needs a read.

1. Session bus: `DBUS_SESSION_BUS_ADDRESS` restricted to `unix:` transports (`autolaunch:`
   and `unixexec:` entries are dropped), else `$XDG_RUNTIME_DIR/bus`. Missing is
   `unavailable`/`no_session_bus`; unreachable or timing out (1 s, asynchronous connect)
   `session_bus_unreachable`. The helper never lets D-Bus autolaunch a bus.
2. Accessibility bus: `GetNameOwner("org.a11y.Bus")`. A failure other than "no owner" is
   `session_bus_unreachable`; no owner is `needs_setup`/`atspi_bus_absent`. If libatspi was
   already connected, no owner, or an owner different from the one it connected to, or a
   dropped libatspi connection, is `atspi_bus_lost` (see below).
3. `org.a11y.Status.IsEnabled`. Unreadable or not a boolean is `atspi_status_unreadable`;
   false is `needs_setup`/`accessibility_disabled`, `permission_denied`/`setup_not_effective`
   after a `setup` that did not turn it on, and `permission_denied`/`accessibility_lost`
   after a grant that was seen and then lost. Deviation from the contract's
   "permission_denied after setup" sentence: an absent accessibility bus stays
   `needs_setup`/`atspi_bus_absent` after `setup`, because the helper cannot start it; and a
   `setup` whose `Set` call got no reply (no bus, no session bus) is not counted as an
   attempt, so a bus that appears later, disabled, is `needs_setup`/`accessibility_disabled`.
   The contract documents this.
4. Zoom: processes of the same user whose executable is named `zoom`
   (`/proc/<pid>/exe`, a ` (deleted)` suffix removed); none is `zoom_not_running`,
   several `ambiguous_processes`, an unreadable `/proc` (or an unexpected error reading an
   exe link) `process_scan_failed`. A process that exited or that this user may not inspect
   (`EACCES`, as for non-dumpable helpers on a real desktop) is skipped. The version is the
   first line of a regular file `version.txt` beside the executable (opened without blocking
   and without following links). A Flatpak or snap Zoom runs in another pid namespace, so
   its pid never matches the registry: it is reported as `zoom_not_exposed` and is
   unsupported.
5. Rules: no validated rule gives `unsupported_version`/`no_validated_rules`; an
   unreadable version `version_unreadable`; a build outside the rule set
   `zoom_version_unsupported`.
6. libatspi, on the first read that gate 5 allows: the address comes from a bounded
   `org.a11y.Bus.GetAddress` call and is handed over through `AT_SPI_BUS_ADDRESS`;
   `atspi_init()` is checked (2 means unreachable, and asking libatspi for the desktop after
   that would abort the process). A failure is `unavailable`/`atspi_unreachable` with
   `atspi_exit()` and a retry after a growing delay (1 s doubling to 60 s). Because the
   first init happens on the polling thread, `setenv` races other threads' `getenv`; the
   reader thread only polls and reads, and GDBus does not consult the environment after
   startup. libatspi's calls inside `atspi_init` (`dbus_bus_register`, the registry's
   first replies) have no timeout of their own: a hang there is bounded only by the
   shutdown guard of the core, not by `deadline_ms`.
7. One bounded traversal (`zoom_atspi_collect`): depth 64, 20000 nodes, 1.5 s, 250 ms per
   libatspi call (`atspi_set_timeout(250, -1)`; a non-negative second argument is a startup
   grace that stretches a new application's timeout), three call errors. Cancellation and
   the budget are polled before every remote call, including between the six calls one node
   makes, so a slow application overruns by at most one call. Traversal stops at a limit, a
   cancellation or the error limit. Every application owned by the pid is read and their
   windows are joined; an application with no windows, a failed property call (error, a
   NULL attribute table, a state set holding only `defunct`), an unreadable child list or a
   node over the state/attribute caps makes the read incomplete (never proof of absence).
   An identity from an over-long object path is treated as missing. A failure on one
   desktop child is `ax_read_failed`; no application for the pid is `zoom_not_exposed`;
   cancellation is `read_cancelled`.
8. Signals and cache: `atspi_init` subscribes to the registry's cache and event signals on
   the default GLib context. The helper registers no event listener of its own, but it
   drains that context (bounded to 256 iterations) once per poll and around every read.
   libatspi dispatches libdbus after each blocking call, so undrained signals do not make
   calls time out; they queue as deferred work that grows in memory for as long as the
   process lives, and the per-application tables never see their removals. Names, states
   and children are cached per application and kept current only by those signals; each
   read sets the cache mask of the desktop and of every application to none and clears it,
   so every read is live. Whether Zoom's Qt bridge behaves with that is part of the live
   validation below.

Two different failures are kept apart. A registry that stalls or restarts on a bus that
is still there (`NoReply`, `ServiceUnknown` on the desktop's child count) is an ordinary
`ax_read_failed`: libatspi re-registers the registry when its well-known name returns, and
the helper recovers on a later poll. What cannot be recovered in-process is the loss of
libatspi's connection to the accessibility bus itself, or a restart of that bus (a
different owner of `org.a11y.Bus`): libatspi keeps a static table of applications that
`atspi_exit()` does not clear, so a later `atspi_init()` cannot reach the new registry. That
is fatal and goes through the core as a source outcome: the helper reports
`unavailable`/`atspi_bus_lost` (a terminal `error` frame with that code, carrying the id of
the request that found it) and exits with status 4 (`kLinuxExitRegistryLost`), leaving the
supervisor to restart it within its bounded budget. A stop that arrived first wins and
exits 0.

Reason tokens and the exit status 4 are recorded in the
[protocol](speaker-observer-protocol.md); the Linux-only tokens are `no_session_bus`,
`session_bus_unreachable`, `atspi_bus_absent`, `atspi_status_unreadable`,
`accessibility_disabled`, `setup_not_effective`, `accessibility_lost`, `atspi_unreachable`,
`atspi_bus_lost`, `process_scan_failed`, `no_validated_rules`, `zoom_not_exposed`,
`read_cancelled`.

`setup` is the only request that changes anything: it sets
`org.a11y.Status.IsEnabled` to true without activating any service (so on a desktop where
the accessibility bus is not running it can do nothing and capabilities keep saying so) (the desktop-neutral switch toolkits read;
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

## CI and packaging

**Linux native stage.** `native-linux` in `.github/workflows/linux-platform-stages.yml` runs in
`archlinux:base-devel@sha256:061679925e5d5028f2df9395d441ce6c4b9accf0157ff3486c06b6962e014ef1`.
A provisional gate of this branch in that unmodified image installed nothing: `at-spi2-core`
2.62.1 and GLib 2.90.1 were already present, so the helper was built and its tests ran
(including `zoom_observer_bus`, which ran and was not skipped), 69/69 CTests, also with
`-DFORESIGHT_REQUIRE_ATSPI=ON`, and the `zoom_` tests were clean under ASan/UBSan. Those
libatspi and GLib versions are rolling Arch (`pacman -Syu` runs in the job), so they float
with the archive; they are not pinned by the image digest.

**Left to the workflow owner** (no workflow, image or packaging file is edited here, see
[CI integrity](../platforms/ci-integrity.md)):

1. Whether to set `-DFORESIGHT_REQUIRE_ATSPI=ON` in the native stage and in package builds.
   Without it a missing library silently skips the helper; the CTest
   `zoom_observer_linux_built` reports Skipped in that case, so the skip is visible but
   not a failure.
2. The Ubuntu paths: `packaging/ci-tooling.Dockerfile` installs neither `libatspi2.0-dev` nor
   `libglib2.0-dev`, and whether the Ubuntu SDK image it extends provides them is not
   verified here. If it does not, the helper is skipped there.
3. Packages: the executable and `libatspi.so.0` in package metadata, the ABI audit and
   `packaging/package_linux.py`, with an assertion that the helper is present.
