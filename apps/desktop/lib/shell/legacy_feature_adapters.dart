part of '../application.dart';

/// Narrow bridges for features that still belong to the application library.
/// Each bridge leaves state and resources with the existing feature owner.
final class _LegacyPreferenceCommands implements PreferenceCommands {
  const _LegacyPreferenceCommands(this.owner);
  final _SettingsController owner;

  @override
  Future<void> preference(String key, String value) =>
      owner.preference(key, value);
}

final class _LegacyMeetingPorts implements MeetingActivity, MeetingCommands {
  const _LegacyMeetingPorts(this.owner);
  final _MeetingsController owner;

  @override
  int? get selectedMeetingId => owner.meetingId;
  @override
  int? get previewMeetingId => owner.meetingPreviewId;
  @override
  RecordingSnapshot? get recording {
    final status = owner.recording;
    if (status == null) return null;
    if (status is RecordingSnapshot) return status;
    return RecordingSnapshot({
      'finishing': status.finishing,
      'paused': status.paused,
      'echo_cancellation': status.echoCancellationState,
      'samples': status.sampleCounts,
      'volumes': status.currentVolumes,
      'peaks': status.peakVolumes,
      'last_audio': status.lastAudioActivity.millisecondsSinceEpoch,
    });
  }

  @override
  bool get meetingEnhancing => owner.meetingEnhancing;
  @override
  bool get systemAudioSetupReviewed => owner.systemAudioSetupReviewed;
  @override
  String get echoCancellationDescription => owner.echoCancellationDescription;
  @override
  Future<void> quickStart() => owner.quickStart();
  @override
  void setSystemAudioSetupReviewed(bool reviewed) =>
      owner.update(() => owner.systemAudioSetupReviewed = reviewed);
}

final class _LegacyOnboardingActivity implements OnboardingActivity {
  const _LegacyOnboardingActivity(this.owner);
  final _OnboardingController owner;

  @override
  bool get active => owner.active;
}
