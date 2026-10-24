// A real per-process filesystem size limit makes VACUUM INTO fail midway,
// without exhausting the host filesystem or touching any unrelated cache.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/persistence/migration_backups.dart';
import 'package:foresight_core/src/persistence/sqlite_preflight.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';

void main(List<String> arguments) {
  final storeVacuum = arguments.length > 1 && arguments[1] == 'store-vacuum';
  final storeLevel =
      storeVacuum || (arguments.length > 1 && arguments[1] == 'store');
  Database? source;
  int? schema;
  if (!storeLevel) {
    // Qualify and initialize WAL before imposing the payload fault. WAL's fixed
    //32KiB index and preflight's full private copy also exceed8KiB: letting either
    // fail first would no longer test the actual VACUUM boundary. Hold the same
    // exclusive/autocommit ownership used by Store throughout backup creation.
    SqlitePreflight(
      arguments.first,
      supportedVersion: Store.schemaVersion,
    ).qualify();
    source = openApplicationDatabase(arguments.first);
    schema = source.select('PRAGMA user_version').single.values.single as int;
    source.execute('PRAGMA journal_mode=WAL');
    source.select('SELECT COUNT(*) FROM sqlite_master');
    source.execute('PRAGMA locking_mode=EXCLUSIVE');
    source.execute('BEGIN EXCLUSIVE');
    source.execute('COMMIT');
  }
  final libc = DynamicLibrary.process();
  final limit = calloc<Uint64>(2);
  try {
    final fileLimit = storeVacuum ? 128 * 1024 : 8192;
    limit[0] = fileLimit;
    limit[1] = fileLimit;
    final setLimit = libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Uint64>),
          int Function(int, Pointer<Uint64>)
        >('setrlimit');
    final signal = libc
        .lookupFunction<
          Pointer<Void> Function(Int32, Pointer<Void>),
          Pointer<Void> Function(int, Pointer<Void>)
        >('signal');
    signal(
      25,
      Pointer<Void>.fromAddress(1),
    ); // SIGXFSZ / SIG_IGN, Linux + Darwin.
    if (setLimit(1, limit) != 0) {
      throw StateError('Cannot set fixture file-size limit');
    }
  } finally {
    calloc.free(limit);
  }
  try {
    if (storeLevel) {
      Store(arguments.first).close();
    } else {
      MigrationBackups(arguments.first).create(source!, schema!);
    }
    stderr.writeln('Migration unexpectedly passed its file-size limit');
    exitCode = 1;
  } on SqliteException catch (error) {
    if (error.resultCode == 10 || error.resultCode == 13) {
      if (storeVacuum) {
        if (error.causingStatement != 'VACUUM INTO ?' ||
            !Directory('${arguments.first}.backups').existsSync()) {
          stderr.writeln(
            'Store failed before the intended VACUUM boundary: $error',
          );
          exitCode = 1;
          return;
        }
        stdout.writeln(
          'store_vacuum_refused sqlite_code=${error.resultCode} limit=131072 statement=VACUUM_INTO',
        );
      }
      stdout.writeln(
        storeLevel ? 'store_startup_refused' : 'migration_refused',
      );
    } else {
      stderr.writeln('Unexpected SQLite fixture result ${error.resultCode}');
      exitCode = 1;
    }
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  } finally {
    source?.dispose();
  }
}
