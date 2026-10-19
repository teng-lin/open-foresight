# Desktop application

Flutter desktop application; the current platform runner is Linux. See the root README for build prerequisites and model setup.

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build linux --release
```

The packaged launcher configures `FORESIGHT_HELPER` and `FORESIGHT_NATIVE`. Application data and runtime locations can be overridden with `FORESIGHT_DATA` and `FORESIGHT_RUNTIME`. Keep user profiles and downloaded models outside version control.

Source imports, notes, meetings and answers persist in SQLite. Final transcript segments are retained separately from generated meeting artifacts. Local Gemma answers use evidence selection, synthesis and source checks; failed verification produces an explicitly labelled source fallback. Original notes and raw transcripts are not replaced by generated text.

First launch opens setup before the workspace: welcome, Gemma and embedding
models, a transcription model, audio/notifications, optional Google sign-in,
and document import. The model pages share the Settings installers and reuse
verified local downloads. Each step is saved in the profile; completion is saved
only after **Get started** succeeds. Models, permissions, and sign-in can be
skipped and configured in Settings later.

Documents imported before the indexing model is configured remain saved and
waiting for model setup. Installing that model indexes the saved queue without
a restart; earlier missing-pipeline failures are retried without replacing
document contents or revisions. Onboarding shows setup/retry guidance rather
than raw transport diagnostics.

On macOS, microphone and system-audio requests require explicit clicks.
The system-audio action immediately starts the Core Audio consent request;
macOS presents consent and adds the responsible app to System Audio Recording Only.
The macOS runner registers its application bundle with Launch Services before
starting Flutter so Privacy & Security can resolve and display its audio-only
entry, including for development builds. The Settings button opens the
System Audio Recording Only destination. If Settings was already open while an
unregistered development build requested access, reopen Settings to refresh its
application lookup. Installing the application in Applications also ensures
normal macOS application discovery.

Pending audio requests are refreshed until they finish, and returning from
System Settings refreshes capabilities without starting another request. Choosing
Done saves the setup review through the service and shows Setup complete with a
checkmark on subsequent launches. The row remains available to review again;
reported access failures take precedence over that saved review.
A completed system-audio request does not prove permission; actual capture checks
access. The Linux PipeWire build explains device access without requesting
macOS permissions. Google sign-in uses the bundled, verified distribution configuration and opens
the default browser. Successful consent brings the app back to the foreground;
users never import an OAuth JSON file. Calendar sync supplies meeting schedules,
reminders, and attachment links; events are not knowledge sources and do not need
an embedding model. Drive imports are chosen explicitly.
The Drive picker marks files with download restrictions as unavailable. Multi-file
imports retain successful documents and report failed filenames with the imported count.

The macOS menu bar shows the Open Foresight icon with transcript, Meetings,
Ask, Knowledge Sources, Settings, and Quit actions. Menu actions bring the window
forward and use the same recording consent and onboarding gates as the workspace;
they do not require enabling global shortcuts.

Closing the last macOS window quits the desktop, including its menu bar item.
After a one-second reconnect
grace period, loss of its authenticated connection closes the application
service, finalizes any recording, and releases helpers and model workers.
Headless services launched solely by MCP retain their independent lifetime.
Startup repairs legacy, user-owned profile directories from read/traverse-only
public permissions (for example 0755) to 0700 without modifying their contents.
Symlinks, foreign ownership, and group/world-writable directories remain rejected.
