import 'dart:convert';
import 'package:clock/clock.dart';
import 'package:sqlite3/sqlite3.dart';
import '../request_errors.dart';
import '../rpc_error.dart';

class RequestKeyStore {
  final Database db;
  final Duration requestKeyLifetime;
  RequestKeyStore(this.db, {required this.requestKeyLifetime});
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => db
      .select(sql, args)
      .map((row) => Map<String, Object?>.from(row))
      .toList();

  /// Runs [write] as one transaction. With a [key], its JSON result commits in
  /// the same transaction, and a repeated key returns that result without
  /// writing again, so a retry after a lost reply applies the change once.
  /// A key is bound to its operation and to the digest of its [arguments].
  ({Object? result, bool replayed}) writeOnce(
    String? key,
    String operation,
    Object? Function() write, {
    String arguments = '',
  }) {
    db.execute('SAVEPOINT write_once');
    try {
      if (key != null) prune();
      final stored = key == null
          ? null
          : _rows(
              'SELECT operation,arguments,result FROM request_keys WHERE key=?',
              [key],
            ).firstOrNull;
      if (stored != null && stored['operation'] != operation) {
        throw RpcError(
          RpcErrorCode.invalidArgument,
          keyReusedForMessage(stored['operation'] as String),
        );
      }
      if (stored != null && stored['arguments'] != arguments) {
        throw RpcError(
          RpcErrorCode.invalidArgument,
          keyReusedWithOtherArgumentsMessage,
        );
      }
      final result = stored == null
          ? write()
          : jsonDecode(stored['result'] as String);
      if (stored == null && key != null) {
        db.execute(
          'INSERT INTO request_keys(key,operation,arguments,result,created) VALUES(?,?,?,?,?)',
          [
            key,
            operation,
            arguments,
            jsonEncode(result),
            clock.now().millisecondsSinceEpoch,
          ],
        );
      }
      db.execute('RELEASE write_once');
      return (result: result, replayed: stored != null);
    } catch (_) {
      // SQLITE_FULL/IOERR can already roll back the whole transaction; then
      // there is no savepoint left, and the original error must surface.
      if (!db.autocommit) {
        db.execute('ROLLBACK TO write_once');
        db.execute('RELEASE write_once');
      }
      rethrow;
    }
  }

  void prune() => db.execute('DELETE FROM request_keys WHERE created<?', [
    clock.now().subtract(requestKeyLifetime).millisecondsSinceEpoch,
  ]);
}
