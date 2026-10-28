/// Whether participant names can currently be attached to speech. It is
/// independent of recording health: capture continues when naming is not
/// available, and a name never changes what was recorded.
enum SpeakerNamingState { ready, needsSetup, unavailable }

/// The UI-facing naming availability. A null status means the read side has no
/// capability data yet, and the transcript shows nothing about naming.
final class SpeakerNamingStatus {
  const SpeakerNamingStatus(this.state, {this.detail = ''});
  final SpeakerNamingState state;

  /// Short, user-readable reason; shown as a tooltip.
  final String detail;

  String get label => switch (state) {
    SpeakerNamingState.ready => 'Speaker names: on',
    SpeakerNamingState.needsSetup => 'Speaker names: needs setup',
    SpeakerNamingState.unavailable => 'Speaker names: unavailable',
  };
}
