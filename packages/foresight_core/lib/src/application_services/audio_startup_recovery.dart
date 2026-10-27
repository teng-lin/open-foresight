import '../audio_models.dart';
import '../native_lifetime.dart';
import '../persistence/recording_media.dart';
import '../recording_recovery.dart';
import '../rpc_error.dart';

final class AudioRecoveryProblem {
  const AudioRecoveryProblem(this.sessionId, this.chunkId);
  final String sessionId, chunkId;
}

final class AudioRecoveryReport {
  const AudioRecoveryReport(
    this.sessions,
    this.recoveredChunks,
    this.problemCount,
    this.problems,
  );
  final int sessions, recoveredChunks, problemCount;

  /// Bounded diagnostic identities; no media/user paths or audio contents.
  final List<AudioRecoveryProblem> problems;
}

typedef RecoverAudioBatch =
    Future<List<AudioChunk>> Function(List<AudioChunkPublication> authorities);

/// Startup runs this before activating any saved worker or admitting capture.
/// The media owner already acquired the inherited-reader flock and independent
/// database binding. Pages are bounded, missing unused reservations are normal,
/// and corrupt candidates do not prevent recovery of other authorized audio.
/// No wall-clock elapsed time is treated as captured duration.
final class AudioStartupRecovery {
  AudioStartupRecovery({
    required this.media,
    required this.bindings,
    required this.current,
    required this.nowMs,
    RecoverAudioBatch? recover,
  }) : _recover = recover;
  final RecordingMedia media;
  final NativeLibrary bindings;
  final bool Function() current;
  final int Function() nowMs;
  final RecoverAudioBatch? _recover;
  Future<AudioRecoveryReport>? _running;

  Future<AudioRecoveryReport> run() => _running ??= _run();

  void _check() {
    if (!current()) {
      throw RpcError(RpcErrorCode.cancelled, 'Recording recovery cancelled');
    }
    bindings.checkAvailable();
    media.ensureAvailable();
  }

  Future<AudioRecoveryReport> _run() async {
    _check();
    var sessions = 0, chunks = 0, failures = 0;
    final problems = <AudioRecoveryProblem>[];
    var afterSession = '';
    Future<List<AudioChunk>> recover(List<AudioChunkPublication> values) =>
        _recover?.call(values) ??
        RecordingRecovery.reconcileBatch(
          bindings: bindings,
          media: media,
          publications: values,
          current: current,
        );
    while (true) {
      _check();
      final page = media.audio.recoverySessions(afterId: afterSession);
      if (page.isEmpty) break;
      for (final session in page) {
        _check();
        var failed = false, afterPublication = '';
        while (true) {
          final pending = media.audio.pendingSessionPublications(
            session.id,
            afterId: afterPublication,
          );
          if (pending.isEmpty) break;
          afterPublication = pending.last.id;
          for (final source in AudioSource.values) {
            final group = pending
                .where((item) => item.source == source)
                .toList();
            if (group.isEmpty) continue;
            try {
              chunks += (await recover(group)).length;
              _check();
            } catch (_) {
              // An uncertain real owner is fatal to further physical work.
              _check();
              // A batch may have synced valid predecessors before finding a
              // bad candidate. Re-delivery is idempotent; one-ID fallback keeps
              // corruption from hiding unrelated recoverable tails.
              for (final authority in group) {
                try {
                  chunks += (await recover([authority])).length;
                  _check();
                } catch (_) {
                  _check();
                  failed = true;
                  failures++;
                  if (problems.length < 32) {
                    problems.add(
                      AudioRecoveryProblem(session.id, authority.id),
                    );
                  }
                }
              }
            }
          }
        }
        var afterSpan = -1;
        while (true) {
          final spans = media.audio.spansPage(
            session.id,
            afterOrdinal: afterSpan,
          );
          if (spans.isEmpty) break;
          for (final span in spans) {
            if (span.captureEndUs == null) {
              final knownEnd = media.audio.capturedEndForSpan(span.id);
              media.audio.closeSpan(
                span.id,
                captureEndUs: knownEnd == null || knownEnd < span.captureStartUs
                    ? span.captureStartUs
                    : knownEnd,
                reason: 'interrupted',
              );
            }
            if (!failed) media.audio.sealSegmentationPublications(span.id);
          }
          afterSpan = spans.last.ordinal;
        }
        media.audio.setCaptureState(
          session.id,
          session.captureState.terminal
              ? session.captureState
              : AudioCaptureState.interrupted,
          stoppedWallMs: nowMs(),
          error: failed
              ? 'recording_recovery_failed'
              : session.captureState.terminal
              ? null
              : 'recording_interrupted',
        );
        sessions++;
      }
      afterSession = page.last.id;
      // Even histories containing only unused reservations must yield to
      // cancellation/service events between bounded metadata pages.
      await Future<void>.delayed(Duration.zero);
    }
    return AudioRecoveryReport(
      sessions,
      chunks,
      failures,
      List.unmodifiable(problems),
    );
  }
}
