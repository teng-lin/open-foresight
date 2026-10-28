import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'package:sqlite3/sqlite3.dart';

/// Invalid acquisition geometry never authorizes moving a source to hide an
/// outage. Original representations remain available for recovery/export.
final class AudioPlaybackTimelineError extends StateError {
  AudioPlaybackTimelineError(super.message);
}

final class AudioPlaybackSpan {
  const AudioPlaybackSpan({
    required this.id,
    required this.ordinal,
    required this.captureStartUs,
    required this.startFrame,
    required this.frameCount,
    required this.closed,
  });
  final String id;
  final int ordinal, captureStartUs, startFrame, frameCount;
  final bool closed;
}

final class AudioPlaybackChunk {
  const AudioPlaybackChunk(this.startFrame, this.frameCount);
  final int startFrame, frameCount;
}

/// Derived span extents only: no list of chunks, paths or decoded meeting PCM.
final class AudioPlaybackTimeline {
  AudioPlaybackTimeline._(List<AudioPlaybackSpan> spans, this.totalFrames)
    : spans = List.unmodifiable(spans),
      _byId = Map.unmodifiable({for (final span in spans) span.id: span});
  static const revision = 'shared-spans-sample-exact-v2';
  static const sampleRate = 48000;
  static const maximumFrames = 48000 * 86400;
  static const maximumCaptureDurationUs = 86400 * 1000000 + 21;
  static const maximumRows = 131072;
  static int frozenFrames(String settings) {
    final value = jsonDecode(settings);
    if (value is! Map<String, dynamic> ||
        value['timeline_revision'] != revision ||
        value['timeline_frames'] is! int ||
        value['timeline_frames'] < 1 ||
        value['timeline_frames'] > maximumFrames) {
      throw AudioPlaybackTimelineError('Unsupported frozen sample timeline');
    }
    return value['timeline_frames'] as int;
  }

  static String chunkIdentity(
    Map<String, Object?> row,
    int startFrame,
    int frames,
  ) => crypto.sha256
      .convert(
        utf8.encode(
          jsonEncode([
            revision,
            startFrame,
            frames,
            for (final key in [
              'id',
              'session_id',
              'storage_generation',
              'span_id',
              'source',
              'sequence',
              'sample_start',
              'sample_count',
              'sample_rate',
              'channels',
              'capture_start_us',
              'capture_end_us',
              'gap_before',
              'interrupted',
              'ordinal',
              'span_start',
              'span_end',
              'playback_start_us',
              'playback_end_us',
            ])
              row[key],
          ]),
        ),
      )
      .toString();

  final List<AudioPlaybackSpan> spans;
  final Map<String, AudioPlaybackSpan> _byId;
  final int totalFrames;
  AudioPlaybackSpan span(String id) =>
      _byId[id] ?? (throw AudioPlaybackTimelineError('Unknown audio span'));
  AudioPlaybackCursor cursor() => AudioPlaybackCursor._(this);
}

/// Two bounded run cursors, driven in source/span/sequence order. An acquisition
/// anchor is quantized once per continuous run; later chunks use exact samples.
final class AudioPlaybackCursor {
  AudioPlaybackCursor._(this.timeline);
  final AudioPlaybackTimeline timeline;
  final _runs = <String, _Run>{};
  AudioPlaybackChunk accept(Map<String, Object?> row) {
    final span = timeline.span(row['span_id'] as String);
    final source = row['source'] as String;
    if (source != 'microphone' && source != 'playback') {
      throw AudioPlaybackTimelineError('Invalid captured audio source');
    }
    final run = _runs.putIfAbsent(source, _Run.new);
    final local = run.accept(row, span.captureStartUs);
    final count = row['sample_count'] as int;
    if (local + count > span.frameCount) {
      throw AudioPlaybackTimelineError('Captured samples exceed shared span');
    }
    return AudioPlaybackChunk(span.startFrame + local, count);
  }
}

final class _Run {
  String? span;
  int sequence = -1, sampleEnd = 0, frameEnd = 0, captureStart = 0;
  int anchorSample = 0, anchorFrame = 0;
  int accept(Map<String, Object?> row, int spanStart) {
    final id = row['span_id'] as String;
    final first = span != id;
    final nextSequence = row['sequence'] as int;
    final sample = row['sample_start'] as int;
    final count = row['sample_count'] as int;
    final capture = row['capture_start_us'] as int;
    final captureEnd = row['capture_end_us'] as int;
    final gap = row['gap_before'] == 1;
    if (count < 1 ||
        count > 240000 ||
        sample < 0 ||
        sample > 0x7fffffffffffffff - count ||
        nextSequence < 0 ||
        row['sample_rate'] != 48000 ||
        row['channels'] != 1 ||
        capture < spanStart ||
        capture - spanStart > AudioPlaybackTimeline.maximumCaptureDurationUs ||
        captureEnd < capture ||
        !first &&
            (nextSequence <= sequence ||
                sample < sampleEnd ||
                capture < captureStart)) {
      throw AudioPlaybackTimelineError('Invalid acquired sample geometry');
    }
    final boundary = first || gap || sample != sampleEnd;
    if (boundary) {
      final next = (capture - spanStart) * 48000 ~/ 1000000;
      if (!first &&
          (next < frameEnd ||
              (gap || sample != sampleEnd) && next == frameEnd)) {
        throw AudioPlaybackTimelineError(
          'Acquisition runs overlap or hide an audio gap',
        );
      }
      anchorSample = sample;
      anchorFrame = next;
    }
    final start = anchorFrame + (sample - anchorSample);
    if (start < 0 || start + count > AudioPlaybackTimeline.maximumFrames) {
      throw AudioPlaybackTimelineError(
        'Captured audio exceeds timeline bounds',
      );
    }
    span = id;
    sequence = nextSequence;
    captureStart = capture;
    sampleEnd = sample + count;
    frameEnd = start + count;
    return start;
  }
}

final class _Span {
  _Span(this.id, this.ordinal, this.captureStart, this.closed, this.frames);
  final String id;
  final int ordinal, captureStart;
  final bool closed;
  int frames;
}

/// Metadata planner shared by duration, transcript links and frozen codec jobs.
/// SQL pages are at most128 rows; missing/quarantined acquired chunks participate
/// in geometry while metadata-only reservations never do. A separate scalar LRU
/// keeps long-session duration polling cheap even when a span plan exceeds the
/// bounded geometry cache.
final class AudioPlaybackTimelinePlanner {
  static final _databases = Expando<AudioPlaybackTimelinePlanner>();
  static AudioPlaybackTimelinePlanner forDatabase(Database database) =>
      _databases[database] ??= AudioPlaybackTimelinePlanner(database);
  AudioPlaybackTimelinePlanner(
    this.db, {
    this.maximumCachedPlans = 4,
    this.maximumCachedSpans = 8192,
    this.maximumCachedDurations = 256,
  });
  final Database db;
  final int maximumCachedPlans, maximumCachedSpans, maximumCachedDurations;
  final _plans = <String, (String, AudioPlaybackTimeline)>{};
  final _durations = <String, (String, int)>{};
  int _cachedSpans = 0;

  String _fingerprint(String session, String authority) {
    final row = db
        .select(
          '''SELECT storage_generation,workspace_epoch,
      (SELECT generation FROM audio_storage_generation WHERE singleton=1) AS current_generation,
      p.spans,p.ordinal,p.span_end,p.span_ends,c.chunks,c.mic,c.playback,c.samples
      FROM recording_sessions s
      CROSS JOIN(SELECT COUNT(*) AS spans,MAX(ordinal) AS ordinal,MAX(capture_end_us) AS span_end,
        SUM(COALESCE(capture_end_us,0)) AS span_ends FROM recording_spans WHERE session_id=?) p
      CROSS JOIN(SELECT COUNT(*) AS chunks,
        MAX(CASE WHEN source='microphone' THEN sequence END) AS mic,
        MAX(CASE WHEN source='playback' THEN sequence END) AS playback,SUM(sample_count) AS samples
        FROM audio_chunks WHERE session_id=? AND state!='reserved') c
      WHERE s.id=?''',
          [session, session, session],
        )
        .firstOrNull;
    if (row == null) {
      throw AudioPlaybackTimelineError('Recording no longer exists');
    }
    return jsonEncode([authority, ...row.values]);
  }

  int durationFrames(String session, {String authority = ''}) {
    final fingerprint = _fingerprint(session, authority);
    final previous = _durations.remove(session);
    if (previous != null && previous.$1 == fingerprint) {
      _durations[session] = previous;
      return previous.$2;
    }
    return _resolve(session, fingerprint).totalFrames;
  }

  AudioPlaybackTimeline resolve(String session, {String authority = ''}) =>
      _resolve(session, _fingerprint(session, authority));

  AudioPlaybackTimeline _resolve(String session, String fingerprint) {
    final previous = _plans.remove(session);
    if (previous != null) {
      _cachedSpans -= previous.$2.spans.length;
      if (previous.$1 == fingerprint) {
        _plans[session] = previous;
        _cachedSpans += previous.$2.spans.length;
        _rememberDuration(session, fingerprint, previous.$2.totalFrames);
        return previous.$2;
      }
    }
    final spans = <_Span>[];
    var after = -1;
    while (true) {
      final page = db.select(
        '''SELECT id,ordinal,capture_start_us,capture_end_us
        FROM recording_spans WHERE session_id=? AND ordinal>? ORDER BY ordinal LIMIT 128''',
        [session, after],
      );
      if (page.isEmpty) break;
      for (final row in page) {
        final start = row['capture_start_us'] as int;
        final end = row['capture_end_us'] as int?;
        if (spans.length >= AudioPlaybackTimeline.maximumRows ||
            end != null &&
                (end < start ||
                    end - start >
                        AudioPlaybackTimeline.maximumCaptureDurationUs)) {
          throw AudioPlaybackTimelineError('Invalid shared audio span');
        }
        spans.add(
          _Span(
            row['id'] as String,
            row['ordinal'] as int,
            start,
            end != null,
            end == null ? 0 : (end - start) * 48000 ~/ 1000000,
          ),
        );
      }
      after = page.last['ordinal'] as int;
    }
    final byId = {for (final span in spans) span.id: span};
    final runs = <String, _Run>{};
    var rows = 0;
    for (final row in acquiredChunks(session)) {
      if (++rows > AudioPlaybackTimeline.maximumRows) {
        throw AudioPlaybackTimelineError('Too many captured audio chunks');
      }
      final span = byId[row['span_id']];
      if (span == null) {
        throw AudioPlaybackTimelineError('Captured span is missing');
      }
      final source = row['source'] as String;
      if (source != 'microphone' && source != 'playback') {
        throw AudioPlaybackTimelineError('Invalid captured audio source');
      }
      final end =
          runs.putIfAbsent(source, _Run.new).accept(row, span.captureStart) +
          (row['sample_count'] as int);
      if (end > span.frames) span.frames = end;
    }
    var total = 0;
    final result = <AudioPlaybackSpan>[];
    for (final span in spans) {
      if (span.frames < 0 ||
          total + span.frames > AudioPlaybackTimeline.maximumFrames) {
        throw AudioPlaybackTimelineError(
          'Recording exceeds 24 hour playback bounds',
        );
      }
      result.add(
        AudioPlaybackSpan(
          id: span.id,
          ordinal: span.ordinal,
          captureStartUs: span.captureStart,
          startFrame: total,
          frameCount: span.frames,
          closed: span.closed,
        ),
      );
      total += span.frames;
    }
    final plan = AudioPlaybackTimeline._(result, total);
    _rememberDuration(session, fingerprint, total);
    if (maximumCachedPlans > 0 && plan.spans.length <= maximumCachedSpans) {
      while (_plans.isNotEmpty &&
          (_plans.length >= maximumCachedPlans ||
              _cachedSpans + plan.spans.length > maximumCachedSpans)) {
        _cachedSpans -= _plans.remove(_plans.keys.first)!.$2.spans.length;
      }
      _plans[session] = (fingerprint, plan);
      _cachedSpans += plan.spans.length;
    }
    return plan;
  }

  void _rememberDuration(String session, String fingerprint, int frames) {
    _durations.remove(session);
    if (maximumCachedDurations <= 0) return;
    while (_durations.length >= maximumCachedDurations) {
      _durations.remove(_durations.keys.first);
    }
    _durations[session] = (fingerprint, frames);
  }

  Iterable<Map<String, Object?>> acquiredChunks(String session) sync* {
    var source = '', ordinal = -1, sequence = -1;
    while (true) {
      final page = db.select(
        '''SELECT c.*,s.ordinal,s.capture_start_us AS span_start,s.capture_end_us AS span_end,
        s.playback_start_us,s.playback_end_us FROM audio_chunks c
        JOIN recording_spans s ON s.id=c.span_id
        WHERE c.session_id=? AND c.state!='reserved' AND
        (c.source>? OR(c.source=? AND(s.ordinal>? OR(s.ordinal=? AND c.sequence>?))))
        ORDER BY c.source,s.ordinal,c.sequence LIMIT 128''',
        [session, source, source, ordinal, ordinal, sequence],
      );
      if (page.isEmpty) return;
      for (final row in page) {
        yield row;
      }
      source = page.last['source'] as String;
      ordinal = page.last['ordinal'] as int;
      sequence = page.last['sequence'] as int;
    }
  }

  AudioPlaybackChunk? chunk(
    String session,
    String chunkId, {
    String authority = '',
  }) {
    final cursor = resolve(session, authority: authority).cursor();
    for (final row in acquiredChunks(session)) {
      final position = cursor.accept(row);
      if (row['id'] == chunkId) return position;
    }
    return null;
  }
}
