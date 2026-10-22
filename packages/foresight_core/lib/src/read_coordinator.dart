import 'dart:async';
import 'dart:convert';

import 'desktop_read_models.dart';
import 'persistence/read_schema_guard.dart';
import 'rpc_error.dart';

/// [revision] is meaningful only on the long-lived connection named by owner.
final class ReadIdentity {
  final String owner, profile, connection, epoch, revision;
  const ReadIdentity({
    required this.owner,
    required this.profile,
    required this.connection,
    required this.epoch,
    required this.revision,
  });

  bool sameOwner(ReadIdentity other) =>
      owner == other.owner &&
      profile == other.profile &&
      connection == other.connection &&
      epoch == other.epoch;
}

/// Serializable query description; only the coordinator invokes [decode].
///
/// Neither SQL nor a Store/SQLite handle can be supplied through this contract.
final class ReadQuery<T> {
  final String projection, scope;
  final Map<String, Object?> arguments;
  final T Function(Object?) decode;
  final Map<String, Object?> Function()? _dispatchArguments;
  ReadQuery({
    required this.projection,
    required this.decode,
    Map<String, Object?> arguments = const {},
    this.scope = '',
    Map<String, Object?> Function()? dispatchArguments,
  }) : arguments = immutableReadMap(arguments),
       _dispatchArguments = dispatchArguments;

  /// Sample only when the coordinator actually starts work, never on invalidation.
  /// The key always uses [arguments]; factory results are deeply frozen.
  Map<String, Object?> argumentsForDispatch() => _dispatchArguments == null
      ? arguments
      : immutableReadMap(_dispatchArguments());

  String get key => jsonEncode([projection, scope, _ordered(arguments)]);
}

Object? _ordered(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList();
  return value;
}

final class ReadWorkerRequest {
  final String projection;
  final Map<String, Object?> arguments;
  final ReadIdentity identity;
  final int sequence;
  const ReadWorkerRequest({
    required this.projection,
    required this.arguments,
    required this.identity,
    required this.sequence,
  });
}

/// [epoch] was read in the same transaction as the entire [value] projection.
final class ReadWorkerReply {
  final String epoch;
  final Object? value;
  const ReadWorkerReply(this.epoch, this.value);
}

abstract interface class ReadWorker {
  Future<ReadWorkerReply> read(ReadWorkerRequest request);
  Future<void> close();
}

enum ReadFreshness { current, preview, busy, failed, cancelled }

final class ReadResult<T> {
  final ReadFreshness freshness;
  final T? value;
  final RpcError? error;
  final String requestTag;
  final int sequence;
  const ReadResult({
    required this.freshness,
    required this.value,
    required this.requestTag,
    required this.sequence,
    this.error,
  });

  bool get current => freshness == ReadFreshness.current;
  bool get retryable => freshness == ReadFreshness.busy;

  ReadResult<R> asType<R>() => ReadResult<R>(
    freshness: freshness,
    value: value as R?,
    requestTag: requestTag,
    sequence: sequence,
    error: error,
  );
}

typedef ReadTimerFactory = Timer Function(Duration, void Function());

/// Serializes each stable query key, without starving it on ordinary commits.
///
/// Cancellation/deadlines settle subscribers promptly; underlying SQLite work
/// remains tracked until its actual future settles. The owner closes the worker
/// after [close] joins those futures, never by assuming a timeout stopped SQL.
final class ReadCoordinator {
  final ReadIdentity Function() identity;
  final ReadWorker _worker;
  final ReadTimerFactory _timer;
  final Duration deadline;
  final void Function()? onClosed;
  final _entries = <String, _ReadEntry>{};
  final _active = <Future<void>>{};
  final _activity = StreamController<void>.broadcast(sync: true);
  var _disposed = false, _sequence = 0;
  Future<void>? _closing;
  IncompatibleReadSchema? _incompatibility;

  ReadCoordinator({
    required this.identity,
    required ReadWorker worker,
    this.deadline = const Duration(seconds: 30),
    this.onClosed,
    ReadTimerFactory? createTimer,
  }) : _worker = worker,
       _timer = createTimer ?? Timer.new;

  int get activeReads => _active.length;
  int get trackedQueries => _entries.length;
  int get pendingRefreshes => _entries.values.where((e) => e.pending).length;
  bool get busy => _active.isNotEmpty;
  RpcError? get failure => _incompatibility?.rpcError;
  Stream<void> get activityChanges => _activity.stream;

  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    if (_disposed) {
      return Stream.value(
        ReadResult<T>(
          freshness: _incompatibility == null
              ? ReadFreshness.cancelled
              : ReadFreshness.failed,
          value: null,
          requestTag: '',
          sequence: 0,
          error:
              _incompatibility?.rpcError ??
              RpcError(RpcErrorCode.cancelled, 'Reader closed'),
        ),
      );
    }
    final entry = _entries.putIfAbsent(query.key, () {
      late _ReadEntry created;
      created = _ReadEntry(
        query,
        onListen: () {
          created.pending = true;
          scheduleMicrotask(() => _pump(created));
        },
        onCancel: () {
          // Leaving and revisiting the same query is a new request identity.
          created.generation++;
          created.pending = false;
          scheduleMicrotask(() => _releaseUnused(created));
        },
      );
      return created;
    });
    return entry.events.stream.map((event) => event.asType<T>());
  }

  Future<ReadResult<T>> read<T>(ReadQuery<T> query) => watch(query).first;

  /// Ordinary data changes request one refresh, without retiring active reads.
  void invalidate() {
    if (_disposed) return;
    for (final entry in _entries.values) {
      if (!entry.events.hasListener) continue;
      entry.pending = true;
      _pump(entry);
    }
  }

  void _pump(_ReadEntry entry) {
    if (_disposed ||
        entry.active ||
        !entry.pending ||
        !entry.events.hasListener) {
      return;
    }
    entry.pending = false;
    entry.active = true;
    final sequence = ++_sequence, generation = entry.generation;
    late Future<void> task;
    task = _execute(entry, sequence, generation).whenComplete(() {
      entry.active = false;
      _active.remove(task);
      if (!_activity.isClosed) _activity.add(null);
      if (!_disposed && entry.pending) scheduleMicrotask(() => _pump(entry));
      _releaseUnused(entry);
    });
    _active.add(task);
    _activity.add(null);
  }

  void _releaseUnused(_ReadEntry entry) {
    if (_disposed ||
        entry.active ||
        entry.events.hasListener ||
        !identical(_entries[entry.query.key], entry)) {
      return;
    }
    _entries.remove(entry.query.key);
    entry.lastValue = null;
    entry.lastIdentity = null;
    unawaited(entry.events.close());
  }

  Future<void> _execute(_ReadEntry entry, int sequence, int generation) async {
    ReadIdentity? before;
    Timer? timer;
    var expired = false;
    bool listening() =>
        !_disposed &&
        entry.events.hasListener &&
        entry.generation == generation;
    void publish(ReadFreshness freshness, {Object? value, RpcError? error}) {
      if (!listening()) return;
      final retained = entry.lastIdentity;
      if (retained != null) {
        var keep = false;
        try {
          keep = retained.sameOwner(identity());
        } on IncompatibleReadSchema catch (error) {
          unawaited(retire(error));
          return;
        } catch (_) {
          // An unreadable/closed owner cannot certify the retained workspace.
        }
        if (!keep) {
          entry.lastIdentity = null;
          entry.lastValue = null;
          // A second ownership check can race an external commit or schema
          // change. Never publish a newly decoded value for a retired owner.
          if (value != null) {
            entry.pending = true;
            return;
          }
        }
      }
      if (!listening()) return;
      entry.events.add(
        ReadResult<Object?>(
          freshness: freshness,
          value: value ?? entry.lastValue,
          error: error,
          requestTag: before?.revision ?? '',
          sequence: sequence,
        ),
      );
    }

    try {
      before = identity();
      if (entry.lastIdentity != null &&
          !entry.lastIdentity!.sameOwner(before)) {
        entry.lastIdentity = null;
        entry.lastValue = null;
      }
      timer = _timer(deadline, () {
        expired = true;
        if (listening()) {
          entry.pending = true;
          publish(
            ReadFreshness.busy,
            error: RpcError(RpcErrorCode.busy, 'Read timed out; retry shortly'),
          );
        }
      });
      final reply = await _worker.read(
        ReadWorkerRequest(
          projection: entry.query.projection,
          arguments: entry.query.argumentsForDispatch(),
          identity: before,
          sequence: sequence,
        ),
      );
      if (!listening() || expired) return;
      final now = identity();
      if (!before.sameOwner(now) || reply.epoch != before.epoch) {
        entry.pending = true;
        return;
      }
      final value = entry.query.decode(reply.value);
      final current = before.revision == now.revision;
      entry.lastValue = value;
      entry.lastIdentity = now;
      publish(
        current ? ReadFreshness.current : ReadFreshness.preview,
        value: value,
      );
      // An invalidation can race even a current result. Preserve its one pending
      // refresh rather than pretending that a broadcast is a snapshot receipt.
      if (!current && listening()) entry.pending = true;
    } catch (error) {
      if (error is IncompatibleReadSchema) {
        // Joining this task from inside itself would deadlock. Retirement
        // publishes immediately, then joins every actual read asynchronously.
        unawaited(retire(error));
      } else if (!expired) {
        publish(
          ReadFreshness.failed,
          error: error is RpcError
              ? error
              : RpcError(RpcErrorCode.internal, 'Read failed: $error'),
        );
      }
    } finally {
      timer?.cancel();
    }
  }

  Future<void> close() => _beginClose();

  /// Every reader connection uses this terminal schema-failure path.
  Future<void> retire(IncompatibleReadSchema error) {
    _incompatibility ??= error;
    final result = _beginClose();
    scheduleMicrotask(() {
      if (!_activity.isClosed) _activity.add(null);
    });
    return result;
  }

  Future<void> _beginClose() {
    if (_closing != null) return _closing!;
    // Establish disposal and the shared join future before notifying a sync
    // listener, which may itself close the owning connection.
    _disposed = true;
    final result = Completer<void>();
    _closing = result.future;
    scheduleMicrotask(() async {
      try {
        await _close();
        result.complete();
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _close() async {
    _disposed = true;
    for (final entry in _entries.values) {
      entry.pending = false;
      if (entry.events.hasListener) {
        entry.events.add(
          ReadResult<Object?>(
            freshness: _incompatibility == null
                ? ReadFreshness.cancelled
                : ReadFreshness.failed,
            value: null,
            requestTag: '',
            sequence: _sequence,
            error:
                _incompatibility?.rpcError ??
                RpcError(RpcErrorCode.cancelled, 'Reader closed'),
          ),
        );
      }
      entry.lastValue = null;
      entry.lastIdentity = null;
      unawaited(entry.events.close());
    }
    _entries.clear();
    await Future.wait(_active.toList());
    try {
      await _worker.close();
    } finally {
      onClosed?.call();
      await _activity.close();
    }
  }
}

final class _ReadEntry {
  final ReadQuery<Object?> query;
  final StreamController<ReadResult<Object?>> events;
  bool active = false, pending = false;
  int generation = 0;
  Object? lastValue;
  ReadIdentity? lastIdentity;
  _ReadEntry(
    this.query, {
    required void Function() onListen,
    required void Function() onCancel,
  }) : events = StreamController.broadcast(
         sync: true,
         onListen: onListen,
         onCancel: onCancel,
       );
}
