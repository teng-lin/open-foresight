import 'dart:async';
import 'dart:isolate';

import 'persistence/read_schema_guard.dart';
import 'platform_services.dart';
import 'read_coordinator.dart';
import 'rpc_error.dart';
import 'sqlite_read_session.dart';

/// Lazy, long-lived core-owned read isolate. No SQLite handle crosses ports.
final class SqliteReadWorker implements ReadWorker {
  final String _path;
  final Map<String, String> _environment;
  final _pending = <int, Completer<ReadWorkerReply>>{};
  final _exited = Completer<void>();
  ReceivePort? _messages;
  Future<SendPort>? _starting;
  Completer<SendPort>? _ready;
  Future<void>? _closing;
  var _closed = false, _sequence = 0;

  SqliteReadWorker(String path, {Map<String, String>? environment})
    : _path = path,
      _environment = Map.unmodifiable(
        environment ?? runtimeConfiguration.environment,
      );

  Future<SendPort> _start() => _starting ??= _spawn();

  Future<SendPort> _spawn() async {
    final ready = _ready = Completer<SendPort>();
    _messages = ReceivePort()
      ..listen((Object? message) {
        if (message is SendPort) {
          if (!ready.isCompleted) ready.complete(message);
        } else if (message is _ReadResponse) {
          final result = _pending.remove(message.id);
          if (result == null) return;
          if (message.error != null) {
            result.completeError(message.error!);
          } else {
            result.complete(message.reply!);
          }
        } else if (message is _ReadStartupFailure) {
          if (!ready.isCompleted) ready.completeError(message.error);
        } else if (message == null) {
          _fail(RpcError(RpcErrorCode.unavailable, 'Read worker exited'));
          if (!_exited.isCompleted) _exited.complete();
        } else {
          _fail(
            RpcError(RpcErrorCode.unavailable, 'Read worker failed: $message'),
          );
        }
      });
    try {
      await Isolate.spawn(
        _runReader,
        (_path, _environment, _messages!.sendPort),
        // One ordered inbox keeps the typed startup refusal ahead of exit.
        onError: _messages!.sendPort,
        onExit: _messages!.sendPort,
      );
    } catch (error, stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
      if (!_exited.isCompleted) _exited.complete();
    }
    return ready.future;
  }

  void _fail(Object error) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    final pending = _pending.values.toList();
    _pending.clear();
    for (final result in pending) {
      result.completeError(error);
    }
  }

  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) async {
    if (_closed) throw RpcError(RpcErrorCode.cancelled, 'Reader closed');
    final port = await _start();
    if (_closed) throw RpcError(RpcErrorCode.cancelled, 'Reader closed');
    if (_exited.isCompleted) {
      throw RpcError(RpcErrorCode.unavailable, 'Read worker exited');
    }
    final id = ++_sequence;
    final result = Completer<ReadWorkerReply>();
    _pending[id] = result;
    port.send((id, request));
    return result.future;
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (_starting == null) return;
    try {
      final port = await _starting;
      port?.send(null);
    } catch (_) {
      // Startup already reported its original failure to every caller.
    }
    await _exited.future;
    _messages?.close();
  }
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

void _runReader((String, Map<String, String>, SendPort) startup) {
  final (path, environment, results) = startup;
  // The process handoff may already have been consumed. Resolve once in the
  // owner and install exactly that map before model/runtime projections run.
  installServiceWorkerEnvironment(environment);
  SqliteReadSession session;
  try {
    session = SqliteReadSession.open(path);
  } catch (error) {
    results.send(_ReadStartupFailure(_sendableFailure(error)));
    return;
  }
  final commands = ReceivePort();
  results.send(commands.sendPort);
  commands.listen((Object? message) {
    if (message == null) {
      session.close();
      commands.close();
      return;
    }
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
