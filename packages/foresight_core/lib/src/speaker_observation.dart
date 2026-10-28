/// Meeting-observer domain values shared by the protocol codec, the supervised
/// observer and the attributor. Every string here originates in another
/// application's accessibility tree and is untrusted source data.
library;

/// Evidence path that produced an active-speaker candidate.
enum SpeakerEvidenceMethod {
  participantStatus('participant_status'),
  compactTalkingLabel('compact_talking_label'),
  orderedTile('ordered_tile'),
  atspiState('atspi_state');

  const SpeakerEvidenceMethod(this.wire);
  final String wire;

  static SpeakerEvidenceMethod? fromWire(Object? value) {
    for (final method in values) {
      if (method.wire == value) return method;
    }
    return null;
  }
}

/// Helper-reported ability to observe the selected meeting.
enum ObserverAvailability {
  available('available'),
  needsSetup('needs_setup'),
  permissionDenied('permission_denied'),
  zoomNotRunning('zoom_not_running'),
  noMeeting('no_meeting'),
  unsupportedVersion('unsupported_version'),
  unsupportedPlatform('unsupported_platform'),
  unavailable('unavailable');

  const ObserverAvailability(this.wire);
  final String wire;

  static ObserverAvailability? fromWire(Object? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// Process and window an observation was read from.
final class ObservationTarget {
  const ObservationTarget({
    required this.pid,
    required this.window,
    this.zoomVersion,
    this.locale,
  });
  final int pid;
  final String window;
  final String? zoomVersion, locale;

  @override
  bool operator ==(Object other) =>
      other is ObservationTarget &&
      other.pid == pid &&
      other.window == window &&
      other.zoomVersion == zoomVersion &&
      other.locale == locale;

  @override
  int get hashCode => Object.hash(pid, window, zoomVersion, locale);
}

/// A roster entry. [ref] is meeting-local: valid only within one session and
/// window, and never a durable user identifier. Equal names with different refs
/// are different participants.
final class ObservedParticipant {
  const ObservedParticipant({
    required this.ref,
    required this.name,
    this.isSelf = false,
  });
  final String ref, name;
  final bool isSelf;

  @override
  bool operator ==(Object other) =>
      other is ObservedParticipant &&
      other.ref == ref &&
      other.name == name &&
      other.isSelf == isSelf;

  @override
  int get hashCode => Object.hash(ref, name, isSelf);
}

/// A participant the helper observed to be the active speaker.
final class SpeakerCandidate {
  const SpeakerCandidate({required this.ref, required this.method});
  final String ref;
  final SpeakerEvidenceMethod method;

  @override
  bool operator ==(Object other) =>
      other is SpeakerCandidate && other.ref == ref && other.method == method;

  @override
  int get hashCode => Object.hash(ref, method);
}

/// One accessibility read. Times are microseconds on the clock domain named by
/// the producer: the helper's clock until the observer applies a measured
/// offset, then the capture clock.
final class SpeakerObservation {
  SpeakerObservation({
    required this.session,
    required this.readStartUs,
    required this.readEndUs,
    required this.target,
    required this.complete,
    required this.parserVersion,
    required List<ObservedParticipant> participants,
    required List<SpeakerCandidate> speakers,
  }) : participants = List.unmodifiable(participants),
       speakers = List.unmodifiable(speakers) {
    if (readEndUs < readStartUs) {
      throw ArgumentError('Observation read ends before it starts');
    }
    final refs = <String>{};
    for (final participant in this.participants) {
      if (!refs.add(participant.ref)) {
        throw ArgumentError('Duplicate participant reference');
      }
    }
    final speakerRefs = <String>{};
    for (final speaker in this.speakers) {
      if (!refs.contains(speaker.ref) || !speakerRefs.add(speaker.ref)) {
        throw ArgumentError('Speaker is not a unique roster entry');
      }
    }
  }
  final String session, parserVersion;
  final int readStartUs, readEndUs;
  final ObservationTarget target;
  final bool complete;
  final List<ObservedParticipant> participants;
  final List<SpeakerCandidate> speakers;

  /// A complete read that saw no active speaker. A partial read never qualifies.
  bool get observedNoSpeaker => complete && speakers.isEmpty;

  ObservedParticipant? participant(String ref) {
    for (final candidate in participants) {
      if (candidate.ref == ref) return candidate;
    }
    return null;
  }

  /// Moves the read window to another clock domain. [extraUncertaintyUs] widens
  /// it symmetrically so offset error can never shrink the claimed interval.
  SpeakerObservation shifted(int offsetUs, {int extraUncertaintyUs = 0}) {
    final slack = extraUncertaintyUs < 0 ? 0 : extraUncertaintyUs;
    return SpeakerObservation(
      session: session,
      readStartUs: readStartUs + offsetUs - slack,
      readEndUs: readEndUs + offsetUs + slack,
      target: target,
      complete: complete,
      parserVersion: parserVersion,
      participants: participants,
      speakers: speakers,
    );
  }
}

/// A period during which the helper reported it could not observe the meeting.
/// [endUs] is null while the interval is still open.
final class ObserverUnavailableInterval {
  const ObserverUnavailableInterval({
    required this.startUs,
    required this.reason,
    this.endUs,
  });
  final int startUs;
  final int? endUs;
  final String reason;
}

/// Characters removed from untrusted participant names because they have no
/// visible form or change how surrounding text is displayed: soft hyphen,
/// Arabic letter mark, zero-width space, directional marks, embeddings and
/// isolates, the word joiner and invisible math operators, deprecated format
/// controls, variation selectors, the byte-order mark and tag characters.
/// The joiners U+200C and U+200D are not here: some names need them, but they
/// are never visible by themselves ([hasVisibleNameCharacter]). The persistence
/// layer strips and judges exactly the same set.
bool isStrippedNameRune(int rune) =>
    rune == 0x00ad ||
    rune == 0x061c ||
    rune == 0x200b ||
    (rune >= 0x200e && rune <= 0x200f) ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x2064) ||
    (rune >= 0x2066 && rune <= 0x206f) ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    rune == 0xfeff ||
    (rune >= 0xe0000 && rune <= 0xe007f) ||
    (rune >= 0xe0100 && rune <= 0xe01ef);

/// Whether [name] shows at least one character: not only whitespace, joiners
/// or characters [isStrippedNameRune] removes.
bool hasVisibleNameCharacter(String name) {
  for (final rune in name.runes) {
    final blank =
        rune <= 0x20 ||
        (rune >= 0x7f && rune <= 0xa0) ||
        rune == 0x2028 ||
        rune == 0x2029 ||
        rune == 0x200c ||
        rune == 0x200d;
    if (!blank && !isStrippedNameRune(rune)) return true;
  }
  return false;
}
