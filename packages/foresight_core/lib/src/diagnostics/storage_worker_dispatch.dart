import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'events.dart';
import 'storage.dart';
import 'storage_worker_protocol.dart';

/// Exec-child-only state, constructed AFTER the native identity, inherited FD
/// gate and independent watcher acknowledgement. The native endpoint enforces
/// request/reply sequencing; this state separately enforces body/file authority.
/// No application database, ownership lock or application-native API is used.
final class DiagnosticStorageWorkerState {
  DiagnosticStorageWorkerState.authenticated({
    required this.parentPid,
    required this.buildId,
  }) : _factory = null;

  @visibleForTesting
  DiagnosticStorageWorkerState.forTesting({
    required this.parentPid,
    required this.buildId,
    required DiagnosticSinkFactory factory,
  }) : _factory = factory;

  final int parentPid;
  final String buildId;
  final DiagnosticSinkFactory? _factory;
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
