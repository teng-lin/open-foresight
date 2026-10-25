import 'dart:ffi';

import '../rpc_error.dart';
import 'sql_support.dart';
import 'sqlite_runtime.dart';

/// One synchronous read on its owner connection. The C monotonic progress
/// callback never enters Dart and remains valid if the entire VM disappears.
/// Normal cleanup unregisters only after the actual statement has returned.
final class SqliteStatementBudget {
  final Database _database;
  final SqlSupportBinding _support;
  final Pointer<NativeFunction<SqliteProgressInstall>> _install;
  bool _running = false;

  SqliteStatementBudget(this._database)
    : _support = currentSqlSupport,
      _install = applicationSqliteProgressInstaller;

  T run<T>(Duration limit, T Function() read) {
    if (limit <= Duration.zero || limit > const Duration(seconds: 30)) {
      throw ArgumentError.value(limit, 'limit');
    }
    if (_running) throw StateError('Nested SQLite statement budget');
    final lease = _support.begin(
      _database.handle.cast<Void>(),
      _install,
      limit,
    );
    _running = true;
    Object? failure;
    StackTrace? failureStack;
    T? result;
    bool expired;
    try {
      try {
        result = read();
        if (result is Future) {
          throw ArgumentError('A statement budget must finish synchronously');
        }
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }
    } finally {
      // A lost VM may never reach here. Its static C slot/code remain retained
      // until process death, rather than being freed while SQL can still run.
      try {
        expired = _support.end(lease);
      } finally {
        _running = false;
      }
    }
    if (failure != null) {
      if (failure is SqliteException && expired) {
        throw RpcError(RpcErrorCode.busy, 'Read execution budget exhausted');
      }
      Error.throwWithStackTrace(failure, failureStack!);
    }
    return result as T;
  }
}
