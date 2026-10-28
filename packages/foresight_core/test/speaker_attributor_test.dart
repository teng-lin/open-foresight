import 'dart:convert';

import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/capture_timeline.dart';
import 'package:foresight_core/src/meeting_speaker_observer.dart';
import 'package:foresight_core/src/speaker_attributor.dart';
import 'package:foresight_core/src/speaker_observation.dart';
import 'package:test/test.dart';

int sec(num seconds) => (seconds * 1000000).round();

const target = ObservationTarget(pid: 1, window: 'w');
const roster = [
  ObservedParticipant(ref: 'a', name: 'Ada Lovelace'),
  ObservedParticipant(ref: 'b', name: 'Bo, Jr.'),
  ObservedParticipant(ref: 'c', name: 'Me', isSelf: true),
  ObservedParticipant(ref: 'd', name: 'Ada Lovelace'),
];

SpeakerObservation read(
  num at, {
  List<String> speakers = const [],
  SpeakerEvidenceMethod method = SpeakerEvidenceMethod.participantStatus,
  bool complete = true,
  List<ObservedParticipant> participants = roster,
  String session = 's1',
  num duration = .03,
}) => SpeakerObservation(
  session: session,
  readStartUs: sec(at),
  readEndUs: sec(at + duration),
  target: target,
  complete: complete,
  parserVersion: 'mac-1',
  participants: participants,
  speakers: [
    for (final ref in speakers) SpeakerCandidate(ref: ref, method: method),
  ],
);

/// Reads of the same state every 500 ms from [from] to [to] inclusive.
void reads(
  ObservationHistory history,
  num from,
  num to, {
  List<String> speakers = const [],
  SpeakerEvidenceMethod method = SpeakerEvidenceMethod.participantStatus,
  List<ObservedParticipant> participants = roster,
}) {
  for (var t = from; t <= to; t += .5) {
    expect(
      history.addObservation(
        read(t, speakers: speakers, method: method, participants: participants),
      ),
      true,
    );
  }
}

MappedAudioRange audio(
  num from,
  num to, {
  AudioSource source = AudioSource.playback,
  int uncertaintyUs = 0,
  bool discontinuity = false,
}) => MappedAudioRange(
  source: source,
  sampleStart: 0,
  sampleEnd: 1,
  pieces: [
    MappedAudioPiece(
      sampleStart: 0,
      sampleEnd: 1,
      startUs: sec(from),
      endUs: sec(to),
    ),
  ],
  uncertaintyUs: uncertaintyUs,
  gapUs: 0,
  hasDiscontinuity: discontinuity,
  crossesRateChange: false,
);

AttributionDecision decide(
  ObservationHistory history,
  MappedAudioRange? mapped, {
  SpeakerAttributionPolicy policy = const SpeakerAttributionPolicy(),
  AudioSource source = AudioSource.playback,
}) => SpeakerAttributor(
  policy,
).attribute(history, source: source, mapped: mapped);

void expectState(
  AttributionDecision decision,
  SpeakerDecisionState state,
  String reason,
) {
  expect(decision.state, state, reason: decision.evidence.reason);
  expect(decision.evidence.reason, reason);
  if (state != SpeakerDecisionState.named) {
    expect(decision.participantRef, isNull);
    expect(decision.displayName, isNull);
    expect(decision.method, isNull);
  }
}

void main() {
  late ObservationHistory history;
  setUp(() => history = ObservationHistory());

  group('single speaker', () {
    test('names a segment fully inside steady observations', () {
      reads(history, 1, 6, speakers: ['a']);
      final decision = decide(history, audio(2, 4));
      expectState(decision, SpeakerDecisionState.named, 'single_speaker');
      expect(decision.participantRef, 'a');
      expect(decision.displayName, 'Ada Lovelace');
      expect(decision.method, SpeakerEvidenceMethod.participantStatus);
      expect(decision.evidence.coveredUs, sec(2));
      expect(decision.evidence.windowStartUs, sec(2));
      expect(decision.evidence.windowEndUs, sec(4));
      expect(decision.evidence.reads, 11);
    });

    test('equal display names with different refs stay separate', () {
      reads(history, 1, 3, speakers: ['a']);
      reads(history, 5, 7, speakers: ['d']);
      final first = decide(history, audio(1.5, 2.5));
      final second = decide(history, audio(5.5, 6.5));
      expect(first.participantRef, 'a');
      expect(second.participantRef, 'd');
      expect(first.displayName, second.displayName);
    });

    test('a rename splits the interval so a name never spans it', () {
      const renamed = [ObservedParticipant(ref: 'a', name: 'Countess Ada')];
      reads(history, 1, 2, speakers: ['a']);
      reads(history, 2.5, 4, speakers: ['a'], participants: renamed);
      expect(decide(history, audio(1.2, 1.9)).displayName, 'Ada Lovelace');
      expect(decide(history, audio(2.8, 3.8)).displayName, 'Countess Ada');
      // Same person, but no single name describes a window across the rename.
      expectState(
        decide(history, audio(1.8, 2.8)),
        SpeakerDecisionState.unknown,
        'name_change',
      );
    });

    test('the local-user flag is sticky within an interval', () {
      const meNow = [ObservedParticipant(ref: 'a', name: 'Ada', isSelf: true)];
      const notMe = [ObservedParticipant(ref: 'a', name: 'Ada')];
      history.addObservation(read(1, speakers: ['a'], participants: notMe));
      history.addObservation(read(1.5, speakers: ['a'], participants: meNow));
      history.addObservation(read(2, speakers: ['a'], participants: notMe));
      history.addObservation(read(2.5, speakers: ['a'], participants: notMe));
      expectState(
        decide(history, audio(1.2, 2.4)),
        SpeakerDecisionState.unknown,
        'self_active',
      );
    });

    test('does not name merely the largest overlap', () {
      reads(history, 1, 3.5, speakers: ['a']);
      reads(history, 4, 7, speakers: ['b']);
      // 80% of the segment overlaps Ada but it crosses the handover.
      final decision = decide(history, audio(2.5, 3.7));
      expectState(decision, SpeakerDecisionState.multiple, 'speaker_change');
      expect(decision.evidence.candidateRefs, ['a', 'b']);
      expect(decision.evidence.coveredUs, greaterThan(0));
    });
  });

  group('boundaries and conflicts', () {
    setUp(() {
      reads(history, 1, 3, speakers: ['a']);
      reads(history, 3.5, 6, speakers: ['b']);
    });

    test('names each speaker away from the handover', () {
      expect(decide(history, audio(1.5, 2.9)).participantRef, 'a');
      expect(decide(history, audio(3.6, 5.9)).participantRef, 'b');
    });

    test('speech inside the handover window is ambiguous', () {
      expectState(
        decide(history, audio(3.1, 3.4)),
        SpeakerDecisionState.multiple,
        'speaker_change',
      );
      expectState(
        decide(history, audio(2.8, 4)),
        SpeakerDecisionState.multiple,
        'speaker_change',
      );
    });

    test('concurrent candidates in one read are multiple speakers', () {
      final both = ObservationHistory();
      reads(both, 1, 3, speakers: ['a', 'b']);
      expectState(
        decide(both, audio(1.5, 2.5)),
        SpeakerDecisionState.multiple,
        'concurrent_speakers',
      );
    });

    test('speaker followed by an observed absence is unknown', () {
      final h = ObservationHistory();
      reads(h, 1, 3, speakers: ['a']);
      reads(h, 3.5, 6);
      expectState(
        decide(h, audio(2, 3.3)),
        SpeakerDecisionState.unknown,
        'transition',
      );
      expectState(
        decide(h, audio(4, 5)),
        SpeakerDecisionState.unknown,
        'no_speaker_observed',
      );
      expect(decide(h, audio(1.5, 2.5)).participantRef, 'a');
    });

    test('the local user highlight never names remote audio', () {
      final h = ObservationHistory();
      reads(h, 1, 4, speakers: ['c']);
      expectState(
        decide(h, audio(2, 3)),
        SpeakerDecisionState.unknown,
        'self_active',
      );
      final mixed = ObservationHistory();
      reads(mixed, 1, 4, speakers: ['a', 'c']);
      expectState(
        decide(mixed, audio(2, 3)),
        SpeakerDecisionState.multiple,
        'concurrent_speakers',
      );
    });

    test('the microphone channel is never attributed to a name', () {
      expectState(
        decide(
          history,
          audio(1.5, 2.5, source: AudioSource.microphone),
          source: AudioSource.microphone,
        ),
        SpeakerDecisionState.unknown,
        'microphone_channel',
      );
    });

    test('an unvalidated evidence method is not used', () {
      final h = ObservationHistory();
      reads(
        h,
        1,
        4,
        speakers: ['a'],
        method: SpeakerEvidenceMethod.orderedTile,
      );
      expectState(
        decide(h, audio(2, 3)),
        SpeakerDecisionState.unknown,
        'unsupported_evidence',
      );
      final decision = decide(
        h,
        audio(2, 3),
        policy: const SpeakerAttributionPolicy(
          allowedMethods: {SpeakerEvidenceMethod.orderedTile},
        ),
      );
      expect(decision.participantRef, 'a');
      expect(decision.method, SpeakerEvidenceMethod.orderedTile);
    });

    test('mixed evidence reports its weakest allowed method', () {
      final h = ObservationHistory();
      reads(h, 1, 2, speakers: ['a']);
      reads(
        h,
        2.5,
        4,
        speakers: ['a'],
        method: SpeakerEvidenceMethod.compactTalkingLabel,
      );
      final decision = decide(h, audio(1.2, 3.8));
      expect(decision.participantRef, 'a');
      expect(decision.method, SpeakerEvidenceMethod.compactTalkingLabel);
      expect(decision.evidence.methods, [
        SpeakerEvidenceMethod.participantStatus,
        SpeakerEvidenceMethod.compactTalkingLabel,
      ]);
    });
  });

  group('timing', () {
    test('audio before the first observation has no history', () {
      reads(history, 2, 5, speakers: ['a']);
      expectState(
        decide(history, audio(1, 3)),
        SpeakerDecisionState.unknown,
        'no_history',
      );
      expectState(
        decide(ObservationHistory(), audio(1, 3)),
        SpeakerDecisionState.unknown,
        'no_history',
      );
    });

    test('audio after the last observation is stale', () {
      reads(history, 1, 3, speakers: ['a']);
      expect(decide(history, audio(1.5, 2.9)).participantRef, 'a');
      expectState(
        decide(history, audio(3.2, 4)),
        SpeakerDecisionState.stale,
        'history_ends',
      );
      expectState(
        decide(history, audio(2.5, 3.5)),
        SpeakerDecisionState.stale,
        'history_ends',
      );
      expect(history.latestReadEndUs, sec(3.03));
    });

    test('a long gap between reads never extends the earlier speaker', () {
      reads(history, 1, 2, speakers: ['a']);
      reads(history, 8, 9, speakers: ['a']);
      expect(history.segmentCount, 2);
      expectState(
        decide(history, audio(3, 4)),
        SpeakerDecisionState.stale,
        'read_gap',
      );
      expect(decide(history, audio(1.2, 1.8)).participantRef, 'a');
      expect(decide(history, audio(8.2, 8.8)).participantRef, 'a');
    });

    test('a measured indicator lag moves transitions earlier', () {
      reads(history, 1, 4, speakers: ['a']);
      // The first read showing Ada is at 1.0 s; speech began earlier.
      expectState(
        decide(history, audio(.8, 2)),
        SpeakerDecisionState.unknown,
        'no_history',
      );
      final lagged = decide(
        history,
        audio(.8, 2),
        policy: SpeakerAttributionPolicy(
          indicatorLagUs: {SpeakerEvidenceMethod.participantStatus: sec(.3)},
        ),
      );
      expect(lagged.participantRef, 'a');
    });

    test('lag adjusted transitions never move backward', () {
      reads(history, 1, 3, speakers: ['a']);
      reads(
        history,
        3.5,
        6,
        speakers: ['b'],
        method: SpeakerEvidenceMethod.compactTalkingLabel,
      );
      // Bo's evidence is lagged by a full second, which would place the
      // handover before Ada's last observation; the overlap is ambiguous.
      final policy = SpeakerAttributionPolicy(
        indicatorLagUs: {SpeakerEvidenceMethod.compactTalkingLabel: sec(1)},
      );
      expectState(
        decide(history, audio(2.5, 2.9), policy: policy),
        SpeakerDecisionState.multiple,
        'speaker_change',
      );
      expect(
        decide(history, audio(1.5, 2.0), policy: policy).participantRef,
        'a',
      );
      expect(
        decide(history, audio(3.2, 5), policy: policy).participantRef,
        'b',
      );
    });

    test('audio timing uncertainty widens the window', () {
      reads(history, 1, 6, speakers: ['a']);
      expect(decide(history, audio(2, 3)).participantRef, 'a');
      expectState(
        decide(history, audio(2, 3, uncertaintyUs: sec(1.5))),
        SpeakerDecisionState.unknown,
        'no_history',
      );
      final margin = decide(
        history,
        audio(1.2, 1.8),
        policy: SpeakerAttributionPolicy(boundaryMarginUs: sec(.5)),
      );
      expectState(margin, SpeakerDecisionState.unknown, 'no_history');
    });

    test('missing mappings and capture discontinuities are unknown', () {
      reads(history, 1, 6, speakers: ['a']);
      expectState(
        decide(history, null),
        SpeakerDecisionState.unknown,
        'timeline_unavailable',
      );
      expectState(
        decide(history, audio(2, 4, discontinuity: true)),
        SpeakerDecisionState.unknown,
        'capture_discontinuity',
      );
    });
  });

  group('lag and timing edge cases', () {
    test('lag inversion considers every later segment, not only the next', () {
      reads(history, 0, 10, speakers: ['a']);
      reads(history, 10.5, 11, speakers: ['b']);
      reads(
        history,
        11.5,
        13,
        speakers: ['c'],
        method: SpeakerEvidenceMethod.compactTalkingLabel,
      );
      final policy = SpeakerAttributionPolicy(
        indicatorLagUs: {SpeakerEvidenceMethod.compactTalkingLabel: sec(3)},
      );
      // Segment c, lagged by 3 s, began before 8.53 s on the audio clock:
      // a's certainty cannot reach past that even though b sits in between.
      final decision = decide(history, audio(8.8, 9.2), policy: policy);
      expect(decision.state, isNot(SpeakerDecisionState.named));
      expect(decide(history, audio(2, 6), policy: policy).participantRef, 'a');
    });

    test(
      'mixed methods start an interval at the smallest lag, end it at the largest',
      () {
        reads(history, 1, 10, speakers: ['b']);
        history.addObservation(read(10.5, speakers: ['a']));
        reads(
          history,
          11,
          13,
          speakers: ['a'],
          method: SpeakerEvidenceMethod.compactTalkingLabel,
        );
        final policy = SpeakerAttributionPolicy(
          indicatorLagUs: {SpeakerEvidenceMethod.compactTalkingLabel: sec(1)},
        );
        // The handover lies somewhere between Bo's last read (10.0 s) and the
        // first status read of Ada (10.5 s): the label's longer lag must not pull
        // the start of Ada's certainty earlier.
        final inside = decide(history, audio(10.05, 10.4), policy: policy);
        expectState(inside, SpeakerDecisionState.multiple, 'speaker_change');
        expect(
          decide(history, audio(10.6, 11.9), policy: policy).participantRef,
          'a',
        );
        // The trailing edge uses the largest lag: the last read at 13.0 s shows
        // speech up to 12.0 s only.
        expectState(
          decide(history, audio(11.5, 12.4), policy: policy),
          SpeakerDecisionState.stale,
          'history_ends',
        );
      },
    );

    test('lag moves the trailing edge of the last interval earlier', () {
      reads(history, 1, 5, speakers: ['a']);
      final policy = SpeakerAttributionPolicy(
        indicatorLagUs: {SpeakerEvidenceMethod.participantStatus: sec(.5)},
      );
      expect(
        decide(history, audio(2, 4.4), policy: policy).participantRef,
        'a',
      );
      expectState(
        decide(history, audio(2, 4.7), policy: policy),
        SpeakerDecisionState.stale,
        'history_ends',
      );
    });

    test('blind periods widen by the largest and smallest configured lag', () {
      reads(history, 1, 4, speakers: ['a']);
      history.addUnavailable(sinceUs: sec(5), reason: 'window_lost');
      reads(history, 6, 8, speakers: ['a']);
      final policy = SpeakerAttributionPolicy(
        indicatorLagUs: {SpeakerEvidenceMethod.participantStatus: sec(.3)},
      );
      // Blind from 5.0 s on the indicator is 4.7 s on the audio clock.
      expectState(
        decide(history, audio(4.75, 4.9), policy: policy),
        SpeakerDecisionState.unavailable,
        'window_lost',
      );
    });

    test('slow reads leave certainty only after their completion', () {
      for (var t = 1.0; t <= 4; t += .5) {
        history.addObservation(read(t, speakers: ['a'], duration: 1));
      }
      expectState(
        decide(history, audio(1.5, 3)),
        SpeakerDecisionState.unknown,
        'no_history',
      );
      expect(decide(history, audio(2.1, 3.9)).participantRef, 'a');
    });

    test('a gap of exactly maxReadGapUs joins reads and one more splits', () {
      final exact = ObservationHistory(maxReadGapUs: sec(2));
      exact.addObservation(read(1, speakers: ['a']));
      exact.addObservation(read(3.03, speakers: ['a']));
      expect(exact.segmentCount, 1);
      final over = ObservationHistory(maxReadGapUs: sec(2));
      over.addObservation(read(1, speakers: ['a']));
      over.addObservation(read(3.031, speakers: ['a']));
      expect(over.segmentCount, 2);
    });

    test('a speaker shorter than the poll period is invisible', () {
      // Documents the limitation: nothing was observed, so nothing is claimed.
      reads(history, 1, 5, speakers: ['a']);
      expect(decide(history, audio(2, 3)).participantRef, 'a');
    });

    test('a decision becomes named once later reads cover the window', () {
      reads(history, 1, 3, speakers: ['a']);
      expectState(
        decide(history, audio(2.5, 3.5)),
        SpeakerDecisionState.stale,
        'history_ends',
      );
      reads(history, 3.5, 4, speakers: ['a']);
      expect(decide(history, audio(2.5, 3.5)).participantRef, 'a');
    });

    test('a named decision is stable as later reads append', () {
      reads(history, 1, 5, speakers: ['a']);
      final first = decide(history, audio(2, 4));
      reads(history, 5.5, 6, speakers: ['a']);
      reads(history, 6.5, 9, speakers: ['b']);
      history.addUnavailable(sinceUs: sec(9.5), reason: 'gone');
      final later = decide(history, audio(2, 4));
      expect(later.participantRef, first.participantRef);
      expect(later.displayName, first.displayName);
      expect(later.evidence.windowStartUs, first.evidence.windowStartUs);
    });

    test('an empty blind reason still reads as unavailable', () {
      history.addUnavailable(sinceUs: 0, reason: '');
      expectState(
        decide(history, audio(1, 2)),
        SpeakerDecisionState.unavailable,
        'observer_unavailable',
      );
    });

    test('evidence stays small even with maximal references', () {
      final long = 'r' * 128;
      final participants = [
        for (var i = 0; i < 4; i++)
          ObservedParticipant(ref: '$i$long', name: 'N' * 256),
      ];
      reads(
        history,
        1,
        3,
        speakers: [for (final p in participants) p.ref],
        participants: participants,
      );
      final decision = decide(history, audio(1.5, 2.5));
      final text = jsonEncode(decision.toJson());
      expect(decision.evidence.candidateRefs.length, lessThanOrEqualTo(4));
      expect(utf8.encode(text).length, lessThan(2048));
      expect(decision.evidence.reason, 'concurrent_speakers');
    });
  });

  group('ambiguity detail', () {
    test('a handover next to concurrent speakers is concurrent', () {
      reads(history, 1, 3, speakers: ['a', 'b']);
      reads(history, 3.5, 6, speakers: ['a']);
      expectState(
        decide(history, audio(2.9, 3.8)),
        SpeakerDecisionState.multiple,
        'concurrent_speakers',
      );
    });

    test('coverage sums every stretch of the best candidate', () {
      reads(history, 1, 2, speakers: ['a']);
      history.addObservation(read(2.5, speakers: ['b']));
      reads(history, 3, 5, speakers: ['a']);
      final decision = decide(history, audio(1.5, 4));
      expectState(decision, SpeakerDecisionState.multiple, 'speaker_change');
      // 0.5 s before the handover plus 0.97 s after it.
      expect(decision.evidence.coveredUs, sec(1.47));
    });

    test('a blind window is reported even before the claim starts', () {
      reads(history, 1, 3, speakers: ['a']);
      history.addUnavailable(sinceUs: sec(3.2), reason: 'window_lost');
      reads(history, 6, 8, speakers: ['a']);
      // Between Ada's last read (3.0 s) and the claimed loss (3.2 s).
      expectState(
        decide(history, audio(3.05, 3.15)),
        SpeakerDecisionState.unavailable,
        'window_lost',
      );
    });

    test('a blind period without a reason still reads as unavailable', () {
      reads(history, 1, 3, speakers: ['a']);
      history.addUnavailable(sinceUs: sec(3.2), reason: '');
      reads(history, 6, 8, speakers: ['a']);
      expectState(
        decide(history, audio(3.05, 3.15)),
        SpeakerDecisionState.unavailable,
        'observer_unavailable',
      );
    });
  });

  group('availability', () {
    test('an unavailable interval blocks naming and then recovers', () {
      reads(history, 1, 3, speakers: ['a']);
      history.addUnavailable(sinceUs: sec(3.2), reason: 'window_lost');
      reads(history, 6, 8, speakers: ['a']);
      expectState(
        decide(history, audio(3.5, 5)),
        SpeakerDecisionState.unavailable,
        'window_lost',
      );
      // Speech spanning the blind period is also unavailable, never extended.
      expectState(
        decide(history, audio(2.5, 6.5)),
        SpeakerDecisionState.unavailable,
        'window_lost',
      );
      expect(decide(history, audio(1.2, 2.8)).participantRef, 'a');
      expect(decide(history, audio(6.3, 7.5)).participantRef, 'a');
      expect(history.unavailableIntervals.single.startUs, sec(3.2));
      expect(history.unavailableIntervals.single.endUs, sec(6.03));
    });

    test('an open interval keeps later audio unavailable', () {
      reads(history, 1, 3, speakers: ['a']);
      history.addUnavailable(sinceUs: sec(3.1), reason: 'permission_revoked');
      history.addUnavailable(sinceUs: sec(3.4), reason: 'other');
      expect(history.unavailableIntervals, hasLength(1));
      expectState(
        decide(history, audio(5, 6)),
        SpeakerDecisionState.unavailable,
        'permission_revoked',
      );
      expect(history.unavailableIntervals.single.endUs, isNull);
    });

    test('unavailable with no reads at all is unavailable', () {
      history.addUnavailable(sinceUs: sec(0), reason: 'zoom_not_running');
      expectState(
        decide(history, audio(1, 2)),
        SpeakerDecisionState.unavailable,
        'zoom_not_running',
      );
    });

    test(
      'an incomplete read is a blind period, not a repeat of the speaker',
      () {
        reads(history, 1, 3, speakers: ['a']);
        expect(
          history.addObservation(read(3.5, speakers: ['a'], complete: false)),
          true,
        );
        reads(history, 5, 7, speakers: ['a']);
        expectState(
          decide(history, audio(3.6, 4.5)),
          SpeakerDecisionState.unavailable,
          'incomplete_read',
        );
        expect(decide(history, audio(5.2, 6.5)).participantRef, 'a');
        expect(decide(history, audio(1.2, 2.8)).participantRef, 'a');
      },
    );

    test('the unavailable claim cannot precede the last complete read', () {
      reads(history, 1, 3, speakers: ['a']);
      history.addUnavailable(sinceUs: sec(1), reason: 'early_claim');
      expect(history.unavailableIntervals.single.startUs, sec(3.03));
    });
  });

  group('history bounds and ordering', () {
    test('identical reads coalesce into one segment', () {
      for (var i = 0; i < 20000; i++) {
        history.addObservation(read(1 + i * .1, speakers: ['a']));
      }
      expect(history.segmentCount, 1);
      expect(history.readCount, 20000);
    });

    test('segments are bounded and trimmed history reads as no history', () {
      final bounded = ObservationHistory(maxSegments: 4);
      for (var i = 0; i < 40; i++) {
        bounded.addObservation(
          read(i.toDouble(), speakers: [i.isEven ? 'a' : 'b']),
        );
      }
      expect(bounded.segmentCount, 4);
      expectState(
        decide(bounded, audio(2, 3)),
        SpeakerDecisionState.unknown,
        'no_history',
      );
    });

    test('unavailable intervals are bounded', () {
      final bounded = ObservationHistory(maxUnavailableIntervals: 3);
      for (var i = 0; i < 10; i++) {
        bounded.addObservation(read(i * 10.0, speakers: ['a']));
        bounded.addUnavailable(sinceUs: sec(i * 10 + 1), reason: 'gone');
      }
      expect(bounded.unavailableIntervals.length, lessThanOrEqualTo(3));
    });

    test('releaseBefore discards segments no queued work can need', () {
      reads(history, 1, 3, speakers: ['a']);
      reads(history, 3.5, 6, speakers: ['b']);
      history.releaseBefore(sec(3.2));
      expect(history.segmentCount, 1);
      expectState(
        decide(history, audio(2, 2.5)),
        SpeakerDecisionState.unknown,
        'no_history',
      );
      expect(decide(history, audio(4, 5)).participantRef, 'b');
    });

    test('reads that go backward in time are rejected', () {
      history.addObservation(read(5, speakers: ['a']));
      expect(history.addObservation(read(4, speakers: ['a'])), false);
      expect(history.rejectedCount, 1);
      expect(history.readCount, 1);
    });

    test('a participant list is not retained beyond active speakers', () {
      final big = [
        for (var i = 0; i < 256; i++)
          ObservedParticipant(ref: 'p$i', name: 'Person $i'),
      ];
      for (var i = 0; i < 5; i++) {
        history.addObservation(
          read(1 + i * .5, speakers: ['p7'], participants: big),
        );
      }
      expect(history.retainedNameCount, 1);
    });

    test('a read with an unlisted speaker cannot be constructed', () {
      expect(
        () => SpeakerObservation(
          session: 's',
          readStartUs: 0,
          readEndUs: 1,
          target: target,
          complete: true,
          parserVersion: 'p',
          participants: roster,
          speakers: const [
            SpeakerCandidate(
              ref: 'ghost',
              method: SpeakerEvidenceMethod.participantStatus,
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => SpeakerObservation(
          session: 's',
          readStartUs: 0,
          readEndUs: 1,
          target: target,
          complete: true,
          parserVersion: 'p',
          participants: [roster.first, roster.first],
          speakers: const [],
        ),
        throwsArgumentError,
      );
    });

    test('policy values are validated', () {
      expect(
        () => SpeakerAttributor(SpeakerAttributionPolicy(boundaryMarginUs: -1)),
        throwsArgumentError,
      );
      expect(
        () => SpeakerAttributor(
          SpeakerAttributionPolicy(
            indicatorLagUs: {SpeakerEvidenceMethod.orderedTile: -5},
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => SpeakerAttributor(SpeakerAttributionPolicy(defaultLagUs: -1)),
        throwsArgumentError,
      );
      expect(() => ObservationHistory(maxSegments: 0), throwsArgumentError);
      expect(
        () => ObservationHistory(maxUnavailableIntervals: 0),
        throwsArgumentError,
      );
      expect(() => ObservationHistory(maxReadGapUs: 0), throwsArgumentError);
    });
  });

  group('evidence', () {
    test('serializes compactly without names or transcript text', () {
      reads(history, 1, 6, speakers: ['a']);
      final decision = decide(history, audio(2, 4, uncertaintyUs: 5000));
      final json = decision.toJson();
      expect(json['state'], 'named');
      expect(json['participant_ref'], 'a');
      expect(json['method'], 'participant_status');
      final evidence = json['evidence']! as Map<String, Object?>;
      expect(evidence['reason'], 'single_speaker');
      expect(evidence['policy'], speakerAttributionPolicyVersion);
      expect(evidence['uncertainty_us'], 5000);
      expect(jsonEncode(json), isNot(contains('Ada')));
      expect(jsonEncode(json).length, lessThan(600));
      final unknown = decide(history, audio(.1, .2)).toJson();
      expect(unknown.containsKey('participant_ref'), false);
    });
  });

  group('session', () {
    test('joins capture timeline samples with observations', () {
      final session = SpeakerAttributionSession(session: 's1');
      // Remote audio: 48 kHz samples; sample 0 is captured at t = 10 s.
      session.timeline.addRun(
        AudioSource.playback,
        sampleStart: 0,
        sampleCount: 48000 * 10,
        sampleRate: 48000,
        startUs: sec(10),
        endUs: sec(20),
      );
      for (var t = 10.0; t <= 20; t += .5) {
        session.addObservation(read(t, speakers: [t < 15 ? 'a' : 'b']));
      }
      final first = session.attribute(
        AudioSource.playback,
        sampleStart: 48000,
        sampleEnd: 48000 * 4,
        generation: 0,
      );
      expect(first.participantRef, 'a');
      final second = session.attribute(
        AudioSource.playback,
        sampleStart: 48000 * 6,
        sampleEnd: 48000 * 9,
        generation: 0,
      );
      expect(second.participantRef, 'b');
      final crossing = session.attribute(
        AudioSource.playback,
        sampleStart: 48000 * 4,
        sampleEnd: 48000 * 6,
        generation: 0,
      );
      expect(crossing.state, SpeakerDecisionState.multiple);
      expect(
        session
            .attribute(
              AudioSource.playback,
              sampleStart: 48000 * 20,
              sampleEnd: 48000 * 21,
              generation: 0,
            )
            .state,
        SpeakerDecisionState.unknown,
        reason: 'unmapped samples',
      );
      expect(session.observationWatermarkUs, sec(20.03));
    });

    test('says why a range could not be placed', () {
      final session = SpeakerAttributionSession(session: 's1');
      String reason(int a, int b) => session
          .attribute(
            AudioSource.playback,
            sampleStart: a,
            sampleEnd: b,
            generation: session.sampleGeneration(AudioSource.playback),
          )
          .evidence
          .reason;
      expect(reason(0, 10), 'timeline_unknown_source');
      expect(reason(5, 5), 'empty_range');
      expect(reason(-1, 5), 'empty_range');
      session.timeline.addRun(
        AudioSource.playback,
        sampleStart: 1000,
        sampleCount: 1000,
        sampleRate: 1000,
        startUs: 0,
        endUs: 1000000,
      );
      session.timeline.addRun(
        AudioSource.playback,
        sampleStart: 3000,
        sampleCount: 1000,
        sampleRate: 1000,
        startUs: 3000000,
        endUs: 4000000,
      );
      expect(reason(0, 500), 'timeline_trimmed');
      expect(reason(1500, 3500), 'timeline_gap');
      expect(reason(5000, 6000), 'timeline_not_captured');
      expect(reason(1100, 1200), 'no_history');
    });

    test('a range recorded before a counter reset no longer exists', () {
      final session = SpeakerAttributionSession(session: 's1');
      for (var t = 0.0; t <= 20; t += .5) {
        session.addObservation(read(t, speakers: [t < 10 ? 'a' : 'b']));
      }
      void run(int startSample, double startSecond) => session.timeline.addRun(
        AudioSource.playback,
        sampleStart: startSample,
        sampleCount: 48000 * 4,
        sampleRate: 48000,
        startUs: sec(startSecond),
        endUs: sec(startSecond + 4),
      );
      run(0, 2); // samples 0..4 s are Ada at 2..6 s
      final queued = session.sampleGeneration(AudioSource.playback);
      AttributionDecision ask(int generation) => session.attribute(
        AudioSource.playback,
        sampleStart: 48000,
        sampleEnd: 48000 * 2,
        generation: generation,
      );
      expect(ask(queued).participantRef, 'a');
      // Device recovery restarts the counter; the new audio is Bo's, at 12 s.
      run(0, 12);
      expect(session.timeline.counterResets(AudioSource.playback), 1);
      final stale = ask(queued);
      expect(stale.state, SpeakerDecisionState.unknown);
      expect(stale.evidence.reason, 'timeline_counter_reset');
      expect(stale.participantRef, isNull);
      final fresh = ask(session.sampleGeneration(AudioSource.playback));
      expect(fresh.participantRef, 'b');
    });

    test('ignores observations from other sessions', () {
      final session = SpeakerAttributionSession(session: 's1');
      expect(session.addObservation(read(1, session: 's2')), false);
      expect(session.addObservation(read(1)), true);
      expect(session.history.readCount, 1);
    });
    test('applies observer events, treating restarts as blind periods', () {
      final session = SpeakerAttributionSession(session: 's1');
      for (var t = 1.0; t <= 3; t += .5) {
        session.apply(ObservationEvent(0, read(t, speakers: ['a'])));
      }
      session.apply(
        ObserverStateEvent(
          0,
          status: ObserverStatus.restarting,
          atUs: sec(3.4),
          restartCount: 1,
        ),
      );
      session.apply(
        const UnavailableEvent(1, sinceUs: 4000000, reason: 'window_lost'),
      );
      session.apply(
        ObserverStateEvent(
          1,
          status: ObserverStatus.running,
          atUs: sec(4.2),
          restartCount: 1,
        ),
      );
      // The restarted helper reports its own references for the same person.
      for (var t = 5.0; t <= 7; t += .5) {
        session.apply(
          ObservationEvent(
            1,
            read(
              t,
              speakers: ['1:a'],
              participants: const [
                ObservedParticipant(ref: '1:a', name: 'Ada Lovelace'),
              ],
            ),
          ),
        );
      }
      final before = session.attributor.attribute(
        session.history,
        source: AudioSource.playback,
        mapped: audio(1.5, 2.5),
      );
      final blind = session.attributor.attribute(
        session.history,
        source: AudioSource.playback,
        mapped: audio(3.5, 4.5),
      );
      final after = session.attributor.attribute(
        session.history,
        source: AudioSource.playback,
        mapped: audio(5.5, 6.5),
      );
      expect(before.participantRef, 'a');
      expect(blind.state, SpeakerDecisionState.unavailable);
      expect(blind.evidence.reason, 'observer_restarting');
      expect(after.participantRef, '1:a');
      expect(session.history.segmentCount, 2);
      session.apply(
        ObserverStateEvent(
          1,
          status: ObserverStatus.stopped,
          atUs: sec(7.5),
          restartCount: 1,
        ),
      );
      // The restart blind period, plus the stop that follows the last read.
      expect(session.history.unavailableIntervals, hasLength(2));
      expect(session.history.unavailableIntervals.last.endUs, isNull);
    });

    test('a stop is a blind period even if the next helper reuses a ref', () {
      final session = SpeakerAttributionSession(session: 's1');
      const bob = [ObservedParticipant(ref: 'p1', name: 'Bob')];
      const ada = [ObservedParticipant(ref: 'p1', name: 'Ada')];
      for (var t = 0.0; t <= 1; t += .5) {
        session.apply(
          ObservationEvent(0, read(t, speakers: ['p1'], participants: ada)),
        );
      }
      session.apply(
        ObserverStateEvent(
          0,
          status: ObserverStatus.stopped,
          atUs: sec(1.1),
          restartCount: 0,
        ),
      );
      // The same observer was started again with the same session identifier.
      for (var t = 1.2; t <= 3; t += .5) {
        session.apply(
          ObservationEvent(1, read(t, speakers: ['p1'], participants: bob)),
        );
      }
      MappedAudioRange? at(num a, num b) => audio(a, b);
      AttributionDecision d(num a, num b) => session.attributor.attribute(
        session.history,
        source: AudioSource.playback,
        mapped: at(a, b),
      );
      expect(d(.2, .8).displayName, 'Ada');
      expect(d(1.05, 1.15).state, SpeakerDecisionState.unavailable);
      expect(d(1.8, 2.6).displayName, 'Bob');
    });

    test('a failed observer leaves later audio unavailable', () {
      final session = SpeakerAttributionSession(session: 's1');
      for (var t = 1.0; t <= 3; t += .5) {
        session.apply(ObservationEvent(0, read(t, speakers: ['a'])));
      }
      session.apply(
        ObserverStateEvent(
          0,
          status: ObserverStatus.failed,
          atUs: sec(3.2),
          restartCount: 5,
        ),
      );
      final decision = session.attributor.attribute(
        session.history,
        source: AudioSource.playback,
        mapped: audio(4, 5),
      );
      expect(decision.state, SpeakerDecisionState.unavailable);
      expect(decision.evidence.reason, 'observer_failed');
    });

    test('older-epoch events are ignored and a new epoch resets ordering', () {
      final session = SpeakerAttributionSession(session: 's1');
      // A first helper reports an absurdly late clock reading.
      session.apply(ObservationEvent(0, read(5000000, speakers: ['a'])));
      expect(session.history.readCount, 1);
      session.apply(
        ObserverStateEvent(
          0,
          status: ObserverStatus.restarting,
          atUs: sec(2),
          restartCount: 1,
        ),
      );
      for (var t = 3.0; t <= 5; t += .5) {
        session.apply(ObservationEvent(1, read(t, speakers: ['a'])));
      }
      expect(session.rejectedObservationCount, 0);
      expect(session.history.readCount, 6);
      // The replaced helper keeps talking: nothing is accepted from it.
      session.apply(ObservationEvent(0, read(5.5, speakers: ['b'])));
      session.apply(
        ObserverStateEvent(
          0,
          status: ObserverStatus.failed,
          atUs: sec(5.6),
          restartCount: 1,
        ),
      );
      expect(session.staleEventCount, 2);
      expect(session.history.readCount, 6);
      expect(session.history.unavailableIntervals.last.endUs, isNotNull);
    });
  });
}
