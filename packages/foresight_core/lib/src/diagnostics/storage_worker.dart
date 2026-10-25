import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'events.dart';
import 'storage.dart';
import 'storage_worker_native.dart';
import 'storage_worker_launch.dart';
export 'storage_worker_launch.dart';
import 'storage_worker_protocol.dart';

/// Constructed on the entrypoint coordinator, before any native preparation.
/// Composition supplies only an already validated original native image/table
/// and a lazy, validated command. This factory never runs in the writer.
typedef DiagnosticWorkerFactory =
    DiagnosticWorkerOwner Function(DiagnosticStorageLaunchContext context);

final class DiagnosticStorageLaunchContext {
  const DiagnosticStorageLaunchContext({
    required this.configuration,
    required this.session,
    required this.applicationPid,
    required this.version,
    required this.revision,
    required this.prepare,
    required this.writerExited,
  });
  final DiagnosticConfiguration configuration;
  final DiagnosticIdentity session;
  final int applicationPid;
  final String version, revision;

  /// One callback into the actual writer. Only original code addresses and the
  /// native opaque generation cross its bootstrap. Completion means the FFI
  /// returned; timeout alone can never complete this ownership barrier.
  final Future<int> Function(List<int> addresses, int generation) prepare;
  final Future<void> writerExited;
}

final class DiagnosticWorkerRequest {
  DiagnosticWorkerRequest(this.type, Uint8List payload)
    : payload = _copy(type, payload);

  static Uint8List _copy(int type, Uint8List payload) {
    final maximum = type == DiagnosticWorkerFrame.append ? 4096 : 8192;
    if (!const {
          DiagnosticWorkerFrame.init,
          DiagnosticWorkerFrame.admit,
          DiagnosticWorkerFrame.classify,
          DiagnosticWorkerFrame.append,
          DiagnosticWorkerFrame.health,
          DiagnosticWorkerFrame.retire,
        }.contains(type) ||
        payload.length > maximum) {
      throw ArgumentError('Invalid diagnostic worker request');
    }
    return Uint8List.fromList(payload).asUnmodifiableView();
  }

  final int type;
  final Uint8List payload;
}

/// A failed Future is not a storage ACK. Only [disposed] proves any request
/// payload can no longer be owned by the physical child. Unknown work keeps its
/// original queue/ticket charge until actual disposal or writer exit.
final class DiagnosticWorkerFailure implements Exception {
  const DiagnosticWorkerFailure(this.reason, {this.disposed = false});
  final DiagnosticHealthReason reason;
  final bool disposed;
}

final class DiagnosticWorkerSnapshot {
  const DiagnosticWorkerSnapshot({
    this.parentSettled = true,
    this.childNotLive = false,
    this.reaped = false,
    this.exitClass = 0,
    this.reason = DiagnosticHealthReason.healthy,
    this.slot,
    this.buildId,
  });
  final String? buildId;
  final bool parentSettled, childNotLive, reaped;
  final int exitClass;
  final DiagnosticHealthReason reason;
  final int? slot;
}

final class DiagnosticWorkerCloseResult {
  const DiagnosticWorkerCloseResult({
    this.ownerSettled = true,
    this.retired = false,
    this.childNotLive = false,
    this.reaped = false,
    this.reason = DiagnosticHealthReason.healthy,
  });
  final bool ownerSettled, retired, childNotLive, reaped;
  final DiagnosticHealthReason reason;
}

abstract interface class DiagnosticWorkerOwner {
  Future<DiagnosticWorkerReply> request(DiagnosticWorkerRequest request);
  DiagnosticWorkerSnapshot get snapshot;
  void heartbeat();
  void force();
  Future<DiagnosticWorkerCloseResult> close({
    Duration normalBudget = const Duration(milliseconds: 300),
    Duration totalBudget = const Duration(milliseconds: 500),
  });
}

void _spawnDiagnosticChild((List<int>, int, SendPort) bootstrap) {
  final (addresses, id, result) = bootstrap;
  final functions = DiagnosticNativeFunctions.fromCodeAddresses(addresses);
  result.send([functions.spawn(id)]);
}

/// Exactly one dedicated spawn isolate. Result and VM exit share an ordered
/// mailbox; receiving the result alone does not prove its native call owner has
/// exited. A held spawn remains owned after cancellation and final-close expiry.
final class _SpawnOwner {
  final returned = Completer<int>();
  final exited = Completer<void>();
  late final RawReceivePort _messages;
  late final RawReceivePort _errors;
  bool _creationSettled = false;

  Future<void> start(List<int> addresses, int id) async {
    _messages = RawReceivePort((dynamic message) {
      if (message is List && message.length == 1 && message.single is int) {
        if (!returned.isCompleted) returned.complete(message.single as int);
      } else if (message == null) {
        if (!returned.isCompleted) {
          returned.completeError(
            const DiagnosticWorkerFailure(
              DiagnosticHealthReason.storageWorkerLaunchFailed,
            ),
          );
        }
        if (!exited.isCompleted) exited.complete();
        _messages.close();
        _errors.close();
      }
    })..keepIsolateAlive = false;
    _errors = RawReceivePort((dynamic _) {})..keepIsolateAlive = false;
    returned.future.ignore();
    try {
      await Isolate.spawn(
        _spawnDiagnosticChild,
        (addresses, id, _messages.sendPort),
        onExit: _messages.sendPort,
        onError: _errors.sendPort,
        errorsAreFatal: true,
        debugName: 'diagnostic-spawn',
      );
    } catch (_) {
      _messages.close();
      _errors.close();
      if (!returned.isCompleted) {
        returned.completeError(
          const DiagnosticWorkerFailure(
            DiagnosticHealthReason.storageWorkerLaunchFailed,
          ),
        );
      }
      if (!exited.isCompleted) exited.complete();
      rethrow;
    } finally {
      _creationSettled = true;
    }
  }

  bool get settled => _creationSettled && exited.isCompleted;
}

/// Parent-side native process owner. It opens no library or command path and
/// never invokes blocking prepare/spawn on the application coordinator. The
/// supplied table retains its original early loaded image for process lifetime.
final class NativeDiagnosticWorkerOwner implements DiagnosticWorkerOwner {
  NativeDiagnosticWorkerOwner(
    this.context,
    this.functions, {
    required this.resolveCommand,
  });
  final DiagnosticStorageLaunchContext context;
  final DiagnosticNativeFunctions functions;
  final DiagnosticStorageCommand Function() resolveCommand;
  DiagnosticNativeEndpoint? _endpoint;
  _SpawnOwner? _spawn;
  Future<void>? _launch;
  Future<DiagnosticWorkerCloseResult>? _close;
  int _id = 0, _nextRequest = 1, _status = 0;
  int? _slot;
  String? _buildId;
  bool _preparing = false,
      _requesting = false,
      _forced = false,
      _closing = false,
      _hello = false,
      _retired = false;
  DiagnosticHealthReason _reason = DiagnosticHealthReason.healthy;

  bool get _parentSettled =>
      !_preparing && (_spawn?.settled ?? true) && !_requesting;
  bool get _notLive =>
      _status >= 0 && (_status & DiagnosticNativeFunctions.notLive) != 0;
  void _poll() {
    if (_id == 0) return;
    final status = functions.poll(_id);
    if (status < 0 || (status & DiagnosticNativeFunctions.failed) != 0) {
      _reason = DiagnosticHealthReason.storageWorkerUnknown;
    }
    if (status >= 0) _status = status;
    if (_notLive &&
        !_retired &&
        !_closing &&
        _reason == DiagnosticHealthReason.healthy) {
      _reason = DiagnosticHealthReason.storageWorkerExited;
    }
  }

  @override
  DiagnosticWorkerSnapshot get snapshot {
    _poll();
    return DiagnosticWorkerSnapshot(
      parentSettled: _parentSettled,
      childNotLive: _notLive,
      reaped: _status >= 0 && (_status & DiagnosticNativeFunctions.reaped) != 0,
      exitClass: _id == 0 ? 0 : functions.exitClass(_id),
      reason: _reason,
      slot: _slot,
      buildId: _buildId,
    );
  }

  Future<void> _start() async {
    final command = resolveCommand();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(command.dartId)) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerLaunchFailed,
        disposed: true,
      );
    }
    _buildId = command.dartId;
    if (_forced || _closing) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.closed,
        disposed: true,
      );
    }
    _id = functions.reserve(
      nativeId: command.nativeId,
      dartId: command.dartId,
      catalogId: command.catalogId,
      arguments: command.arguments,
    );
    if (_id == 0) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerLaunchFailed,
        disposed: true,
      );
    }
    _preparing = true;
    late final int prepared;
    try {
      prepared = await context.prepare(functions.codeAddresses, _id);
    } finally {
      _preparing = false;
    }
    if (_forced || _closing) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.closed,
        disposed: true,
      );
    }
    if (prepared != DiagnosticNativeFunctions.prepared) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerUnknown,
        disposed: true,
      );
    }
    final spawn = _spawn = _SpawnOwner();
    await spawn.start(functions.codeAddresses, _id);
    final result = await spawn.returned.future;
    if (result < 0 || result != DiagnosticNativeFunctions.spawned) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerLaunchFailed,
      );
    }
    await spawn.exited.future;
    if (_forced || _closing) {
      throw const DiagnosticWorkerFailure(DiagnosticHealthReason.closed);
    }
    _endpoint = DiagnosticNativeEndpoint(functions, _id);
    final clock = Stopwatch()..start();
    while (!_hello) {
      _check(clock);
      final frame = _endpoint!.receive();
      if (frame.result == DiagnosticNativeFunctions.complete) {
        if (frame.type != DiagnosticWorkerFrame.hello ||
            frame.request != 0 ||
            frame.total != 0 ||
            frame.bytes.isNotEmpty) {
          throw const DiagnosticWorkerFailure(
            DiagnosticHealthReason.storageWorkerProtocolFailed,
          );
        }
        _hello = true;
      } else if (frame.result < 0) {
        throw const DiagnosticWorkerFailure(
          DiagnosticHealthReason.storageWorkerProtocolFailed,
        );
      }
      _poll();
      if (!_hello || (_status & DiagnosticNativeFunctions.watchBound) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    while ((_status & DiagnosticNativeFunctions.watchBound) == 0) {
      _check(clock);
      _poll();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void _check(Stopwatch clock) {
    _poll();
    if ((_status & DiagnosticNativeFunctions.failed) != 0) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerUnknown,
      );
    }
    if (_notLive) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerExited,
        disposed: true,
      );
    }
    if (_forced) {
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerUnknown,
      );
    }
    if (clock.elapsed >= const Duration(seconds: 5)) {
      force();
      throw const DiagnosticWorkerFailure(
        DiagnosticHealthReason.storageWorkerUnresponsive,
      );
    }
  }

  @override
  Future<DiagnosticWorkerReply> request(DiagnosticWorkerRequest request) async {
    if (_requesting || _closing || _forced) {
      throw DiagnosticWorkerFailure(_reason);
    }
    _requesting = true;
    try {
      await (_launch ??= _start());
      return await _exchange(request);
    } on DiagnosticWorkerFailure catch (failure) {
      _reason = failure.reason;
      force();
      rethrow;
    } catch (_) {
      _reason = DiagnosticHealthReason.storageWorkerUnknown;
      force();
      throw DiagnosticWorkerFailure(_reason);
    } finally {
      _requesting = false;
    }
  }

  Future<DiagnosticWorkerReply> _exchange(
    DiagnosticWorkerRequest request,
  ) async {
    final clock = Stopwatch()..start();
    final id = _nextRequest;
    var offset = 0;
    do {
      _check(clock);
      final end = (offset + DiagnosticNativeFunctions.chunkBytes).clamp(
        0,
        request.payload.length,
      );
      final result = _endpoint!.send(
        request.type,
        id,
        request.payload.length,
        Uint8List.sublistView(request.payload, offset, end),
      );
      if (result < 0 || result == DiagnosticNativeFunctions.exhausted) {
        throw const DiagnosticWorkerFailure(
          DiagnosticHealthReason.storageWorkerProtocolFailed,
        );
      }
      if (result != DiagnosticNativeFunctions.empty) offset = end;
      if (result == DiagnosticNativeFunctions.complete) break;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    } while (true);
    while (true) {
      // A final matching ACK can remain published after the child exits.
      // Consume that authoritative disposition before treating exit as an
      // unknown reply; the native mapping is retained for this process.
      final frame = _endpoint!.receive();
      if (frame.result < 0) {
        throw const DiagnosticWorkerFailure(
          DiagnosticHealthReason.storageWorkerProtocolFailed,
        );
      }
      if (frame.result == DiagnosticNativeFunctions.complete) {
        if (frame.request != id ||
            frame.type !=
                (request.type == DiagnosticWorkerFrame.retire
                    ? DiagnosticWorkerFrame.retired
                    : DiagnosticWorkerFrame.result)) {
          throw const DiagnosticWorkerFailure(
            DiagnosticHealthReason.storageWorkerProtocolFailed,
          );
        }
        if (frame.total != 4 || frame.bytes.length != 4) {
          throw const DiagnosticWorkerFailure(
            DiagnosticHealthReason.storageWorkerProtocolFailed,
          );
        }
        final reply = DiagnosticWorkerReply.decode(frame.bytes);
        if (request.type == DiagnosticWorkerFrame.retire) {
          if (reply.result != DiagnosticWorkerResult.ok ||
              reply.reason != DiagnosticHealthReason.closed) {
            throw const DiagnosticWorkerFailure(
              DiagnosticHealthReason.storageWorkerProtocolFailed,
            );
          }
          _retired = true;
          return reply;
        }
        _slot = reply.slot;
        _nextRequest++;
        return reply;
      }
      _check(clock);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  @override
  void heartbeat() {
    if (_id != 0 && !_forced) functions.heartbeat(_id);
  }

  @override
  void force() {
    _forced = true;
    if (_id != 0) functions.force(_id);
  }

  @override
  Future<DiagnosticWorkerCloseResult> close({
    Duration normalBudget = const Duration(milliseconds: 300),
    Duration totalBudget = const Duration(milliseconds: 500),
  }) => _close ??= _finishClose(normalBudget, totalBudget);

  Future<DiagnosticWorkerCloseResult> _finishClose(
    Duration normal,
    Duration total,
  ) async {
    _closing = true;
    final clock = Stopwatch()..start();
    var retireStarted = false;
    while (clock.elapsed < total) {
      _poll();
      if (!_forced && clock.elapsed >= normal) force();
      if (!_requesting && !retireStarted && _hello && !_forced) {
        retireStarted = true;
        _requesting = true;
        unawaited(
          _exchange(
                DiagnosticWorkerRequest(
                  DiagnosticWorkerFrame.retire,
                  Uint8List(0),
                ),
              )
              .then<void>((_) {}, onError: (Object _) {})
              .whenComplete(() => _requesting = false),
        );
      }
      if (_parentSettled &&
          (_notLive || _id == 0 || (_spawn == null && !_preparing))) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (!_notLive && _id != 0) force();
    final state = snapshot;
    if (state.parentSettled) {
      _endpoint?.close();
      _endpoint = null;
    }
    return DiagnosticWorkerCloseResult(
      ownerSettled: state.parentSettled,
      retired: _retired,
      childNotLive: state.childNotLive,
      reaped: state.reaped,
      reason: _retired && state.childNotLive
          ? DiagnosticHealthReason.closed
          : _reason == DiagnosticHealthReason.healthy
          ? DiagnosticHealthReason.storageWorkerUnknown
          : _reason,
    );
  }
}
