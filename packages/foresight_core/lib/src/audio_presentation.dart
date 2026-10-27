/// Read-only audio values shared by service and desktop. No filesystem paths,
/// worker leases or persistence objects cross this boundary.
library;

enum MeetingAudioSource { microphone, playback }

enum MeetingAudioAvailability { none, pending, available, partial, missing }

enum MeetingAudioPhysicalState {
  idle,
  starting,
  recording,
  pausing,
  paused,
  stopping,
}

enum MeetingAudioWorkState { idle, pending, running, failed, complete }

enum MeetingAudioPlaybackState { idle, loading, playing, paused, failed }

enum MeetingAudioExportFormat { opus, mp3, wav }

/// Supplied only by the current capture owner. A database row is never evidence
/// that an operating-system device is still capturing.
final class AudioCaptureActivity {
  const AudioCaptureActivity({
    this.activeSessionId,
    this.state = MeetingAudioPhysicalState.idle,
    this.acquiredThroughUs,
  });
  final String? activeSessionId;
  final MeetingAudioPhysicalState state;
  final int? acquiredThroughUs;
  bool isRecording(String sessionId) =>
      activeSessionId == sessionId &&
      state == MeetingAudioPhysicalState.recording;
}

final class AudioSourceProcessingPresentation {
  const AudioSourceProcessingPresentation({
    required this.source,
    required this.pendingDurationUs,
    required this.pendingJobs,
    this.error = '',
    this.failedJobs = 0,
  });
  final MeetingAudioSource source;

  /// Acquired owned samples still awaiting recognition, excluding duplicated
  /// lookback/context and missing acquisition time.
  final int pendingDurationUs, pendingJobs;
  final int failedJobs;
  final String error;

  Map<String, Object?> toMap() => {
    'source': source.name,
    'pendingDurationUs': pendingDurationUs,
    'pendingJobs': pendingJobs,
    'failedJobs': failedJobs,
    'error': error,
  };
  factory AudioSourceProcessingPresentation.fromMap(Map<String, Object?> map) =>
      AudioSourceProcessingPresentation(
        source: MeetingAudioSource.values.byName(map['source'] as String),
        pendingDurationUs: map['pendingDurationUs'] as int,
        pendingJobs: map['pendingJobs'] as int,
        failedJobs: map['failedJobs'] as int? ?? 0,
        error: map['error'] as String,
      );
}

final class AudioWorkPresentation {
  const AudioWorkPresentation({
    this.state = MeetingAudioWorkState.idle,
    this.pending = 0,
    this.running = 0,
    this.completed = 0,
    this.failed = 0,
    this.error = '',
  });
  final MeetingAudioWorkState state;
  final int pending, running, completed, failed;
  final String error;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'pending': pending,
    'running': running,
    'completed': completed,
    'failed': failed,
    'error': error,
  };
  factory AudioWorkPresentation.fromMap(Map<String, Object?> map) =>
      AudioWorkPresentation(
        state: MeetingAudioWorkState.values.byName(map['state'] as String),
        pending: map['pending'] as int,
        running: map['running'] as int,
        completed: map['completed'] as int,
        failed: map['failed'] as int,
        error: map['error'] as String,
      );
}

final class AudioMeetingPresentation {
  const AudioMeetingPresentation({
    required this.meetingId,
    required this.sessionCount,
    required this.durationUs,
    required this.availability,
    required this.retainedBytes,
    required this.stagingBytes,
    required this.sources,
    required this.compression,
    this.activeSessionId,
    this.physicalState = MeetingAudioPhysicalState.idle,
    this.captureError = '',
    this.hasGaps = false,
  });
  final int meetingId, sessionCount, durationUs, retainedBytes, stagingBytes;
  final MeetingAudioAvailability availability;
  final String? activeSessionId;
  final MeetingAudioPhysicalState physicalState;
  final String captureError;
  final bool hasGaps;
  final List<AudioSourceProcessingPresentation> sources;
  final AudioWorkPresentation compression;
  bool get isRecording =>
      activeSessionId != null &&
      physicalState == MeetingAudioPhysicalState.recording;

  Map<String, Object?> toMap() => {
    'meetingId': meetingId,
    'sessionCount': sessionCount,
    'durationUs': durationUs,
    'availability': availability.name,
    'retainedBytes': retainedBytes,
    'stagingBytes': stagingBytes,
    'sources': sources.map((v) => v.toMap()).toList(),
    'compression': compression.toMap(),
    'activeSessionId': activeSessionId,
    'physicalState': physicalState.name,
    'captureError': captureError,
    'hasGaps': hasGaps,
  };
  factory AudioMeetingPresentation.fromMap(Map<String, Object?> map) =>
      AudioMeetingPresentation(
        meetingId: map['meetingId'] as int,
        sessionCount: map['sessionCount'] as int,
        durationUs: map['durationUs'] as int,
        availability: MeetingAudioAvailability.values.byName(
          map['availability'] as String,
        ),
        retainedBytes: map['retainedBytes'] as int,
        stagingBytes: map['stagingBytes'] as int,
        sources: List.unmodifiable(
          (map['sources'] as List).map(
            (v) => AudioSourceProcessingPresentation.fromMap(
              Map<String, Object?>.from(v as Map),
            ),
          ),
        ),
        compression: AudioWorkPresentation.fromMap(
          Map<String, Object?>.from(map['compression'] as Map),
        ),
        activeSessionId: map['activeSessionId'] as String?,
        physicalState: MeetingAudioPhysicalState.values.byName(
          map['physicalState'] as String,
        ),
        captureError: map['captureError'] as String,
        hasGaps: map['hasGaps'] as bool,
      );
}

final class AudioSessionPresentation {
  const AudioSessionPresentation({
    required this.id,
    required this.startedWallMs,
    required this.durationUs,
    required this.availability,
    required this.retainedBytes,
    required this.stagingBytes,
    required this.hasGaps,
    required this.sources,
    required this.compression,
    required this.export,
    this.physicalState = MeetingAudioPhysicalState.idle,
    this.captureError = '',
    this.canExport = false,
    this.exportFormats = const [],
    this.retainLossless = false,
    this.hasLosslessOriginals = false,
    this.canDeleteRecording = false,
    this.canChangeRetention = false,
    this.playbackSupported = false,
    this.canRetryTranscription = false,
    this.canRetryCompression = false,
  });
  final String id;
  final int startedWallMs, durationUs, retainedBytes, stagingBytes;
  final MeetingAudioAvailability availability;
  final MeetingAudioPhysicalState physicalState;
  final bool hasGaps, canExport;

  /// Verified service capabilities for this recording. Absent means unsupported.
  final List<MeetingAudioExportFormat> exportFormats;
  final bool retainLossless,
      hasLosslessOriginals,
      canDeleteRecording,
      canChangeRetention;
  final bool playbackSupported;
  final bool canRetryTranscription, canRetryCompression;
  final String captureError;
  final List<AudioSourceProcessingPresentation> sources;
  final AudioWorkPresentation compression, export;
  bool get isRecording => physicalState == MeetingAudioPhysicalState.recording;
  bool get canPlay =>
      playbackSupported &&
      (availability == MeetingAudioAvailability.available ||
          availability == MeetingAudioAvailability.partial);

  Map<String, Object?> toMap() => {
    'id': id,
    'startedWallMs': startedWallMs,
    'durationUs': durationUs,
    'availability': availability.name,
    'retainedBytes': retainedBytes,
    'stagingBytes': stagingBytes,
    'hasGaps': hasGaps,
    'sources': sources.map((v) => v.toMap()).toList(),
    'compression': compression.toMap(),
    'export': export.toMap(),
    'physicalState': physicalState.name,
    'captureError': captureError,
    'canExport': canExport,
    'exportFormats': exportFormats.map((v) => v.name).toList(),
    'retainLossless': retainLossless,
    'hasLosslessOriginals': hasLosslessOriginals,
    'canDeleteRecording': canDeleteRecording,
    'canChangeRetention': canChangeRetention,
    'playbackSupported': playbackSupported,
    'canRetryTranscription': canRetryTranscription,
    'canRetryCompression': canRetryCompression,
  };
  factory AudioSessionPresentation.fromMap(Map<String, Object?> map) =>
      AudioSessionPresentation(
        id: map['id'] as String,
        startedWallMs: map['startedWallMs'] as int,
        durationUs: map['durationUs'] as int,
        availability: MeetingAudioAvailability.values.byName(
          map['availability'] as String,
        ),
        retainedBytes: map['retainedBytes'] as int,
        stagingBytes: map['stagingBytes'] as int,
        hasGaps: map['hasGaps'] as bool,
        sources: List.unmodifiable(
          (map['sources'] as List).map(
            (v) => AudioSourceProcessingPresentation.fromMap(
              Map<String, Object?>.from(v as Map),
            ),
          ),
        ),
        compression: AudioWorkPresentation.fromMap(
          Map<String, Object?>.from(map['compression'] as Map),
        ),
        export: AudioWorkPresentation.fromMap(
          Map<String, Object?>.from(map['export'] as Map),
        ),
        physicalState: MeetingAudioPhysicalState.values.byName(
          map['physicalState'] as String,
        ),
        captureError: map['captureError'] as String,
        canExport: map['canExport'] as bool,
        exportFormats: List.unmodifiable(
          (map['exportFormats'] as List? ?? const []).map(
            (value) => MeetingAudioExportFormat.values.byName(value as String),
          ),
        ),
        retainLossless: map['retainLossless'] as bool? ?? false,
        hasLosslessOriginals: map['hasLosslessOriginals'] as bool? ?? false,
        canDeleteRecording: map['canDeleteRecording'] as bool? ?? false,
        canChangeRetention: map['canChangeRetention'] as bool? ?? false,
        playbackSupported: map['playbackSupported'] as bool? ?? false,
        canRetryTranscription: map['canRetryTranscription'] as bool? ?? false,
        canRetryCompression: map['canRetryCompression'] as bool? ?? false,
      );
}

/// Stable keyset ordering is source name then sequence within a session.
final class AudioClipPresentation {
  const AudioClipPresentation({
    required this.id,
    required this.source,
    required this.sequence,
    required this.playbackStartUs,
    required this.durationUs,
    required this.available,
    required this.gapBefore,
  });
  final String id;
  final MeetingAudioSource source;
  final int sequence, playbackStartUs, durationUs;
  final bool available, gapBefore;

  Map<String, Object?> toMap() => {
    'id': id,
    'source': source.name,
    'sequence': sequence,
    'playbackStartUs': playbackStartUs,
    'durationUs': durationUs,
    'available': available,
    'gapBefore': gapBefore,
  };
  factory AudioClipPresentation.fromMap(Map<String, Object?> map) =>
      AudioClipPresentation(
        id: map['id'] as String,
        source: MeetingAudioSource.values.byName(map['source'] as String),
        sequence: map['sequence'] as int,
        playbackStartUs: map['playbackStartUs'] as int,
        durationUs: map['durationUs'] as int,
        available: map['available'] as bool,
        gapBefore: map['gapBefore'] as bool,
      );
}

final class AudioPlaybackPresentation {
  const AudioPlaybackPresentation({
    this.state = MeetingAudioPlaybackState.idle,
    this.positionUs = 0,
    this.error = '',
  });
  final MeetingAudioPlaybackState state;
  final int positionUs;
  final String error;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'positionUs': positionUs,
    'error': error,
  };
  factory AudioPlaybackPresentation.fromMap(Map<String, Object?> map) =>
      AudioPlaybackPresentation(
        state: MeetingAudioPlaybackState.values.byName(map['state'] as String),
        positionUs: map['positionUs'] as int,
        error: map['error'] as String,
      );
}

/// A seek target is supplied only after the service validates the immutable
/// transcript audio link and current recording availability.
final class AudioTranscriptSeekTarget {
  const AudioTranscriptSeekTarget({
    required this.transcriptId,
    required this.sessionId,
    required this.playbackUs,
    this.playbackFrame,
  });
  final int transcriptId, playbackUs;
  final int? playbackFrame;
  final String sessionId;

  Map<String, Object?> toMap() => {
    'transcriptId': transcriptId,
    'sessionId': sessionId,
    'playbackUs': playbackUs,
    if (playbackFrame != null) 'playbackFrame': playbackFrame,
  };
  factory AudioTranscriptSeekTarget.fromMap(Map<String, Object?> map) =>
      AudioTranscriptSeekTarget(
        transcriptId: map['transcriptId'] as int,
        sessionId: map['sessionId'] as String,
        playbackUs: map['playbackUs'] as int,
        playbackFrame: map['playbackFrame'] as int?,
      );
}

/// One bounded service-owned read. Live media authority and physical activity
/// never originate in the desktop's independent SQLite reader.
final class AudioMeetingReadPage {
  const AudioMeetingReadPage({
    required this.meeting,
    required this.sessions,
    this.nextAfterId,
    this.playbackSessionId,
    this.playback = const AudioPlaybackPresentation(),
    this.supported = true,
    this.serviceError = '',
  });
  final AudioMeetingPresentation meeting;
  final List<AudioSessionPresentation> sessions;
  final String? nextAfterId, playbackSessionId;
  final AudioPlaybackPresentation playback;
  final bool supported;
  final String serviceError;
  Map<String, Object?> toMap() => {
    'meeting': meeting.toMap(),
    'sessions': sessions.map((s) => s.toMap()).toList(),
    'nextAfterId': nextAfterId,
    'playbackSessionId': playbackSessionId,
    'playback': playback.toMap(),
    'supported': supported,
    'serviceError': serviceError,
  };
  factory AudioMeetingReadPage.fromWire(Object? wire) {
    final map = Map<String, Object?>.from(wire as Map);
    return AudioMeetingReadPage(
      meeting: AudioMeetingPresentation.fromMap(
        Map<String, Object?>.from(map['meeting'] as Map),
      ),
      sessions: List.unmodifiable(
        (map['sessions'] as List).map(
          (s) => AudioSessionPresentation.fromMap(
            Map<String, Object?>.from(s as Map),
          ),
        ),
      ),
      nextAfterId: map['nextAfterId'] as String?,
      playbackSessionId: map['playbackSessionId'] as String?,
      playback: AudioPlaybackPresentation.fromMap(
        Map<String, Object?>.from(map['playback'] as Map),
      ),
      supported: map['supported'] as bool,
      serviceError: map['serviceError'] as String? ?? '',
    );
  }
}

final class AudioExportDestinationGrant {
  const AudioExportDestinationGrant(this.token);
  final String token;
  Map<String, Object?> toMap() => {'token': token};
  factory AudioExportDestinationGrant.fromWire(Object? wire) =>
      AudioExportDestinationGrant((wire as Map)['token'] as String);
}

final class AudioExportJobReceipt {
  const AudioExportJobReceipt(this.jobId);
  final String jobId;
  Map<String, Object?> toMap() => {'jobId': jobId};
  factory AudioExportJobReceipt.fromWire(Object? wire) =>
      AudioExportJobReceipt((wire as Map)['jobId'] as String);
}

AudioTranscriptSeekTarget? decodeAudioTranscriptTarget(Object? wire) =>
    wire == null
    ? null
    : AudioTranscriptSeekTarget.fromMap(Map<String, Object?>.from(wire as Map));
