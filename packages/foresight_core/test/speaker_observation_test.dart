import 'package:foresight_core/src/speaker_observation.dart';
import 'package:test/test.dart';

void main() {
  const target = ObservationTarget(pid: 1, window: 'w', locale: 'en');
  SpeakerObservation make({int start = 1000, int end = 2000}) =>
      SpeakerObservation(
        session: 's',
        readStartUs: start,
        readEndUs: end,
        target: target,
        complete: true,
        parserVersion: 'p',
        participants: [const ObservedParticipant(ref: 'a', name: 'Ada')],
        speakers: [
          const SpeakerCandidate(
            ref: 'a',
            method: SpeakerEvidenceMethod.participantStatus,
          ),
        ],
      );

  test('value types compare by content', () {
    expect(const ObservationTarget(pid: 1, window: 'w', locale: 'en'), target);
    expect(
      const ObservationTarget(pid: 2, window: 'w', locale: 'en'),
      isNot(target),
    );
    expect(
      target.hashCode,
      const ObservationTarget(pid: 1, window: 'w', locale: 'en').hashCode,
    );
    const ada = ObservedParticipant(ref: 'a', name: 'Ada');
    expect(ada, const ObservedParticipant(ref: 'a', name: 'Ada'));
    expect(
      ada,
      isNot(const ObservedParticipant(ref: 'a', name: 'Ada', isSelf: true)),
    );
    expect(
      ada.hashCode,
      const ObservedParticipant(ref: 'a', name: 'Ada').hashCode,
    );
    const candidate = SpeakerCandidate(
      ref: 'a',
      method: SpeakerEvidenceMethod.participantStatus,
    );
    expect(
      candidate,
      const SpeakerCandidate(
        ref: 'a',
        method: SpeakerEvidenceMethod.participantStatus,
      ),
    );
    expect(
      candidate,
      isNot(
        const SpeakerCandidate(
          ref: 'a',
          method: SpeakerEvidenceMethod.orderedTile,
        ),
      ),
    );
    expect(candidate.hashCode, isNotNull);
  });

  test('wire names round trip and unknown names do not parse', () {
    for (final method in SpeakerEvidenceMethod.values) {
      expect(SpeakerEvidenceMethod.fromWire(method.wire), method);
    }
    for (final state in ObserverAvailability.values) {
      expect(ObserverAvailability.fromWire(state.wire), state);
    }
    expect(SpeakerEvidenceMethod.fromWire('ocr'), isNull);
    expect(ObserverAvailability.fromWire(null), isNull);
  });

  test('shifting moves and widens the read, never narrows it', () {
    final shifted = make().shifted(500, extraUncertaintyUs: 100);
    expect(shifted.readStartUs, 1400);
    expect(shifted.readEndUs, 2600);
    expect(shifted.participants, make().participants);
    final negative = make().shifted(0, extraUncertaintyUs: -50);
    expect(negative.readStartUs, 1000);
    expect(negative.readEndUs, 2000);
  });

  test('construction enforces ordering and exposes immutable lists', () {
    expect(() => make(start: 5, end: 4), throwsArgumentError);
    final observation = make();
    expect(
      () => observation.participants.add(
        const ObservedParticipant(ref: 'b', name: 'Bo'),
      ),
      throwsUnsupportedError,
    );
    expect(observation.participant('a')?.name, 'Ada');
    expect(observation.participant('zz'), isNull);
    expect(observation.observedNoSpeaker, false);
  });
}
