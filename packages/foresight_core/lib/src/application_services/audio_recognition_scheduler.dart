import 'dart:async';

import '../audio_models.dart';
import '../persistence/audio_store.dart';

/// A result is not a worker-exit fence. Implementations retain every native
/// model/file reader until [closed] confirms actual completion or cancellation.
abstract interface class AudioRecognitionExecution {
  Future<List<AudioTranscriptResult>> get result;
  Future<void> get closed;
  void cancel();
}

final class AudioRecognitionBlocked implements Exception {
  const AudioRecognitionBlocked(this.reason);
  final String reason;
}

/// One serialized, fair disk-backed ASR owner, independent of capture handles.
/// The service calls runOne on its background work cadence and wakes it when
/// segmentation admits work. Stop recording never drains this scheduler.
final class AudioRecognitionScheduler {
  AudioRecognitionScheduler({
    required this.store,
    required this.ownerGeneration,
    required this.start,
    required this.nowMs,
    required this.committed,
    required this.changed,
  });

  final AudioStore store;
  final String ownerGeneration;
  final AudioRecognitionExecution Function(AudioAsrLease lease) start;
  final int Function() nowMs;
  final void Function(AudioResultCommit result) committed;
  final void Function() changed;
  Future<void>? _work;
  AudioRecognitionExecution? _execution;
  AudioAsrLease? _lease;
  String? _afterSession;
  AudioSource _afterSource = AudioSource.playback;
  bool _closed = false, _suspended = false, _cancelled = false;
  bool _ownershipUnconfirmed = false;

  bool get busy => _work != null;
  bool get suspended => _suspended;
  bool get restartRequired => _ownershipUnconfirmed;
  String get runningJobId => _lease?.job.id ?? '';
  String lastError = '', notificationError = '';

  Future<void> runOne() {
    final existing = _work;
    if (existing != null) return existing;
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
    // Publish _work before observers can synchronously suspend this owner.
    await Future<void>.value();
    if (_closed || _suspended) return;
    final job = store.nextPendingJob(
      nowMs: nowMs(),
      afterSessionId: _afterSession,
      afterSource: _afterSource,
    );
    if (job == null) return;
    _afterSession = job.sessionId;
    _afterSource = job.source;
    final lease = store.claimJob(
      job.id,
      ownerGeneration: ownerGeneration,
      nowMs: nowMs(),
    );
    if (lease == null) return;
    _lease = lease;
    _cancelled = false;
    var fenced = false;
    List<AudioTranscriptResult>? results;
    Object? failure;
    try {
      try {
        final execution = _execution = start(lease);
        if (_closed || _suspended || _cancelled) {
          try {
            execution.cancel();
          } catch (error) {
            failure = error;
          }
        }
        _notify();
        try {
          results = await execution.result;
        } catch (error) {
          failure = error;
        }
        try {
          await execution.closed;
          fenced = true;
        } catch (_) {
          // An expired Dart timeout is not proof that native readers stopped.
          // Keep the durable lease/references until process-owned recovery.
          _ownershipUnconfirmed = true;
          lastError =
              'Speech worker ownership is unconfirmed; restart the service';
          rethrow;
        }
      } catch (error) {
        if (_ownershipUnconfirmed) rethrow;
        // A synchronous creation failure admits no execution/read owner.
        if (_execution == null) fenced = true;
        failure ??= error;
      }
      if (_cancelled || _closed || _suspended) {
        store.interruptJob(lease, error: 'worker_interrupted');
      } else if (failure != null) {
        final blocked = failure is AudioRecognitionBlocked;
        final reason = blocked ? failure.reason : 'speech_recognition_failed';
        store.failJob(lease, error: reason, nowMs: nowMs(), blocked: blocked);
        lastError = reason;
      } else {
        late final AudioResultCommit result;
        try {
          result = store.commitAsrResult(lease, results!);
        } catch (error, stack) {
          lastError = 'Transcript storage needs retry';
          try {
            store.failJob(
              lease,
              error: 'transcript_commit_failed',
              nowMs: nowMs(),
            );
          } catch (_) {
            // A failed status write leaves the durable running lease for
            // process recovery. Preserve the original commit failure.
          }
          Error.throwWithStackTrace(error, stack);
        }
        if (result.newlyCommitted) {
          // Durable text/index intent already committed. Observer failure must
          // neither retry ASR nor replay an older result over a user correction.
          try {
            committed(result);
          } catch (_) {
            notificationError = 'Saved transcript notification needs retry';
          }
        }
      }
    } finally {
      if (fenced) store.releaseAsrLeaseReferences(lease);
    }
  }

  void _notify() {
    try {
      changed();
    } catch (_) {
      /* Presentation never owns reader cleanup. */
    }
  }

  Future<void> suspend() async {
    _suspended = true;
    _cancelled = true;
    Object? failure;
    StackTrace? stack;
    try {
      _execution?.cancel();
    } catch (error, trace) {
      failure = error;
      stack = trace;
    }
    await _work;
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  void resume() {
    if (_closed || _ownershipUnconfirmed) {
      throw StateError('Speech scheduler is unavailable');
    }
    _suspended = false;
  }

  Future<void> close() async {
    _closed = true;
    await suspend();
  }
}
