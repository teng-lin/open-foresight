/// Channel labels recovered from the original SpeakerIdManager contract.
/// These identify capture routes, not distinct people in a room or call.
enum MeetingSpeaker {
  microphone(0, 'Microphone'),
  remote(1, 'Remote'),
  unknown(null, 'Unknown');

  const MeetingSpeaker(this.id, this.label);
  final int? id;
  final String label;

  static MeetingSpeaker fromId(int? id) => switch (id) {
    0 => microphone,
    1 => remote,
    _ => unknown,
  };

  static MeetingSpeaker fromSource(String source) => switch (source) {
    'microphone' || 'microphone-capture-interruption' => microphone,
    'playback' || 'playback-capture-interruption' => remote,
    _ => unknown,
  };
}

const meetingSpeakerInstructions =
    'Microphone, Remote, and Unknown are audio channel labels, not people or '
    'speaker names. Never attribute statements or actions to those labels. '
    'Attribute a point to a real person only when their name is clearly '
    'established in the transcript; otherwise describe the point without '
    'inventing a speaker.';
