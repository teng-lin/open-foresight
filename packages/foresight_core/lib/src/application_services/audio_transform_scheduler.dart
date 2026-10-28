import 'dart:async';

import '../audio_models.dart';
import '../persistence/audio_store.dart';

/// A codec result is evidence only after the separate actual exit fence.
final class AudioEncodedResult {
  const AudioEncodedResult({
    required this.sha256,
    required this.byteLength,
    required this.frames,
    required this.preSkip,
    required this.finalGranule,
    required this.workerBuildId,
    required this.workerSha256,
  });
  final String sha256, workerBuildId, workerSha256;
  final int byteLength, frames, preSkip, finalGranule;
}

abstract interface class AudioTransformExecution {
  Future<AudioEncodedResult> get result;
  Future<void> get closed;
  void cancel();
}

final class AudioTransformOutput {
  const AudioTransformOutput({this.representation, required this.metadata});
  final AudioRepresentation? representation;
  final Map<String, Object?> metadata;
}

/// Service-owned descriptors, publication and crash reconciliation. Prepare and
/// start retain input references across their awaits; neither accepts RPC paths.
abstract interface class AudioTransformOperation {
  bool get hasValidatedOutput;
  Future<AudioTransformExecution> start();
  void markWorkerClosed();
  Future<AudioTransformOutput> publish(AudioEncodedResult? result);
  FutureOr<void> resetForRetry();
  FutureOr<void> abort();
  FutureOr<void> committed();
  void close();
}

final class AudioTransformBlocked implements Exception {
  const AudioTransformBlocked(this.reason);
  final String reason;
}

/// One fair, serialized compression/export owner. Capturing and ASR never wait
/// for its queue. Only actual native retirement releases durable input readers.
final class AudioTransformScheduler {
  AudioTransformScheduler({
    required this.store,
    required this.ownerGeneration,
    required this.prepare,
    required this.nowMs,
    required this.committed,
    required this.changed,
  });
  final AudioStore store;
  final String ownerGeneration;
  final Future<AudioTransformOperation> Function(
    AudioTransformLease lease,
    bool Function() current,
  )
  prepare;
  final int Function() nowMs;
  final void Function(AudioTransformCommit) committed;
  final void Function() changed;
  Future<void>? _work;
  AudioTransformExecution? _execution;
  AudioTransformLease? _lease;
  AudioTransformOperation? _unconfirmedOperation;
  AudioTransformExecution? _unconfirmedExecution;
  String _afterSession = '';
  AudioTransformKind _afterKind = AudioTransformKind.export;
  bool _closed = false, _suspended = false, _cancelled = false;
  bool _abandon = false, _ownershipUnconfirmed = false;
  String lastError = '', notificationError = '';
  bool get busy => _work != null;
  bool get suspended => _suspended;
  bool get restartRequired =>
      _ownershipUnconfirmed ||
      _unconfirmedOperation != null ||
      _unconfirmedExecution != null;
  String get runningJobId => _lease?.job.id ?? '';

  bool _current(AudioTransformLease lease) {
    final actual = store.transformJob(lease.job.id);
    return !_closed &&
        !_suspended &&
        !_cancelled &&
        store.mediaAdmitted &&
        actual?.state == AudioJobState.running &&
        actual?.ownerGeneration == lease.ownerGeneration &&
        actual?.leaseGeneration == lease.leaseGeneration;
  }

  Future<void> runOne() {
    if (_work case final work?) return work;
    if (_closed || _suspended || _ownershipUnconfirmed) return Future.value();
    late final Future<void> work;
    work = Future<void>.sync(_run).whenComplete(() {
      _work = null;
      _execution = null;
      _lease = null;
      _notify();
    });
    _work = work;
    work.ignore();
    return work;
  }

  Future<void> _run() async {
    await Future<void>.value();
    if (_closed || _suspended) return;
    final job = store.nextPendingTransformJob(
      nowMs: nowMs(),
      afterSessionId: _afterSession,
      afterKind: _afterKind,
    );
    if (job == null) return;
    _afterSession = job.sessionId;
    _afterKind = job.kind;
    final lease = store.claimTransformJob(
      job.id,
      ownerGeneration: ownerGeneration,
      nowMs: nowMs(),
    );
    if (lease == null) return;
    _lease = lease;
    _cancelled = _abandon = false;
    AudioTransformOperation? operation;
    var fenced = false, manifestCommitted = false;
    Object? failure;
    try {
      try {
        operation = await prepare(lease, () => _current(lease));
        if (!_current(lease)) {
          // Prepare never starts native work. Its files/readers are now closed.
          fenced = true;
        } else if (operation.hasValidatedOutput) {
          // Startup reconciliation validated a receipt under exclusive ownership.
          fenced = true;
          operation.markWorkerClosed();
        } else {
          final execution = _execution = await operation.start();
          execution.closed.ignore();
          if (!_current(lease)) {
            try {
              execution.cancel();
            } catch (error) {
              failure = error;
            }
          }
          _notify();
          AudioEncodedResult? encoded;
          try {
            encoded = await execution.result;
          } catch (error) {
            failure ??= error;
          }
          try {
            await execution.closed;
            fenced = true;
            operation.markWorkerClosed();
          } catch (_) {
            _ownershipUnconfirmed = true;
            _unconfirmedOperation = operation;
            _unconfirmedExecution = execution;
            lastError =
                'Audio worker ownership is unconfirmed; restart the service';
            rethrow;
          }
          if (_current(lease) && failure == null) {
            final output = await operation.publish(encoded!);
            if (!_current(lease)) {
              throw StateError('Transform authority changed');
            }
            _commit(lease, output);
            manifestCommitted = true;
          }
        }
        if (fenced &&
            _current(lease) &&
            failure == null &&
            !manifestCommitted) {
          final output = await operation.publish(null);
          if (!_current(lease)) throw StateError('Transform authority changed');
          _commit(lease, output);
          manifestCommitted = true;
        }
      } catch (error) {
        if (_ownershipUnconfirmed) rethrow;
        // Failed prepare/start admits no surviving execution. Native start must
        // settle only after owning or retiring every admitted descriptor owner.
        if (_execution == null) fenced = true;
        failure ??= error;
      }
      if (manifestCommitted) {
        try {
          await operation!.committed();
        } catch (_) {
          notificationError = 'Saved audio cleanup needs retry';
        }
      } else if (fenced) {
        // Preserve any validated publication receipt across a DB commit failure.
        if (operation != null && !operation.hasValidatedOutput) {
          try {
            if (_abandon) {
              await operation.abort();
            } else {
              await operation.resetForRetry();
            }
          } catch (error) {
            failure ??= error;
          }
        }
        if (_cancelled || _closed || _suspended) {
          store.interruptTransformJob(lease, error: 'worker_interrupted');
          if (_abandon) store.abandonTransformJob(job.id);
        } else {
          final blocked = failure is AudioTransformBlocked;
          final reason = blocked ? failure.reason : 'audio_processing_failed';
          store.failTransformJob(
            lease,
            error: reason,
            nowMs: nowMs(),
            blocked: blocked,
          );
          lastError = reason;
        }
      }
    } finally {
      if (fenced) {
        try {
          operation?.close();
        } finally {
          store.releaseTransformLeaseReferences(lease);
        }
      }
      // Unconfirmed workers retain native/descriptors and DB readers. Only
      // process-owned startup recovery can subsequently reclaim their authority.
    }
  }

  void _commit(AudioTransformLease lease, AudioTransformOutput output) {
    final result = store.commitTransformResult(
      lease,
      representation: output.representation,
      outputMetadata: output.metadata,
    );
    if (result.newlyCommitted) {
      try {
        committed(result);
      } catch (_) {
        notificationError = 'Saved audio notification needs retry';
      }
    }
  }

  void _notify() {
    try {
      changed();
    } catch (_) {
      /* Observers own no readers. */
    }
  }

  /// Explicit cancellation abandons this job only after real worker exit. A
  /// service suspend instead refunds its claim and leaves durable retry work.
  Future<void> cancel(String jobId) async {
    if (_lease?.job.id != jobId) {
      store.abandonTransformJob(jobId);
      return;
    }
    _cancelled = _abandon = true;
    Object? failure;
    StackTrace? trace;
    try {
      _execution?.cancel();
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    await _work;
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  Future<void> suspend() async {
    _suspended = _cancelled = true;
    Object? failure;
    StackTrace? trace;
    try {
      _execution?.cancel();
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    await _work;
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  void resume() {
    if (_closed || _ownershipUnconfirmed) {
      throw StateError('Audio scheduler is unavailable');
    }
    _suspended = false;
  }

  Future<void> close() async {
    _closed = true;
    await suspend();
  }
}
