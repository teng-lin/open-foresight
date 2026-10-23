import 'read_coordinator.dart';
import 'rpc_error.dart';

/// Read capabilities supplied by the connection; it owns disposal and paths.
///
/// Durable projections are asynchronous and selected through StoreReadQueries.
/// Feature views consume owned prepared state; only identity metadata is sync.
abstract interface class StoreReader {
  /// Terminal incompatibility retires all prepared rows until reconnect/update.
  RpcError? get failure;
  String get workspaceEpoch;
  String get dataRevision;
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query);
  Future<ReadResult<T>> read<T>(ReadQuery<T> query);
}
