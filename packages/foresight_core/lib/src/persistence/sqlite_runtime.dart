import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart' as loader;
import 'package:sqlite3/sqlite3.dart' as upstream;

import '../platform_services.dart';

export 'package:sqlite3/sqlite3.dart' hide sqlite3;

/// Match the application-owned source pinned in ForesightSqlite.cmake.
const applicationSqliteVersion = '3.54.1';
const applicationSqliteSourceId =
    '2026-10-16 14:45:20 '
    '555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76';

// Each service/read isolate initializes its own package loader before opening
// any connection. Never silently fall back to Apple's different WAL behavior.
final upstream.Sqlite3 sqlite3 = _loadSqlite();

DynamicLibrary _openMacSqlite() {
  final path = runtimeConfiguration['FORESIGHT_SQLITE_LIBRARY'];
  if (path == null || !File(path).isAbsolute) {
    throw StateError(
      'The application SQLite runtime is missing. Build foresight_sqlite3 and '
      'set FORESIGHT_SQLITE_LIBRARY, or reinstall Open Foresight.',
    );
  }
  return DynamicLibrary.open(path);
}

upstream.Sqlite3 _loadSqlite() {
  if (Platform.isMacOS) {
    loader.open.overrideFor(loader.OperatingSystem.macOS, _openMacSqlite);
  }
  final api = upstream.sqlite3;
  if (Platform.isMacOS && api.version.sourceId != applicationSqliteSourceId) {
    throw StateError(
      'Incompatible application SQLite runtime: expected '
      '$applicationSqliteVersion; rebuild or reinstall Open Foresight.',
    );
  }
  return api;
}
