import '../test_support/reader_admissions.dart';
import 'package:foresight_core/foresight_core.dart' show Store;
import 'package:foresight_core/remote.dart' show StoreReader;
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/sqlite_read_session.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';

final _readers = Expando<StoreReader>();
final _admissions = Expando<ReaderAdmissions>();
final _sessions = Expando<SqliteStoreReader>();
final _identities = Expando<(String, String)>();

/// Match RemoteDomain's data invalidation without turning helper/status events
/// into persistence admissions. The wrapped public reader remains countable.
void invalidateFixtureReader(Store store) {
  final reader = _sessions[store];
  if (reader == null) return;
  final identity = (reader.workspaceEpoch, reader.dataRevision);
  if (identity == _identities[store]) return;
  _identities[store] = identity;
  reader.invalidate();
}

StoreReader fixtureReader(Store store, {ReaderAdmissions? admissions}) {
  final existing = _readers[store];
  if (existing != null) {
    if (admissions != null && !identical(_admissions[store], admissions)) {
      throw StateError('Install the admissions probe before the first reader');
    }
    return existing;
  }
  if (admissions != null) _admissions[store] = admissions;
  return _readers[store] = _createReader(store, admissions);
}

StoreReader _createReader(Store store, ReaderAdmissions? admissions) {
  final reader = SqliteStoreReader.borrow(
    store,
    worker: _FixtureReadWorker(store, admissions),
  );
  _sessions[store] = reader;
  _identities[store] = (reader.workspaceEpoch, reader.dataRevision);
  return admissions == null ? reader : CountingStoreReader(reader, admissions);
}

final class _FixtureReadWorker implements ReadWorker {
  final SqliteReadSession session;
  final ReaderAdmissions? admissions;
  _FixtureReadWorker(Store store, this.admissions)
    : session = SqliteReadSession.borrow(store);
  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) async {
    final probe = admissions;
    probe?.count(probe.workers, request.projection);
    return session.query(request.projection, request.arguments);
  }

  @override
  Future<void> close() async => session.close();
}
