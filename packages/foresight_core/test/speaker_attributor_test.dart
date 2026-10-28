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
  AttributionState state,
  String reason,
) {
  expect(decision.state, state, reason: decision.evidence.reason);
  expect(decision.evidence.reason, reason);
  if (state != AttributionState.named) {
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
      expectState(decision, AttributionState.named, 'single_speaker');
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

    test('uses the latest name when a participant is renamed', () {
      history.addObservation(read(1, speakers: ['a']));
      history.addObservation(
        read(
          1.5,
          speakers: ['a'],
          participants: const [
            ObservedParticipant(ref: 'a', name: 'Countess Ada'),
          ],
        ),
      );
      history.addObservation(read(2, speakers: ['a']));
      history.addObservation(
        read(
          2.5,
          speakers: ['a'],
          participants: const [
            ObservedParticipant(ref: 'a', name: 'Countess Ada'),
          ],
        ),
      );
      expect(decide(history, audio(1.6, 2.4)).displayName, 'Countess Ada');
    });

    test('does not name merely the largest overlap', () {
      reads(history, 1, 3.5, speakers: ['a']);
      reads(history, 4, 7, speakers: ['b']);
      // 80% of the segment overlaps Ada but it crosses the handover.
      final decision = decide(history, audio(2.5, 3.7));
      expectState(decision, AttributionState.multiple, 'speaker_change');
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
        AttributionState.multiple,
        'speaker_change',
      );
      expectState(
        decide(history, audio(2.8, 4)),
        AttributionState.multiple,
        'speaker_change',
      );
    });

    test('concurrent candidates in one read are multiple speakers', () {
      final both = ObservationHistory();
      reads(both, 1, 3, speakers: ['a', 'b']);
      expectState(
        decide(both, audio(1.5, 2.5)),
        AttributionState.multiple,
        'concurrent_speakers',
      );
    });

    test('speaker followed by an observed absence is unknown', () {
      final h = ObservationHistory();
      reads(h, 1, 3, speakers: ['a']);
      reads(h, 3.5, 6);
      expectState(
        decide(h, audio(2, 3.3)),
        AttributionState.unknown,
        'transition',
      );
      expectState(
        decide(h, audio(4, 5)),
        AttributionState.unknown,
        'no_speaker_observed',
      );
      expect(decide(h, audio(1.5, 2.5)).participantRef, 'a');
    });

    test('the local user highlight never names remote audio', () {
      final h = ObservationHistory();
      reads(h, 1, 4, speakers: ['c']);
      expectState(
        decide(h, audio(2, 3)),
        AttributionState.unknown,
        'self_active',
      );
      final mixed = ObservationHistory();
      reads(mixed, 1, 4, speakers: ['a', 'c']);
      expectState(
        decide(mixed, audio(2, 3)),
        AttributionState.multiple,
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
        AttributionState.unknown,
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
        AttributionState.unknown,
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
        AttributionState.unknown,
        'no_history',
      );
      expectState(
        decide(ObservationHistory(), audio(1, 3)),
        AttributionState.unknown,
        'no_history',
      );
    });

    test('audio after the last observation is stale', () {
      reads(history, 1, 3, speakers: ['a']);
      expect(decide(history, audio(1.5, 2.9)).participantRef, 'a');
      expectState(
        decide(history, audio(3.2, 4)),
        AttributionState.stale,
        'history_ends',
      );
      expectState(
        decide(history, audio(2.5, 3.5)),
        AttributionState.stale,
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
        AttributionState.stale,
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
        AttributionState.unknown,
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
        AttributionState.multiple,
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
        AttributionState.unknown,
        'no_history',
      );
      final margin = decide(
        history,
        audio(1.2, 1.8),
        policy: SpeakerAttributionPolicy(boundaryMarginUs: sec(.5)),
      );
      expectState(margin, AttributionState.unknown, 'no_history');
    });

    test('missing mappings and capture discontinuities are unknown', () {
      reads(history, 1, 6, speakers: ['a']);
      expectState(
        decide(history, null),
        AttributionState.unknown,
        'timeline_unavailable',
      );
      expectState(
        decide(history, audio(2, 4, discontinuity: true)),
        AttributionState.unknown,
        'capture_discontinuity',
      );
    });
  });

  group('ambiguity detail', () {
    test('a handover next to concurrent speakers is concurrent', () {
      reads(history, 1, 3, speakers: ['a', 'b']);
      reads(history, 3.5, 6, speakers: ['a']);
      expectState(
        decide(history, audio(2.9, 3.8)),
        AttributionState.multiple,
        'concurrent_speakers',
      );
    });

    test('coverage sums every stretch of the best candidate', () {
      reads(history, 1, 2, speakers: ['a']);
      history.addObservation(read(2.5, speakers: ['b']));
      reads(history, 3, 5, speakers: ['a']);
      final decision = decide(history, audio(1.5, 4));
      expectState(decision, AttributionState.multiple, 'speaker_change');
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
        AttributionState.unavailable,
        'window_lost',
      );
    });

    test('a blind period without a reason still reads as unavailable', () {
      reads(history, 1, 3, speakers: ['a']);
      history.addUnavailable(sinceUs: sec(3.2), reason: '');
      reads(history, 6, 8, speakers: ['a']);
      expectState(
        decide(history, audio(3.05, 3.15)),
        AttributionState.unavailable,
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
        AttributionState.unavailable,
        'window_lost',
      );
      // Speech spanning the blind period is also unavailable, never extended.
      expectState(
        decide(history, audio(2.5, 6.5)),
        AttributionState.unavailable,
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
        AttributionState.unavailable,
        'permission_revoked',
      );
      expect(history.unavailableIntervals.single.endUs, isNull);
    });

    test('unavailable with no reads at all is unavailable', () {
      history.addUnavailable(sinceUs: sec(0), reason: 'zoom_not_running');
      expectState(
        decide(history, audio(1, 2)),
        AttributionState.unavailable,
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
          AttributionState.unavailable,
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
        AttributionState.unknown,
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
        AttributionState.unknown,
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
      );
      expect(first.participantRef, 'a');
      final second = session.attribute(
        AudioSource.playback,
        sampleStart: 48000 * 6,
        sampleEnd: 48000 * 9,
      );
      expect(second.participantRef, 'b');
      final crossing = session.attribute(
        AudioSource.playback,
        sampleStart: 48000 * 4,
        sampleEnd: 48000 * 6,
      );
      expect(crossing.state, AttributionState.multiple);
      expect(
        session
            .attribute(
              AudioSource.playback,
              sampleStart: 48000 * 20,
              sampleEnd: 48000 * 21,
            )
            .state,
        AttributionState.unknown,
        reason: 'unmapped samples',
      );
      expect(session.observationWatermarkUs, sec(20.03));
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
      expect(blind.state, AttributionState.unavailable);
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
      expect(session.history.unavailableIntervals, hasLength(1));
    });
  });
}
