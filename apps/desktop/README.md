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
