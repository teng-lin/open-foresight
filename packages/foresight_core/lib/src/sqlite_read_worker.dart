import 'dart:async';
import 'dart:isolate';

import 'persistence/read_schema_guard.dart';
import 'persistence/sql_support.dart';
import 'platform_services.dart';
import 'read_coordinator.dart';
import 'rpc_error.dart';
import 'sqlite_read_session.dart';

const _ownerWatchReady = 'read-worker-owner-watch-ready';
const _ownerAttachTimeout = Duration(seconds: 5);

/// Lazy, long-lived core-owned read isolate. No SQLite handle crosses ports.
final class SqliteReadWorker
    implements ReadWorker, ReadQueueCancellation, ReadAdmissionAvailability {
  final String _path;
  final Map<String, String> _environment;
  final SqlSupportBootstrap _sqlSupport;
  final Duration executionBudget;
  final int maxQueuedReads;
  _ReaderGeneration? _generation;
  Future<void>? _closing;
  var _closed = false, _sequence = 0, _drainScheduled = false;
  // Bounded by the callers waiting for admission, never by refused requests.
  final _admissionWaiters = <_AdmissionWaiter>{};

  SqliteReadWorker(
    String path, {
    Map<String, String>? environment,
    SqlSupportBootstrap? sqlSupport,
    this.executionBudget = const Duration(seconds: 5),
    this.maxQueuedReads = 16,
  }) : _path = path,
       _environment = Map.unmodifiable(
         environment ?? runtimeConfiguration.environment,
       ),
       _sqlSupport = sqlSupport ?? currentSqlSupportBootstrap {
    if (executionBudget <= Duration.zero ||
        executionBudget > const Duration(seconds: 30)) {
      throw ArgumentError.value(executionBudget, 'executionBudget');
    }
    if (maxQueuedReads < 1 || maxQueuedReads > 64) {
      throw ArgumentError.value(maxQueuedReads, 'maxQueuedReads');
    }
  }

  _ReaderGeneration _start() {
    final current = _generation;
    if (current != null && !current.exited.isCompleted) return current;
    final generation = _generation = _ReaderGeneration();
    generation.messages.listen((Object? message) {
      if (!identical(_generation, generation)) return;
      if (message is SendPort) {
        generation.port = message;
        // Exit-listener requests are asynchronous. A following OOB ping to
        // ourselves acknowledges their installation before SQL is admitted.
        Isolate.current.addOnExitListener(message);
        Isolate.current.ping(
          generation.messages.sendPort,
          response: _ownerWatchReady,
          priority: Isolate.immediate,
        );
      } else if (message == _ownerWatchReady) {
        generation.attached = true;
        generation.port!.send(true);
        _dispatch(generation);
      } else if (message is _ReadResponse) {
        final active = generation.active;
        if (active == null || message.id != active.id) return;
        generation.active = null;
        if (message.error != null) {
          active.result.completeError(message.error!);
        } else {
          active.result.complete(message.reply!);
        }
        _dispatch(generation);
        _releaseAdmission(fromEvent: true);
      } else if (message == null) {
        _exit(generation);
      } else {
        // An error precedes EOF. Keep physical work reserved until actual exit.
        generation.failure = message is _ReadStartupFailure
            ? message.error
            : RpcError(
                RpcErrorCode.unavailable,
                'Read worker failed: $message',
              );
      }
    });
    unawaited(_spawn(generation));
    return generation;
  }

  Future<void> _spawn(_ReaderGeneration generation) async {
    try {
      await Isolate.spawn(
        _runReader,
        (
          _path,
          _environment,
          generation.messages.sendPort,
          executionBudget,
          _sqlSupport,
        ),
        onError: generation.messages.sendPort,
        onExit: generation.messages.sendPort,
      );
    } catch (error) {
      generation.failure = error;
      _exit(generation); // No child exists after spawn failure.
    }
  }

  void _exit(_ReaderGeneration generation) {
    if (generation.exited.isCompleted) return;
    final error =
        generation.failure ??
        RpcError(RpcErrorCode.unavailable, 'Read worker exited');
    final active = generation.active;
    generation.active = null;
    if (active != null) active.result.completeError(error);
    for (final pending in generation.queue) {
      pending.result.completeError(error);
    }
    generation.queue.clear();
    final port = generation.port;
    if (port != null) Isolate.current.removeOnExitListener(port);
    generation.messages.close();
    generation.exited.complete();
    _releaseAdmission(fromEvent: true);
  }

  void _dispatch(_ReaderGeneration generation) {
    final port = generation.port;
    if (port == null ||
        generation.active != null ||
        generation.failure != null) {
      return;
    }
    if (_closed) {
      port.send(null);
      return;
    }
    if (!generation.attached) return;
    if (generation.queue.isEmpty) return;
    final next = generation.queue.removeAt(0);
    generation.active = next;
    try {
      port.send((next.id, next.request));
    } catch (error) {
      // Serialization refusal means no command was dispatched. Do not strand
      // this reservation or the queued reads behind an unsendable argument.
      generation.active = null;
      next.result.completeError(
        RpcError(
          RpcErrorCode.invalidArgument,
          'Read request cannot be sent: $error',
        ),
      );
      _releaseAdmission();
      _dispatch(generation);
    }
  }

  static int _reserved(_ReaderGeneration generation) =>
      generation.queue.length + (generation.active == null ? 0 : 1);

  @override
  bool get admitsRead {
    final generation = _generation;
    // An exited generation is replaced by a fresh, empty one on admission.
    return _closed ||
        generation == null ||
        generation.exited.isCompleted ||
        _reserved(generation) < maxQueuedReads;
  }

  @override
  void Function() whenAdmissionAvailable(void Function() onAvailable) {
    final waiter = _AdmissionWaiter(onAvailable);
    _admissionWaiters.add(waiter);
    // A release can precede registration; never strand a waiter by capacity.
    if (admitsRead) _releaseAdmission();
    return () => _admissionWaiters.remove(waiter);
  }

  /// Called only where an actual reservation ended or the worker closed.
  ///
  /// A settlement or exit event has no caller frames, so it readmits in the
  /// same turn the reservation ended, as the queue itself dispatches. Releases
  /// inside a caller's stack (cancellation, close, refusal to send) defer to
  /// a microtask rather than re-enter that caller.
  void _releaseAdmission({bool fromEvent = false}) {
    if (_admissionWaiters.isEmpty) return;
    if (fromEvent) {
      _drainAdmission();
      return;
    }
    if (_drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(_drainAdmission);
  }

  void _drainAdmission() {
    _drainScheduled = false;
    // Every notified waiter is removed first; one that still waits issues a
    // read (consuming capacity) before registering again behind the others.
    while (_admissionWaiters.isNotEmpty && admitsRead) {
      final waiter = _admissionWaiters.first;
      _admissionWaiters.remove(waiter);
      try {
        waiter.notify();
      } catch (error, stack) {
        Zone.current.handleUncaughtError(error, stack);
      }
    }
  }

  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) {
    if (_closed) {
      return Future.error(RpcError(RpcErrorCode.cancelled, 'Reader closed'));
    }
    final generation = _start();
    if (_reserved(generation) >= maxQueuedReads) {
      return Future.error(ReadAdmissionRejected());
    }
    final pending = _PendingRead(++_sequence, request);
    generation.queue.add(pending);
    _dispatch(generation);
    return pending.result.future;
  }

  @override
  bool cancelQueued(ReadWorkerRequest request) {
    final generation = _generation;
    if (generation == null) return false;
    final index = generation.queue.indexWhere(
      (pending) => identical(pending.request, request),
    );
    if (index < 0) return false;
    final pending = generation.queue.removeAt(index);
    pending.result.completeError(
      RpcError(RpcErrorCode.cancelled, 'Queued read cancelled'),
    );
    _releaseAdmission();
    return true;
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    // Waiters observe the terminal refusal rather than wait for capacity.
    _releaseAdmission();
    final generation = _generation;
    if (generation == null) return;
    for (final pending in generation.queue) {
      pending.result.completeError(
        RpcError(RpcErrorCode.cancelled, 'Reader closed'),
      );
    }
    generation.queue.clear();
    _dispatch(generation);
    // A timeout is failure, not evidence that physical work has settled.
    await generation.exited.future.timeout(
      executionBudget + const Duration(seconds: 5),
      onTimeout: () =>
          throw RpcError(RpcErrorCode.busy, 'Read worker has not settled'),
    );
  }
}

final class _ReaderGeneration {
  final messages = ReceivePort();
  final exited = Completer<void>();
  final queue = <_PendingRead>[];
  SendPort? port;
  _PendingRead? active;
  Object? failure;
  bool attached = false;
}

final class _AdmissionWaiter {
  final void Function() notify;
  _AdmissionWaiter(this.notify);
}

final class _PendingRead {
  final int id;
  final ReadWorkerRequest request;
  final result = Completer<ReadWorkerReply>();
  _PendingRead(this.id, this.request);
}

final class _ReadResponse {
  final int id;
  final ReadWorkerReply? reply;
  final Object? error;
  const _ReadResponse(this.id, this.reply, this.error);
}

final class _ReadStartupFailure {
  final Object error;
  const _ReadStartupFailure(this.error);
}

void _runReader(
  (String, Map<String, String>, SendPort, Duration, SqlSupportBootstrap)
  startup,
) {
  final (path, environment, results, executionBudget, sqlSupport) = startup;
  // The process handoff may already have been consumed. Resolve once in the
  // owner and install exactly that map before model/runtime projections run.
  installServiceWorkerEnvironment(environment);
  SqliteReadSession session;
  try {
    bindSqlSupportBootstrap(sqlSupport);
    session = SqliteReadSession.open(path, executionBudget: executionBudget);
  } catch (error) {
    results.send(_ReadStartupFailure(_sendableFailure(error)));
    return;
  }
  final commands = ReceivePort();
  var attached = false, closed = false;
  late final Timer attachDeadline;
  void close() {
    if (closed) return;
    closed = true;
    attachDeadline.cancel();
    session.close();
    commands.close();
  }

  // If the owner dies before its exit listener can be installed, no attach
  // arrives. Once attached, owner-exit null and ordinary close share the same
  // ordered command inbox and cannot dispose a live native callback.
  attachDeadline = Timer(_ownerAttachTimeout, close);
  results.send(commands.sendPort);
  commands.listen((Object? message) {
    if (message == null) {
      close();
      return;
    }
    if (message == true) {
      attached = true;
      attachDeadline.cancel();
      return;
    }
    if (!attached || closed) return;
    final (id, request) = message as (int, ReadWorkerRequest);
    try {
      results.send(
        _ReadResponse(
          id,
          session.query(request.projection, request.arguments),
          null,
        ),
      );
    } catch (error) {
      results.send(_ReadResponse(id, null, _sendableFailure(error)));
    }
  });
}

Object _sendableFailure(Object error) =>
    error is IncompatibleReadSchema || error is RpcError
    ? error
    : RpcError(RpcErrorCode.internal, 'Read failed: $error');
