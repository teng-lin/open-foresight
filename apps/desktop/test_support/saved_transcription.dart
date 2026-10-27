import 'package:foresight_core/desktop.dart';

/// Read-only acceptance predicate after the caller observes capture closure.
/// Pending duration includes acquired tails not yet admitted as ASR jobs. The
/// caller owns the existing workflow deadline; conversion availability is
/// independent of transcription and does not gate this read.
Future<AudioMeetingReadPage?> readSettledSavedTranscription(
  DesktopConnection connection,
  int meetingId,
) async {
  final page = AudioMeetingReadPage.fromWire(
    await connection.command(Operation.recordingsRead, {
      'meeting_id': meetingId,
    }),
  );
  final audio = page.meeting;
  if (!page.supported ||
      page.sessions.isEmpty ||
      audio.sessionCount == 0 ||
      audio.retainedBytes == 0 ||
      audio.activeSessionId != null ||
      audio.physicalState != MeetingAudioPhysicalState.idle ||
      audio.captureError.isNotEmpty ||
      !audio.sources
          .map((source) => source.source)
          .toSet()
          .containsAll(MeetingAudioSource.values) ||
      audio.sources.any(
        (source) =>
            source.pendingDurationUs != 0 ||
            source.pendingJobs != 0 ||
            source.failedJobs != 0 ||
            source.error.isNotEmpty,
      )) {
    return null;
  }
  return page;
}
