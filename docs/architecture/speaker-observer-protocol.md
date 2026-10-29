# Meeting speaker observer protocol

Wire contract between the service-owned `MeetingSpeakerObserver` (Dart) and the
platform helpers (`zoom_observer_macos`, `zoom_observer_linux`). Design context:
[Zoom speaker attribution](zoom-speaker-attribution.md).

## Transport

- The service starts the helper as a child process with `--protocol 1`. The
  helper reads requests from stdin and writes frames to stdout as UTF-8,
  newline-delimited JSON, one object per line. Stderr carries bounded
  diagnostics only and never participant names or transcript text.
- A line is at most 262144 bytes. Longer input is a protocol error; the receiver
  closes the session. Unknown fields are ignored; unknown frame `type` values are
  a protocol error.
- Every frame has `v` (protocol version, `1`), `type`, and `seq` (a per-direction
  counter from 0, incremented by one per frame). A gap or repeat in `seq` is a
  protocol error. The helper's first frame is `hello` (`seq` 0); the service's
  first request is `seq` 0 independently.
- A protocol error is fatal: the helper writes one `error` frame without `id`
  (`code` is one of `malformed_json`, `protocol_version`, `protocol_seq`,
  `protocol_type`, `line_too_long`, `truncated_line`, `input_error`), then exits
  2. Malformed JSON, a non-object line, a blank line, invalid UTF-8, nesting
  deeper than 16 levels (the top-level object counts as one), a missing or wrong
  `v`, a missing or wrong `seq`, and an unknown `type` are all protocol errors,
  as is a final request cut off by end of input (`truncated_line`) and a read
  error on stdin (`input_error`, not a clean EOF). Requests behind a fatal one
  are never processed. A well-formed request of a known type with invalid fields
  is not fatal: it gets `error` with `code` `invalid_request` (and the request
  `id` when it was valid) and the session continues.
- If stdout can no longer be written (a failed write, or a hang-up noticed while
  idle) the helper stops reading Zoom, writes the token `stdout_closed` to stderr
  and exits 3. An invalid helper configuration exits 64 before any frame.
- A platform source may also end the session itself when only a restart can fix
  it (the Linux helper does when libatspi loses its accessibility registry for
  good). The helper then writes one terminal `error` frame whose `code` is the
  source's reason token (`atspi_bus_lost`), with the `id` of the request whose read
  found it (none when a poll did; that poll first reports the `unavailable`
  interval), and exits with the source's status (4 for the Linux registry loss). A
  stop, end of input or broken stdout that began first wins and the request is
  answered `cancelled`: after a stop `stopped` is written and the exit is 0; end of
  input writes no further frame and exits 0; a broken stdout writes nothing and
  exits 3. If a stop arrives while the fatal `error` is being finished, the shutdown
  guard leaves with the status of the frame that was written (4 here), not the
  stop's 0.
- The helper is launched as `<helper> --protocol 1`; any other arguments exit 64
  with a usage line on stderr.
- All observed strings (names, window titles) are untrusted source data.

## Requests (service to helper)

| `type` | Fields | Meaning |
| --- | --- | --- |
| `capabilities` | `id` | Report availability without prompting or changing settings |
| `setup` | `id` | Explicit accessibility setup (may prompt / guide the user); reply with `capabilities` |
| `start` | `id`, `session`, `poll_ms`, `deadline_ms` | Begin observing the selected meeting for recording session `session` |
| `stop` | `id` | Finish the interval, emit `stopped`, exit 0 within `deadline_ms` |
| `clock` | `id` | Reply with `clock` frame for offset measurement |

`id` is a service-chosen request identifier echoed in the reply: an integer or a
non-empty string, required on every request. `session` is an opaque
recording-session identifier (non-empty string) echoed in every observation.
Both are limited to 128 bytes of JSON-escaped text, so a control character
counts six; longer values are `invalid_request`. This keeps every reply the
reader or the stop guard writes under the pipe's atomic-write size. `poll_ms` is an integer from 100 to 5000 (default
500); `deadline_ms` an integer from 100 to 30000 (default 2000).

`start` is accepted whether or not a meeting exists. The helper answers
`started` and keeps polling; `target` carries `pid` and `zoom_version` when
Zoom is running and `null` for either otherwise (the window is only known from
observations). Until a meeting can be read it reports `unavailable`, and the
session continues, so a recording that begins before the call does is not
refused. A second `start` is answered with `error` / `already_started`; it never changes
the running session's id or `deadline_ms`. A `start` refused as `busy` changed
nothing and may simply be retried. Requests that were already queued when
shutdown began (`stop`, end of input, a fatal error, a broken stdout) are
answered with `error` / `cancelled` instead of a state the cancelled read could
not establish; a `setup` in that position never prompts. Requests sent after
`stop` are never read. End of input uses the session's `deadline_ms` for the same
stall guard as `stop`. The helper queues at most 64 requests; a request that
finds the queue full is refused with `error` / `busy` (the reader never blocks
on queue space, so `stop` is always seen).

`stop` before any accepted `start` is answered with `stopped` whose `session` is
`null`; otherwise `stopped` carries the id of the accepted `start`, even if its
first read never completed. `stop` is honored while an accessibility read is
stalled: the read is abandoned and, if the helper has not finished within
`deadline_ms`, its reader thread writes `stopped` itself. A stalled read never
outlives the deadline.

The reader thread and this guard never wait on a consumer that stopped reading:
each write waits at most about 100 ms for the writer lock and for the pipe to be
writable. After one such wait times out, further reader/guard writes give up at
once for 250 ms, so a burst of replies ahead of a `stop` adds at most one wait
(about 200 ms) to the exit, not one per reply. If the guard's closing frame
cannot be written (wedged or closed stdout, or an oversize frame) it exits 3
rather than 0 (but if the main loop had already written it, the guard leaves with
the main loop's code: 0 after `stopped`, 2 after a fatal `error`), and it may leave a torn last line on stdout when it exits during
a write; a consumer must treat a truncated final line as an unclean stop.
`capabilities`, `setup` and `start` are answered by the polling
thread (between reads); `clock` is answered immediately.

## Frames (helper to service)

| `type` | Fields |
| --- | --- |
| `hello` | `helper`, `helper_version`, `parser_version`, `platform` (`macos` or `linux`) |
| `capabilities` | `id`, `state`, `reason`, `zoom_version`, `locale` |
| `started` | `id`, `session`, `target` |
| `observation` | see below |
| `unavailable` | `session`, `reason`, `since_ms` |
| `clock` | `id`, `monotonic_ms`, `uptime_ms` (optional extra) |
| `error` | `id` (optional), `code`, `message` |
| `stopped` | `id`, `session` |

`state` is one of `available`, `needs_setup`, `permission_denied`,
`zoom_not_running`, `no_meeting`, `unsupported_version`, `unsupported_platform`,
`unavailable`. `reason` is a short stable token, never user content. `zoom_version`
and `locale` are `null` when unknown. `unavailable` frames report a change, not
every failed poll: one frame when an unavailable interval begins and another if
its `reason` changes (`since_ms` stays at the start of the interval). Observed
reason tokens include `zoom_not_running`, `accessibility_not_trusted`,
`zoom_version_unsupported`, `no_meeting_window`, `no_participant_evidence`,
`ambiguous_windows`, `ambiguous_processes`, `locale_conflict`,
`unsupported_locale`, `ax_read_failed`, `ax_timeout_unavailable`,
`version_unreadable`, `incomplete_read`, `frame_too_large`. The Linux helper also
reports `no_session_bus`, `session_bus_unreachable`, `atspi_bus_absent`,
`atspi_status_unreadable`, `accessibility_disabled`, `accessibility_lost`,
`setup_not_effective`, `atspi_unreachable`, `atspi_bus_lost`, `process_scan_failed`,
`no_validated_rules`, `zoom_not_exposed` and `read_cancelled`. `incomplete_read`
means a bound, timeout or failed attribute cut the read short and no evidence
was found, so a meeting is neither confirmed nor ruled out; only a complete read
with no evidence reports `no_meeting`. `needs_setup` means
accessibility was never granted to this helper; after an explicit `setup` that
is still not granted, or after a grant is lost, the state is `permission_denied`.
On Linux this holds when the accessibility bus is there but stays disabled
(`permission_denied`/`setup_not_effective`, or `accessibility_lost` after a grant
was seen) and not when the bus is absent: the helper cannot start it, so that
state stays `needs_setup`/`atspi_bus_absent` after `setup`, and a `setup` that no
live accessibility bus answered (none running, a timeout) is not counted as an
attempt; a refusal from a running bus is.
`clock.uptime_ms` is the same instant on the sleep-excluding uptime clock
(`mach_absolute_time` on macOS; on Linux `CLOCK_MONOTONIC` already excludes sleep, so
it equals `monotonic_ms`), provided because native capture timestamps may
be derived from a steady clock that does not count system sleep.

### Observation

```json
{
  "v": 1, "type": "observation", "seq": 7, "session": "s1",
  "read_start_ms": 123456, "read_end_ms": 123492,
  "target": {"pid": 4242, "window": "w1", "zoom_version": "7.2.2.88465", "locale": "en"},
  "complete": true,
  "parser_version": "mac-1",
  "participants": [{"ref": "p1", "name": "Ada Lovelace", "self": false}],
  "speakers": [{"ref": "p1", "method": "participant_status"}]
}
```

- `read_start_ms`/`read_end_ms` are on the helper's monotonic clock: macOS
  `mach_continuous_time` and Linux `CLOCK_MONOTONIC`, in milliseconds. Capture
  timestamps use the same clock domains; a `clock` exchange measures any offset.
  Never substitute wall-clock time.
- `ref` is meeting-local and valid only within `session`/`window`; it is not a
  durable user identifier. With element identity a ref is keyed by (element,
  display-name key): an element that shows a different name gets a new ref.
  Equal display names with different `ref`s stay separate participants.
- `complete` is false when a bound or failed read cut the tree short, when an
  unnamed or unreadable tile was dropped, when a tile's active marker is not the
  last item (inactive but unsure), or when references could not be kept
  trustworthy (element identity missing, the reference table at capacity, or
  refs that may have swapped between people who share a display name: the
  elements behind a duplicated name changed in this poll, or, without element
  identity, its slot's occupant did). Two people sharing a name do not by
  themselves make a read incomplete and both stay listed. A speaker whose name
  is shared is withheld from `speakers` and the read is incomplete, because the
  marker may belong to either.
- A frame (without its newline) is at most 262144 bytes in both directions. An
  observation that would exceed it is replaced by `unavailable` /
  `frame_too_large`.
- `target.window` is a meeting-local label (`w1`, `w2`, ...) assigned in order of
  first sight; `target.locale` is the pattern-set id that produced the evidence
  or `null`. `self` is true only when exactly one participant carries the
  observed self name.
- `speakers` empty with `complete: true` means an observed absence of an active
  speaker. A failed or partial read is reported as `unavailable` or with
  `complete: false` and never extends a previous speaker.
- `method` is one of `participant_status`, `compact_talking_label`,
  `ordered_tile` (disabled by default), `atspi_state` (Linux, reserved until a
  live signal is established).
- Names keep their original spelling, including commas and punctuation.

## Limits and lifecycle

Per read: tree depth at most 64, nodes at most 20000, one observation at most
256 participants. Exceeding a bound sets `complete: false`. The service enforces
an outer read deadline, terminates and reaps only the helper it started, and
restarts it with bounded backoff (at most 5 restarts per session). The helper
must exit when stdin closes.
