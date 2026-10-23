import 'package:foresight_core/desktop.dart';
import 'ports.dart';

/// Composition defers cyclic command dependencies until the command is used.
final class PreferenceCommandBridge implements PreferenceCommands {
  const PreferenceCommandBridge(this.write);
  final Future<void> Function(String, String) write;
  @override
  Future<void> preference(String key, String value) => write(key, value);
}

final class OnboardingActivityBridge implements OnboardingActivity {
  const OnboardingActivityBridge(this.readActive);
  final bool Function() readActive;
  @override
  bool get active => readActive();
}

final class MeetingPortsBridge implements MeetingActivity, MeetingCommands {
  const MeetingPortsBridge(this.activity, this.commands);
  final MeetingActivity Function() activity;
  final MeetingCommands Function() commands;
  @override
  int? get selectedMeetingId => activity().selectedMeetingId;
  @override
  int? get previewMeetingId => activity().previewMeetingId;
  @override
  RecordingSnapshot? get recording => activity().recording;
  @override
  bool get meetingEnhancing => activity().meetingEnhancing;
  @override
  bool get systemAudioSetupReviewed => activity().systemAudioSetupReviewed;
  @override
  String get echoCancellationDescription =>
      activity().echoCancellationDescription;
  @override
  Future<void> quickStart() => commands().quickStart();
  @override
  void setSystemAudioSetupReviewed(bool reviewed) =>
      commands().setSystemAudioSetupReviewed(reviewed);
}
