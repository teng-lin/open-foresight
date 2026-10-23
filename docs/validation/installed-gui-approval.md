# Installed GUI approval acceptance

Installed package probes use the unchanged bundled desktop to review external
RPC writes. Python never reads `.desktop-capability`, attaches as the desktop,
or substitutes a test executable into a package. The helper checks the exact
owned GUI PID/image and private profile, verifies the service installation and
profile identity, completes the six ordinary onboarding actions, then clicks
one production **Allow once** button for each explicitly permitted fixture
request. Capture Start/Resume and capture approval dialogs are refused.

`tools/smoke_macos_bundle.py` retains both startup orders. MCP-first proves two
MCP clients share an owner before opening the GUI for approved graph writes.
Desktop-first starts the actual GUI before MCP. The GUI stays alive through
source revision, labels and graph writes, then closes before idle upgrade.
Persistence and restart checks remain mandatory. The standalone AOT component
test uses an explicitly allowlisted native development host and refuses bundled
service paths; it is not installed GUI evidence.

Document acceptance separately approves the public `preferences.set` command
for the disposable document directory's import-root preference, then approves
the actual file-import requests. It does not invoke host-only security RPCs or
write the database. Read-only SQLite observations acknowledge actual onboarding
writes and verify persisted content. GUI logs and per-request approval evidence
are retained outside disposable profiles.

## macOS permission prerequisite

No helper changes OS Accessibility, Automation, TCC, or host configuration.
Missing permission is a failed/unexecuted production GUI gate, never a skip or
synthetic success. Linux production GUI automation is not implemented by this
Mac helper and is reported explicitly as unsupported.

On HanSolo, a read-only controlled query against owned Release app PID 44332 on
2026-10-22 failed with exit 1:

```
System Events got an error: osascript is not allowed assistive access. (-25211)
```

The app used a fresh private profile and both app and service were stopped. A
separate harmless `UI elements enabled` query returned `false`. No grant was
made. The existing Flutter WidgetTester integration executable cannot establish
Accessibility permission or automate a separate production Release application.

To enable this exact runner, the machine owner can open **System Settings →
Privacy & Security → Accessibility**, enable the existing **osascript** entry,
or use **+** and **Command-Shift-G** to select `/usr/bin/osascript`. The observed
error identifies osascript; if macOS instead presents a responsible SSH/terminal
host identity, retain that exact label/error for review before granting it.
No Full Disk Access, developer-tool bypass or blanket permission is required by
this helper. Recheck from the same SSH runner with:

```sh
/usr/bin/osascript -e 'tell application "System Events" to return UI elements enabled'
```

A true result only establishes the prerequisite. Run the scoped package probe
again to qualify actual production onboarding, per-request consent and cleanup.
The prior failed evidence must remain alongside the new run.
