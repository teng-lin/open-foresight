import '../audio_presentation.dart';
import 'audio_store.dart';
import 'read_schema_guard.dart';
import 'audio_playback_timeline.dart';

/// Metadata projections only. Availability additionally requires the independent
/// live media-root binding; no restored SQL flag alone admits playback.
final class AudioQueries {
  AudioQueries(this.audio);
  final AudioStore audio;

  T _snapshot<T>(T Function() read) =>
      readSnapshot(audio.db, read, supportedVersion: audio.supportedVersion);

  AudioMeetingPresentation meeting(
    int meetingId, {
    AudioCaptureActivity activity = const AudioCaptureActivity(),
    int? estimatedRemainingRecordingUs,
  }) => _snapshot(() {
    final totals = _totals(meetingId: meetingId);
    final active = activity.activeSessionId == null
        ? null
        : audio.db.select(
            'SELECT id FROM recording_sessions WHERE id=? AND meeting_id=? AND storage_generation=? AND workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=recording_sessions.id)',
            [
              activity.activeSessionId,
              meetingId,
              audio.storageGeneration,
              audio.workspaceEpoch(),
            ],
          ).firstOrNull;
    final admitted = audio.mediaAdmitted && active != null;
    final state = admitted ? activity.state : MeetingAudioPhysicalState.idle;
    if (admitted && activity.acquiredThroughUs != null) {
      final saved = _totals(sessionId: activity.activeSessionId);
      final live = _totals(
        sessionId: activity.activeSessionId,
        activity: activity,
      );
      totals['duration'] =
          totals['duration']! + live['duration']! - saved['duration']!;
    }
    return AudioMeetingPresentation(
      meetingId: meetingId,
      estimatedRemainingRecordingUs: estimatedRemainingRecordingUs,
      sessionCount: totals['sessions']!,
      durationUs: totals['duration']!,
      availability: _availability(totals),
      retainedBytes: totals['retained']!,
      stagingBytes: totals['staging']!,
      hasGaps: totals['gaps']! > 0,
      sources: _sources(meetingId: meetingId),
      compression: _work('compression', meetingId: meetingId),
      activeSessionId: admitted ? activity.activeSessionId : null,
      physicalState: state,
      captureError: _captureError(meetingId: meetingId),
    );
  });

  /// Fetch subsequent pages with the last returned id. Id order deliberately
  /// remains stable even if wall-clock display anchors are corrected.
  List<AudioSessionPresentation> sessions(
    int meetingId, {
    String afterId = '',
    int limit = 32,
    AudioCaptureActivity activity = const AudioCaptureActivity(),
    List<MeetingAudioExportFormat> exportFormats = const [],
    bool allowDeleteRecordings = false,
    bool allowRetentionChanges = false,
    bool playbackSupported = false,
    bool allowRetryTranscription = false,
    bool allowRetryCompression = false,
  }) => _snapshot(() {
    _limit(limit);
    return List.unmodifiable(
      audio.db
          .select(
            'SELECT id,started_wall_ms,terminal_error,capture_state,retain_lossless,workspace_epoch FROM recording_sessions WHERE meeting_id=? AND id>? ORDER BY id LIMIT ?',
            [meetingId, afterId, limit],
          )
          .map((r) {
            final id = r['id'] as String;
            final totals = _totals(sessionId: id, activity: activity);
            final isOwner =
                _mediaForSession(id) && activity.activeSessionId == id;
            return AudioSessionPresentation(
              id: id,
              startedWallMs: r['started_wall_ms'] as int,
              durationUs: totals['duration']!,
              availability: _availability(totals),
              retainedBytes: totals['retained']!,
              stagingBytes: totals['staging']!,
              hasGaps: totals['gaps']! > 0,
              sources: _sources(sessionId: id),
              compression: _work('compression', sessionId: id),
              export: _work('export', sessionId: id),
              physicalState: isOwner
                  ? activity.state
                  : MeetingAudioPhysicalState.idle,
              captureError: r['terminal_error'] as String,
              exportFormats: List.unmodifiable(exportFormats.toSet()),
              retainLossless: r['retain_lossless'] == 1,
              playbackSupported: playbackSupported,
              canRetryTranscription:
                  allowRetryTranscription &&
                  _mediaForSession(id) &&
                  audio.db.select(
                    "SELECT 1 FROM audio_asr_jobs WHERE session_id=? AND state IN ('failed','blocked') LIMIT 1",
                    [id],
                  ).isNotEmpty,
              canRetryCompression:
                  allowRetryCompression &&
                  _mediaForSession(id) &&
                  audio.db.select(
                    "SELECT 1 FROM audio_transform_jobs WHERE session_id=? AND kind='compression' AND state IN ('failed','blocked') LIMIT 1",
                    [id],
                  ).isNotEmpty,
              hasLosslessOriginals: totals['raw']! > 0,
              canDeleteRecording:
                  allowDeleteRecordings &&
                  audio.mediaGeneration != null &&
                  audio.mediaGeneration!() == audio.storageGeneration &&
                  r['workspace_epoch'] == audio.workspaceEpoch() &&
                  (r['capture_state'] == 'stopped' ||
                      r['capture_state'] == 'interrupted') &&
                  (activity.activeSessionId != id ||
                      activity.state == MeetingAudioPhysicalState.idle),
              canChangeRetention:
                  allowRetentionChanges &&
                  _mediaForSession(id) &&
                  totals['raw']! > 0,
              canExport:
                  exportFormats.isNotEmpty &&
                  _mediaForSession(id) &&
                  totals['usable']! > 0 &&
                  (r['capture_state'] == 'stopped' ||
                      r['capture_state'] == 'interrupted') &&
                  audio.db.select(
                    'SELECT 1 FROM recording_spans WHERE session_id=? AND capture_end_us IS NULL LIMIT 1',
                    [id],
                  ).isEmpty,
            );
          }),
    );
  });

  List<AudioClipPresentation> clips(
    String sessionId, {
    String afterSource = '',
    int afterSequence = -1,
    int limit = 64,
  }) => _snapshot(() {
    _limit(limit);
    final admitted = _mediaForSession(sessionId);
    return List.unmodifiable(
      audio.db
          .select(
            '''SELECT c.*,s.playback_start_us,s.capture_start_us AS span_start,
      EXISTS(SELECT 1 FROM audio_representations r WHERE r.chunk_id=c.id AND r.state='published' AND r.validated=1) AS usable
      FROM audio_chunks c JOIN recording_spans s ON s.id=c.span_id
      WHERE c.session_id=? AND (c.source>? OR (c.source=? AND c.sequence>?)) ORDER BY c.source,c.sequence LIMIT ?''',
            [sessionId, afterSource, afterSource, afterSequence, limit],
          )
          .map(
            (r) => AudioClipPresentation(
              id: r['id'] as String,
              source: MeetingAudioSource.values.byName(r['source'] as String),
              sequence: r['sequence'] as int,
              playbackStartUs:
                  (r['playback_start_us'] as int) +
                  (r['capture_start_us'] as int) -
                  (r['span_start'] as int),
              durationUs:
                  (r['capture_end_us'] as int) - (r['capture_start_us'] as int),
              available:
                  admitted &&
                  r['storage_generation'] == audio.storageGeneration &&
                  r['state'] == 'published' &&
                  r['usable'] == 1,
              gapBefore: r['gap_before'] == 1,
            ),
          ),
    );
  });

  /// Links are explicit ownership metadata. Legacy text timestamps alone never
  /// authorize a seek, and absent restored media never produces a target.
  AudioTranscriptSeekTarget? transcriptSeekTarget(
    int transcriptId,
  ) => _snapshot(() {
    final row = audio.db
        .select(
          '''SELECT j.session_id,c.id AS chunk_id,c.storage_generation,c.sample_start,l.sample_start AS target_sample
      FROM transcript_audio_links l JOIN transcript t ON t.id=l.transcript_id
      JOIN audio_asr_jobs j ON j.id=l.job_id JOIN recording_sessions s ON s.id=j.session_id AND s.meeting_id=t.meeting_id
      JOIN recording_spans sp ON sp.id=j.span_id JOIN audio_chunks c ON c.span_id=j.span_id AND c.session_id=j.session_id AND c.source=l.source AND c.sample_start<=l.sample_start AND c.sample_start+c.sample_count>l.sample_start
      WHERE l.transcript_id=? AND c.state='published' AND EXISTS(SELECT 1 FROM audio_representations r WHERE r.chunk_id=c.id AND r.state='published' AND r.validated=1) LIMIT 1''',
          [transcriptId],
        )
        .firstOrNull;
    if (row == null ||
        !_mediaForSession(row['session_id'] as String) ||
        row['storage_generation'] != audio.storageGeneration) {
      return null;
    }
    final String sessionId = row['session_id'] as String;
    final AudioPlaybackChunk? chunk;
    try {
      chunk = audio.playbackTimeline.chunk(
        sessionId,
        row['chunk_id'] as String,
        authority: audio.playbackTimelineAuthority,
      );
    } on AudioPlaybackTimelineError {
      return null;
    }
    if (chunk == null) return null;
    final frame =
        chunk.startFrame +
        (row['target_sample'] as int) -
        (row['sample_start'] as int);
    return AudioTranscriptSeekTarget(
      transcriptId: transcriptId,
      sessionId: sessionId,
      playbackFrame: frame,
      playbackUs: frame * 1000000 ~/ 48000,
    );
  });

  bool _mediaForSession(String id) {
    final session = audio.session(id);
    return audio.mediaAdmitted &&
        session?.storageGeneration == audio.storageGeneration &&
        session?.workspaceEpoch == audio.workspaceEpoch() &&
        audio.db.select(
          'SELECT 1 FROM audio_erasure_intents WHERE session_id=?',
          [id],
        ).isEmpty;
  }

  String _scope(int? meetingId, String? sessionId, [String alias = 's']) =>
      sessionId != null ? '$alias.id=?' : '$alias.meeting_id=?';
  Object _key(int? meetingId, String? sessionId) => sessionId ?? meetingId!;
  void _limit(int limit) =>
      RangeError.checkValueInInterval(limit, 1, 128, 'limit');

  Map<String, int> _totals({
    int? meetingId,
    String? sessionId,
    AudioCaptureActivity activity = const AudioCaptureActivity(),
  }) {
    final scope = _scope(meetingId, sessionId);
    final key = _key(meetingId, sessionId);
    final generation = audio.mediaAdmitted ? audio.storageGeneration : '';
    final r = audio.db
        .select(
          '''WITH sessions AS (SELECT * FROM recording_sessions s WHERE $scope),
      chunks AS (SELECT c.* FROM audio_chunks c JOIN sessions s ON s.id=c.session_id),
      choices AS (SELECT c.id,c.gap_before,c.state,
        CASE WHEN c.state='published' AND c.storage_generation=? AND c.session_id IN (SELECT id FROM sessions WHERE workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=sessions.id)) THEN (SELECT r.byte_length FROM audio_representations r WHERE r.chunk_id=c.id AND r.state='published' AND r.validated=1 ORDER BY CASE WHEN r.codec='opus' THEN 0 ELSE 1 END,r.id LIMIT 1) END AS retained FROM chunks c),
      extents AS (SELECT sp.session_id,MAX(COALESCE(sp.playback_end_us,sp.playback_start_us+MAX(0,COALESCE((SELECT MAX(c.capture_end_us) FROM chunks c WHERE c.span_id=sp.id),sp.capture_start_us)-sp.capture_start_us))) AS duration FROM recording_spans sp JOIN sessions s ON s.id=sp.session_id GROUP BY sp.session_id)
      SELECT (SELECT COUNT(*) FROM sessions) AS sessions,
        COALESCE((SELECT SUM(duration) FROM extents),0) AS duration,
        (SELECT COUNT(*) FROM choices) AS chunks,
        (SELECT COUNT(*) FROM choices WHERE retained IS NOT NULL) AS usable,
        (SELECT COUNT(*) FROM audio_representations r JOIN choices c ON c.id=r.chunk_id WHERE c.retained IS NOT NULL AND r.codec='pcm_s16le' AND r.state='published' AND r.validated=1) AS raw,
        (SELECT COUNT(*) FROM choices WHERE gap_before=1 OR state IN ('missing','quarantined')) AS gaps,
        COALESCE((SELECT SUM(retained) FROM choices),0) AS retained,
        COALESCE((SELECT SUM(r.byte_length) FROM audio_representations r JOIN chunks c ON c.id=r.chunk_id WHERE r.state IN ('published','superseded_pending_purge')),0) AS bytes,
        (SELECT COUNT(*) FROM audio_chunk_publications p JOIN sessions s ON s.id=p.session_id WHERE NOT EXISTS(SELECT 1 FROM chunks c WHERE c.id=p.id)) AS reservations''',
          [key, generation, audio.workspaceEpoch()],
        )
        .single;
    final result = <String, int>{
      for (final name in [
        'sessions',
        'duration',
        'chunks',
        'usable',
        'raw',
        'gaps',
        'retained',
        'bytes',
        'reservations',
      ])
        name: r[name] as int,
    };
    result['staging'] = result['bytes']! - result['retained']!;
    // Closed-session extents use the same sample grid as playback and export.
    // The scalar LRU survives geometry-plan eviction and ignores ASR writes.
    var after = '';
    while (true) {
      final closed = audio.db.select(
        '''SELECT s.id,COALESCE(MAX(sp.playback_end_us),0) AS old_duration
        FROM recording_sessions s LEFT JOIN recording_spans sp ON sp.session_id=s.id
        WHERE $scope AND s.id>? AND s.capture_state IN ('stopped','interrupted')
        AND NOT EXISTS(SELECT 1 FROM recording_spans p WHERE p.session_id=s.id AND p.capture_end_us IS NULL)
        GROUP BY s.id ORDER BY s.id LIMIT 128''',
        [key, after],
      );
      if (closed.isEmpty) break;
      for (final session in closed) {
        try {
          final frames = audio.playbackTimeline.durationFrames(
            session['id'] as String,
            authority: audio.playbackTimelineAuthority,
          );
          result['duration'] =
              result['duration']! -
              (session['old_duration'] as int) +
              frames * 1000000 ~/ 48000;
        } on AudioPlaybackTimelineError {
          // Ambiguous geometry cannot authorize a seek/render. Preserve the
          // original clock metadata and surface incomplete availability.
          result['gaps'] = result['gaps']! + 1;
        }
      }
      after = closed.last['id'] as String;
    }
    // Open capture can display only the owner's acquired extent, never now().
    if (sessionId != null &&
        activity.activeSessionId == sessionId &&
        _mediaForSession(sessionId) &&
        activity.acquiredThroughUs != null) {
      final open = audio.db.select(
        'SELECT capture_start_us,playback_start_us FROM recording_spans WHERE session_id=? AND capture_end_us IS NULL',
        [sessionId],
      ).firstOrNull;
      if (open != null &&
          activity.acquiredThroughUs! >= (open['capture_start_us'] as int)) {
        final extent =
            (open['playback_start_us'] as int) +
            activity.acquiredThroughUs! -
            (open['capture_start_us'] as int);
        if (extent > result['duration']!) {
          result['duration'] = extent;
        }
      }
    }
    return result;
  }

  MeetingAudioAvailability _availability(Map<String, int> t) {
    if (t['chunks'] == 0) {
      return t['reservations']! > 0
          ? MeetingAudioAvailability.pending
          : MeetingAudioAvailability.none;
    }
    if (t['usable'] == 0) return MeetingAudioAvailability.missing;
    if (t['usable'] != t['chunks'] || t['gaps']! > 0) {
      return MeetingAudioAvailability.partial;
    }
    return MeetingAudioAvailability.available;
  }

  List<AudioSourceProcessingPresentation> _sources({
    int? meetingId,
    String? sessionId,
  }) {
    final scope = _scope(meetingId, sessionId);
    final key = _key(meetingId, sessionId);
    final rows = audio.db.select(
      '''WITH sessions AS (SELECT id FROM recording_sessions s WHERE $scope),
      chunks AS (SELECT c.* FROM audio_chunks c JOIN sessions s ON s.id=c.session_id),
      progress AS (SELECT p.* FROM audio_segmentation_progress p JOIN sessions s ON s.id=p.session_id),
      jobs AS (SELECT j.* FROM audio_asr_jobs j JOIN sessions s ON s.id=j.session_id WHERE j.state NOT IN ('completed','abandoned')),
      ranges AS (SELECT session_id,span_id,source,owned_start AS a,owned_end AS b FROM jobs
        UNION ALL SELECT session_id,span_id,source,CASE WHEN json_valid(CAST(context AS TEXT)) THEN json_extract(CAST(context AS TEXT),'\$.owned_start') END,cursor_sample FROM progress
        UNION ALL SELECT c.session_id,c.span_id,c.source,MAX(c.sample_start,COALESCE(p.cursor_sample,c.sample_start)),c.sample_start+c.sample_count FROM chunks c LEFT JOIN progress p ON p.session_id=c.session_id AND p.span_id=c.span_id AND p.source=c.source),
      clipped AS (SELECT c.id,c.source,c.sample_rate,MAX(c.sample_start,r.a) AS a,MIN(c.sample_start+c.sample_count,r.b) AS b FROM ranges r JOIN chunks c ON c.session_id=r.session_id AND c.span_id=r.span_id AND c.source=r.source WHERE r.a IS NOT NULL AND r.b>r.a AND c.sample_start<r.b AND c.sample_start+c.sample_count>r.a),
      merged AS (SELECT *,MAX(b) OVER(PARTITION BY id ORDER BY a,b ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS previous_end FROM clipped),
      durations AS (SELECT source,SUM(MAX(0,b-MAX(a,COALESCE(previous_end,a)))*1000000/sample_rate) AS us FROM merged GROUP BY source)
      SELECT source,COALESCE((SELECT us FROM durations d WHERE d.source=names.source),0) AS us,
        (SELECT COUNT(*) FROM jobs j WHERE j.source=names.source) AS jobs,
        (SELECT COUNT(*) FROM jobs j WHERE j.source=names.source AND j.state IN ('failed','blocked')) AS failed_jobs,
        COALESCE((SELECT error FROM progress p WHERE p.source=names.source AND error<>'' ORDER BY span_id LIMIT 1),(SELECT error FROM jobs j WHERE j.source=names.source AND error<>'' ORDER BY id LIMIT 1),'') AS error
      FROM (SELECT 'microphone' AS source UNION ALL SELECT 'playback') names''',
      [key],
    );
    return List.unmodifiable(
      rows.map(
        (r) => AudioSourceProcessingPresentation(
          source: MeetingAudioSource.values.byName(r['source'] as String),
          pendingDurationUs: r['us'] as int,
          pendingJobs: r['jobs'] as int,
          failedJobs: r['failed_jobs'] as int,
          error: r['error'] as String,
        ),
      ),
    );
  }

  AudioWorkPresentation _work(
    String kind, {
    int? meetingId,
    String? sessionId,
  }) {
    final rows = audio.db.select(
      '''SELECT j.state,COUNT(*) AS n FROM audio_transform_jobs j JOIN recording_sessions s ON s.id=j.session_id WHERE ${_scope(meetingId, sessionId)} AND j.kind=? GROUP BY j.state''',
      [_key(meetingId, sessionId), kind],
    );
    final counts = {
      for (final row in rows) row['state'] as String: row['n'] as int,
    };
    final pending = (counts['pending'] ?? 0) + (counts['retry'] ?? 0);
    final running = counts['running'] ?? 0;
    final failed = (counts['blocked'] ?? 0) + (counts['failed'] ?? 0);
    final completed = counts['completed'] ?? 0;
    final errors = audio.db.select(
      '''SELECT j.error FROM audio_transform_jobs j JOIN recording_sessions s ON s.id=j.session_id WHERE ${_scope(meetingId, sessionId)} AND j.kind=? AND j.error<>'' AND j.state NOT IN ('completed','abandoned') ORDER BY j.id LIMIT 1''',
      [_key(meetingId, sessionId), kind],
    );
    return AudioWorkPresentation(
      state: failed > 0
          ? MeetingAudioWorkState.failed
          : running > 0
          ? MeetingAudioWorkState.running
          : pending > 0
          ? MeetingAudioWorkState.pending
          : completed > 0
          ? MeetingAudioWorkState.complete
          : MeetingAudioWorkState.idle,
      pending: pending,
      running: running,
      completed: completed,
      failed: failed,
      error: errors.isEmpty ? '' : errors.single['error'] as String,
    );
  }

  String _captureError({int? meetingId, String? sessionId}) =>
      audio.db.select(
            'SELECT terminal_error FROM recording_sessions s WHERE ${_scope(meetingId, sessionId)} AND terminal_error<>\'\' ORDER BY started_wall_ms DESC,id DESC LIMIT 1',
            [_key(meetingId, sessionId)],
          ).firstOrNull?['terminal_error']
          as String? ??
      '';
}
