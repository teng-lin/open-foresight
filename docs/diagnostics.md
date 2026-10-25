# Diagnostics and logs

Open Foresight keeps a small diagnostic log on your computer to help explain
failures. Logs are never uploaded: there is no telemetry, crash reporter or log
exporter, and opening the logs folder does not send anything anywhere. You
decide whether to share anything in a bug report.

## Where logs are stored

Logs belong to the profile in use and live in its `logs` folder:

| Platform | Default location |
| --- | --- |
| macOS | `~/Library/Application Support/Open Foresight/logs` |
| Linux | `$XDG_DATA_HOME/open-foresight/logs`, usually `~/.local/share/open-foresight/logs` |

When `FORESIGHT_DATA` selects another profile, its logs are in that profile's
`logs` folder. There is no separate setting for the log location.

To find the folder, open **Settings → Diagnostics** and choose **Open logs
folder**. Your file manager shows the folder (Finder on macOS; on Linux, a file
manager that provides the freedesktop `FileManager1` service, such as Files,
Dolphin or Nemo). Open Foresight only shows a real folder inside the current
profile that is private to your account. It does not create the folder.

The desktop app, its background service and agent (MCP) connections each keep
their own sessions in the same folder. The Diagnostics section shows the
health of the desktop app's own session only.

## What is recorded

Records are JSON Lines: one JSON object per line. They contain only registered
event names, components, categories and numeric values such as counts, byte
sizes, durations, status codes and retry attempts, plus the application
version and build identity. A failure can include up to eight normalized code
locations inside Open Foresight.

Logs never contain note, source or meeting titles or identifiers,
transcripts or audio, prompts or model output, file or model paths, URLs,
account names or email addresses, credentials, request or response bodies,
command lines, environment variables, other programs' output, or exception
messages. Text that is not part of the registered vocabulary is dropped rather
than scrubbed.

Logs still show when Open Foresight ran and which features started or failed.
Review them before you share them.

Clearing workspace data does not delete the logs folder; the logs contain no
workspace content.

## Configuration

Logging is configured when Open Foresight starts, through environment
variables. Changes apply the next time it starts.

| Variable | Values | Default |
| --- | --- | --- |
| `FORESIGHT_LOG_LEVEL` | `error`, `warn`, `info`, `debug`, `trace` or `off` | `info` |
| `FORESIGHT_SERVICE_TRACE` | `1` records service transport detail at trace level | unset |

An unrecognized `FORESIGHT_LOG_LEVEL` uses `info`; Settings → Diagnostics then
says that the level was invalid. An explicit `FORESIGHT_LOG_LEVEL`, including
`off`, takes precedence over `FORESIGHT_SERVICE_TRACE`. `off` records nothing
and starts no log writer.

For example, on Linux:

```sh
FORESIGHT_LOG_LEVEL=debug open-foresight
```

A background service that is already running keeps the level it started
with. To change its level too, quit Open Foresight and stop the service (or
wait for it to exit) before starting again.

## Retention and size

Logs have a fixed upper bound for each profile. There are ten session slots,
each holding at most three files of 2 MiB: at most 60 MiB of records plus at
most 1 MiB of bookkeeping. Three slots are reserved for the background service
and two for the desktop app; the other five are shared.

When a new session needs room, Open Foresight reuses the oldest inactive
session, preferring sessions without warnings or errors. The newest session in
which the background service failed is kept for seven days. Running sessions
are never removed. Cleanup happens only when a session starts writing, not on
a timer.

Short sessions without warnings or errors may stay in memory only: records are
written once there is a warning or error, 100 records, or five seconds of
running time. An empty or missing logs folder right after the first start is
normal.

To remove all logs, quit Open Foresight, stop its background service, then
delete the `logs` folder. Logging never deletes files outside the folder.

## Health in Settings

**Settings → Diagnostics** shows the state of the desktop app's logging
session. **Refresh** reads it again; it is not updated in the background.

| Status | Meaning |
| --- | --- |
| Recording | Logging works normally. |
| Held in memory, not written | Records are held in memory and have not been written to files. |
| Not writing log files | Log files cannot be written here, for example on a network file system or when every slot is in use. Open Foresight keeps working. |
| Log writing stopped after a failure | Writing failed, for example because the disk is full. Earlier files are kept. Open Foresight keeps working. |
| Off | `FORESIGHT_LOG_LEVEL=off`. |
| Closed | The session ended normally. |
| Unavailable in this session | Logging did not start, for example because the profile could not be opened. |

The section also shows how many records this session recorded, dropped (for
example under heavy load) or rejected.

**Copy health summary** copies these values as plain text, with the
application version, so you can paste them into a bug report. The summary
contains only the closed status values and counters shown here: no paths,
account details or content.

## Troubleshooting

- **"No log files have been written yet."** Nothing has been written to this
  profile's logs folder. Logging may be `off`, the session may still be held in
  memory, or files cannot be written here. Check the status above.
- **"The logs folder was not opened because it is not a private folder."** The
  folder, or a folder above it, is a symbolic link, is not a folder, or can be
  accessed by other users. Open Foresight creates its logs folder privately;
  check the permissions of the profile and its `logs` folder and remove any
  link you created there.
- **"Could not show the logs folder."** The file manager could not be started.
  On Linux, install or start a file manager that provides
  `org.freedesktop.FileManager1`, or open the location in the table above
  yourself.
- **"The logs folder is unavailable in this session."** Startup did not select
  a profile for logging. Restart Open Foresight; if startup keeps failing,
  report the error shown at startup.
- To follow a session while reproducing a problem, use ordinary console tools,
  for example `tail -F` on the newest file in the logs folder.

## Reporting a problem

Use the [bug report form](https://github.com/teng-lin/open-foresight/issues/new?template=bug_report.yml).
Attaching diagnostics is optional. Paste the health summary from Settings
and, if you choose, short excerpts of log records after reviewing them. Do not
attach the whole logs folder, and never include credentials. Report security
problems privately as described in the [security policy](../SECURITY.md).
