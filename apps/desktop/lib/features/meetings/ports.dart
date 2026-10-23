import 'package:foresight_core/desktop.dart';

abstract interface class MeetingActivity {
  int? get selectedMeetingId;
  int? get previewMeetingId;
  RecordingSnapshot? get recording;
  bool get meetingEnhancing;
  bool get systemAudioSetupReviewed;
  String get echoCancellationDescription;
}

abstract interface class MeetingCommands {
  Future<void> quickStart();
  void setSystemAudioSetupReviewed(bool reviewed);
}
