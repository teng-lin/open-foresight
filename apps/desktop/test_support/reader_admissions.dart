import 'package:foresight_core/remote.dart';

/// Counts typed boundary admissions. Fixture worker counts do not prove isolate placement.
final class ReaderAdmissions {
  final synchronous = <String, int>{},
      reads = <String, int>{},
      watches = <String, int>{},
      workers = <String, int>{};
  void count(Map<String, int> target, String key) =>
      target.update(key, (value) => value + 1, ifAbsent: () => 1);
  T sync<T>(String key, T Function() read) {
    count(synchronous, key);
    return read();
  }

  Map<String, Map<String, int>> snapshot() => {
    'sync': Map.of(synchronous),
    'read': Map.of(reads),
    'watch': Map.of(watches),
    'worker': Map.of(workers),
  };
}

final class CountingStoreReader implements StoreReader {
  final StoreReader delegate;
  final ReaderAdmissions admissions;
  CountingStoreReader(this.delegate, this.admissions);

  @override
  RpcError? get failure => admissions.sync('failure', () => delegate.failure);

  @override
  String get workspaceEpoch =>
      admissions.sync('workspaceEpoch', () => delegate.workspaceEpoch);

  @override
  String get dataRevision =>
      admissions.sync('dataRevision', () => delegate.dataRevision);

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    admissions.count(admissions.reads, query.projection);
    return delegate.read(query);
  }

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    admissions.count(admissions.watches, query.projection);
    return delegate.watch(query);
  }
}
