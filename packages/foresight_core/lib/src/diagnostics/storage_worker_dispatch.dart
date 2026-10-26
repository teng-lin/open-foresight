import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../persistence/backup_files.dart' show BackupDirectoryReader;
import 'events.dart';
import 'storage.dart';
import 'storage_worker_native.dart';
import 'storage_worker_protocol.dart';

/// Exec-child-only state, constructed AFTER the native identity, inherited FD
/// gate and independent watcher acknowledgement. The native endpoint enforces
/// request/reply sequencing; this state separately enforces body/file authority.
/// No application database, ownership lock or application-native API is used.
final class DiagnosticStorageWorkerState {
  DiagnosticStorageWorkerState.authenticated({
    required this.parentPid,
    required this.buildId,
    required BackupDirectoryReader? directoryReader,
  }) : _factory = null,
       _directoryReader = directoryReader;

  @visibleForTesting
  DiagnosticStorageWorkerState.forTesting({
    required this.parentPid,
    required this.buildId,
    required DiagnosticSinkFactory factory,
  }) : _factory = factory,
       _directoryReader = null;

  final int parentPid;
  final String buildId;
  final DiagnosticSinkFactory? _factory;
  final BackupDirectoryReader? _directoryReader;
  DiagnosticWorkerInit? _init;
  DiagnosticSink? _sink;
  DiagnosticRole? _role;
  var _attempts = 0, _sequence = 0;
  var _disabled = false, _retired = false, _classified = false;
  var _retirementFailed = false;
  var _errorProtected = false, _failureProtected = false;
  var _reason = DiagnosticHealthReason.bootstrapOnly;
  bool get retired => _retired;

  DiagnosticWorkerReply _reply(DiagnosticWorkerResult result) =>
      DiagnosticWorkerReply(result, _reason, slot: _sink?.slot);

  DiagnosticWorkerReply _disable(DiagnosticHealthReason reason) {
    _disabled = true;
    _reason = reason;
    return _reply(DiagnosticWorkerResult.disabled);
  }

  static void _empty(Uint8List bytes) {
    if (bytes.isNotEmpty) {
      throw const FormatException('Invalid diagnostic control payload');
    }
  }

  /// Call under a native active-operation budget. It includes all synchronous
  /// admission/classification/write/close FFI and is cleared only on return.
  /// Replies are closed scalars; exception messages/stacks never cross IPC.
  DiagnosticWorkerReply handle(int type, Uint8List bytes) {
    if (_retired) {
      throw const FormatException('Retired diagnostic storage worker');
    }
    try {
      if (type == DiagnosticWorkerFrame.retire) {
        _empty(bytes);
        if (_retirementFailed) return _reply(DiagnosticWorkerResult.disabled);
        try {
          _sink?.close();
        } catch (_) {
          _retirementFailed = true;
          return _disable(DiagnosticHealthReason.sinkFailed);
        }
        _sink = null;
        _retired = true;
        _reason = DiagnosticHealthReason.closed;
        return _reply(DiagnosticWorkerResult.ok);
      }
      if (_disabled) return _reply(DiagnosticWorkerResult.disabled);
      if (type == DiagnosticWorkerFrame.init) {
        if (_init != null ||
            parentPid <= 1 ||
            parentPid > 0x7fffffff ||
            buildId.length != 64 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(buildId)) {
          return _disable(DiagnosticHealthReason.writerFailed);
        }
        _init = DiagnosticWorkerInit.decode(bytes);
        _role = _init!.role;
        return _reply(DiagnosticWorkerResult.ok);
      }
      final init = _init;
      if (init == null) return _disable(DiagnosticHealthReason.writerFailed);
      switch (type) {
        case DiagnosticWorkerFrame.admit:
          _empty(bytes);
          if (_sink != null || _attempts >= 5) {
            return _disable(DiagnosticHealthReason.writerFailed);
          }
          ++_attempts;
          try {
            _sink = _factory == null
                ? DiagnosticStorage.admit(
                    init.profile,
                    init.session,
                    _role!,
                    applicationPid: parentPid,
                    // An image without the bounded reader disables logging;
                    // libc directory streams are never the fallback.
                    directoryReader:
                        _directoryReader ??
                        (throw const DiagnosticStorageUnavailable(
                          DiagnosticHealthReason.unsupportedFilesystem,
                        )),
                  )
                : _factory(init.profile, init.session, _role!);
          } on DiagnosticStorageUnavailable catch (error) {
            _reason = error.reason;
          } catch (_) {
            _reason = DiagnosticHealthReason.storageUnavailable;
          }
          if (_sink == null) {
            if (_reason == DiagnosticHealthReason.bootstrapOnly ||
                _reason == DiagnosticHealthReason.healthy) {
              _reason = DiagnosticHealthReason.storageUnavailable;
            }
            if (_attempts == 5) _disabled = true;
            return _reply(
              _disabled
                  ? DiagnosticWorkerResult.disabled
                  : DiagnosticWorkerResult.retry,
            );
          }
          if (_sink!.failed) return _disable(DiagnosticHealthReason.sinkFailed);
          _reason = DiagnosticHealthReason.healthy;
          return _reply(DiagnosticWorkerResult.ok);
        case DiagnosticWorkerFrame.classify:
          final classification = DiagnosticWorkerClassification.decode(bytes);
          if (classification.role != _role &&
              !(_role == DiagnosticRole.candidate &&
                  classification.role == DiagnosticRole.service)) {
            return _disable(DiagnosticHealthReason.writerFailed);
          }
          final sink = _sink;
          if (sink == null) {
            return _disable(DiagnosticHealthReason.writerFailed);
          }
          if (!sink.classify(
            classification.role,
            error: classification.error,
            genuineFailure: classification.genuineFailure,
          )) {
            return sink.failed
                ? _disable(DiagnosticHealthReason.sinkFailed)
                : _reply(DiagnosticWorkerResult.retry);
          }
          _role = classification.role;
          _classified = true;
          _errorProtected |= classification.error;
          _failureProtected |=
              classification.role == DiagnosticRole.service &&
              classification.genuineFailure;
          return _reply(DiagnosticWorkerResult.ok);
        case DiagnosticWorkerFrame.append:
          final sink = _sink;
          if (sink == null) {
            return _disable(DiagnosticHealthReason.writerFailed);
          }
          final record = diagnosticStoredRecord(
            bytes,
            buildId: buildId,
            session: init.session.value,
            parentPid: parentPid,
            afterSequence: _sequence,
          );
          if (record == null) {
            return _disable(DiagnosticHealthReason.writerFailed);
          }
          if (!_classified ||
              (record.level.index <= DiagnosticLevel.warn.index &&
                  !_errorProtected) ||
              (record.level == DiagnosticLevel.error &&
                  _role == DiagnosticRole.service &&
                  !_failureProtected)) {
            return _reply(DiagnosticWorkerResult.retry);
          }
          if (!sink.append(bytes)) {
            return _disable(DiagnosticHealthReason.sinkFailed);
          }
          _sequence = record.sequence;
          return _reply(DiagnosticWorkerResult.ok);
        case DiagnosticWorkerFrame.health:
          _empty(bytes);
          return _reply(DiagnosticWorkerResult.ok);
        default:
          return _disable(DiagnosticHealthReason.writerFailed);
      }
    } on FormatException {
      return _disable(DiagnosticHealthReason.writerFailed);
    } catch (_) {
      return _disable(DiagnosticHealthReason.sinkFailed);
    }
  }
}

void _storageWatch((List<int>, int, SendPort) arguments) {
  final (addresses, id, ready) = arguments;
  DiagnosticNativeFunctions? functions;
  try {
    functions = DiagnosticNativeFunctions.fromCodeAddresses(addresses);
    if (functions.watch(id) != 0) {
      functions.finishChild(id, 67);
      return;
    }
    ready.send(true);
    final retained = functions;
    Timer.periodic(const Duration(milliseconds: 100), (_) {
      try {
        if (retained.watch(id) != 0) retained.finishChild(id, 67);
      } catch (_) {
        retained.finishChild(id, 67);
      }
    });
  } catch (_) {
    // No arbitrary exception/stack is formatted or sent to the parent.
    functions?.finishChild(id, 67);
  }
}

Future<void> _storageReply(
  DiagnosticNativeEndpoint endpoint,
  int type,
  int request,
  Uint8List bytes,
) async {
  if (bytes.length > DiagnosticWorkerFrame.maximumReplyBytes) {
    throw const FormatException('Invalid diagnostic reply');
  }
  while (true) {
    final result = endpoint.send(type, request, bytes.length, bytes);
    if (result == DiagnosticNativeFunctions.complete) return;
    if (result != DiagnosticNativeFunctions.empty) {
      throw const FormatException('Invalid diagnostic reply channel');
    }
    // Bootstrap/active-operation/FORCE watches remain armed during backpressure.
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Run only the exact internal exec-child mode, with composition-validated
/// early loaded functions and generated expected identities. This never loads a
/// path or resolves a profile. The sole private profile arrives later in INIT.
/// Once armed, native child-only finish ends the process without waiting for a
/// held VM isolate; parent contexts cannot use that native operation.
Future<int> runDiagnosticStorageWorker({
  required DiagnosticNativeFunctions functions,
  required int expectedParentPid,
  required String nativeId,
  required String dartId,
  required String catalogId,
  Future<void> Function()? verifyBeforeHello,
}) async {
  final int id;
  try {
    id = functions.armChild(
      parentPid: expectedParentPid,
      nativeId: nativeId,
      dartId: dartId,
      catalogId: catalogId,
    );
    if (id != 1) return 65;
  } catch (_) {
    return 65;
  }
  final armed = Completer<void>();
  final acknowledgement = RawReceivePort((dynamic value) {
    if (value == true && !armed.isCompleted) {
      armed.complete();
    } else {
      functions.finishChild(id, 67);
    }
  });
  // A watch-isolate failure before/after ACK is a child failure, never a
  // business outcome. The watch also catches its own callback errors so the
  // native finish path works while this main isolate is inside file FFI.
  final watchFailed = RawReceivePort((dynamic _) {
    functions.finishChild(id, 67);
  })..keepIsolateAlive = false;
  try {
    final spawned = Isolate.spawn(
      _storageWatch,
      (functions.codeAddresses, id, acknowledgement.sendPort),
      onError: watchFailed.sendPort,
      onExit: watchFailed.sendPort,
      errorsAreFatal: true,
    );
    await Future.wait<void>([
      spawned.then<void>((_) {}),
      armed.future,
    ]).timeout(const Duration(seconds: 1));
  } catch (_) {
    functions.finishChild(id, 65);
    return 65;
  } finally {
    acknowledgement.close();
  }
  try {
    if (functions.mapChild(id) != DiagnosticNativeFunctions.prepared) {
      functions.finishChild(id, 67);
      return 67;
    }
    if (verifyBeforeHello != null) {
      if (functions.operation(id, active: true) != 0) {
        functions.finishChild(id, 67);
        return 67;
      }
      await verifyBeforeHello();
      if (functions.operation(id, active: false) != 0) {
        functions.finishChild(id, 67);
        return 67;
      }
    }
    final endpoint = DiagnosticNativeEndpoint(functions, id);
    final buffer = Uint8List(DiagnosticWorkerFrame.maximumRequestBytes);
    final state = DiagnosticStorageWorkerState.authenticated(
      parentPid: expectedParentPid,
      buildId: dartId,
      directoryReader: functions.directoryReader,
    );
    final idle = Stopwatch()..start();
    var offset = 0;
    await _storageReply(endpoint, DiagnosticWorkerFrame.hello, 0, Uint8List(0));
    while (true) {
      final frame = endpoint.receiveBorrowed();
      if (frame.result == DiagnosticNativeFunctions.empty) {
        await Future<void>.delayed(
          Duration(milliseconds: idle.elapsedMilliseconds < 50 ? 1 : 50),
        );
        continue;
      }
      if ((frame.result != DiagnosticNativeFunctions.partial &&
              frame.result != DiagnosticNativeFunctions.complete) ||
          offset + frame.bytes.length > buffer.length ||
          (frame.result == DiagnosticNativeFunctions.partial &&
              frame.bytes.isEmpty)) {
        functions.finishChild(id, 67);
        return 67;
      }
      buffer.setRange(offset, offset + frame.bytes.length, frame.bytes);
      offset += frame.bytes.length;
      idle.reset();
      if (frame.result == DiagnosticNativeFunctions.partial) continue;
      if (frame.total != offset || functions.operation(id, active: true) != 0) {
        functions.finishChild(id, 67);
        return 67;
      }
      final result = state.handle(
        frame.type,
        Uint8List.sublistView(buffer, 0, offset),
      );
      final retiring = frame.type == DiagnosticWorkerFrame.retire;
      if (retiring && !state.retired) {
        // An uncertain file close cannot be converted into RETIRED. Kernel
        // process teardown owns the remaining child-only descriptors instead.
        functions.finishChild(id, 67);
        return 67;
      }
      await _storageReply(
        endpoint,
        retiring ? DiagnosticWorkerFrame.retired : DiagnosticWorkerFrame.result,
        frame.request,
        result.encode(),
      );
      if (functions.operation(id, active: false) != 0) {
        functions.finishChild(id, 67);
        return 67;
      }
      offset = 0;
      if (retiring) {
        endpoint.close();
        functions.finishChild(id, 0);
        return 0;
      }
    }
  } catch (_) {
    functions.finishChild(id, 67);
    return 67;
  }
}
