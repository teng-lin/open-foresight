import '../audio_presentation.dart';

/// Physical worker barriers supplied by the service owner. Configuration keeps
/// its existing reservation until these model leases are retired and resumed.
abstract interface class AudioApplicationLifecycle {
  bool get busy;
  Future<void> suspendForModelChange();
  Future<void> resumeAfterModelChange();
  Future<void> clearWorkspace(Future<void> Function() clear);
  void invalidateCaller(Object caller);
  Future<void> close();
}

/// The application owner supplies actual media/capture/playback/export workers.
/// All async boundaries must recheck [current], workspace and storage generation.
abstract interface class AudioApplicationPort {
  Future<AudioMeetingReadPage> readMeeting(
    int meetingId, {
    String afterSessionId = '',
    int limit = 32,
    required bool Function() current,
  });
  Future<AudioTranscriptSeekTarget?> transcriptTarget(
    int transcriptId, {
    required bool Function() current,
  });
  Future<void> play(String sessionId, {required bool Function() current});
  Future<void> pauseAudio(String sessionId, {required bool Function() current});
  Future<void> seek(
    String sessionId,
    int playbackUs, {
    required bool Function() current,
  });
  Future<void> seekTranscript(
    String sessionId,
    int transcriptId, {
    required bool Function() current,
  });
  Future<void> cancelExport(
    String sessionId, {
    required bool Function() current,
  });

  /// Retry only existing failed/blocked jobs with their frozen model/settings.
  /// Revalidate media authority and wake the scheduler without retargeting jobs.
  Future<void> retryTranscription(
    String sessionId, {
    required bool Function() current,
  });

  /// Retry only existing failed/blocked jobs with their frozen model/settings.
  /// Revalidate media authority and wake the scheduler without retargeting jobs.
  Future<void> retryCompression(
    String sessionId, {
    required bool Function() current,
  });

  /// Fence capture, workers, playback, exports, backups and real filesystem
  /// readers before committing the audio tombstone. Transcript text survives.
  Future<void> deleteRecording(
    String sessionId, {
    required bool Function() current,
  });

  /// Join any active raw purge before acknowledgement. This changes remaining
  /// originals only; it cannot recreate an already removed lossless file.
  Future<void> setRetainLossless(
    String sessionId,
    bool value, {
    required bool Function() current,
  });

  /// Only an attached desktop host may mint this one-use grant after its native
  /// save picker. Bind exact session, epoch, caller lifetime, format, partial and
  /// overwrite choices plus an anchored output identity. Never grant profile or
  /// managed-media overwrites. No caller-selected input media paths are accepted.
  Future<AudioExportDestinationGrant> authorizeExportDestination({
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required String outputPath,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  });

  /// Consume the grant once; this request cannot widen any of its permissions.
  Future<AudioExportJobReceipt> export({
    required String sessionId,
    required Object callerIdentity,
    required String workspaceEpoch,
    required MeetingAudioExportFormat format,
    required String destinationToken,
    required bool overwrite,
    required bool allowIncomplete,
    required bool Function() current,
  });
}
