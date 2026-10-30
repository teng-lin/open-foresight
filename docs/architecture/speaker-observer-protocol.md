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
- Field syntax: `id`, `session`, `ref` and `window` are opaque, 1 to 128
  characters, with no control characters. `helper`, `helper_version`,
  `parser_version`, `platform`, `code` and `reason` are tokens of at most 64
  characters from `A-Za-z0-9_.:-` (`reason` may be empty or absent).
  `zoom_version` and `locale` are optional text of at most 64 characters.
  Millisecond fields are non-negative integers strictly below 2^50. The receiver treats
  any violation as a protocol error and reports only a fixed description.

## Requests (service to helper)

| `type` | Fields | Meaning |
| --- | --- | --- |
| `capabilities` | `id` | Report availability without prompting or changing settings |
| `setup` | `id` | Explicit accessibility setup (may prompt / guide the user); reply with `capabilities` |
| `start` | `id`, `session`, `poll_ms` (100 to 5000), `deadline_ms` (100 to 30000) | Begin observing the selected meeting for recording session `session`; `deadline_ms` bounds the helper's shutdown; a read has a fixed 1500 ms budget in both helpers whatever it is |
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
| `started` | `id`, `session`, `target` (`pid` and `zoom_version`, each `null` while Zoom is not running) |
| `observation` | see below |
| `unavailable` | `session`, `reason`, `since_ms` |
| `clock` | `id`, `monotonic_ms`, `uptime_ms` (optional extra) |
| `error` | `id` (optional), `code`, `message` |
| `stopped` | `id`, `session` (null or absent when `stop` arrived before any `start` was accepted) |

A `start` that cannot be honoured is answered with an `error` frame, or with a
`capabilities` frame (same `id`) whose `state` is not `available`; no
observation follows either. An `available` state in that reply is a protocol
error. A first start reports the failure to its caller without retrying; what
the service does when a restart is answered this way is under Service
supervision.

While started, the helper emits one `observation` per poll while it can read
the meeting, and an `unavailable` frame only when an unavailable interval begins
or its reason changes. The service therefore expects a frame within
`poll_ms + max(deadline_ms, 1500)` plus a slack after an `observation`, and treats longer
silence as a stalled helper, terminates it and restarts it. After an
`unavailable` frame silence is normal; the service then sends a `capabilities`
request each stall timeout, which the polling thread answers between reads, and
restarts the helper if none is answered within the request timeout. An `error`
frame without `id` while started is fatal. An `observation` before `started`,
or for another `session`, is a protocol error.

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
- Names keep their original spelling, including commas and punctuation. The
  receiver removes control characters and these format characters, the same set
  persistence strips: U+00AD, U+061C, U+200B, U+200E and U+200F, U+202A to
  U+202E, U+2060 to U+2064, U+2066 to U+206F, U+FE00 to U+FE0F, U+FEFF, U+E0000
  to U+E007F and U+E0100 to U+E01EF. Line breaks become spaces and the name is
  trimmed. The joiners U+200C and U+200D stay inside names but are never visible
  by themselves. A roster entry with no visible character left is dropped by the
  receiver, and one longer than 256 characters is clamped to 256; either makes
  that read `complete: false`, and an entry so treated is never an active
  speaker (its `speakers` entry is dropped). The native filters do not remove
  every such name (variation selectors and tag characters pass them), so this is
  not a protocol error: a name on screen must not restart the helper.
  Known gap, shared with persistence: characters that render blank but are not
  in that set (U+180E, U+034F, the Hangul fillers U+115F, U+1160, U+3164 and
  U+FFA0, and U+2800) still count as visible, so a participant named only with
  them is accepted. Changing that needs a joint change to both.
- Every `speakers[].ref` must name a distinct entry of the same observation's
  `participants`, and `participants[].ref` values are distinct. Violations are
  protocol errors, so a speaker can never lack a roster entry (the receiver may
  still drop a speaker whose name it cannot use, as above).
- An `error` frame's `message` is untrusted diagnostic text; the receiver
  bounds it to 256 characters and does not log it by default.

## Limits and lifecycle

Per read: tree depth at most 64, nodes at most 20000, one observation at most
256 participants. Exceeding a bound sets `complete: false`. The helper must exit
when stdin closes.

### Service supervision

- **One helper at a time.** The service never launches a helper while an earlier
  one is unreaped. `stop` cancels any start, restart or query in flight and
  waits until every child that exists has exited. A launch that was abandoned
  (timeout or cancellation) is waited for at most one kill grace by `stop` and
  one spawn timeout by the next launch (a `stop` cuts that wait short); a child
  that appears is always drained and reaped before either returns. A launch
  still pending after that owns no child yet: it is reaped in the background if
  it ever produces one, and the next launch, `stop` or `dispose` waits for it
  again, until it has been pending for two spawn timeouts, after which it is no
  longer waited for (it is still reaped in the background). A child that cannot be
  reaped (it survives SIGKILL) puts the service in a refuse-further-use state.
- **Shutdown.** `stop` asks the helper to stop, waits `exitGrace` (at least the
  read deadline), then sends SIGTERM and SIGKILL, each with a bounded wait. A
  shutdown that needed a signal, exited nonzero, or answered with an error or
  another session's `stopped` is reported on the `stopped` state event. Stop is
  only sent after an accepted start, so a `stopped` with a null `session` is
  also unclean (that answer belongs to a stop that precedes any start). A stop
  refused with `error` / `busy` is unclean and has its own diagnostic.
- **Restarts.** A failed or stalled helper is replaced, with exponential
  backoff, at most 5 restarts per budget. The budget refills once a helper had
  run for 5 minutes before failing, so isolated crashes hours apart never
  exhaust it; `maxRestarts: 0` disables restarting. A restart whose `start` is
  answered `permission_denied`, `needs_setup`, `unsupported_version` or
  `unsupported_platform` is final (retrying cannot help) and the `failed` state
  event carries that state. `zoom_not_running`, `no_meeting` and `unavailable`
  are retried within the budget, since the meeting window may reappear.
- **Epochs.** Every helper process start increments an epoch counter that lives
  as long as the observer. The service qualifies every `ref` it delivers as
  `<epoch>:<ref>`, so one helper's references can never alias another's, even
  across `stop` and a new `start` with the same session identifier. A
  restarting, failed or stopped observer is a blind interval, never a
  continuation of the previous speaker.
- **Clock.** Observer timestamps are shifted onto the capture clock with the
  offset from the best of at least one (default three) `clock` exchanges per
  helper; the shift widens each read by half the round trip plus one
  millisecond. A probe during which the capture clock went backward is
  discarded. The offset is not constant: the macOS helper's `monotonic_ms`
  counts system sleep (`mach_continuous_time`) while native capture timestamps do
  not, so every sleep moves the offset by its length. The offset is therefore
  measured again every 30 s (default) while running, and at once when a read
  ends later than the clock would allow (more than the measurement's uncertainty
  plus 250 ms after the moment it arrived). A re-measured offset that differs
  from the one in use by more than both uncertainties plus 250 ms is a shift: the
  new offset is used, and an `UnavailableEvent` with `retractsReads` and the
  reason `clock_shift` tells the consumer to forget every read after the last
  one the old offset was known to fit (for a helper clock that moved ahead, as
  across a sleep, that is the end of the last read that was not ahead of the
  capture clock, whatever the length of the sleep; otherwise the last
  confirmation). A consumer that ignores the flag keeps reads timed up to the
  sleep's length too late. A time the helper reports about the past (the start
  of an unavailable interval) is mapped with the offset that was in force then.
  Timers count time asleep and the capture clock does not, so a stall timeout
  that fires after the capture clock moved less than the timeout is re-armed for
  the rest of it, and a frame the helper sent (even one dropped as implausible)
  proves it alive. Reads that arrive while the session is stopping or
  restarting are not judged. The capture clock is the native capture monotonic
  clock, which runs whether or not audio is flowing; a clock that has not moved
  at all, went backward, or stops moving (waited on at most three times) does not
  defer a stall.
  Known limits: a blind period that began more than the sleep's length before
  the last good read is mapped with the new offset and is early by the sleep's
  length; a request in flight across a sleep (a probe or a clock exchange) times
  out on a timer that counted the sleep and can cost one restart; reads that
  arrive during a recheck do not advance the last-good mark and may be retracted
  although correct. Attributions already made
  from such reads are not revisited. A shift smaller than the tolerance, or one
  that happened since the last recheck and shows in no read, is not seen until
  the next periodic measurement; the error until then is the shift.
- **Plausibility.** A read is a protocol violation, and the helper is replaced,
  when its mapped end lies more than the read skew (default 5 s) in the
  service's future, its start more than the skew before the session began, or
  it took longer than the read deadline plus the skew. An `unavailable` frame's
  `since_ms` is checked the same way (mapped time not in the future, not before
  the session began). Before such a read is blamed on the helper the clock offset
  is measured again: a shifted offset (a long sleep) explains the read, which is
  dropped, and the helper is kept.
- **Flooding.** More than `max(20, 4000 / poll_ms)` stream frames per second is a
  protocol violation.
- **Busy.** A request refused with `error` / `busy` (the helper's queue was
  full) changed nothing. The service resends `start`, `clock` and query
  requests up to three more times, each with a fresh `id` and after one
  backoff interval (a stop or failure ends the wait at once), and then reports
  a `helperError` with code `busy`, which a first `start` returns to its caller
  to retry and a restart retries within its budget.
- **Queries.** `capabilities` and `setup` against a running session reuse its
  helper, and a timed-out query does not fail the session (the late reply is
  ignored). Without a session each query uses its own short-lived helper;
  queries are serialized and a `start` waits for one in flight.
