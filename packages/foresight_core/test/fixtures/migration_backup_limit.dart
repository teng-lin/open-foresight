// A real per-process filesystem size limit makes VACUUM INTO fail midway,
// without exhausting the host filesystem or touching any unrelated cache.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';

void main(List<String> arguments) {
  final libc = DynamicLibrary.process();
  final limit = calloc<Uint64>(2);
  try {
    limit[0] = 8192;
    limit[1] = 8192;
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
    Store(arguments.single).close();
    stderr.writeln('Migration unexpectedly passed its file-size limit');
    exitCode = 1;
  } on SqliteException catch (error) {
    if (error.resultCode == 10 || error.resultCode == 13) {
      stdout.writeln('migration_refused');
    } else {
      stderr.writeln('Unexpected SQLite fixture result ${error.resultCode}');
      exitCode = 1;
    }
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}
