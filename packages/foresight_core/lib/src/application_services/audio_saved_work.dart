import 'dart:async';

import '../audio_models.dart';
import '../audio_segmentation.dart';
import '../native_lifetime.dart';
import '../persistence/recording_media.dart';
import '../platform_services.dart';
import 'audio_recognition_scheduler.dart';
import 'audio_speech_models.dart';
import 'native_audio_recognition.dart';
import 'recording_audio_work.dart';

/// Service-owned saved-audio work, independent of the currently recording
/// meeting. Every wake can be reconstructed from durable cursors/jobs; stopping
/// capture never drains or cancels transcription. Startup activates this owner
/// only after publication recovery, without opening any capture device.
final class AudioSavedWork implements RecordingAudioWorkPort {
  AudioSavedWork({
    required this.media,
    required NativeLibrary bindings,
    required this.changed,
    required void Function(AudioResultCommit) committed,
    required int Function() nowMs,
    RuntimeConfiguration? configuration,
    AudioSpeechModels? models,
    AudioRecognitionExecution Function(AudioAsrLease)? startRecognition,
  }) {
    speechModels =
        models ??
        AudioSpeechModels.native(
          registration: () => media.store.sourceQueries.model('speech'),
          bindings: bindings,
          configuration: configuration,
        );
    segmenter = AudioSegmentationOwner(
      store: media.audio,
      ownerGeneration: media.ownerGeneration,
      readPcm: media.readPcm,
    );
    recognition = AudioRecognitionScheduler(
      store: media.audio,
      ownerGeneration: media.ownerGeneration,
      nowMs: nowMs,
      committed: committed,
      changed: _notify,
      start:
          startRecognition ??
          (lease) => NativeAudioRecognition(
            bindings: bindings,
            store: media.audio,
            lease: lease,
            readPcm: media.readPcm,
            acquireModel: speechModels.acquire,
          ),
    );
  }

  final RecordingMedia media;
  final void Function() changed;
  late final AudioSpeechModels speechModels;
  late final AudioRecognitionScheduler recognition;
  late final AudioSegmentationOwner segmenter;
  Timer? _timer;
  Future<void>? _segmentation, _suspending, _closing;
  String _afterSpanId = '';
  AudioSource _afterSource = AudioSource.playback;
  bool _active = false, _suspended = false, _closed = false;
  String lastError = '';
  bool get busy => _segmentation != null || recognition.busy;
  bool get restartRequired =>
      recognition.restartRequired || speechModels.restartRequired;

  void activate() {
    if (_closed) throw StateError('Saved audio owner is closed');
    if (_active) return;
    _active = true;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => wake());
    wake();
  }

  /// Metadata-only transaction: complete frozen settings and initial context
  /// exist before any source can acquire its first frame.
  @override
  void prepareSpan(
    AudioSpan span, {
    required String modelRevision,
    required Map<AudioSource, int> sourceStarts,
  }) {
    if (!_active || _closed || _suspended || sourceStarts.isEmpty) {
      throw StateError('Saved audio work is unavailable');
    }
    media.ensureAvailable();
    media.audio.transaction(() {
      for (final entry in sourceStarts.entries) {
        segmenter.prepare(
          span: span,
          source: entry.key,
          modelRevision: modelRevision,
          initialSample: entry.value,
        );
      }
    });
  }

  @override
  void published(AudioChunk chunk) => wake();

  /// Called only after native finish ACKs, all final notices committed and a
  /// final empty native drain. A closed span by itself cannot call this method.
  @override
  void spanSealed(AudioSpan span) {
    media.audio.sealSegmentationPublications(span.id);
    wake();
  }

  @override
  void captureStopped(AudioSession session) => wake();

  void wake() {
    if (!_active || _closed || _suspended || restartRequired) return;
    _segmentation ??= _segment().whenComplete(() => _segmentation = null);
    _segmentation!.ignore();
    unawaited(
      recognition.runOne().catchError((Object error) {
        lastError = 'Saved transcription needs attention';
        _notify();
      }),
    );
  }

  Future<void> _segment() async {
    await Future<void>.value();
    try {
      // Fair bounded turns keep long stopped meetings from starving active
      // sources and leave the service responsive while hashing/reading media.
      final waiting = <(String, AudioSource)>{};
      for (var pass = 0; pass < 4 && !_closed && !_suspended; pass++) {
        final cursor = media.audio.nextSegmentation(
          afterSpanId: _afterSpanId,
          afterSource: _afterSource,
        );
        if (cursor == null ||
            waiting.contains((cursor.spanId, cursor.source))) {
          break;
        }
        _afterSpanId = cursor.spanId;
        _afterSource = cursor.source;
        final result = await segmenter.advance(
          sessionId: cursor.sessionId,
          spanId: cursor.spanId,
          source: cursor.source,
          modelRevision: cursor.modelRevision,
          sourceSealed: cursor.publicationSealed,
        );
        if (result.processedFrames == 0 && !result.flushed) {
          waiting.add((cursor.spanId, cursor.source));
        }
        if (result.blockedReason != null) {
          lastError = 'Saved audio segmentation needs attention';
        }
        if (result.processedFrames != 0 ||
            result.flushed ||
            result.admittedJobIds.isNotEmpty ||
            result.blockedReason != null) {
          _notify();
        }
      }
    } catch (_) {
      lastError = 'Saved audio processing needs attention';
      _notify();
    }
  }

  void _notify() {
    try {
      changed();
    } catch (_) {
      /* Presentation cannot own work admission. */
    }
  }

  /// Caller first stops capture for clear/shutdown; model configuration is
  /// already forbidden while recording. No model lease expires on a timeout.
  Future<void> suspend() {
    _suspended = true;
    return _suspending ??= () async {
      await recognition.suspend();
      await _segmentation;
      await speechModels.suspend();
      await media.fencePublications();
    }().whenComplete(() => _suspending = null);
  }

  void resume() {
    if (_closed || _suspending != null || restartRequired) {
      throw StateError('Saved audio owner is unavailable');
    }
    speechModels.resume();
    recognition.resume();
    _suspended = false;
    wake();
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await suspend();
    await recognition.close();
    await speechModels.close();
  }();
}
