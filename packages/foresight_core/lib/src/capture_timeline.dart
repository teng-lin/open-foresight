/// Maps each capture channel's sample counter onto the monotonic capture clock.
///
/// Transcript times remain derived from sample counts, which exclude capture
/// gaps; this timeline never changes them. It answers a different question:
/// when, on the monotonic clock, were the samples of a transcript segment
/// captured. Clock-domain conversion for observer timestamps is the observer's
/// job; every value here is microseconds on the capture clock.
library;

import 'dart:math' as math;

import 'audio_models.dart';

/// A contiguous stretch of one range's samples and the monotonic time it spans.
final class MappedAudioPiece {
  const MappedAudioPiece({
    required this.sampleStart,
    required this.sampleEnd,
    required this.startUs,
    required this.endUs,
  });
  final int sampleStart, sampleEnd, startUs, endUs;
}

/// A sample range placed on the monotonic clock.
final class MappedAudioRange {
  MappedAudioRange({
    required this.source,
    required this.sampleStart,
    required this.sampleEnd,
    required List<MappedAudioPiece> pieces,
    required this.uncertaintyUs,
    required this.gapUs,
    required this.hasDiscontinuity,
    required this.crossesRateChange,
  }) : pieces = List.unmodifiable(pieces);
  final AudioSource source;
  final int sampleStart, sampleEnd;
  final List<MappedAudioPiece> pieces;

  /// Worst timing error among the runs the range touches: timestamp drift,
  /// anchor imprecision and monotonic clamping.
  final int uncertaintyUs;

  /// Captured-clock time inside the range during which no samples exist.
  final int gapUs;

  /// A pause, device recovery, dropped audio or timestamp jump lies inside the
  /// range, so its samples are not one continuous stretch of time.
  final bool hasDiscontinuity;
  final bool crossesRateChange;

  int get startUs => pieces.first.startUs;
  int get endUs => pieces.last.endUs;
}

final class _Run {
  _Run({
    required this.sampleStart,
    required this.sampleCount,
    required this.sampleRate,
    required this.startUs,
    required this.durationUs,
    required this.uncertaintyUs,
    required this.discontinuousBefore,
    required this.gapBeforeUs,
  });
  final int sampleStart, sampleCount, sampleRate, startUs, durationUs;
  final int uncertaintyUs, gapBeforeUs;
  final bool discontinuousBefore;
  int get sampleEnd => sampleStart + sampleCount;
  int get endUs => startUs + durationUs;
  int timeAt(int sample) =>
      startUs +
      (sample - sampleStart) * Duration.microsecondsPerSecond ~/ sampleRate;
}

/// Why a sample range could not be placed on the monotonic clock.
enum TimelineMiss {
  /// No run was ever recorded for the channel.
  unknownSource,

  /// The range starts before the oldest retained run: trimmed or released.
  trimmed,

  /// The range lies beyond the newest recorded sample.
  notYetCaptured,

  /// A hole in the sample counter lies inside the range.
  sampleGap,

  /// The sample counter restarted after the caller captured the range, so its
  /// numbers now belong to different audio.
  counterReset,
}

typedef TimelineMapOutcome = ({MappedAudioRange? range, TimelineMiss? miss});

/// Result of recording a run.
enum CaptureRunResult {
  added,

  /// The sample counter went backward (device recovery restarted it). Earlier
  /// runs would alias the new counter values, so they were discarded.
  counterReset,
}

final class _Channel {
  final List<_Run> runs = [];
  int head = 0;
  int resets = 0;

  /// The highest sample ever recorded, kept when history is released so that a
  /// counter reset is still recognised once every run is gone.
  int maxSampleEnd = 0;
  bool recorded = false;
  bool pendingDiscontinuity = false;

  int get length => runs.length - head;
  _Run? get last => length == 0 ? null : runs.last;

  void dropHead(int count) {
    head += count;
    if (head > 1024 && head > runs.length ~/ 2) {
      runs.removeRange(0, head);
      head = 0;
    }
  }

  /// Index of the run holding [sample], or -1.
  int find(int sample) {
    var low = head, high = runs.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final run = runs[mid];
      if (sample < run.sampleStart) {
        high = mid - 1;
      } else if (sample >= run.sampleEnd) {
        low = mid + 1;
      } else {
        return mid;
      }
    }
    return -1;
  }
}

final class CaptureTimeline {
  CaptureTimeline({
    this.maxRunsPerChannel = 32768,
    this.jitterToleranceUs = 50000,
  }) {
    if (maxRunsPerChannel < 1 || jitterToleranceUs < 0) {
      throw ArgumentError('Invalid capture timeline bounds');
    }
  }

  /// Oldest runs are dropped beyond this; their samples then stop mapping.
  final int maxRunsPerChannel;

  /// A start later than the previous run's end by more than this is a gap.
  final int jitterToleranceUs;
  final Map<AudioSource, _Channel> _channels = {};

  _Channel _channel(AudioSource source) =>
      _channels.putIfAbsent(source, _Channel.new);

  /// Record that [sampleCount] samples starting at counter [sampleStart] were
  /// captured over [startUs, endUs] on the monotonic clock. [uncertaintyUs] is
  /// the anchor's own imprecision. Runs arrive in increasing sample order.
  CaptureRunResult addRun(
    AudioSource source, {
    required int sampleStart,
    required int sampleCount,
    required int sampleRate,
    required int startUs,
    required int endUs,
    bool discontinuousBefore = false,
    int uncertaintyUs = 0,
  }) {
    if (sampleStart < 0 ||
        sampleCount < 1 ||
        sampleRate < 1 ||
        startUs < 0 ||
        endUs < startUs ||
        uncertaintyUs < 0) {
      throw ArgumentError('Invalid capture run');
    }
    final channel = _channel(source);
    channel.recorded = true;
    var previous = channel.last;
    var result = CaptureRunResult.added;
    if (sampleStart < channel.maxSampleEnd) {
      // Never throw into the capture path: forget what the counter now aliases.
      channel.runs.clear();
      channel
        ..head = 0
        ..resets += 1
        ..maxSampleEnd = 0
        ..pendingDiscontinuity = false;
      previous = null;
      result = CaptureRunResult.counterReset;
    }
    final durationUs =
        sampleCount * Duration.microsecondsPerSecond ~/ sampleRate;
    var effectiveStart = startUs, overlap = 0, gap = 0;
    var discontinuous = false;
    if (previous != null) {
      if (effectiveStart < previous.endUs) {
        overlap = previous.endUs - effectiveStart;
        effectiveStart = previous.endUs;
      }
      gap = effectiveStart - previous.endUs;
      discontinuous =
          discontinuousBefore ||
          channel.pendingDiscontinuity ||
          gap > jitterToleranceUs ||
          sampleStart != previous.sampleEnd;
    }
    channel.pendingDiscontinuity = false;
    final drift = ((endUs - startUs) - durationUs).abs();
    channel.runs.add(
      _Run(
        sampleStart: sampleStart,
        sampleCount: sampleCount,
        sampleRate: sampleRate,
        startUs: effectiveStart,
        durationUs: durationUs,
        uncertaintyUs:
            uncertaintyUs + drift + overlap + (discontinuous ? 0 : gap),
        discontinuousBefore: discontinuous,
        gapBeforeUs: discontinuous ? gap : 0,
      ),
    );
    channel.maxSampleEnd = sampleStart + sampleCount;
    final excess = channel.length - maxRunsPerChannel;
    if (excess > 0) channel.dropHead(excess);
    return result;
  }

  /// A published durable chunk is a run with its own capture timestamps.
  CaptureRunResult addChunk(AudioChunk chunk, {int uncertaintyUs = 0}) =>
      addRun(
        chunk.source,
        sampleStart: chunk.sampleStart,
        sampleCount: chunk.sampleCount,
        sampleRate: chunk.sampleRate,
        startUs: chunk.captureStartUs,
        endUs: chunk.captureEndUs,
        discontinuousBefore: chunk.gapBefore,
        uncertaintyUs: uncertaintyUs,
      );

  /// A native PCM event stamped when its frame was emitted. Emission follows
  /// capture by an unknown buffering delay, so the event is treated as the end
  /// of its samples and [uncertaintyUs] must cover that delay.
  CaptureRunResult addEmission(
    AudioSource source, {
    required int sampleStart,
    required int sampleCount,
    required int sampleRate,
    required int emittedUs,
    required int uncertaintyUs,
  }) {
    final duration =
        sampleCount * Duration.microsecondsPerSecond ~/ math.max(1, sampleRate);
    return addRun(
      source,
      sampleStart: sampleStart,
      sampleCount: sampleCount,
      sampleRate: sampleRate,
      startUs: math.max(0, emittedUs - duration),
      endUs: emittedUs,
      uncertaintyUs: uncertaintyUs,
    );
  }

  /// The next run follows a pause, device recovery, overflow or dropped frames.
  void markDiscontinuity(AudioSource source) {
    _channel(source).pendingDiscontinuity = true;
  }

  /// Forget runs that end at or before [sample] once no queued work needs them.
  void releaseBefore(AudioSource source, int sample) {
    final channel = _channels[source];
    if (channel == null) return;
    var drop = 0;
    while (drop < channel.length &&
        channel.runs[channel.head + drop].sampleEnd <= sample) {
      drop++;
    }
    if (drop > 0) channel.dropHead(drop);
  }

  /// Forget every run. Ranges recorded earlier no longer exist: each channel's
  /// generation advances, and generations never go back for the timeline's life.
  void clear() {
    for (final channel in _channels.values) {
      channel.runs.clear();
      channel
        ..head = 0
        ..resets += 1
        ..maxSampleEnd = 0
        ..pendingDiscontinuity = false;
    }
  }

  /// How many times the channel's sample counter restarted.
  int counterResets(AudioSource source) => _channels[source]?.resets ?? 0;

  /// The counter generation a sample range belongs to. Record it when a range
  /// is captured (for example when speech is queued for recognition) and pass
  /// it back to [mapOutcome], so that after a reset the old numbers never map
  /// onto the new audio.
  int generation(AudioSource source) => counterResets(source);

  int runCount(AudioSource source) => _channels[source]?.length ?? 0;

  int? oldestSample(AudioSource source) {
    final channel = _channels[source];
    return channel == null || channel.length == 0
        ? null
        : channel.runs[channel.head].sampleStart;
  }

  int? endSample(AudioSource source) => _channels[source]?.last?.sampleEnd;

  /// Places [sampleStart, sampleEnd) on the monotonic clock, or null when any of
  /// it is outside the retained history ([mapOutcome] says why).
  MappedAudioRange? map(
    AudioSource source, {
    required int sampleStart,
    required int sampleEnd,
    int? generation,
  }) => mapOutcome(
    source,
    sampleStart: sampleStart,
    sampleEnd: sampleEnd,
    generation: generation,
  ).range;

  /// With [generation] the range is only placed if the counter has not been
  /// reset since the caller recorded it; null accepts the current generation.
  TimelineMapOutcome mapOutcome(
    AudioSource source, {
    required int sampleStart,
    required int sampleEnd,
    int? generation,
  }) {
    if (sampleStart < 0 || sampleEnd <= sampleStart) {
      throw ArgumentError('Invalid sample range');
    }
    if (generation != null && generation != this.generation(source)) {
      return (range: null, miss: TimelineMiss.counterReset);
    }
    final channel = _channels[source];
    if (channel == null || !channel.recorded) {
      return (range: null, miss: TimelineMiss.unknownSource);
    }
    if (channel.length == 0) {
      return (range: null, miss: TimelineMiss.trimmed);
    }
    if (sampleStart < channel.runs[channel.head].sampleStart) {
      return (range: null, miss: TimelineMiss.trimmed);
    }
    if (sampleStart >= channel.last!.sampleEnd) {
      return (range: null, miss: TimelineMiss.notYetCaptured);
    }
    var index = channel.find(sampleStart);
    if (index < 0) return (range: null, miss: TimelineMiss.sampleGap);
    final pieces = <MappedAudioPiece>[];
    var uncertainty = 0, gap = 0;
    var discontinuity = false, rateChange = false;
    int? rate;
    var cursor = sampleStart;
    while (cursor < sampleEnd) {
      if (index >= channel.runs.length) {
        return (range: null, miss: TimelineMiss.notYetCaptured);
      }
      final run = channel.runs[index];
      if (run.sampleStart != cursor && pieces.isNotEmpty) {
        return (range: null, miss: TimelineMiss.sampleGap);
      }
      if (pieces.isNotEmpty) {
        if (run.discontinuousBefore) {
          discontinuity = true;
          gap += run.gapBeforeUs;
        }
        if (run.sampleRate != rate) rateChange = true;
      }
      rate = run.sampleRate;
      final end = math.min(sampleEnd, run.sampleEnd);
      pieces.add(
        MappedAudioPiece(
          sampleStart: cursor,
          sampleEnd: end,
          startUs: run.timeAt(cursor),
          endUs: run.timeAt(end),
        ),
      );
      uncertainty = math.max(uncertainty, run.uncertaintyUs);
      cursor = end;
      index++;
    }
    return (
      range: MappedAudioRange(
        source: source,
        sampleStart: sampleStart,
        sampleEnd: sampleEnd,
        pieces: pieces,
        uncertaintyUs: uncertainty,
        gapUs: gap,
        hasDiscontinuity: discontinuity,
        crossesRateChange: rateChange,
      ),
      miss: null,
    );
  }
}
