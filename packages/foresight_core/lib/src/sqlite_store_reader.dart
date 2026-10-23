import 'dart:async';

import 'read_coordinator.dart';
import 'rpc_error.dart';
import 'sqlite_read_session.dart';
import 'sqlite_read_worker.dart';
import 'store.dart';
import 'store_reader.dart';

int _readerOwner = 0;

/// Core implementation. Connection lifecycle owns it; widgets see StoreReader.
final class SqliteStoreReader implements StoreReader {
  final SqliteReadSession _session;
  final String _owner = 'reader:${++_readerOwner}';
  final String _profile;
  String _connection;
  late final ReadCoordinator _coordinator;
  Future<void>? _closing;

  factory SqliteStoreReader.open(
    String path, {
    required String profile,
    required String connection,
  }) {
    // Resolve the environment before allocating the authoritative connection.
    final worker = SqliteReadWorker(path);
    return SqliteStoreReader._(
      SqliteReadSession.open(path),
      worker,
      profile,
      connection,
    );
  }

  /// Service reads use the writer connection's revision token, while SQL
  /// projections run on the same core-owned read worker as desktop reads.
  /// Closing this reader never closes the service's writer connection.
  factory SqliteStoreReader.service(
    Store writer, {
    required String profile,
    required String connection,
  }) => SqliteStoreReader.borrow(
    writer,
    worker: SqliteReadWorker(writer.path),
    profile: profile,
    connection: connection,
  );

  /// Internal tests can hold actual SQLite snapshots without an isolate gate.
  SqliteStoreReader.borrow(
    Store store, {
    required ReadWorker worker,
    String profile = 'fixture-profile',
    String connection = 'fixture-connection',
  }) : this._(SqliteReadSession.borrow(store), worker, profile, connection);

  SqliteStoreReader._(
    this._session,
    ReadWorker worker,
    this._profile,
    this._connection,
  ) {
    _coordinator = ReadCoordinator(
      identity: _identity,
      worker: worker,
      onClosed: _session.close,
    );
    _session.onIncompatible = (error) => unawaited(_coordinator.retire(error));
  }

  ReadIdentity _identity() => _session.identity(
    owner: _owner,
    profile: _profile,
    connection: _connection,
  );

  @override
  RpcError? get failure => _coordinator.failure;
  @override
  String get workspaceEpoch => _identity().epoch;
  @override
  String get dataRevision => _identity().revision;
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) =>
      _coordinator.watch(query);
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) => _coordinator.read(query);

  void invalidate() => _coordinator.invalidate();
  void validateSchema() => _identity();
  void retarget(String connection) {
    _connection = connection;
    invalidate();
  }

  bool get busy => _coordinator.busy;
  Stream<void> get activityChanges => _coordinator.activityChanges;

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await _coordinator.close();
    _session.close();
  }
}
