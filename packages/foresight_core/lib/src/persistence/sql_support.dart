import 'dart:ffi';
import 'dart:io';

import '../rpc_error.dart';

typedef SqliteProgressCheck = Int Function(Pointer<Void>);
typedef SqliteProgressInstall =
    Void Function(
      Pointer<Void>,
      Int,
      Pointer<NativeFunction<SqliteProgressCheck>>,
      Pointer<Void>,
    );
typedef _ReadyNative = Int Function();
typedef _BeginNative =
    Int64 Function(
      Pointer<Void>,
      Pointer<NativeFunction<SqliteProgressInstall>>,
      Int64,
    );
typedef _Begin =
    int Function(
      Pointer<Void>,
      Pointer<NativeFunction<SqliteProgressInstall>>,
      int,
    );
typedef _EndNative = Int Function(Int64);
typedef _End = int Function(int);

final class _SqlApi extends Struct {
  @Uint32()
  external int abi;
  @Uint32()
  external int size;
  @Uint32()
  external int capacity;
  @Uint32()
  external int interval;
  external Pointer<NativeFunction<_ReadyNative>> ready;
  external Pointer<NativeFunction<_BeginNative>> begin;
  external Pointer<NativeFunction<_EndNative>> end;
}

SqlSupportBootstrap? _bootstrap;
SqlSupportBinding? _binding;
bool _openedConnection = false;
String? _selectedLibrary;

/// A private startup handoff of original, validated, process-pinned code only.
/// No SQLite database or native context pointer crosses an isolate boundary.
/// Instances originate only from the trusted early mapping owner below.
final class SqlSupportBootstrap {
  final int _ready, _begin, _end;
  const SqlSupportBootstrap._(this._ready, this._begin, this._end);

  bool _same(SqlSupportBootstrap other) =>
      _ready == other._ready && _begin == other._begin && _end == other._end;
}

/// Explicit embedding startup, using the artifact path already selected and
/// validated by its owner. No environment selector, basename or fallback search.
/// Call before ANY application database/worker, not from an individual read.
void initializeSelectedSqlSupport(String selectedLibrary) {
  if (_bootstrap != null) {
    if (_selectedLibrary != selectedLibrary) {
      throw StateError('Cannot replace the original SQL support selection');
    }
    currentSqlSupport.ensureAvailable();
    return;
  }
  if (_openedConnection) {
    throw StateError('SQL support must be initialized before database access');
  }
  if (!File(selectedLibrary).isAbsolute) {
    throw ArgumentError.value(
      selectedLibrary,
      'selectedLibrary',
      'Use the validated absolute runtime artifact',
    );
  }
  final original = DynamicLibrary.open(selectedLibrary);
  initializeSqlSupportEarly(original);
  _selectedLibrary = selectedLibrary;
}

/// Loader-owner gate, before ANY application DB opens or worker is created.
/// The caller supplies its original trusted mapping; this does not select a
/// pathname, consult an environment override, or load the heavyweight library.
/// Entry-point/package ownership must establish that mapping before calling.
SqlSupportBootstrap initializeSqlSupportEarly(DynamicLibrary ownedImage) {
  if (_openedConnection) {
    throw StateError('SQL support must be initialized before database access');
  }
  final initialize = ownedImage
      .lookupFunction<
        Pointer<_SqlApi> Function(Uint32),
        Pointer<_SqlApi> Function(int)
      >('fs_sql_support_early_init');
  final table = initialize(1);
  if (table == nullptr) throw StateError('SQL support early gate failed');
  final api = table.ref;
  if (api.abi != 1 ||
      api.size != sizeOf<_SqlApi>() ||
      api.capacity != 64 ||
      api.interval != 1000 ||
      api.ready == nullptr ||
      api.begin == nullptr ||
      api.end == nullptr) {
    throw StateError('Incompatible SQL support ABI');
  }
  // The native early gate verifies every table entry against the pinned image.
  // It is never included in a worker bootstrap and never called from a read.
  final bootstrap = SqlSupportBootstrap._(
    api.ready.address,
    api.begin.address,
    api.end.address,
  );
  bindSqlSupportBootstrap(bootstrap);
  return bootstrap;
}

/// Bind only already validated original code. There is no loader operation in
/// this worker path: ready() is a pure native atomic read.
void bindSqlSupportBootstrap(SqlSupportBootstrap bootstrap) {
  final existing = _bootstrap;
  if (existing != null) {
    if (!existing._same(bootstrap)) {
      throw StateError('Cannot replace the original SQL support mapping');
    }
    return;
  }
  final binding = SqlSupportBinding._(bootstrap);
  if (binding._ready() != 1) throw StateError('SQL support is not ready');
  _binding = binding;
  _bootstrap = bootstrap;
}

SqlSupportBootstrap get currentSqlSupportBootstrap =>
    _bootstrap ?? (throw StateError('SQL support early gate was missed'));

SqlSupportBinding get currentSqlSupport =>
    _binding ?? (throw StateError('SQL support early gate was missed'));

/// Called before the application opens a connection. A missing handoff fails
/// before SQLite or a database path is touched, never by lazy native loading.
void requireSqlSupportBeforeConnection() {
  currentSqlSupport.ensureAvailable();
  _openedConnection = true;
}

final class SqlSupportBinding {
  final int Function() _ready;
  final _Begin _begin;
  final _End _end;
  bool _unconfirmed = false;

  SqlSupportBinding._(SqlSupportBootstrap bootstrap)
    : _ready = Pointer<NativeFunction<_ReadyNative>>.fromAddress(
        bootstrap._ready,
      ).asFunction<int Function()>(),
      _begin = Pointer<NativeFunction<_BeginNative>>.fromAddress(
        bootstrap._begin,
      ).asFunction<_Begin>(),
      _end = Pointer<NativeFunction<_EndNative>>.fromAddress(
        bootstrap._end,
      ).asFunction<_End>();

  void ensureAvailable() {
    if (_unconfirmed || _ready() != 1) {
      throw RpcError(
        RpcErrorCode.unavailable,
        'SQL ownership is unconfirmed; restart the service',
      );
    }
  }

  int begin(
    Pointer<Void> database,
    Pointer<NativeFunction<SqliteProgressInstall>> install,
    Duration budget,
  ) {
    ensureAvailable();
    final lease = _begin(database, install, budget.inMicroseconds * 1000);
    if (lease > 0) return lease;
    if (lease == -4) {
      throw RpcError(RpcErrorCode.busy, 'SQL deadline capacity is full');
    }
    if (lease == -2) throw ArgumentError('Invalid SQL deadline arguments');
    if (lease != -1 && lease != -3 && lease != -5) _unconfirmed = true;
    throw RpcError(
      RpcErrorCode.unavailable,
      lease == -3
          ? 'SQL monotonic deadline is unavailable'
          : 'SQL deadline admission failed; restart the service',
    );
  }

  /// This must run only after the actual synchronous statement returned.
  /// A subscriber timeout or cancel is never permission to unregister.
  bool end(int lease) {
    final result = _end(lease);
    if (result == 0 || result == 1) return result == 1;
    _unconfirmed = true;
    throw RpcError(
      RpcErrorCode.unavailable,
      'SQL deadline retirement is unconfirmed; restart the service',
    );
  }
}
