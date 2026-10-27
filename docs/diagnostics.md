# Diagnostics and logs

Open Foresight keeps a small diagnostic log on your computer to help explain
failures. Logs are never uploaded: there is no telemetry, crash reporter or log
exporter, and showing the logs folder does not send anything anywhere. You
decide whether to share anything in a bug report.

## Where logs are stored

Logs belong to the profile in use and live in its `logs` folder:

| Platform | Default location |
| --- | --- |
| macOS | `~/Library/Application Support/Open Foresight/logs` |
| Linux | `$XDG_DATA_HOME/open-foresight/logs`, usually `~/.local/share/open-foresight/logs` |

When `FORESIGHT_DATA` selects another profile, its logs are in that profile's
`logs` folder. There is no separate setting for the log location.

To find the folder, open **Settings → Diagnostics** and choose **Show logs
folder**. Your file manager opens the profile folder with `logs` selected
(Finder on macOS; on Linux, a file manager that provides the freedesktop
`FileManager1` service, such as Files, Dolphin or Nemo). Open Foresight shows
the folder only when the profile and its `logs` folder are real folders owned
by your user account, with no symbolic link anywhere in their path, the profile
is not writable by other users and `logs` is not accessible to other users. It
does not create the folder.

Inside `logs`, each session slot is a `slot-0` … `slot-9` folder holding up to
three record files `0.jsonl`, `1.jsonl` and `2.jsonl` plus small `manifest.json`
and `lease` files; `admission.lock` coordinates slot use.

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

**Clear workspace data** removes workspace content from the database, cleans
up the cleared sources, signs out workspace accounts and removes leftover
speech audio files. It does not remove the `logs` folder: only the log writer
creates or changes files there.

## Configuration

Logging is configured through environment variables that the desktop app
reads when it starts. Changes apply the next time it starts.

| Variable | Values | Default |
| --- | --- | --- |
| `FORESIGHT_LOG_LEVEL` | `error`, `warn`, `info`, `debug`, `trace` or `off` | `info` |
| `FORESIGHT_SERVICE_TRACE` | `1` records service transport detail at trace level | unset |

An unrecognized `FORESIGHT_LOG_LEVEL` uses `info`; Settings → Diagnostics then
says that the level was invalid. An explicit `FORESIGHT_LOG_LEVEL`, including
`off`, takes precedence over `FORESIGHT_SERVICE_TRACE`. `off` records nothing
and starts no log writer.

On Linux, start Open Foresight from a terminal. The installed package's
`open-foresight` command and a portable bundle's `open-foresight` launcher both
pass the terminal's variables to the app:

```sh
FORESIGHT_LOG_LEVEL=debug open-foresight
FORESIGHT_LOG_LEVEL=debug /path/to/open-foresight-bundle/open-foresight
```

Starting the app from the application menu uses your desktop session's
environment instead.

On macOS, an app started from Finder, the Dock or Launchpad does not receive
variables set in a terminal, and this version offers no other supported way to
set them.

These settings apply to the desktop app's own session. This version does not
guarantee that a background service started by the app uses the same level.

## Retention and size

Logs have a fixed upper bound for each profile. There are ten session slots,
each holding at most three files of 2 MiB: at most 60 MiB of records plus at
most 1 MiB of bookkeeping. Three slots are reserved for the background service
and two for the desktop app; the other five are shared.

When a session needs a slot, Open Foresight picks an inactive one in this
order: an empty slot, then a session older than seven days, then a session
without errors, then a session with errors; within each group it prefers the
role's reserved slots and then the oldest session. The newest session in which
the background service genuinely failed is kept for seven days. Slots held by
running sessions are skipped. Only the record files and manifest of the chosen
slot are removed, and only while a session is being admitted, never on a timer.

Records stay in memory until there is a warning or error, 100 records, or five
seconds of running time; only then is a slot admitted and a file written. A
missing or empty logs folder soon after the first start is normal. A short
session that closes before that point writes no files.

To remove all logs, quit Open Foresight and wait until its background service
has exited, then delete the `logs` folder. The next session that writes logs
creates it again, private to your account, provided the profile folder itself
is private. Logging never deletes files outside the `logs` folder.

## Health in Settings

**Settings → Diagnostics** shows the state of the desktop app's own logging
session, as reported by that session. It is read when the page opens, after
**Show logs folder** and when you choose **Refresh**; it is not updated in the
background.

| Status | Meaning |
| --- | --- |
| Writing to a log file | Log storage is configured, nothing has failed and the session holds a log file slot. This is not a guarantee that data reached the disk. |
| Starting | Log storage is configured and nothing has failed, but no slot has been admitted yet; records are still in memory. |
| Unknown | There is no report yet, or the last report is out of date. |
| Degraded | Log files are not being written, for example because log storage is not configured, no slot is available, the file system is not used for logs, writing failed or the storage worker stopped. Open Foresight keeps working. |
| Closing | The session is shutting down. |
| Closed | The session finished closing. |
| Off | `FORESIGHT_LOG_LEVEL=off`. |
| Unavailable in this session | No logging session is connected to Settings, for example because startup did not finish. |

The section also shows how many records this session recorded, dropped (for
example under heavy load) or rejected. When the application's native library
reports its own diagnostics, a separate **Native diagnostics** line shows
whether they work, are unsupported, at capacity, failed or not settled, and
whether drop counts are exact.

**Copy health summary** copies these values as plain text, with the
application version, so you can paste them into a bug report. The summary
contains only the closed status values and counters: no paths, account details
or content. `storage_configured: true` only means a log storage backend was
set up for the session, not that your system supports it.

## Troubleshooting

- **"No log files have been written yet."** This profile has no `logs` folder.
  Logging may be `off`, the session may still be starting, or files cannot be
  written here. Check the status above.
- **"The logs folder was not shown because it is not a private folder owned by
  you."** The profile or `logs` folder is a symbolic link or has one in its
  path, is not a folder, belongs to another user, or allows access that it
  should not. Open Foresight creates `logs` privately; check the owner and
  permissions of the profile and its `logs` folder and remove any link there.
- **"Could not show the logs folder."** The file manager could not be started.
  On Linux, nothing may appear even without this message if no file manager
  provides `org.freedesktop.FileManager1`. Install or start one, or open the
  location in the table above yourself.
- **"The logs folder is unavailable in this session."** Startup did not select
  a profile for logging. Restart Open Foresight; if startup keeps failing,
  report the error shown at startup.
- To follow sessions while reproducing a problem, use ordinary console tools,
  for example on Linux:
  `tail -F ~/.local/share/open-foresight/logs/slot-*/*.jsonl`.

## Reporting a problem

Use the [bug report form](https://github.com/teng-lin/open-foresight/issues/new?template=bug_report.yml).
Attaching diagnostics is optional. Paste the health summary from Settings
and, if you choose, short excerpts of log records after reviewing them. Do not
attach the whole logs folder, and never include credentials. Report security
problems privately as described in the [security policy](../SECURITY.md).
