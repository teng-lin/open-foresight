/// Durable audio identities use source sample frames and monotonic microseconds.
/// Wall-clock anchors are display metadata and never determine durations.
enum AudioSource { microphone, playback }

enum AudioCaptureState {
  starting,
  recording,
  pausing,
  paused,
  stopping,
  stopped,
  interrupted;

  bool get terminal => this == stopped || this == interrupted;
}

enum AudioJobState {
  pending,
  running,
  retry,
  blocked,
  failed,
  completed,
  abandoned,
}

enum AudioChunkState { reserved, published, missing, quarantined }

enum AudioRepresentationState {
  published,
  supersededPendingPurge,
  purged,
  missing,
}

final class AudioSession {
  const AudioSession({
    required this.id,
    required this.meetingId,
    required this.workspaceEpoch,
    required this.storageGeneration,
    required this.startedWallMs,
    required this.captureState,
    this.stoppedWallMs,
    this.lastSequence = -1,
    this.terminalError = '',
    this.retainLossless = false,
  });
  final String id, workspaceEpoch, storageGeneration, terminalError;
  final int meetingId, startedWallMs, lastSequence;
  final int? stoppedWallMs;
  final AudioCaptureState captureState;
  final bool retainLossless;
  factory AudioSession.fromRow(Map<String, Object?> r) => AudioSession(
    id: r['id'] as String,
    meetingId: r['meeting_id'] as int,
    workspaceEpoch: r['workspace_epoch'] as String,
    storageGeneration: r['storage_generation'] as String,
    startedWallMs: r['started_wall_ms'] as int,
    stoppedWallMs: r['stopped_wall_ms'] as int?,
    captureState: AudioCaptureState.values.byName(r['capture_state'] as String),
    lastSequence: r['last_sequence'] as int,
    terminalError: r['terminal_error'] as String,
    retainLossless: r['retain_lossless'] == 1,
  );
}

final class AudioSpan {
  const AudioSpan({
    required this.id,
    required this.sessionId,
    required this.ordinal,
    required this.captureStartUs,
    required this.playbackStartUs,
    required this.wallAnchorMs,
    this.captureEndUs,
    this.playbackEndUs,
    this.endReason,
  });
  final String id, sessionId;
  final int ordinal, captureStartUs, playbackStartUs, wallAnchorMs;
  final int? captureEndUs, playbackEndUs;
  final String? endReason;
  factory AudioSpan.fromRow(Map<String, Object?> r) => AudioSpan(
    id: r['id'] as String,
    sessionId: r['session_id'] as String,
    ordinal: r['ordinal'] as int,
    captureStartUs: r['capture_start_us'] as int,
    playbackStartUs: r['playback_start_us'] as int,
    wallAnchorMs: r['wall_anchor_ms'] as int,
    captureEndUs: r['capture_end_us'] as int?,
    playbackEndUs: r['playback_end_us'] as int?,
    endReason: r['end_reason'] as String?,
  );
}

/// A reservation survives rename-before-manifest crashes. Only its publication
/// token in the current admitted generation authorizes orphan adoption.
final class AudioChunk {
  const AudioChunk({
    required this.id,
    required this.sessionId,
    required this.spanId,
    required this.source,
    required this.sequence,
    required this.relativePath,
    required this.publicationToken,
    required this.storageGeneration,
    required this.sampleStart,
    required this.sampleCount,
    required this.sampleRate,
    required this.channels,
    required this.captureStartUs,
    required this.captureEndUs,
    required this.state,
    this.byteLength,
    this.sha256,
    this.interrupted = false,
    this.gapBefore = false,
  });
  final String id,
      sessionId,
      spanId,
      relativePath,
      publicationToken,
      storageGeneration;
  final AudioSource source;
  final int sequence,
      sampleStart,
      sampleCount,
      sampleRate,
      channels,
      captureStartUs,
      captureEndUs;
  final int? byteLength;
  final String? sha256;
  final AudioChunkState state;
  final bool interrupted, gapBefore;
  int get sampleEnd => sampleStart + sampleCount;
  factory AudioChunk.fromRow(Map<String, Object?> r) => AudioChunk(
    id: r['id'] as String,
    sessionId: r['session_id'] as String,
    spanId: r['span_id'] as String,
    source: AudioSource.values.byName(r['source'] as String),
    sequence: r['sequence'] as int,
    relativePath: r['relative_path'] as String,
    publicationToken: r['publication_token'] as String,
    storageGeneration: r['storage_generation'] as String,
    sampleStart: r['sample_start'] as int,
    sampleCount: r['sample_count'] as int,
    sampleRate: r['sample_rate'] as int,
    channels: r['channels'] as int,
    captureStartUs: r['capture_start_us'] as int,
    captureEndUs: r['capture_end_us'] as int,
    byteLength: r['byte_length'] as int?,
    sha256: r['sha256'] as String?,
    state: AudioChunkState.values.byName(r['state'] as String),
    interrupted: r['interrupted'] == 1,
    gapBefore: r['gap_before'] == 1,
  );
}

final class AudioRepresentation {
  const AudioRepresentation({
    required this.id,
    required this.chunkId,
    required this.codec,
    required this.container,
    required this.settingsRevision,
    required this.relativePath,
    required this.byteLength,
    required this.sha256,
    required this.decodedSamples,
    required this.state,
    this.preSkip = 0,
    this.validated = false,
  });
  final String id,
      chunkId,
      codec,
      container,
      settingsRevision,
      relativePath,
      sha256;
  final int byteLength, decodedSamples, preSkip;
  final AudioRepresentationState state;
  final bool validated;
  factory AudioRepresentation.fromRow(Map<String, Object?> r) =>
      AudioRepresentation(
        id: r['id'] as String,
        chunkId: r['chunk_id'] as String,
        codec: r['codec'] as String,
        container: r['container'] as String,
        settingsRevision: r['settings_revision'] as String,
        relativePath: r['relative_path'] as String,
        byteLength: r['byte_length'] as int,
        sha256: r['sha256'] as String,
        decodedSamples: r['decoded_samples'] as int,
        preSkip: r['pre_skip'] as int,
        state: r['state'] == 'superseded_pending_purge'
            ? AudioRepresentationState.supersededPendingPurge
            : AudioRepresentationState.values.byName(r['state'] as String),
        validated: r['validated'] == 1,
      );
}

final class AudioSegmentationCursor {
  const AudioSegmentationCursor({
    required this.sessionId,
    required this.spanId,
    required this.source,
    required this.settingsRevision,
    required this.modelRevision,
    required this.cursorSample,
    required this.retainFromSample,
    required this.context,
    required this.flushed,
    this.publicationSealed = false,
    this.error = '',
  });
  final String sessionId, spanId, settingsRevision, modelRevision, error;
  final AudioSource source;
  final int cursorSample, retainFromSample;
  final List<int> context;
  final bool flushed, publicationSealed;
  factory AudioSegmentationCursor.fromRow(Map<String, Object?> r) =>
      AudioSegmentationCursor(
        sessionId: r['session_id'] as String,
        spanId: r['span_id'] as String,
        source: AudioSource.values.byName(r['source'] as String),
        settingsRevision: r['settings_revision'] as String,
        modelRevision: r['model_revision'] as String,
        cursorSample: r['cursor_sample'] as int,
        retainFromSample: r['retain_from_sample'] as int,
        context: List<int>.unmodifiable(r['context'] as List<int>),
        flushed: r['flushed'] == 1,
        publicationSealed: r['publication_sealed'] == 1,
        error: r['error'] as String,
      );
}

/// Frozen ASR input includes context; only ownedStart..ownedEnd emits text.
final class AudioAsrRange {
  const AudioAsrRange({
    required this.id,
    required this.sampleStart,
    required this.sampleEnd,
    required this.ownedStart,
    required this.ownedEnd,
  });
  final String id;
  final int sampleStart, sampleEnd, ownedStart, ownedEnd;
}

final class AudioAsrJob {
  const AudioAsrJob({
    required this.id,
    required this.sessionId,
    required this.spanId,
    required this.source,
    required this.sampleStart,
    required this.sampleEnd,
    required this.ownedStart,
    required this.ownedEnd,
    required this.modelRevision,
    required this.settingsRevision,
    required this.state,
    required this.attempts,
    required this.leaseGeneration,
    required this.error,
    this.ownerGeneration,
  });
  final String id, sessionId, spanId, modelRevision, settingsRevision, error;
  final String? ownerGeneration;
  final AudioSource source;
  final int sampleStart,
      sampleEnd,
      ownedStart,
      ownedEnd,
      attempts,
      leaseGeneration;
  final AudioJobState state;
  factory AudioAsrJob.fromRow(Map<String, Object?> r) => AudioAsrJob(
    id: r['id'] as String,
    sessionId: r['session_id'] as String,
    spanId: r['span_id'] as String,
    source: AudioSource.values.byName(r['source'] as String),
    sampleStart: r['sample_start'] as int,
    sampleEnd: r['sample_end'] as int,
    ownedStart: r['owned_start'] as int,
    ownedEnd: r['owned_end'] as int,
    modelRevision: r['model_revision'] as String,
    settingsRevision: r['settings_revision'] as String,
    state: AudioJobState.values.byName(r['state'] as String),
    attempts: r['attempts'] as int,
    leaseGeneration: r['lease_generation'] as int,
    ownerGeneration: r['owner_generation'] as String?,
    error: r['error'] as String,
  );
}

final class AudioAsrLease {
  const AudioAsrLease(this.job, this.ownerGeneration, this.leaseGeneration);
  final AudioAsrJob job;
  final String ownerGeneration;
  final int leaseGeneration;
}

final class AudioTranscriptResult {
  const AudioTranscriptResult({
    required this.text,
    required this.sampleStart,
    required this.sampleEnd,
    required this.startMs,
    required this.endMs,
  });
  final String text;
  final int sampleStart, sampleEnd, startMs, endMs;
}

final class AudioResultCommit {
  const AudioResultCommit({
    required this.newlyCommitted,
    required this.meetingId,
    required this.transcriptIds,
  });
  final bool newlyCommitted;
  final int meetingId;
  final List<int> transcriptIds;
}

/// Persist before the first frame can be acquired; actual format/count/timing
/// are established at publication (including partial chunks on Pause/Stop).
final class AudioChunkPublication {
  const AudioChunkPublication({
    required this.id,
    required this.sessionId,
    required this.spanId,
    required this.source,
    required this.sequence,
    required this.relativePath,
    required this.publicationToken,
    required this.storageGeneration,
  });
  final String id,
      sessionId,
      spanId,
      relativePath,
      publicationToken,
      storageGeneration;
  final AudioSource source;
  final int sequence;
  factory AudioChunkPublication.fromRow(Map<String, Object?> r) =>
      AudioChunkPublication(
        id: r['id'] as String,
        sessionId: r['session_id'] as String,
        spanId: r['span_id'] as String,
        source: AudioSource.values.byName(r['source'] as String),
        sequence: r['sequence'] as int,
        relativePath: r['relative_path'] as String,
        publicationToken: r['publication_token'] as String,
        storageGeneration: r['storage_generation'] as String,
      );
}

enum AudioTransformKind { compression, export, playback }

final class AudioTransformJob {
  const AudioTransformJob({
    required this.id,
    required this.sessionId,
    required this.kind,
    required this.inputIdentity,
    required this.codec,
    required this.container,
    required this.settingsRevision,
    required this.settings,
    required this.state,
    required this.attempts,
    required this.leaseGeneration,
    required this.error,
    this.ownerGeneration,
    this.outputRepresentationId,
    this.outputMetadata,
  });
  final String id,
      sessionId,
      inputIdentity,
      codec,
      container,
      settingsRevision,
      settings,
      error;
  final String? ownerGeneration, outputRepresentationId, outputMetadata;
  final AudioTransformKind kind;
  final AudioJobState state;
  final int attempts, leaseGeneration;
  factory AudioTransformJob.fromRow(Map<String, Object?> r) =>
      AudioTransformJob(
        id: r['id'] as String,
        sessionId: r['session_id'] as String,
        kind: AudioTransformKind.values.byName(r['kind'] as String),
        inputIdentity: r['input_identity'] as String,
        codec: r['codec'] as String,
        container: r['container'] as String,
        settingsRevision: r['settings_revision'] as String,
        settings: r['settings'] as String,
        state: AudioJobState.values.byName(r['state'] as String),
        attempts: r['attempts'] as int,
        leaseGeneration: r['lease_generation'] as int,
        error: r['error'] as String,
        ownerGeneration: r['owner_generation'] as String?,
        outputRepresentationId: r['output_representation_id'] as String?,
        outputMetadata: r['output_metadata'] as String?,
      );
}

final class AudioTransformLease {
  const AudioTransformLease(
    this.job,
    this.ownerGeneration,
    this.leaseGeneration,
  );
  final AudioTransformJob job;
  final String ownerGeneration;
  final int leaseGeneration;
}

final class AudioTransformCommit {
  const AudioTransformCommit({required this.newlyCommitted, required this.job});
  final bool newlyCommitted;
  final AudioTransformJob job;
}

final class TranscriptAudioLink {
  const TranscriptAudioLink({
    required this.transcriptId,
    required this.jobId,
    required this.sessionId,
    required this.spanId,
    required this.ordinal,
    required this.transcriptRevision,
    required this.source,
    required this.sampleStart,
    required this.sampleEnd,
  });
  final String jobId, sessionId, spanId;
  final int transcriptId, ordinal, transcriptRevision, sampleStart, sampleEnd;
  final AudioSource source;
  factory TranscriptAudioLink.fromRow(Map<String, Object?> r) =>
      TranscriptAudioLink(
        transcriptId: r['transcript_id'] as int,
        jobId: r['job_id'] as String,
        sessionId: r['session_id'] as String,
        spanId: r['span_id'] as String,
        ordinal: r['ordinal'] as int,
        transcriptRevision: r['transcript_revision'] as int,
        source: AudioSource.values.byName(r['source'] as String),
        sampleStart: r['sample_start'] as int,
        sampleEnd: r['sample_end'] as int,
      );
}

/// Evidence describes clock provenance; a missing measurement stays null.
enum AudioSourceClockQuality {
  unavailable('unavailable'),
  hardwareHostTime('hardware_host_time'),
  pipeDrainEstimate('pipe_drain_estimate'),
  linuxPts('linux_pts'),
  pipewireHeaderPts('pipewire_header_pts'),
  pipewireGraphTime('pipewire_graph_time');

  const AudioSourceClockQuality(this.storedValue);
  final String storedValue;
}

final class AudioSourceClockEvidence {
  const AudioSourceClockEvidence({
    required this.spanId,
    required this.source,
    required this.revision,
    required this.quality,
    this.uncertaintyUs,
    this.observedCaptureUs,
  });
  final String spanId;
  final AudioSource source;
  final int revision;
  final AudioSourceClockQuality quality;
  final int? uncertaintyUs, observedCaptureUs;
  factory AudioSourceClockEvidence.fromRow(Map<String, Object?> r) =>
      AudioSourceClockEvidence(
        spanId: r['span_id'] as String,
        source: AudioSource.values.byName(r['source'] as String),
        revision: r['revision'] as int,
        quality: AudioSourceClockQuality.values.singleWhere(
          (q) => q.storedValue == r['quality'],
        ),
        uncertaintyUs: r['uncertainty_us'] as int?,
        observedCaptureUs: r['observed_capture_us'] as int?,
      );
}
