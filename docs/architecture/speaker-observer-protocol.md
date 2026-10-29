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
  protocol error.
- All observed strings (names, window titles) are untrusted source data.

## Requests (service to helper)

| `type` | Fields | Meaning |
| --- | --- | --- |
| `capabilities` | `id` | Report availability without prompting or changing settings |
| `setup` | `id` | Explicit accessibility setup (may prompt / guide the user); reply with `capabilities` |
| `start` | `id`, `session`, `poll_ms`, `deadline_ms` | Begin observing the selected meeting for recording session `session` |
| `stop` | `id` | Finish the interval, emit `stopped`, exit 0 within `deadline_ms` |
| `clock` | `id` | Reply with `clock` frame for offset measurement |

`id` is a service-chosen request identifier echoed in the reply. `session` is
an opaque recording-session identifier echoed in every observation.

## Frames (helper to service)

| `type` | Fields |
| --- | --- |
| `hello` | `helper`, `helper_version`, `parser_version`, `platform` (`macos` or `linux`) |
| `capabilities` | `id`, `state`, `reason`, `zoom_version`, `locale` |
| `started` | `id`, `session`, `target` |
| `observation` | see below |
| `unavailable` | `session`, `reason`, `since_ms` |
| `clock` | `id`, `monotonic_ms` |
| `error` | `id` (optional), `code`, `message` |
| `stopped` | `id`, `session` |

`state` is one of `available`, `needs_setup`, `permission_denied`,
`zoom_not_running`, `no_meeting`, `unsupported_version`, `unsupported_platform`,
`unavailable`. `reason` is a short stable token, never user content.

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
  durable user identifier. Equal display names with different `ref`s stay
  separate participants.
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
