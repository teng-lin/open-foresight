/// Conservative joining of remote-channel audio intervals with observed
/// active-speaker history.
///
/// A segment is named only when its whole timing window, widened by audio
/// timing uncertainty, lies inside a period in which the same single
/// participant was certainly the only active speaker. Handovers, concurrent
/// speakers, observed silence, blind periods, stale or trimmed history, capture
/// discontinuities and the microphone channel all stay unattributed, each with
/// its own state. Nothing here logs, and decisions carry no transcript text.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'audio_models.dart';
import 'capture_timeline.dart';
import 'meeting_speaker_observer.dart';
import 'speaker_observation.dart';

const speakerAttributionPolicyVersion = 'attr-1';

enum AttributionState { named, unknown, multiple, stale, unavailable }

/// Tunable attribution inputs. Lag is the measured delay between speech and
/// its indicator, per evidence method; it is zero until measured.
final class SpeakerAttributionPolicy {
  const SpeakerAttributionPolicy({
    this.indicatorLagUs = const {},
    this.defaultLagUs = 0,
    this.boundaryMarginUs = 0,
    this.allowedMethods = const {
      SpeakerEvidenceMethod.participantStatus,
      SpeakerEvidenceMethod.compactTalkingLabel,
    },
  });
  final Map<SpeakerEvidenceMethod, int> indicatorLagUs;
  final int defaultLagUs, boundaryMarginUs;

  /// Evidence paths validated for the platform. Others never name anyone.
  final Set<SpeakerEvidenceMethod> allowedMethods;

  int lagFor(SpeakerEvidenceMethod method) =>
      indicatorLagUs[method] ?? defaultLagUs;

  void validate() {
    if (defaultLagUs < 0 ||
        boundaryMarginUs < 0 ||
        indicatorLagUs.values.any((lag) => lag < 0)) {
      throw ArgumentError('Invalid speaker attribution policy');
    }
  }
}

/// Compact explanation of a decision. It contains no names or text.
final class AttributionEvidence {
  const AttributionEvidence({
    required this.reason,
    this.windowStartUs,
    this.windowEndUs,
    this.uncertaintyUs = 0,
    this.coveredUs = 0,
    this.reads = 0,
    this.lagUs = 0,
    this.marginUs = 0,
    this.methods = const [],
    this.candidateRefs = const [],
  });

  /// A short stable token.
  final String reason;

  /// The queried window: mapped audio widened by uncertainty and margin.
  final int? windowStartUs, windowEndUs;
  final int uncertaintyUs, coveredUs, reads, lagUs, marginUs;
  final List<SpeakerEvidenceMethod> methods;
  final List<String> candidateRefs;

  Map<String, Object?> toJson() => {
    'reason': reason,
    'policy': speakerAttributionPolicyVersion,
    if (windowStartUs != null) 'window_start_us': windowStartUs,
    if (windowEndUs != null) 'window_end_us': windowEndUs,
    'uncertainty_us': uncertaintyUs,
    'covered_us': coveredUs,
    'reads': reads,
    'lag_us': lagUs,
    'margin_us': marginUs,
    if (methods.isNotEmpty) 'methods': [for (final m in methods) m.wire],
    if (candidateRefs.isNotEmpty) 'candidate_refs': candidateRefs,
  };
}

/// A plain value for one audio interval. The display name is a snapshot of
/// untrusted source data; the evidence never contains it.
final class AttributionDecision {
  const AttributionDecision({
    required this.state,
    required this.evidence,
    this.participantRef,
    this.displayName,
    this.method,
  });
  final AttributionState state;
  final String? participantRef, displayName;
  final SpeakerEvidenceMethod? method;
  final AttributionEvidence evidence;

  Map<String, Object?> toJson() => {
    'state': state.name,
    if (participantRef != null) 'participant_ref': participantRef,
    if (method != null) 'method': method!.wire,
    'evidence': evidence.toJson(),
  };
}

enum _Break { none, hole, unavailable }

const _maxRefsPerSegment = 8;

/// Consecutive reads with the same active-speaker set.
final class _Segment {
  _Segment(this.key, this.refs, this.speakerCount, SpeakerObservation first)
    : firstStartUs = first.readStartUs,
      firstEndUs = first.readEndUs,
      lastStartUs = first.readStartUs,
      lastEndUs = first.readEndUs;
  final String key;
  final List<String> refs;
  final int speakerCount;
  final Map<String, String> names = {};
  final Set<String> selfRefs = {};
  final Set<SpeakerEvidenceMethod> methods = {};
  final int firstStartUs, firstEndUs;
  int lastStartUs, lastEndUs;
  int reads = 0;
  _Break breakAfter = _Break.none;
  String breakReason = '';

  void absorb(SpeakerObservation read) {
    reads++;
    lastStartUs = read.readStartUs;
    lastEndUs = read.readEndUs;
    for (final speaker in read.speakers) {
      methods.add(speaker.method);
      if (!refs.contains(speaker.ref)) continue;
      final participant = read.participant(speaker.ref)!;
      names[speaker.ref] = participant.name;
      if (participant.isSelf) {
        selfRefs.add(speaker.ref);
      } else {
        selfRefs.remove(speaker.ref);
      }
    }
  }
}

final class _Unavailable {
  _Unavailable(this.startUs, this.reason);
  final int startUs;
  final String reason;
  int? endUs;
}

/// Coalesced, bounded history of active-speaker reads for one session. Reads
/// are in the capture clock domain. Only active speakers' names are retained,
/// never the roster.
final class ObservationHistory {
  ObservationHistory({
    this.maxSegments = 2048,
    this.maxUnavailableIntervals = 256,
    this.maxReadGapUs = 2000000,
  }) {
    if (maxSegments < 1 || maxUnavailableIntervals < 1 || maxReadGapUs < 1) {
      throw ArgumentError('Invalid observation history bounds');
    }
  }
  final int maxSegments, maxUnavailableIntervals;

  /// Reads further apart than this are not joined: the time between them is
  /// unobserved, not a continuation of the earlier state.
  final int maxReadGapUs;
  final Queue<_Segment> _segments = Queue();
  final List<_Unavailable> _unavailable = [];
  _Unavailable? _open;
  int _readCount = 0, _rejected = 0;
  int? _latestReadStartUs, _latestReadEndUs, _lastCompleteEndUs;

  int get segmentCount => _segments.length;
  int get readCount => _readCount;
  int get rejectedCount => _rejected;
  int get retainedNameCount =>
      _segments.fold(0, (sum, segment) => sum + segment.names.length);

  /// End of the latest read. Attribution of speech ending later than this, plus
  /// the indicator lag, cannot yet be decided.
  int? get latestReadEndUs => _latestReadEndUs;

  List<ObserverUnavailableInterval> get unavailableIntervals => [
    for (final interval in _unavailable)
      ObserverUnavailableInterval(
        startUs: interval.startUs,
        endUs: interval.endUs,
        reason: interval.reason,
      ),
  ];

  /// Returns false for a read that is older than one already accepted.
  bool addObservation(SpeakerObservation read) {
    final previousStart = _latestReadStartUs;
    if (previousStart != null && read.readStartUs < previousStart) {
      _rejected++;
      return false;
    }
    _readCount++;
    _latestReadStartUs = read.readStartUs;
    _latestReadEndUs = math.max(_latestReadEndUs ?? 0, read.readEndUs);
    if (!read.complete) {
      _beginUnavailable(read.readStartUs, 'incomplete_read');
      return true;
    }
    final open = _open;
    if (open != null) {
      open.endUs = math.max(open.startUs, read.readEndUs);
      _open = null;
    }
    _lastCompleteEndUs = read.readEndUs;
    final refs = [for (final speaker in read.speakers) speaker.ref]..sort();
    final key =
        '${refs.length}:${refs.take(_maxRefsPerSegment).join('\u0000')}';
    final last = _segments.isEmpty ? null : _segments.last;
    if (last != null && last.breakAfter == _Break.none) {
      if (read.readStartUs - last.lastEndUs > maxReadGapUs) {
        last.breakAfter = _Break.hole;
      } else if (last.key == key) {
        last.absorb(read);
        return true;
      }
    }
    final segment = _Segment(
      key,
      refs.take(_maxRefsPerSegment).toList(),
      refs.length,
      read,
    );
    segment.absorb(read);
    _segments.add(segment);
    _trim();
    return true;
  }

  /// The helper lost the meeting from [sinceUs]. The claim cannot predate the
  /// last complete read, and the earliest open claim is kept.
  void addUnavailable({required int sinceUs, required String reason}) =>
      _beginUnavailable(sinceUs, reason);

  /// Forget reads that ended before [us] once no queued work can need them.
  void releaseBefore(int us) {
    while (_segments.isNotEmpty && _segments.first.lastEndUs < us) {
      _segments.removeFirst();
    }
    _pruneUnavailable();
  }

  void _beginUnavailable(int sinceUs, String reason) {
    if (_open != null) return;
    final start = math.max(sinceUs, _lastCompleteEndUs ?? sinceUs);
    final interval = _Unavailable(start, reason);
    _unavailable.add(interval);
    _open = interval;
    if (_segments.isNotEmpty) {
      _segments.last
        ..breakAfter = _Break.unavailable
        ..breakReason = reason;
    }
    while (_unavailable.length > maxUnavailableIntervals) {
      final dropped = _unavailable.removeAt(0);
      if (identical(dropped, _open)) _open = null;
    }
  }

  void _trim() {
    while (_segments.length > maxSegments) {
      _segments.removeFirst();
    }
    _pruneUnavailable();
  }

  void _pruneUnavailable() {
    if (_segments.isEmpty) return;
    final oldest = _segments.first.firstStartUs;
    _unavailable.removeWhere((interval) {
      final end = interval.endUs;
      return end != null && end < oldest;
    });
  }
}

enum _RegionType { before, certain, transition, hole, unavailable, after }

final class _Region {
  const _Region(this.type, this.lo, this.hi, {this.segment, this.next});
  final _RegionType type;
  final int lo, hi;
  final _Segment? segment, next;
}

const _negativeInfinity = -(1 << 62), _positiveInfinity = 1 << 62;

final class SpeakerAttributor {
  SpeakerAttributor([this.policy = const SpeakerAttributionPolicy()]) {
    policy.validate();
  }
  final SpeakerAttributionPolicy policy;

  AttributionDecision attribute(
    ObservationHistory history, {
    required AudioSource source,
    required MappedAudioRange? mapped,
  }) {
    if (source == AudioSource.microphone) {
      // A microphone may carry several people; the remote highlight says
      // nothing about it.
      return _plain(AttributionState.unknown, 'microphone_channel', mapped);
    }
    if (mapped == null) {
      return _plain(AttributionState.unknown, 'timeline_unavailable', null);
    }
    if (mapped.hasDiscontinuity) {
      return _plain(AttributionState.unknown, 'capture_discontinuity', mapped);
    }
    final margin = mapped.uncertaintyUs + policy.boundaryMarginUs;
    final start = mapped.startUs - margin;
    final end = math.max(mapped.endUs + margin, start + 1);

    final blind = _blindOverlap(history, start, end);
    if (blind != null) {
      return _verdict(AttributionState.unavailable, blind, mapped, start, end);
    }
    final regions = _regions(history);
    final overlapped = [
      for (final region in regions)
        if (region.lo < end && region.hi > start) region,
    ];
    for (final region in overlapped) {
      switch (region.type) {
        case _RegionType.unavailable:
          final reason = region.segment!.breakReason;
          return _verdict(
            AttributionState.unavailable,
            reason.isEmpty ? 'observer_unavailable' : reason,
            mapped,
            start,
            end,
          );
        case _RegionType.hole:
          return _verdict(
            AttributionState.stale,
            'read_gap',
            mapped,
            start,
            end,
          );
        case _RegionType.after:
          return _verdict(
            AttributionState.stale,
            'history_ends',
            mapped,
            start,
            end,
          );
        case _RegionType.before:
          return _verdict(
            AttributionState.unknown,
            'no_history',
            mapped,
            start,
            end,
          );
        case _RegionType.certain:
        case _RegionType.transition:
          break;
      }
    }
    if (overlapped.length == 1 &&
        overlapped.single.type == _RegionType.certain) {
      return _single(overlapped.single.segment!, mapped, start, end);
    }
    return _ambiguous(overlapped, mapped, start, end);
  }

  // Blind periods: the helper reported it could not observe the meeting.
  String? _blindOverlap(ObservationHistory history, int start, int end) {
    if (history._unavailable.isEmpty) return null;
    final lags = [policy.defaultLagUs, ...policy.indicatorLagUs.values];
    final maxLag = lags.reduce(math.max), minLag = lags.reduce(math.min);
    for (final interval in history._unavailable) {
      final from = interval.startUs - maxLag;
      final to = interval.endUs == null
          ? _positiveInfinity
          : interval.endUs! - minLag;
      if (from < end && to > start) return interval.reason;
    }
    return null;
  }

  int _lagOf(_Segment segment) => segment.methods.isEmpty
      ? policy.defaultLagUs
      : segment.methods.map(policy.lagFor).reduce(math.max);

  /// Time regions of the history on the lag-adjusted audio clock. Boundary
  /// points are made non-decreasing, and a handover whose lagged order
  /// inverts becomes an ambiguous window rather than moving backward.
  List<_Region> _regions(ObservationHistory history) {
    final segments = history._segments.toList();
    if (segments.isEmpty) {
      return const [
        _Region(_RegionType.before, _negativeInfinity, _positiveInfinity),
      ];
    }
    final regions = <_Region>[];
    var cursor = segments.first.firstEndUs - _lagOf(segments.first);
    regions.add(_Region(_RegionType.before, _negativeInfinity, cursor));
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final lastRead = segment.lastStartUs - _lagOf(segment);
      if (i == segments.length - 1) {
        final certainEnd = math.max(lastRead, cursor);
        regions
          ..add(
            _Region(_RegionType.certain, cursor, certainEnd, segment: segment),
          )
          ..add(
            _Region(
              _RegionType.after,
              certainEnd,
              _positiveInfinity,
              segment: segment,
            ),
          );
        break;
      }
      final next = segments[i + 1];
      final nextFirst = next.firstEndUs - _lagOf(next);
      final certainEnd = math.max(math.min(lastRead, nextFirst), cursor);
      final windowEnd = math.max(math.max(lastRead, nextFirst), certainEnd);
      regions
        ..add(
          _Region(_RegionType.certain, cursor, certainEnd, segment: segment),
        )
        ..add(
          _Region(
            switch (segment.breakAfter) {
              _Break.none => _RegionType.transition,
              _Break.hole => _RegionType.hole,
              _Break.unavailable => _RegionType.unavailable,
            },
            certainEnd,
            windowEnd,
            segment: segment,
            next: next,
          ),
        );
      cursor = windowEnd;
    }
    return regions;
  }

  bool _supported(_Segment segment) =>
      segment.methods.every(policy.allowedMethods.contains);

  AttributionDecision _single(
    _Segment segment,
    MappedAudioRange mapped,
    int start,
    int end,
  ) {
    if (segment.speakerCount == 0) {
      return _verdict(
        AttributionState.unknown,
        'no_speaker_observed',
        mapped,
        start,
        end,
        segments: [segment],
      );
    }
    if (!_supported(segment)) {
      return _verdict(
        AttributionState.unknown,
        'unsupported_evidence',
        mapped,
        start,
        end,
        segments: [segment],
      );
    }
    if (segment.speakerCount > 1) {
      return _verdict(
        AttributionState.multiple,
        'concurrent_speakers',
        mapped,
        start,
        end,
        segments: [segment],
      );
    }
    final ref = segment.refs.single;
    if (segment.selfRefs.contains(ref)) {
      return _verdict(
        AttributionState.unknown,
        'self_active',
        mapped,
        start,
        end,
        segments: [segment],
      );
    }
    final method = _weakest(segment.methods);
    return AttributionDecision(
      state: AttributionState.named,
      participantRef: ref,
      displayName: segment.names[ref],
      method: method,
      evidence: AttributionEvidence(
        reason: 'single_speaker',
        windowStartUs: start,
        windowEndUs: end,
        uncertaintyUs: mapped.uncertaintyUs,
        coveredUs: end - start,
        reads: segment.reads,
        lagUs: policy.lagFor(method),
        marginUs: policy.boundaryMarginUs,
        methods: _ordered(segment.methods),
        candidateRefs: [ref],
      ),
    );
  }

  AttributionDecision _ambiguous(
    List<_Region> overlapped,
    MappedAudioRange mapped,
    int start,
    int end,
  ) {
    final involved = <_Segment>[];
    for (final region in overlapped) {
      for (final segment in [region.segment, region.next]) {
        if (segment != null && !involved.contains(segment)) {
          involved.add(segment);
        }
      }
    }
    final refs = <String>{};
    var concurrent = false;
    for (final segment in involved) {
      if (segment.speakerCount == 0 || !_supported(segment)) continue;
      if (segment.speakerCount > 1) {
        concurrent = true;
      } else {
        refs.add(segment.refs.single);
      }
    }
    if (concurrent) {
      return _verdict(
        AttributionState.multiple,
        'concurrent_speakers',
        mapped,
        start,
        end,
        segments: involved,
      );
    }
    return refs.length > 1
        ? _verdict(
            AttributionState.multiple,
            'speaker_change',
            mapped,
            start,
            end,
            segments: involved,
            overlapped: overlapped,
          )
        : _verdict(
            AttributionState.unknown,
            'transition',
            mapped,
            start,
            end,
            segments: involved,
            overlapped: overlapped,
          );
  }

  AttributionDecision _plain(
    AttributionState state,
    String reason,
    MappedAudioRange? mapped,
  ) => AttributionDecision(
    state: state,
    evidence: AttributionEvidence(
      reason: reason,
      uncertaintyUs: mapped?.uncertaintyUs ?? 0,
      marginUs: policy.boundaryMarginUs,
    ),
  );

  AttributionDecision _verdict(
    AttributionState state,
    String reason,
    MappedAudioRange mapped,
    int start,
    int end, {
    List<_Segment> segments = const [],
    List<_Region> overlapped = const [],
  }) {
    final refs = <String>{};
    final methods = <SpeakerEvidenceMethod>{};
    for (final segment in segments) {
      if (_supported(segment)) refs.addAll(segment.refs);
      methods.addAll(segment.methods);
    }
    // Best single-participant coverage, for diagnosis only.
    final coverage = <String, int>{};
    for (final region in overlapped) {
      final segment = region.segment;
      if (region.type != _RegionType.certain ||
          segment == null ||
          segment.speakerCount != 1 ||
          !_supported(segment)) {
        continue;
      }
      final int overlap =
          math.min<int>(end, region.hi) - math.max<int>(start, region.lo);
      coverage.update(
        segment.refs.single,
        (value) => value + overlap,
        ifAbsent: () => overlap,
      );
    }
    return AttributionDecision(
      state: state,
      evidence: AttributionEvidence(
        reason: reason,
        windowStartUs: start,
        windowEndUs: end,
        uncertaintyUs: mapped.uncertaintyUs,
        coveredUs: coverage.values.fold(0, math.max),
        lagUs: policy.defaultLagUs,
        marginUs: policy.boundaryMarginUs,
        methods: _ordered(methods),
        candidateRefs: (refs.toList()..sort()).take(4).toList(),
      ),
    );
  }

  static const _strength = {
    SpeakerEvidenceMethod.participantStatus: 3,
    SpeakerEvidenceMethod.compactTalkingLabel: 2,
    SpeakerEvidenceMethod.atspiState: 1,
    SpeakerEvidenceMethod.orderedTile: 0,
  };

  static SpeakerEvidenceMethod _weakest(Set<SpeakerEvidenceMethod> methods) =>
      methods.reduce((a, b) => _strength[a]! <= _strength[b]! ? a : b);

  static List<SpeakerEvidenceMethod> _ordered(
    Set<SpeakerEvidenceMethod> methods,
  ) => (methods.toList()..sort((a, b) => a.index.compareTo(b.index)));
}

/// One recording session's timeline, history and attribution policy, ready for
/// a controller to feed observations and capture runs into and to query.
final class SpeakerAttributionSession {
  SpeakerAttributionSession({
    required this.session,
    SpeakerAttributionPolicy policy = const SpeakerAttributionPolicy(),
    CaptureTimeline? timeline,
    ObservationHistory? history,
  }) : timeline = timeline ?? CaptureTimeline(),
       history = history ?? ObservationHistory(),
       attributor = SpeakerAttributor(policy);
  final String session;
  final CaptureTimeline timeline;
  final ObservationHistory history;
  final SpeakerAttributor attributor;

  /// Observations of another session are ignored (returns false).
  bool addObservation(SpeakerObservation observation) =>
      observation.session == session && history.addObservation(observation);

  void addUnavailable({required int sinceUs, required String reason}) =>
      history.addUnavailable(sinceUs: sinceUs, reason: reason);

  /// Feed one event of a [MeetingSpeakerObserver]. A restart or failure is a
  /// blind period that the next complete read ends, so a restarted helper's
  /// references are never joined to the earlier helper's reads.
  void apply(SpeakerObserverEvent event) {
    switch (event) {
      case ObservationEvent(:final observation):
        addObservation(observation);
      case UnavailableEvent(:final sinceUs, :final reason):
        addUnavailable(sinceUs: sinceUs, reason: reason);
      case ObserverStateEvent(:final status, :final atUs):
        if (status == ObserverStatus.restarting ||
            status == ObserverStatus.failed) {
          addUnavailable(sinceUs: atUs, reason: 'observer_${status.name}');
        }
    }
  }

  /// Latest observed time. Speech ending later than this cannot be decided yet.
  int? get observationWatermarkUs => history.latestReadEndUs;

  AttributionDecision attribute(
    AudioSource source, {
    required int sampleStart,
    required int sampleEnd,
  }) => attributor.attribute(
    history,
    source: source,
    mapped: timeline.map(
      source,
      sampleStart: sampleStart,
      sampleEnd: sampleEnd,
    ),
  );
}
