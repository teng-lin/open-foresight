import 'dart:ffi';

import '../rpc_error.dart';
import 'sqlite_runtime.dart';

typedef _Progress = Int Function(Pointer<Void>);
typedef _InstallNative =
    Void Function(
      Pointer<Void>,
      Int,
      Pointer<NativeFunction<_Progress>>,
      Pointer<Void>,
    );
typedef _Install =
    void Function(
      Pointer<Void>,
      int,
      Pointer<NativeFunction<_Progress>>,
      Pointer<Void>,
    );

/// Synchronous, owner-isolate control for one connection and one read job.
/// SQLite calls back on its invoking thread; package:sqlite3's step/prepare
/// calls are non-leaf. No timer or borrowed connection pointer is involved.
final class SqliteStatementBudget {
  final Database _database;
  final _Install _install;
  bool _running = false;

  SqliteStatementBudget(this._database)
    : _install = applicationSqliteLibrary
          .lookupFunction<_InstallNative, _Install>('sqlite3_progress_handler');

  T run<T>(Duration limit, T Function() read) {
    if (limit <= Duration.zero) throw ArgumentError.value(limit, 'limit');
    if (_running) throw StateError('Nested SQLite statement budget');
    final watch = Stopwatch()..start();
    var expired = false;
    final callback = NativeCallable<_Progress>.isolateLocal((Pointer<Void> _) {
      if (watch.elapsed >= limit) expired = true;
      return expired ? 1 : 0;
    }, exceptionalReturn: 1);
    _running = true;
    try {
      _install(
        _database.handle.cast<Void>(),
        1000,
        callback.nativeFunction,
        nullptr,
      );
      try {
        final result = read();
        if (result is Future) {
          throw ArgumentError('A statement budget must finish synchronously');
        }
        return result;
      } on SqliteException {
        if (expired) {
          throw RpcError(RpcErrorCode.busy, 'Read execution budget exhausted');
        }
        rethrow;
      }
    } finally {
      // Remove before closing the callback and before the snapshot owner rolls
      // back. A late interrupt can never affect a replacement job/connection.
      _install(_database.handle.cast<Void>(), 0, nullptr, nullptr);
      callback.close();
      watch.stop();
      _running = false;
    }
  }
}
