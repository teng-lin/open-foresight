import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart' as loader;
import 'package:sqlite3/sqlite3.dart' as upstream;

import '../platform_services.dart';
import 'sql_support.dart';

export 'package:sqlite3/sqlite3.dart' hide sqlite3;

/// Match the application-owned source pinned in ForesightSqlite.cmake.
const applicationSqliteVersion = '3.54.1';
const applicationSqliteSourceId =
    '2026-10-16 14:45:20 '
    '555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76';

// Each service/read isolate initializes its own package loader before opening
// any connection. Never silently fall back to Apple's different WAL behavior.
final upstream.Sqlite3 sqlite3 = _loadSqlite();

DynamicLibrary? _sqliteLibrary;
Pointer<NativeFunction<SqliteProgressInstall>>? _progressInstaller;

/// Resolved from the original package mapping before a database can open.
/// Budget construction/read transactions perform no dlsym or loader operation.
Pointer<NativeFunction<SqliteProgressInstall>>
get applicationSqliteProgressInstaller {
  sqlite3;
  return _progressInstaller ??
      (throw StateError(
        'SQLite was initialized outside the application loader',
      ));
}

/// Only for owner-isolate connection controls; no handle leaves that isolate.
DynamicLibrary get applicationSqliteLibrary {
  sqlite3; // Initialize and retain the same mapping used by package:sqlite3.
  return _sqliteLibrary ??
      (throw StateError(
        'SQLite was initialized outside the application loader',
      ));
}

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

DynamicLibrary _openLinuxBundleSqlite(String root) {
  final file = File('$root/lib/libsqlite3.so');
  final String path;
  try {
    path = file.resolveSymbolicLinksSync();
  } on FileSystemException {
    throw StateError(
      'The packaged SQLite runtime is missing. Reinstall Open Foresight.',
    );
  }
  if (!path.startsWith('$root/')) {
    throw StateError(
      'The packaged SQLite runtime leaves this installation. Reinstall Open Foresight.',
    );
  }
  return DynamicLibrary.open(path);
}

upstream.Sqlite3 _loadSqlite() {
  requireSqlSupportBeforeConnection();
  if (Platform.isMacOS) {
    loader.open.overrideFor(loader.OperatingSystem.macOS, _openMacSqlite);
  } else if (Platform.isLinux) {
    final root = runtimeConfiguration.linuxBundleRoot;
    if (root != null) {
      loader.open.overrideFor(
        loader.OperatingSystem.linux,
        () => _openLinuxBundleSqlite(root),
      );
    }
  }
  // Retain the original mapping for connection-local FFI such as progress
  // handlers. The package loader receives these exact bytes, never a later
  // path reopen after a bundle or symlink might have changed.
  final library = loader.open.openSqlite();
  loader.open.overrideForAll(() {
    _sqliteLibrary = library;
    _progressInstaller = library.lookup<NativeFunction<SqliteProgressInstall>>(
      'sqlite3_progress_handler',
    );
    return library;
  });
  final api = upstream.sqlite3;
  if (Platform.isMacOS && api.version.sourceId != applicationSqliteSourceId) {
    throw StateError(
      'Incompatible application SQLite runtime: expected '
      '$applicationSqliteVersion; rebuild or reinstall Open Foresight.',
    );
  }
  return api;
}

/// A short lock wait applies equally to writable and read-only connections.
/// The application owns retries; a busy database must not stall capture behind
/// SQLite's default or an unbounded retry loop.
const applicationSqliteBusyTimeout = Duration(milliseconds: 50);
upstream.Database openApplicationDatabase(
  String path, {
  upstream.OpenMode mode = upstream.OpenMode.readWriteCreate,
}) {
  requireSqlSupportBeforeConnection();
  // Enable URI selection for controlled ATTACH/VACUUM destinations. The main
  // filename is always an absolute filesystem path (or :memory:), so an input
  // beginning with file: cannot bypass profile/path qualification.
  final filename = path == ':memory:' ? path : File(path).absolute.path;
  final db = sqlite3.open(filename, mode: mode, uri: true);
  try {
    db.execute(
      'PRAGMA busy_timeout=${applicationSqliteBusyTimeout.inMilliseconds}',
    );
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}
