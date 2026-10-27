import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'audio_models.dart';
import 'persistence/audio_store.dart';

/// Reads exactly the requested canonical PCM16 mono frames from a verified
/// recording-wav-v1 chunk. The service supplies its anchored, checksum/identity
/// validating reader. No arbitrary path or unbounded file read crosses this port.
typedef PublishedPcmWindowReader =
    Future<Int16List> Function(
      AudioChunk chunk, {
      required int frameOffset,
      required int frameCount,
    });

/// Normalized PCM RMS preserves the legacy recording.dart >.003 activity rule.
/// Deterministic 100ms windows replace event-drain dependent segmentation timing.
/// Device inactivity policy continues to observe capture itself, never this owner.
final class AudioSegmentationSettings {
  const AudioSegmentationSettings({
    this.rmsThreshold = .003,
    this.overlapSamples = 0,
    this.supportsOwnedRangeCropping = false,
  });
  static const sampleRate = 48000;
  static const windowSamples = 4800;
  static const preRollSamples = 4800;
  static const trailingSilenceSamples = 48000;
  static const maximumOwnedSamples = 960000;
  final double rmsThreshold;
  final int overlapSamples;
  final bool supportsOwnedRangeCropping;

  factory AudioSegmentationSettings.fromCursor(AudioSegmentationCursor cursor) {
    try {
      final map =
          jsonDecode(utf8.decode(cursor.context)) as Map<String, dynamic>;
      final config = map['settings'] as Map<String, dynamic>;
      final value = AudioSegmentationSettings(
        rmsThreshold: (config['rms_threshold'] as num).toDouble(),
        overlapSamples: config['overlap_samples'] as int,
        supportsOwnedRangeCropping: config['owned_range_cropping'] as bool,
      );
      value.validate();
      if (value.revision != cursor.settingsRevision ||
          jsonEncode(config) != jsonEncode(value._configuration)) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw StateError(
        'Frozen segmentation settings are unavailable or incompatible',
      );
    }
  }

  void validate() {
    if (!rmsThreshold.isFinite ||
        rmsThreshold <= 0 ||
        rmsThreshold >= 1 ||
        overlapSamples < 0 ||
        overlapSamples > 12000) {
      throw ArgumentError('Invalid durable segmentation settings');
    }
    if (overlapSamples > 0 && !supportsOwnedRangeCropping) {
      throw ArgumentError(
        'Overlapped ASR requires timestamp-based owned-range result cropping',
      );
    }
  }

  Map<String, Object?> get _configuration => {
    'version': 1,
    'sample_rate': sampleRate,
    'window_samples': windowSamples,
    'pre_roll_samples': preRollSamples,
    'trailing_silence_samples': trailingSilenceSamples,
    'maximum_owned_samples': maximumOwnedSamples,
    'rms_threshold': rmsThreshold,
    'overlap_samples': overlapSamples,
    'owned_range_cropping': supportsOwnedRangeCropping,
  };
  String get revision =>
      'rms-window-v1:${crypto.sha256.convert(utf8.encode(jsonEncode(_configuration)))}';
}

final class AudioSegmentationPass {
  const AudioSegmentationPass({
    required this.processedFrames,
    required this.cursorSample,
    required this.admittedJobIds,
    required this.flushed,
    required this.waitingForPublication,
    this.blockedReason,
  });
  final int processedFrames, cursorSample;
  final List<String> admittedJobIds;
  final bool flushed, waitingForPublication;
  final String? blockedReason;
}

final class AudioSegmentationUnavailable extends StateError {
  AudioSegmentationUnavailable(super.message);
}

/// Durable saved-audio work. Each pass reads at most two seconds/20 windows,
/// retains at most one 100ms PCM window, and commits frozen jobs/cursor/context
/// together. It owns no capture handles, timers, model process or UI callbacks.
final class AudioSegmentationOwner {
  AudioSegmentationOwner({
    required this.store,
    required this.ownerGeneration,
    required this.readPcm,
  });
  final AudioStore store;
  final String ownerGeneration;
  final PublishedPcmWindowReader readPcm;

  /// Freeze the complete cursor/settings contract before native capture admits
  /// any frames. This transaction performs no audio I/O or model work.
  AudioSegmentationCursor prepare({
    required AudioSpan span,
    required AudioSource source,
    required String modelRevision,
    required int initialSample,
    AudioSegmentationSettings settings = const AudioSegmentationSettings(),
  }) {
    settings.validate();
    return store.initializeSegmentation(
      sessionId: span.sessionId,
      spanId: span.id,
      source: source,
      settingsRevision: settings.revision,
      modelRevision: modelRevision,
      initialSample: initialSample,
      initialContext: _SegmentState(
        cursor: initialSample,
        previousOwnedEnd: initialSample,
        lastVoiceEnd: initialSample,
      ).encode(settings),
    );
  }

  /// [sourceSealed] is a service-owned publication fence, never an RPC argument:
  /// native acquisition has finished, final notices are committed and drained,
  /// or startup orphan/intents reconciliation has completed for this source/span.
  /// A closed span row alone does not establish that no late chunk can arrive.
  Future<AudioSegmentationPass> advance({
    required String sessionId,
    required String spanId,
    required AudioSource source,
    required String modelRevision,
    AudioSegmentationSettings? settings,
    int maxWindows = 20,
    bool sourceSealed = false,
  }) async {
    if (maxWindows < 1 || maxWindows > 20) {
      throw ArgumentError.value(maxWindows, 'maxWindows');
    }
    final span = store
        .spans(sessionId)
        .where((span) => span.id == spanId)
        .firstOrNull;
    if (span == null) throw StateError('Recording span no longer exists');
    if (sourceSealed && span.captureEndUs == null) {
      throw StateError('Source publication cannot be sealed before its span');
    }
    final previous = store.segmentation(sessionId, source, spanId);
    if (previous?.flushed == true) {
      return AudioSegmentationPass(
        processedFrames: 0,
        cursorSample: previous!.cursorSample,
        admittedJobIds: const [],
        flushed: true,
        waitingForPublication: false,
      );
    }
    final configured =
        settings ??
        (previous == null
            ? const AudioSegmentationSettings()
            : AudioSegmentationSettings.fromCursor(previous));
    configured.validate();
    final first = store.segmentationStartSample(sessionId, spanId, source);
    final expected = store.initializeSegmentation(
      sessionId: sessionId,
      spanId: spanId,
      source: source,
      settingsRevision: configured.revision,
      modelRevision: modelRevision,
      initialSample: first,
      initialContext: _SegmentState(
        cursor: first,
        previousOwnedEnd: first,
        lastVoiceEnd: first,
      ).encode(configured),
    );
    if (expected.flushed) {
      return AudioSegmentationPass(
        processedFrames: 0,
        cursorSample: expected.cursorSample,
        admittedJobIds: const [],
        flushed: true,
        waitingForPublication: false,
      );
    }
    AudioSegmentationSettings.fromCursor(expected);
    final state = _SegmentState.decode(expected, first);
    final admitted = <AudioAsrRange>[];
    final references = <String, String>{};
    var processed = 0, waiting = false, flushed = false, contextChanged = false;
    String? blockedReason;
    void emit(int start, int end) => admitted.add(
      _range(
        sessionId,
        spanId,
        source,
        modelRevision,
        configured,
        state.boundaryStart,
        start,
        end,
      ),
    );
    void gapBoundary({bool keepClock = false}) {
      if (state.ownedStart case final start?) {
        if (state.cursor > start) emit(start, state.cursor);
      }
      state.previousOwnedEnd = state.cursor;
      state.ownedStart = null;
      state.lastVoiceEnd = state.cursor;
      state.recent.clear();
      state.boundaryStart = state.cursor;
      if (!keepClock) {
        state.lastCaptureEndUs = null;
        state.lastClockUncertaintyUs = null;
      }
      contextChanged = true;
    }

    try {
      for (var window = 0; window < maxWindows; window++) {
        final end = store.segmentationEndSample(sessionId, spanId, source);
        if (state.cursor >= end) {
          waiting = !sourceSealed;
          break;
        }
        final remaining = end - state.cursor;
        if (remaining < AudioSegmentationSettings.windowSamples &&
            !sourceSealed) {
          waiting = true;
          break;
        }
        _PcmWindow? pcm;
        try {
          pcm = await _readWindow(
            sessionId,
            spanId,
            source,
            state,
            min(AudioSegmentationSettings.windowSamples, remaining),
            references,
            sealed: sourceSealed,
          );
        } on AudioSegmentationUnavailable catch (error) {
          blockedReason = error.message;
          if (processed == 0 && !contextChanged) {
            store.markSegmentationFailure(expected, blockedReason);
            rethrow;
          }
          gapBoundary(keepClock: true);
          break;
        } catch (_) {
          try {
            store.markSegmentationFailure(expected, 'Saved audio read failed');
          } catch (_) {
            // Preserve the original failed read if storage cannot save its status.
          }
          rethrow;
        }
        if (pcm == null) {
          waiting = true;
          break;
        }
        if (pcm.gapBefore) {
          gapBoundary();
          continue;
        }
        final before = state.cursor;
        _consume(state, pcm.samples, configured, state.boundaryStart, emit);
        state.lastCaptureEndUs = pcm.captureEndUs;
        state.lastClockUncertaintyUs = pcm.uncertaintyUs;
        processed += state.cursor - before;
        if (pcm.gapAfter) gapBoundary();
      }
      final end = store.segmentationEndSample(sessionId, spanId, source);
      if (sourceSealed && state.cursor == end && !waiting) {
        if (state.ownedStart case final start?) {
          if (state.cursor > start) {
            emit(start, state.cursor);
            state.previousOwnedEnd = state.cursor;
          }
        }
        state.ownedStart = null;
        flushed = true;
      }
      if (processed > 0 || admitted.isNotEmpty || flushed || contextChanged) {
        final retain = flushed
            ? state.cursor
            : state.ownedStart != null
            ? max(
                state.boundaryStart,
                state.ownedStart! - configured.overlapSamples,
              )
            : max(
                state.boundaryStart,
                state.cursor -
                    AudioSegmentationSettings.preRollSamples -
                    configured.overlapSamples,
              );
        store.admitSegments(
          expected,
          throughSample: state.cursor,
          retainFromSample: retain,
          ranges: admitted,
          context: flushed ? const [] : state.encode(configured),
          flush: flushed,
          error: blockedReason ?? '',
        );
      }
      return AudioSegmentationPass(
        processedFrames: processed,
        cursorSample: state.cursor,
        admittedJobIds: List.unmodifiable(admitted.map((range) => range.id)),
        flushed: flushed,
        waitingForPublication: waiting,
        blockedReason: blockedReason,
      );
    } finally {
      // An invalidated cursor/generation does not prove an awaited file read
      // stopped. Every acquired reference stays held until that actual await
      // and the following admission have returned, even when either throws.
      for (final reference in references.values) {
        store.releaseReference(reference);
      }
    }
  }

  Future<_PcmWindow?> _readWindow(
    String sessionId,
    String spanId,
    AudioSource source,
    _SegmentState state,
    int count,
    Map<String, String> references, {
    required bool sealed,
  }) async {
    final start = state.cursor;
    final chunks = store.segmentationChunks(
      sessionId,
      spanId,
      source,
      afterSample: start,
      limit: 32,
    );
    final result = Int16List(count);
    var position = start, written = 0;
    var captureEnd = state.lastCaptureEndUs,
        uncertainty = state.lastClockUncertaintyUs;
    for (final chunk in chunks) {
      if (chunk.sampleStart > position) {
        throw AudioSegmentationUnavailable(
          'Source sample gap before committed audio',
        );
      }
      if (chunk.state == AudioChunkState.reserved) {
        if (sealed) {
          throw AudioSegmentationUnavailable(
            'Sealed source still has unpublished audio',
          );
        }
        return null;
      }
      if (chunk.state != AudioChunkState.published) {
        throw AudioSegmentationUnavailable('Saved source audio is unavailable');
      }
      if (chunk.sampleRate != AudioSegmentationSettings.sampleRate ||
          chunk.channels != 1) {
        throw AudioSegmentationUnavailable(
          'Saved source format is not canonical PCM',
        );
      }
      final offset = position - chunk.sampleStart;
      if (offset == 0 &&
          chunk.gapBefore &&
          chunk.sampleStart != state.boundaryStart) {
        return _PcmWindow(
          Int16List.sublistView(result, 0, written),
          captureEndUs: captureEnd,
          uncertaintyUs: uncertainty,
          gapBefore: written == 0,
          gapAfter: written > 0,
        );
      }
      final captureStart =
          chunk.captureStartUs + offset * 1000000 ~/ chunk.sampleRate;
      final observed = store
          .sourceClockAt(spanId, source, captureStart)
          ?.uncertaintyUs;
      // A known measured uncertainty plus canonical frame-rounding can qualify
      // continuity. Unknown quality is never replaced with a physical bound;
      // the native durable gap flag remains authoritative in that case.
      if (offset == 0 &&
          captureEnd != null &&
          uncertainty != null &&
          observed != null &&
          (captureStart - captureEnd).abs() > uncertainty + observed + 23) {
        throw AudioSegmentationUnavailable(
          'Unflagged source clock discontinuity exceeds measured uncertainty',
        );
      }
      final frames = min(count - written, chunk.sampleCount - offset);
      if (frames <= 0) continue;
      references.putIfAbsent(
        chunk.id,
        () => store.acquireReference(
          '${chunk.id}.raw',
          ownerGeneration: ownerGeneration,
          purpose: 'segmentation:$spanId:${source.name}',
        ),
      );
      final bytes = await readPcm(
        chunk,
        frameOffset: offset,
        frameCount: frames,
      );
      if (bytes.length != frames) {
        throw AudioSegmentationUnavailable(
          'Published PCM window has an invalid extent',
        );
      }
      result.setRange(written, written + frames, bytes);
      written += frames;
      position += frames;
      captureEnd =
          chunk.captureStartUs +
          (offset + frames) * 1000000 ~/ chunk.sampleRate;
      uncertainty = observed;
      if (written == count) {
        return _PcmWindow(
          result,
          captureEndUs: captureEnd,
          uncertaintyUs: uncertainty,
        );
      }
    }
    throw AudioSegmentationUnavailable(
      'Source range has missing or excessively fragmented audio',
    );
  }

  AudioAsrRange _range(
    String sessionId,
    String spanId,
    AudioSource source,
    String modelRevision,
    AudioSegmentationSettings settings,
    int first,
    int start,
    int end,
  ) {
    final inputStart = max(first, start - settings.overlapSamples);
    final digest = crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sessionId,
              spanId,
              source.name,
              inputStart,
              end,
              start,
              end,
              modelRevision,
              settings.revision,
            ]),
          ),
        )
        .toString()
        .substring(0, 32);
    final id =
        '${digest.substring(0, 8)}-${digest.substring(8, 12)}-${digest.substring(12, 16)}-${digest.substring(16, 20)}-${digest.substring(20)}';
    return AudioAsrRange(
      id: id,
      sampleStart: inputStart,
      sampleEnd: end,
      ownedStart: start,
      ownedEnd: end,
    );
  }

  void _consume(
    _SegmentState state,
    Int16List pcm,
    AudioSegmentationSettings settings,
    int first,
    void Function(int start, int end) emit,
  ) {
    final start = state.cursor, end = start + pcm.length;
    var squares = 0;
    for (final sample in pcm) {
      squares += sample * sample;
    }
    final rms = sqrt(squares / pcm.length) / 32768;
    if (rms > settings.rmsThreshold) {
      state.ownedStart ??= max(
        state.previousOwnedEnd,
        max(first, start - AudioSegmentationSettings.preRollSamples),
      );
      state.lastVoiceEnd = end;
    }
    state.cursor = end;
    if (state.ownedStart == null) return;
    state.recent.add(_EnergyWindow(start, end, rms));
    if (state.recent.length > 3) state.recent.removeAt(0);
    final owned = state.ownedStart!;
    if (end - state.lastVoiceEnd >=
        AudioSegmentationSettings.trailingSilenceSamples) {
      emit(owned, end);
      state.previousOwnedEnd = end;
      state.ownedStart = null;
      state.recent.clear();
      return;
    }
    if (end - owned >= AudioSegmentationSettings.maximumOwnedSamples) {
      final maximum = owned + AudioSegmentationSettings.maximumOwnedSamples;
      final candidates =
          state.recent
              .where(
                (window) =>
                    window.start >=
                        maximum - 2 * AudioSegmentationSettings.windowSamples &&
                    window.start > owned &&
                    window.end <= maximum,
              )
              .toList()
            ..sort((a, b) {
              final energy = a.rms.compareTo(b.rms);
              return energy != 0 ? energy : a.start.compareTo(b.start);
            });
      final cut = candidates.isEmpty ? maximum : candidates.first.start;
      emit(owned, cut);
      state.previousOwnedEnd = cut;
      state.ownedStart = cut;
      state.recent.removeWhere((window) => window.end <= cut);
    }
  }
}

final class _PcmWindow {
  const _PcmWindow(
    this.samples, {
    this.captureEndUs,
    this.uncertaintyUs,
    this.gapBefore = false,
    this.gapAfter = false,
  });
  final Int16List samples;
  final int? captureEndUs, uncertaintyUs;
  final bool gapBefore, gapAfter;
}

final class _EnergyWindow {
  const _EnergyWindow(this.start, this.end, this.rms);
  final int start, end;
  final double rms;
  List<Object> toJson() => [start, end, rms];
}

final class _SegmentState {
  _SegmentState({
    required this.cursor,
    required this.previousOwnedEnd,
    required this.lastVoiceEnd,
    this.ownedStart,
    this.lastCaptureEndUs,
    this.lastClockUncertaintyUs,
    int? boundaryStart,
    List<_EnergyWindow>? recent,
  }) : boundaryStart = boundaryStart ?? previousOwnedEnd,
       recent = recent ?? [];
  int cursor, previousOwnedEnd, lastVoiceEnd, boundaryStart;
  int? ownedStart, lastCaptureEndUs, lastClockUncertaintyUs;
  final List<_EnergyWindow> recent;

  static _SegmentState decode(AudioSegmentationCursor expected, int first) {
    if (expected.context.isEmpty) {
      if (expected.cursorSample != first) {
        throw StateError('Durable segmentation context was lost');
      }
      return _SegmentState(
        cursor: expected.cursorSample,
        previousOwnedEnd: first,
        lastVoiceEnd: first,
      );
    }
    try {
      if (expected.context.length > 4096) throw const FormatException();
      final map =
          jsonDecode(utf8.decode(expected.context)) as Map<String, dynamic>;
      if (map['version'] != 1 || map['cursor'] != expected.cursorSample) {
        throw const FormatException();
      }
      final state = _SegmentState(
        cursor: map['cursor'] as int,
        previousOwnedEnd: map['previous_owned_end'] as int,
        lastVoiceEnd: map['last_voice_end'] as int,
        ownedStart: map['owned_start'] as int?,
        boundaryStart: map['boundary_start'] as int,
        lastCaptureEndUs: map['last_capture_end_us'] as int?,
        lastClockUncertaintyUs: map['last_clock_uncertainty_us'] as int?,
      );
      final recent = map['recent'] as List;
      if (recent.length > 3 ||
          state.boundaryStart < first ||
          state.boundaryStart > state.cursor ||
          (state.lastCaptureEndUs != null && state.lastCaptureEndUs! < 0) ||
          (state.lastClockUncertaintyUs != null &&
              state.lastClockUncertaintyUs! < 0) ||
          state.previousOwnedEnd < first ||
          state.previousOwnedEnd > state.cursor ||
          state.lastVoiceEnd < first ||
          state.lastVoiceEnd > state.cursor ||
          (state.ownedStart != null &&
              (state.ownedStart! < state.previousOwnedEnd ||
                  state.ownedStart! > state.cursor))) {
        throw const FormatException();
      }
      for (final raw in recent) {
        final value = raw as List;
        final start = value[0] as int,
            end = value[1] as int,
            rms = (value[2] as num).toDouble();
        if (value.length != 3 ||
            start < first ||
            end <= start ||
            end > state.cursor ||
            !rms.isFinite ||
            rms < 0 ||
            rms > 1) {
          throw const FormatException();
        }
        state.recent.add(_EnergyWindow(start, end, rms));
      }
      return state;
    } catch (_) {
      throw StateError('Durable segmentation context is invalid');
    }
  }

  List<int> encode(AudioSegmentationSettings settings) => utf8.encode(
    jsonEncode({
      'version': 1,
      'settings': settings._configuration,
      'cursor': cursor,
      'previous_owned_end': previousOwnedEnd,
      'last_voice_end': lastVoiceEnd,
      'owned_start': ownedStart,
      'boundary_start': boundaryStart,
      'last_capture_end_us': lastCaptureEndUs,
      'last_clock_uncertainty_us': lastClockUncertaintyUs,
      'recent': recent.map((window) => window.toJson()).toList(),
    }),
  );
}
