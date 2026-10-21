import 'package:foresight_core/foresight_core.dart' show Store;
import 'package:foresight_core/remote.dart' show StoreReader;
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/sqlite_read_session.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';

final _readers = Expando<SqliteStoreReader>();
StoreReader fixtureReader(Store store) => _readers[store] ??=
    SqliteStoreReader.borrow(store, worker: _FixtureReadWorker(store));

final class _FixtureReadWorker implements ReadWorker {
  final SqliteReadSession session;
  _FixtureReadWorker(Store store) : session = SqliteReadSession.borrow(store);
  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) async =>
      session.query(request.projection, request.arguments);
  @override
  Future<void> close() async => session.close();
}
