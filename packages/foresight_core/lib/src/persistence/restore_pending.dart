import 'dart:io';

/// Names an offline restore activation keeps beside a profile database while
/// it runs and after it was interrupted: the staged database and its durable
/// marker. Dependency-free, so Store can check them before opening SQLite.
RegExp restoringDatabase(String base) =>
    RegExp('^${RegExp.escape(base)}\\.restoring-[a-f0-9]{32}\$');
RegExp restoringMarker(String base) =>
    RegExp('^${RegExp.escape(base)}\\.restoring-[a-f0-9]{32}\\.json\$');
RegExp restoringPartialMarker(String base) => RegExp(
  '^${RegExp.escape(base)}\\.restoring-[a-f0-9]{32}\\.json\\.partial\$',
);

/// A restore of this profile database is running or was interrupted. Its
/// staged file may be the previous profile, which managed backup erasure does
/// not cover until recovery retains it.
class PendingProfileRestore extends StateError {
  PendingProfileRestore(String directory, List<String> entries)
    : super(
        'An offline restore of this profile is running or was interrupted: '
        '$directory holds ${entries.join(', ')}, which may be the previous '
        'profile. Stop Open Foresight and run foresight-service '
        '--restore-recover; '
        'nothing was opened or removed.',
      );
}

/// Returns [databasePath] unless a restore of it is pending. Reads directory
/// names only; never opens, follows or removes an entry.
String requireNoPendingRestore(String databasePath) {
  if (databasePath == ':memory:') return databasePath;
  final file = File(databasePath).absolute;
  final base = file.uri.pathSegments.last;
  if (!file.parent.existsSync()) return databasePath;
  final staged = restoringDatabase(base), marker = restoringMarker(base);
  final pending = [
    for (final entry in file.parent.listSync(followLinks: false))
      if (staged.hasMatch(entry.uri.pathSegments.last) ||
          marker.hasMatch(entry.uri.pathSegments.last))
        entry.uri.pathSegments.last,
  ]..sort();
  if (pending.isNotEmpty) {
    throw PendingProfileRestore(file.parent.path, pending);
  }
  return databasePath;
}
