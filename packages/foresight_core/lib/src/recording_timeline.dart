/// A closed interval of active acquisition, relative to a monotonic session
/// origin. Intentional pauses lie between spans; source outages remain inside
/// spans so microphone and playback never compact their timelines separately.
final class RecordingTimeSpan {
  RecordingTimeSpan(this.id, this.startUs, this.endUs) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
    RangeError.checkNotNegative(startUs, 'startUs');
    if (endUs <= startUs) {
      throw ArgumentError('A recording span must have positive duration');
    }
  }

  final String id;
  final int startUs, endUs;
  int get durationUs => endUs - startUs;
}

/// One contiguous part of a requested playback range. Empty intentional pauses
/// are never returned. A mixer uses these shared ranges for every source.
final class RecordingTimelineSlice {
  const RecordingTimelineSlice({
    required this.spanId,
    required this.sessionStartUs,
    required this.sessionEndUs,
    required this.playbackStartUs,
  });

  final String spanId;
  final int sessionStartUs, sessionEndUs, playbackStartUs;
  int get durationUs => sessionEndUs - sessionStartUs;
}

/// Maps closed active spans to a compact playback clock. Inputs are immutable
/// snapshots; an open capture span is closed at the snapshot's acquired extent.
/// Time ranges are half-open, with the final endpoint accepted for seek-to-end.
final class RecordingTimeline {
  RecordingTimeline(Iterable<RecordingTimeSpan> spans)
    : spans = List.unmodifiable(spans) {
    var total = 0;
    RecordingTimeSpan? previous;
    final ids = <String>{};
    for (final span in this.spans) {
      if (!ids.add(span.id)) throw ArgumentError('Duplicate recording span');
      if (previous != null && previous.endUs > span.startUs) {
        throw ArgumentError('Recording spans overlap or are out of order');
      }
      _playbackStarts.add(total);
      total += span.durationUs;
      previous = span;
    }
    durationUs = total;
  }

  final List<RecordingTimeSpan> spans;
  final _playbackStarts = <int>[];
  late final int durationUs;

  int? playbackForSession(int sessionUs) {
    if (spans.isEmpty || sessionUs < spans.first.startUs) return null;
    if (sessionUs == spans.last.endUs) return durationUs;
    final index = _floorIndex(spans.length, (i) => spans[i].startUs, sessionUs);
    if (index < 0 || sessionUs >= spans[index].endUs) return null;
    return _playbackStarts[index] + sessionUs - spans[index].startUs;
  }

  int? sessionForPlayback(int playbackUs) {
    if (spans.isEmpty || playbackUs < 0 || playbackUs > durationUs) return null;
    if (playbackUs == durationUs) return spans.last.endUs;
    final index = _floorIndex(
      spans.length,
      (i) => _playbackStarts[i],
      playbackUs,
    );
    return spans[index].startUs + playbackUs - _playbackStarts[index];
  }

  /// Splits a playback read across resume boundaries, without reading paused
  /// time or hiding an outage in just one source. Callers bound the requested
  /// range before allocating decoded PCM.
  List<RecordingTimelineSlice> slices(int startUs, int endUs) {
    RangeError.checkValueInInterval(startUs, 0, durationUs, 'startUs');
    RangeError.checkValueInInterval(endUs, startUs, durationUs, 'endUs');
    if (startUs == endUs) return const [];
    final result = <RecordingTimelineSlice>[];
    var index = _floorIndex(spans.length, (i) => _playbackStarts[i], startUs);
    while (index < spans.length && _playbackStarts[index] < endUs) {
      final span = spans[index];
      final playbackStart = startUs > _playbackStarts[index]
          ? startUs
          : _playbackStarts[index];
      final spanPlaybackEnd = _playbackStarts[index] + span.durationUs;
      final playbackEnd = endUs < spanPlaybackEnd ? endUs : spanPlaybackEnd;
      result.add(
        RecordingTimelineSlice(
          spanId: span.id,
          sessionStartUs: span.startUs + playbackStart - _playbackStarts[index],
          sessionEndUs: span.startUs + playbackEnd - _playbackStarts[index],
          playbackStartUs: playbackStart,
        ),
      );
      index++;
    }
    return List.unmodifiable(result);
  }
}

/// A source chunk's integer sample clock anchored to acquired session time.
/// Wall-clock timestamps and encoder delay must not be used as sample clocks.
/// A rate/route change creates another anchor; a missing source has no anchor.
final class RecordingSampleAnchor {
  RecordingSampleAnchor({
    required this.chunkId,
    required this.spanId,
    required this.source,
    required this.firstFrame,
    required this.frameCount,
    required this.sampleRate,
    required this.sessionStartUs,
  }) {
    if (chunkId.isEmpty || spanId.isEmpty || source.isEmpty) {
      throw ArgumentError('Recording sample identity is empty');
    }
    RangeError.checkNotNegative(firstFrame, 'firstFrame');
    RangeError.checkNotNegative(sessionStartUs, 'sessionStartUs');
    if (frameCount <= 0 || sampleRate <= 0 || sampleRate > 1000000) {
      throw ArgumentError('Invalid recording sample count or rate');
    }
  }

  final String chunkId, spanId, source;
  final int firstFrame, frameCount, sampleRate, sessionStartUs;
  int get lastFrameExclusive => firstFrame + frameCount;
  int get sessionEndUs => sessionStartUs + frameCount * 1000000 ~/ sampleRate;

  int? sessionForFrame(int frame) {
    if (frame < firstFrame || frame > lastFrameExclusive) return null;
    return sessionStartUs + (frame - firstFrame) * 1000000 ~/ sampleRate;
  }

  /// Returns the frame at or immediately preceding this microsecond position.
  /// Integer microseconds can round a frame boundary down by less than one
  /// frame; durable ASR identities retain exact sample offsets instead.
  int? frameForSession(int sessionUs) {
    if (sessionUs < sessionStartUs || sessionUs > sessionEndUs) return null;
    if (sessionUs == sessionEndUs) return lastFrameExclusive;
    return firstFrame + (sessionUs - sessionStartUs) * sampleRate ~/ 1000000;
  }
}

int _floorIndex(int count, int Function(int) value, int target) {
  var lower = 0, upper = count;
  while (lower < upper) {
    final middle = lower + (upper - lower) ~/ 2;
    if (value(middle) <= target) {
      lower = middle + 1;
    } else {
      upper = middle;
    }
  }
  return lower - 1;
}
