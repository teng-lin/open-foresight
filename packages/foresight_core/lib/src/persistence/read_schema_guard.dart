import 'package:sqlite3/sqlite3.dart';

import '../rpc_error.dart';

/// A live reader cannot continue against a schema from a newer application.
final class IncompatibleReadSchema implements Exception {
  final int version, supportedVersion;
  const IncompatibleReadSchema(this.version, this.supportedVersion);

  RpcError get rpcError => RpcError(
    RpcErrorCode.unavailable,
    'This workspace uses database schema $version; this application supports '
    'up to $supportedVersion. Update Open Foresight and reconnect.',
  );

  @override
  String toString() => rpcError.message;
}

/// Check version and dependent rows in one short snapshot, without migrations.
///
/// Existing transactions retain their owner and snapshot. This synchronous
/// callback must not return a Future or hold a transaction across an await.
/// Connection-local invalidation tokens are sampled outside this function.
T readSnapshot<T>(
  Database db,
  T Function() read, {
  required int supportedVersion,
}) {
  final ownTransaction = db.autocommit;
  if (ownTransaction) db.execute('BEGIN');
  try {
    final version =
        db.select('PRAGMA user_version').single.values.single as int;
    if (version > supportedVersion) {
      throw IncompatibleReadSchema(version, supportedVersion);
    }
    final result = read();
    if (result is Future) {
      throw ArgumentError('A read snapshot must finish synchronously');
    }
    if (ownTransaction) db.execute('COMMIT');
    return result;
  } catch (_) {
    if (ownTransaction && !db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
}
