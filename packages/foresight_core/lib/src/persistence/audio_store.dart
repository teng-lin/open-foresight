import 'dart:convert';
import 'dart:math';

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:sqlite3/sqlite3.dart';

import '../audio_models.dart';
import '../rpc_error.dart';
import '../store.dart';
import 'meeting_index_jobs.dart';
import 'read_schema_guard.dart';
import 'audio_playback_timeline.dart';

/// Service-owned metadata only. The native publisher owns filesystem validation,
/// sync and rename; this module never treats a metadata commit as a file sync.
/// Every media-admitting entry point fences the workspace and media generation. Callers
/// must hold exclusive service/profile ownership before recovering worker leases.
final class AudioStore {
  AudioStore(
    this.db, {
    required this.workspaceEpoch,
    this.supportedVersion = Store.schemaVersion,
    this.mediaGeneration,
  });
  factory AudioStore.forStore(Store store) =>
      AudioStore(store.db, workspaceEpoch: () => store.workspaceEpoch);
  final Database db;
  final String Function() workspaceEpoch;
  final int supportedVersion;
  AudioPlaybackTimelinePlanner get playbackTimeline =>
      AudioPlaybackTimelinePlanner.forDatabase(db);
  String get playbackTimelineAuthority =>
      '$storageGeneration:${workspaceEpoch()}';

  /// Independent profile-owned media-root authority, never restored from the
  /// database snapshot. Service supplies this after startup reconciliation.
  final String? Function()? mediaGeneration;

  static String newIdentity() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => readSnapshot(
    db,
    () =>
        db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList(),
    supportedVersion: supportedVersion,
  );

  T transaction<T>(T Function() work) {
    db.execute('SAVEPOINT audio_store');
    try {
      final result = work();
      if (result is Future) {
        throw ArgumentError('Audio transactions must be synchronous');
      }
      db.execute('RELEASE audio_store');
      return result;
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO audio_store');
        db.execute('RELEASE audio_store');
      }
      rethrow;
    }
  }

  String get storageGeneration =>
      _rows(
            'SELECT generation FROM audio_storage_generation WHERE singleton=1',
          ).single['generation']
          as String;
  bool get _databaseMediaAdmitted =>
      _rows(
        'SELECT admission FROM audio_storage_generation WHERE singleton=1',
      ).single['admission'] ==
      'live';
  bool get mediaAdmitted =>
      _databaseMediaAdmitted &&
      (mediaGeneration != null && mediaGeneration!() == storageGeneration);

  void validateMediaGeneration(String observed) {
    if (observed != storageGeneration || !_databaseMediaAdmitted) {
      throw StateError(
        'Recording media is not admitted for this restored profile',
      );
    }
  }

  AudioSession? session(String id) {
    final row = _rows('SELECT * FROM recording_sessions WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : AudioSession.fromRow(row);
  }

  bool retainLossless(String sessionId) =>
      session(sessionId)?.retainLossless ?? false;

  /// The service joins an in-progress purge before acknowledging this change.
  /// It preserves remaining originals; previously purged bytes cannot return.
  void setRetainLossless(String sessionId, bool value) => transaction(() {
    _live(sessionId);
    db.execute('UPDATE recording_sessions SET retain_lossless=? WHERE id=?', [
      value ? 1 : 0,
      sessionId,
    ]);
  });

  List<AudioSession> sessionsForMeeting(int meeting) => _rows(
    'SELECT * FROM recording_sessions WHERE meeting_id=? ORDER BY started_wall_ms,id',
    [meeting],
  ).map(AudioSession.fromRow).toList();

  List<AudioSession> recoverySessions({String afterId = '', int limit = 64}) {
    _page(limit);
    if (!mediaAdmitted) return const [];
    return _rows(
      'SELECT s.* FROM recording_sessions s WHERE s.id>? AND s.storage_generation=? AND s.workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) ORDER BY s.id LIMIT ?',
      [afterId, storageGeneration, workspaceEpoch(), limit],
    ).map(AudioSession.fromRow).toList();
  }

  AudioSpan? span(String id) {
    final row = _rows('SELECT * FROM recording_spans WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : AudioSpan.fromRow(row);
  }

  int? capturedEndForSpan(String spanId) =>
      _rows(
            "SELECT MAX(capture_end_us) AS extent FROM audio_chunks WHERE span_id=? AND state!='reserved'",
            [spanId],
          ).single['extent']
          as int?;

  List<AudioSpan> spansPage(
    String sessionId, {
    int afterOrdinal = -1,
    int limit = 64,
  }) {
    _page(limit);
    return _rows(
      'SELECT * FROM recording_spans WHERE session_id=? AND ordinal>? ORDER BY ordinal LIMIT ?',
      [sessionId, afterOrdinal, limit],
    ).map(AudioSpan.fromRow).toList();
  }

  List<AudioSpan> spans(String sessionId) => _rows(
    'SELECT * FROM recording_spans WHERE session_id=? ORDER BY ordinal',
    [sessionId],
  ).map(AudioSpan.fromRow).toList();
  AudioChunk? chunk(String id) {
    final row = _rows('SELECT * FROM audio_chunks WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : AudioChunk.fromRow(row);
  }

  List<AudioChunk> chunks(
    String sessionId, {
    int afterSequence = -1,
    AudioSource afterSource = AudioSource.playback,
    int limit = 128,
  }) {
    _page(limit);
    return _rows(
      'SELECT * FROM audio_chunks WHERE session_id=? AND (sequence>? OR (sequence=? AND source>?)) ORDER BY sequence,source LIMIT ?',
      [sessionId, afterSequence, afterSequence, afterSource.name, limit],
    ).map(AudioChunk.fromRow).toList();
  }

  List<AudioRepresentation> representations(String chunkId) => _rows(
    'SELECT * FROM audio_representations WHERE chunk_id=? ORDER BY id',
    [chunkId],
  ).map(AudioRepresentation.fromRow).toList();

  /// Playback/export must use this admitted projection, not the complete
  /// historical representation inventory (which intentionally includes missing).
  List<AudioRepresentation> usableRepresentations(String chunkId) {
    final value = chunk(chunkId);
    if (value == null || !mediaAdmitted) return const [];
    try {
      _live(value.sessionId);
    } on RpcError {
      return const [];
    }
    return representations(chunkId)
        .where(
          (r) => r.state == AudioRepresentationState.published && r.validated,
        )
        .toList();
  }

  AudioSession _live(String id) {
    final value = session(id);
    if (value == null ||
        value.workspaceEpoch != workspaceEpoch() ||
        value.storageGeneration != storageGeneration ||
        !mediaAdmitted ||
        _rows('SELECT 1 FROM audio_erasure_intents WHERE session_id=?', [
          id,
        ]).isNotEmpty) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'The recording storage generation is no longer active.',
      );
    }
    return value;
  }

  static void _identity(String value) {
    if (!RegExp(
      r'^(?:[a-f0-9]{32}|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$',
    ).hasMatch(value)) {
      throw ArgumentError('Invalid audio identity');
    }
  }

  static void _path(String value) {
    if (value.isEmpty ||
        value.length > 1024 ||
        value.startsWith('/') ||
        value.contains('\\') ||
        value
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        value.contains('\u0000')) {
      throw ArgumentError(
        'Media paths must be profile-relative without traversal',
      );
    }
  }

  static void _digest(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw ArgumentError('Invalid media checksum');
    }
  }

  static void _revision(String value) {
    if (value.isEmpty || value.length > 512) {
      throw ArgumentError('Invalid audio settings/model revision');
    }
  }

  static void _page(int limit) {
    if (limit < 1 || limit > 256) throw ArgumentError.value(limit, 'limit');
  }

  AudioSession createSession({
    required int meetingId,
    required int startedWallMs,
    String? id,
  }) => transaction(() {
    final identity = id ?? newIdentity();
    _identity(identity);
    if (!mediaAdmitted) {
      throw StateError('Restored audio requires explicit media admission');
    }
    db.execute(
      'INSERT INTO recording_sessions(id,meeting_id,workspace_epoch,storage_generation,started_wall_ms,capture_state) VALUES(?,?,?,?,?,?)',
      [
        identity,
        meetingId,
        workspaceEpoch(),
        storageGeneration,
        startedWallMs,
        'starting',
      ],
    );
    return _live(identity);
  });

  AudioSpan startSpan(
    String sessionId, {
    required int captureStartUs,
    required int playbackStartUs,
    required int wallAnchorMs,
    String? id,
  }) => transaction(() {
    final owner = _live(sessionId);
    if (owner.captureState.terminal ||
        owner.captureState == AudioCaptureState.stopping) {
      throw StateError('A stopped recording cannot resume');
    }
    final previous = spans(sessionId).lastOrNull;
    if (captureStartUs < 0 ||
        playbackStartUs < 0 ||
        (previous != null &&
            (previous.captureEndUs == null ||
                captureStartUs < previous.captureEndUs! ||
                playbackStartUs != previous.playbackEndUs))) {
      throw ArgumentError(
        'A span must follow its closed predecessor on the compact timeline',
      );
    }
    final identity = id ?? newIdentity();
    _identity(identity);
    db.execute(
      'INSERT INTO recording_spans(id,session_id,ordinal,capture_start_us,playback_start_us,wall_anchor_ms) VALUES(?,?,?,?,?,?)',
      [
        identity,
        sessionId,
        (previous?.ordinal ?? -1) + 1,
        captureStartUs,
        playbackStartUs,
        wallAnchorMs,
      ],
    );
    for (final source in AudioSource.values) {
      db.execute(
        "INSERT INTO audio_source_clocks(span_id,source,revision,quality) VALUES(?,?,0,'unavailable')",
        [identity, source.name],
      );
    }
    db.execute(
      "UPDATE recording_sessions SET capture_state='starting' WHERE id=?",
      [sessionId],
    );
    return AudioSpan.fromRow(
      _rows('SELECT * FROM recording_spans WHERE id=?', [identity]).single,
    );
  });

  List<AudioSourceClockEvidence> sourceClockEvidence(
    String spanId,
    AudioSource source, {
    int afterRevision = -1,
    int limit = 64,
  }) {
    _page(limit);
    return _rows(
      'SELECT * FROM audio_source_clocks WHERE span_id=? AND source=? AND revision>? ORDER BY revision LIMIT ?',
      [spanId, source.name, afterRevision, limit],
    ).map(AudioSourceClockEvidence.fromRow).toList();
  }

  AudioSourceClockEvidence? latestSourceClock(
    String spanId,
    AudioSource source,
  ) {
    final row = _rows(
      'SELECT * FROM audio_source_clocks WHERE span_id=? AND source=? ORDER BY revision DESC LIMIT 1',
      [spanId, source.name],
    ).firstOrNull;
    return row == null ? null : AudioSourceClockEvidence.fromRow(row);
  }

  AudioSourceClockEvidence? sourceClockAt(
    String spanId,
    AudioSource source,
    int captureUs,
  ) {
    final row = _rows(
      'SELECT * FROM audio_source_clocks WHERE span_id=? AND source=? AND (observed_capture_us IS NULL OR observed_capture_us<=?) ORDER BY revision DESC LIMIT 1',
      [spanId, source.name, captureUs],
    ).firstOrNull;
    return row == null ? null : AudioSourceClockEvidence.fromRow(row);
  }

  AudioSourceClockEvidence recordSourceClock(
    String spanId,
    AudioSource source,
    AudioSourceClockQuality quality, {
    required int observedCaptureUs,
    int? uncertaintyUs,
  }) => transaction(() {
    final span = AudioSpan.fromRow(
      _rows('SELECT * FROM recording_spans WHERE id=?', [spanId]).single,
    );
    _live(span.sessionId);
    if ((span.captureEndUs != null && observedCaptureUs > span.captureEndUs!) ||
        observedCaptureUs < span.captureStartUs ||
        (uncertaintyUs != null && uncertaintyUs < 0) ||
        (quality == AudioSourceClockQuality.unavailable &&
            uncertaintyUs != null)) {
      throw ArgumentError('Invalid source clock evidence');
    }
    final latest = latestSourceClock(spanId, source)!;
    if (latest.observedCaptureUs != null &&
        observedCaptureUs < latest.observedCaptureUs!) {
      throw StateError('Clock evidence cannot rewrite acquisition history');
    }
    if (latest.quality == quality && latest.uncertaintyUs == uncertaintyUs) {
      return latest;
    }
    if (_rows(
      "SELECT 1 FROM audio_transform_jobs WHERE session_id=? AND kind='export' LIMIT 1",
      [span.sessionId],
    ).isNotEmpty) {
      throw StateError(
        'Export snapshot already froze recording clock evidence',
      );
    }
    final revision = latest.revision + 1;
    db.execute('INSERT INTO audio_source_clocks VALUES(?,?,?,?,?,?)', [
      spanId,
      source.name,
      revision,
      quality.storedValue,
      uncertaintyUs,
      observedCaptureUs,
    ]);
    return latestSourceClock(spanId, source)!;
  });

  void closeSpan(
    String spanId, {
    required int captureEndUs,
    required String reason,
  }) => transaction(() {
    final row = _rows('SELECT * FROM recording_spans WHERE id=?', [
      spanId,
    ]).single;
    final value = AudioSpan.fromRow(row);
    _live(value.sessionId);
    if (value.captureEndUs != null) {
      if (value.captureEndUs != captureEndUs || value.endReason != reason) {
        throw StateError('A closed span is immutable');
      }
      return;
    }
    if (captureEndUs < value.captureStartUs ||
        reason.isEmpty ||
        reason.length > 128) {
      throw ArgumentError('Invalid span end');
    }
    final latest =
        _rows(
              'SELECT MAX(capture_end_us) AS end FROM audio_chunks WHERE span_id=?',
              [spanId],
            ).single['end']
            as int?;
    if (latest != null && captureEndUs < latest) {
      throw ArgumentError('Span ends before its captured audio');
    }
    db.execute(
      'UPDATE recording_spans SET capture_end_us=?,playback_end_us=?,end_reason=? WHERE id=?',
      [
        captureEndUs,
        value.playbackStartUs + captureEndUs - value.captureStartUs,
        reason,
        spanId,
      ],
    );
  });

  void setCaptureState(
    String sessionId,
    AudioCaptureState state, {
    int? stoppedWallMs,
    String? error,
  }) => transaction(() {
    final value = _live(sessionId);
    if (value.captureState.terminal && value.captureState != state) {
      throw StateError('A stopped recording cannot resume');
    }
    if (state == AudioCaptureState.recording &&
        (spans(sessionId).isEmpty ||
            spans(sessionId).last.captureEndUs != null)) {
      throw StateError('Recording requires an open span');
    }
    if ((state.terminal || state == AudioCaptureState.paused) &&
        spans(sessionId).any((s) => s.captureEndUs == null)) {
      throw StateError('Seal the active span before acknowledging pause/stop');
    }
    if (error != null && error.length > 1024) {
      throw ArgumentError('Audio error is too long');
    }
    db.execute(
      'UPDATE recording_sessions SET capture_state=?,stopped_wall_ms=COALESCE(stopped_wall_ms,?),terminal_error=COALESCE(?,terminal_error) WHERE id=?',
      [state.name, stoppedWallMs, error, sessionId],
    );
  });

  AudioChunkPublication preallocateChunk({
    required String sessionId,
    required String spanId,
    required AudioSource source,
    required int sequence,
    required String relativePath,
    String? id,
    String? publicationToken,
  }) => transaction(() {
    final owner = _live(sessionId);
    final identity = id ?? newIdentity();
    final token = publicationToken ?? newIdentity();
    _identity(identity);
    _identity(token);
    _path(relativePath);
    if (sequence < 0 ||
        owner.captureState.terminal ||
        _rows(
          'SELECT 1 FROM recording_spans WHERE id=? AND session_id=? AND capture_end_us IS NULL',
          [spanId, sessionId],
        ).isEmpty) {
      throw StateError('Preallocation requires an active recording span');
    }
    db.execute('INSERT INTO audio_chunk_publications VALUES(?,?,?,?,?,?,?,?)', [
      identity,
      sessionId,
      spanId,
      source.name,
      sequence,
      relativePath,
      token,
      owner.storageGeneration,
    ]);
    return publication(identity)!;
  });

  AudioChunkPublication? publication(String id) {
    final row = _rows('SELECT * FROM audio_chunk_publications WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : AudioChunkPublication.fromRow(row);
  }

  List<AudioChunkPublication> pendingPublications({
    String afterId = '',
    int limit = 64,
  }) {
    _page(limit);
    return _rows(
      'SELECT p.* FROM audio_chunk_publications p WHERE p.id>? AND NOT EXISTS(SELECT 1 FROM audio_chunks c WHERE c.id=p.id) ORDER BY p.id LIMIT ?',
      [afterId, limit],
    ).map(AudioChunkPublication.fromRow).toList();
  }

  List<AudioChunkPublication> pendingSessionPublications(
    String sessionId, {
    String afterId = '',
    int limit = 64,
  }) {
    _page(limit);
    _live(sessionId);
    return _rows(
      'SELECT p.* FROM audio_chunk_publications p WHERE p.session_id=? AND p.id>? AND NOT EXISTS(SELECT 1 FROM audio_chunks c WHERE c.id=p.id) ORDER BY p.id LIMIT ?',
      [sessionId, afterId, limit],
    ).map(AudioChunkPublication.fromRow).toList();
  }

  AudioChunk publishPreallocatedChunk(
    String id, {
    required String publicationToken,
    required int sampleStart,
    required int sampleCount,
    required int sampleRate,
    required int channels,
    required int captureStartUs,
    required int captureEndUs,
    required int byteLength,
    required String sha256,
    bool interrupted = false,
    bool gapBefore = false,
  }) => transaction(() {
    final authority = publication(id);
    if (authority == null || authority.publicationToken != publicationToken) {
      throw StateError('No matching audio publication authority');
    }
    _live(authority.sessionId);
    final span = _rows('SELECT * FROM recording_spans WHERE id=?', [
      authority.spanId,
    ]).single;
    if (sampleRate < 8000 ||
        sampleRate > 192000 ||
        channels < 1 ||
        channels > 8 ||
        sampleStart < 0 ||
        sampleCount < 1 ||
        sampleCount > sampleRate * 10 ||
        captureStartUs < (span['capture_start_us'] as int) ||
        captureEndUs < captureStartUs ||
        captureEndUs - captureStartUs > 10000000 ||
        (span['capture_end_us'] != null &&
            captureEndUs > (span['capture_end_us'] as int))) {
      throw ArgumentError('Invalid finalized audio metadata');
    }
    final previous = chunk(id);
    if (previous != null) {
      if (previous.sampleStart != sampleStart ||
          previous.sampleCount != sampleCount ||
          previous.sampleRate != sampleRate ||
          previous.channels != channels ||
          previous.captureStartUs != captureStartUs ||
          previous.captureEndUs != captureEndUs ||
          previous.gapBefore != gapBefore) {
        throw StateError('Published audio format/timeline is immutable');
      }
    } else {
      if (_rows(
        'SELECT 1 FROM audio_chunks WHERE session_id=? AND source=? AND sample_start<? AND sample_start+sample_count>?',
        [
          authority.sessionId,
          authority.source.name,
          sampleStart + sampleCount,
          sampleStart,
        ],
      ).isNotEmpty) {
        throw StateError('Audio source samples overlap');
      }
      db.execute(
        'INSERT INTO audio_chunks(id,session_id,span_id,source,sequence,relative_path,publication_token,storage_generation,sample_start,sample_count,sample_rate,channels,capture_start_us,capture_end_us,state,gap_before) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          id,
          authority.sessionId,
          authority.spanId,
          authority.source.name,
          authority.sequence,
          authority.relativePath,
          publicationToken,
          authority.storageGeneration,
          sampleStart,
          sampleCount,
          sampleRate,
          channels,
          captureStartUs,
          captureEndUs,
          'reserved',
          gapBefore ? 1 : 0,
        ],
      );
    }
    return publishChunk(
      id,
      publicationToken: publicationToken,
      byteLength: byteLength,
      sha256: sha256,
      interrupted: interrupted,
    );
  });

  AudioChunk reserveChunk({
    required String sessionId,
    required String spanId,
    required AudioSource source,
    required int sequence,
    required String relativePath,
    required int sampleStart,
    required int sampleCount,
    required int sampleRate,
    required int channels,
    required int captureStartUs,
    required int captureEndUs,
    String? id,
    String? publicationToken,
    bool gapBefore = false,
  }) => transaction(() {
    final owner = _live(sessionId);
    final identity = id ?? newIdentity();
    final token = publicationToken ?? newIdentity();
    _identity(identity);
    _identity(token);
    _path(relativePath);
    final span = _rows(
      'SELECT * FROM recording_spans WHERE id=? AND session_id=?',
      [spanId, sessionId],
    ).firstOrNull;
    if (span == null ||
        span['capture_end_us'] != null ||
        owner.captureState.terminal) {
      throw StateError('Audio reservation requires an open span');
    }
    if (sampleRate < 8000 ||
        sampleRate > 192000 ||
        channels < 1 ||
        channels > 8 ||
        sampleStart < 0 ||
        sampleCount < 1 ||
        sampleCount > sampleRate * 10 ||
        sequence < 0 ||
        captureStartUs < (span['capture_start_us'] as int) ||
        captureEndUs < captureStartUs ||
        captureEndUs - captureStartUs > 10000000) {
      throw ArgumentError('Invalid or oversized audio chunk');
    }
    if (_rows(
      'SELECT 1 FROM audio_chunks WHERE session_id=? AND source=? AND sample_start<? AND sample_start+sample_count>?',
      [sessionId, source.name, sampleStart + sampleCount, sampleStart],
    ).isNotEmpty) {
      throw StateError('Audio source samples overlap');
    }
    preallocateChunk(
      sessionId: sessionId,
      spanId: spanId,
      source: source,
      sequence: sequence,
      relativePath: relativePath,
      id: identity,
      publicationToken: token,
    );
    db.execute(
      'INSERT INTO audio_chunks(id,session_id,span_id,source,sequence,relative_path,publication_token,storage_generation,sample_start,sample_count,sample_rate,channels,capture_start_us,capture_end_us,state,gap_before) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        identity,
        sessionId,
        spanId,
        source.name,
        sequence,
        relativePath,
        token,
        owner.storageGeneration,
        sampleStart,
        sampleCount,
        sampleRate,
        channels,
        captureStartUs,
        captureEndUs,
        'reserved',
        gapBefore ? 1 : 0,
      ],
    );
    return chunk(identity)!;
  });

  /// The caller has independently validated/synced the finalized file. Identical
  /// redelivery is harmless; altered immutable metadata is rejected.
  AudioChunk publishChunk(
    String id, {
    required String publicationToken,
    required int byteLength,
    required String sha256,
    bool interrupted = false,
  }) => transaction(() {
    final value = chunk(id);
    if (value == null) {
      throw StateError('No surviving audio publication reservation');
    }
    _live(value.sessionId);
    _digest(sha256);
    if (publicationToken != value.publicationToken ||
        byteLength < 1 ||
        byteLength > 16 * 1024 * 1024) {
      throw ArgumentError('Invalid audio publication');
    }
    if (value.state == AudioChunkState.published) {
      if (value.byteLength != byteLength ||
          value.sha256 != sha256 ||
          value.interrupted != interrupted) {
        throw StateError('Published audio is immutable');
      }
      return value;
    }
    if (value.state != AudioChunkState.reserved) {
      throw StateError('Audio is quarantined or unavailable');
    }
    db.execute(
      "UPDATE audio_chunks SET state='published',byte_length=?,sha256=?,interrupted=? WHERE id=?",
      [byteLength, sha256, interrupted ? 1 : 0, id],
    );
    db.execute(
      'UPDATE recording_sessions SET last_sequence=MAX(last_sequence,?) WHERE id=?',
      [value.sequence, value.sessionId],
    );
    db.execute(
      "INSERT INTO audio_representations(id,chunk_id,codec,container,settings_revision,relative_path,byte_length,sha256,decoded_samples,state,validated) VALUES(?,?,'pcm_s16le','wav','recording-wav-v1',?,?,?,?,'published',1)",
      [
        '$id.raw',
        id,
        value.relativePath,
        byteLength,
        sha256,
        value.sampleCount,
      ],
    );
    return chunk(id)!;
  });

  bool mayAdoptChunk(
    String id,
    String publicationToken,
    String observedStorageGeneration,
  ) {
    final authority = publication(id);
    if (authority == null ||
        authority.publicationToken != publicationToken ||
        authority.storageGeneration != observedStorageGeneration) {
      return false;
    }
    final value = chunk(id);
    if (value != null && value.state != AudioChunkState.reserved) return false;
    try {
      _live(authority.sessionId);
      return true;
    } on RpcError {
      return false;
    }
  }

  void markChunkUnavailable(
    String id, {
    bool quarantine = false,
  }) => transaction(() {
    final value = chunk(id);
    if (value == null) return;
    _live(value.sessionId);
    db.execute('UPDATE audio_chunks SET state=? WHERE id=?', [
      quarantine ? 'quarantined' : 'missing',
      id,
    ]);
    db.execute(
      "UPDATE audio_representations SET state='missing' WHERE chunk_id=? AND state='published'",
      [id],
    );
    db.execute(
      "UPDATE audio_asr_jobs SET state='blocked',error='audio_unavailable',owner_generation=NULL,lease_generation=lease_generation+1 WHERE id IN (SELECT job_id FROM audio_asr_job_chunks WHERE chunk_id=?) AND state NOT IN ('completed','abandoned')",
      [id],
    );
    db.execute(
      "UPDATE audio_transform_jobs SET state='blocked',error='audio_unavailable',owner_generation=NULL,lease_generation=lease_generation+1 WHERE id IN (SELECT i.job_id FROM audio_transform_inputs i JOIN audio_representations r ON r.id=i.representation_id WHERE r.chunk_id=?) AND state NOT IN ('completed','abandoned')",
      [id],
    );
  });

  int segmentationStartSample(
    String sessionId,
    String spanId,
    AudioSource source,
  ) =>
      (_rows(
            'SELECT MAX(c.sample_start+c.sample_count) AS end FROM audio_chunks c JOIN recording_spans s ON s.id=c.span_id WHERE c.session_id=? AND c.source=? AND s.ordinal<(SELECT ordinal FROM recording_spans WHERE id=?)',
            [sessionId, source.name, spanId],
          ).single['end']
          as int?) ??
      0;

  int segmentationEndSample(
    String sessionId,
    String spanId,
    AudioSource source,
  ) =>
      (_rows(
            'SELECT MAX(sample_start+sample_count) AS end FROM audio_chunks WHERE session_id=? AND span_id=? AND source=?',
            [sessionId, spanId, source.name],
          ).single['end']
          as int?) ??
      segmentationStartSample(sessionId, spanId, source);

  List<AudioChunk> segmentationChunks(
    String sessionId,
    String spanId,
    AudioSource source, {
    required int afterSample,
    int limit = 32,
  }) {
    _page(limit);
    return _rows(
      'SELECT * FROM audio_chunks WHERE session_id=? AND span_id=? AND source=? AND sample_start+sample_count>? ORDER BY sample_start LIMIT ?',
      [sessionId, spanId, source.name, afterSample, limit],
    ).map(AudioChunk.fromRow).toList();
  }

  AudioSegmentationCursor initializeSegmentation({
    required String sessionId,
    required String spanId,
    required AudioSource source,
    required String settingsRevision,
    required String modelRevision,
    required int initialSample,
    List<int> initialContext = const [],
  }) => transaction(() {
    _live(sessionId);
    _revision(settingsRevision);
    _revision(modelRevision);
    if (initialContext.length > 65536) {
      throw ArgumentError('Initial segmentation context exceeds budget');
    }
    if (initialSample < 0 ||
        _rows('SELECT 1 FROM recording_spans WHERE id=? AND session_id=?', [
          spanId,
          sessionId,
        ]).isEmpty) {
      throw ArgumentError('Invalid segmentation span/start');
    }
    if (segmentation(sessionId, source, spanId) == null &&
        initialSample != segmentationStartSample(sessionId, spanId, source)) {
      throw ArgumentError(
        'Initial segmentation must include every source frame',
      );
    }
    db.execute(
      "INSERT OR IGNORE INTO audio_segmentation_progress(session_id,source,span_id,settings_revision,model_revision,cursor_sample,retain_from_sample,context) VALUES(?,?,?,?,?,?,?,?)",
      [
        sessionId,
        source.name,
        spanId,
        settingsRevision,
        modelRevision,
        initialSample,
        initialSample,
        Uint8List.fromList(initialContext),
      ],
    );
    final cursor = segmentation(sessionId, source, spanId)!;
    if (cursor.settingsRevision != settingsRevision ||
        cursor.modelRevision != modelRevision) {
      throw StateError('Segmentation settings are frozen for this span');
    }
    return cursor;
  });

  AudioSegmentationCursor? segmentation(
    String sessionId,
    AudioSource source,
    String spanId,
  ) {
    final row = _rows(
      'SELECT * FROM audio_segmentation_progress WHERE session_id=? AND source=? AND span_id=?',
      [sessionId, source.name, spanId],
    ).firstOrNull;
    return row == null ? null : AudioSegmentationCursor.fromRow(row);
  }

  /// Trusted service publication fence, never derived from a closed span row
  /// alone. Call only after all physical owners joined, final notices committed
  /// and the final native drain was empty, or after authorized crash recovery.
  void sealSegmentationPublications(String spanId) => transaction(() {
    final row = _rows('SELECT * FROM recording_spans WHERE id=?', [
      spanId,
    ]).firstOrNull;
    if (row == null || row['capture_end_us'] == null) {
      throw StateError('Recording span is not closed');
    }
    _live(row['session_id'] as String);
    db.execute(
      'UPDATE audio_segmentation_progress SET publication_sealed=1 WHERE span_id=?',
      [spanId],
    );
  });

  /// Bounded fair background selection, restricted to independently admitted
  /// media. A persisted seal lets a stopped session finish after app restart.
  AudioSegmentationCursor? nextSegmentation({
    String afterSpanId = '',
    AudioSource afterSource = AudioSource.playback,
  }) {
    if (!mediaAdmitted) return null;
    List<Map<String, Object?>> select(bool wrap) => _rows(
      "SELECT p.* FROM audio_segmentation_progress p JOIN recording_sessions s ON s.id=p.session_id WHERE p.flushed=0 AND p.error='' AND s.storage_generation=? AND s.workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) AND (? OR p.span_id>? OR (p.span_id=? AND p.source>?)) AND (p.publication_sealed=1 OR EXISTS(SELECT 1 FROM audio_chunks c WHERE c.session_id=p.session_id AND c.span_id=p.span_id AND c.source=p.source AND c.state='published' AND c.sample_start+c.sample_count>p.cursor_sample)) ORDER BY p.span_id,p.source LIMIT 1",
      [
        storageGeneration,
        workspaceEpoch(),
        wrap ? 1 : 0,
        afterSpanId,
        afterSpanId,
        afterSource.name,
      ],
    );
    final row = (select(false).firstOrNull ?? select(true).firstOrNull);
    return row == null ? null : AudioSegmentationCursor.fromRow(row);
  }

  List<AudioChunk> _cover(
    String sessionId,
    String spanId,
    AudioSource source,
    int start,
    int end,
  ) {
    if (end <= start) return const [];
    final covered = _rows(
      "SELECT * FROM audio_chunks WHERE session_id=? AND span_id=? AND source=? AND state='published' AND sample_start<? AND sample_start+sample_count>? ORDER BY sample_start LIMIT 257",
      [sessionId, spanId, source.name, end, start],
    ).map(AudioChunk.fromRow).toList();
    if (covered.length > 256) {
      throw StateError('Audio range exceeds bounded segmentation work unit');
    }
    var cursor = start;
    for (final value in covered) {
      if (value.sampleStart > cursor) {
        throw StateError(
          'Segmentation cannot pass unpublished or missing media',
        );
      }
      // First-pass recognition always needs a published lossless representation.
      if (_rows(
        "SELECT 1 FROM audio_representations WHERE chunk_id=? AND codec='pcm_s16le' AND state='published' AND validated=1",
        [value.id],
      ).isEmpty) {
        throw StateError('First-pass PCM is unavailable');
      }
      cursor = max(cursor, value.sampleEnd);
    }
    if (cursor < end) {
      throw StateError('Segmentation cannot pass unpublished or missing media');
    }
    return covered;
  }

  /// Silence advances the same cursor with no jobs. Cursor comparison, frozen
  /// ranges, dependency references and end-of-span flush commit together.
  void admitSegments(
    AudioSegmentationCursor expected, {
    required int throughSample,
    required int retainFromSample,
    required List<AudioAsrRange> ranges,
    List<int> context = const [],
    bool flush = false,
    String error = '',
  }) => transaction(() {
    _live(expected.sessionId);
    final actual = segmentation(
      expected.sessionId,
      expected.source,
      expected.spanId,
    );
    if (actual == null ||
        actual.cursorSample != expected.cursorSample ||
        actual.settingsRevision != expected.settingsRevision ||
        actual.modelRevision != expected.modelRevision ||
        actual.retainFromSample != expected.retainFromSample ||
        actual.context.length != expected.context.length ||
        List.generate(
          actual.context.length,
          (i) => i,
        ).any((i) => actual.context[i] != expected.context[i]) ||
        actual.flushed) {
      throw StateError('Stale or flushed segmentation cursor');
    }
    if (throughSample < actual.cursorSample ||
        retainFromSample < actual.retainFromSample ||
        retainFromSample > throughSample ||
        context.length > 65536 ||
        ranges.length > 64 ||
        error.length > 1024) {
      throw ArgumentError('Invalid segmentation advance');
    }
    _cover(
      expected.sessionId,
      expected.spanId,
      expected.source,
      actual.cursorSample,
      throughSample,
    );
    if (flush) {
      final span = _rows(
        'SELECT capture_end_us FROM recording_spans WHERE id=?',
        [expected.spanId],
      ).single;
      final end =
          _rows(
                'SELECT MAX(sample_start+sample_count) AS end FROM audio_chunks WHERE span_id=? AND source=?',
                [expected.spanId, expected.source.name],
              ).single['end']
              as int?;
      if (span['capture_end_us'] == null ||
          throughSample != (end ?? actual.cursorSample) ||
          retainFromSample != throughSample ||
          context.isNotEmpty) {
        throw StateError(
          'Flush requires a closed fully scanned span with no retained context',
        );
      }
    }
    var previousOwnedEnd =
        (_rows(
              'SELECT MAX(owned_end) AS end FROM audio_asr_jobs WHERE session_id=? AND source=? AND span_id=?',
              [expected.sessionId, expected.source.name, expected.spanId],
            ).single['end']
            as int?) ??
        actual.retainFromSample;
    for (final range in ranges) {
      _identity(range.id);
      if (range.sampleStart < actual.retainFromSample ||
          range.sampleEnd > throughSample ||
          range.ownedStart < previousOwnedEnd ||
          range.ownedStart < range.sampleStart ||
          range.ownedEnd > range.sampleEnd ||
          range.ownedEnd <= range.ownedStart) {
        throw ArgumentError('Invalid or overlapping frozen ASR range');
      }
      previousOwnedEnd = range.ownedEnd;
      final dependencies = _cover(
        expected.sessionId,
        expected.spanId,
        expected.source,
        range.sampleStart,
        range.sampleEnd,
      );
      db.execute(
        "INSERT INTO audio_asr_jobs(id,session_id,span_id,source,sample_start,sample_end,owned_start,owned_end,model_revision,settings_revision,state) VALUES(?,?,?,?,?,?,?,?,?,?,'pending')",
        [
          range.id,
          expected.sessionId,
          expected.spanId,
          expected.source.name,
          range.sampleStart,
          range.sampleEnd,
          range.ownedStart,
          range.ownedEnd,
          expected.modelRevision,
          expected.settingsRevision,
        ],
      );
      for (final dependency in dependencies) {
        db.execute('INSERT INTO audio_asr_job_chunks VALUES(?,?)', [
          range.id,
          dependency.id,
        ]);
      }
    }
    db.execute(
      'UPDATE audio_segmentation_progress SET cursor_sample=?,retain_from_sample=?,context=?,flushed=?,error=? WHERE session_id=? AND source=? AND span_id=?',
      [
        throughSample,
        retainFromSample,
        Uint8List.fromList(context),
        flush ? 1 : 0,
        error,
        expected.sessionId,
        expected.source.name,
        expected.spanId,
      ],
    );
  });

  void markSegmentationFailure(
    AudioSegmentationCursor expected,
    String error,
  ) => transaction(() {
    _live(expected.sessionId);
    if (error.isEmpty || error.length > 1024) {
      throw ArgumentError('Invalid segmentation error');
    }
    db.execute(
      'UPDATE audio_segmentation_progress SET error=? WHERE session_id=? AND source=? AND span_id=? AND cursor_sample=? AND settings_revision=? AND model_revision=? AND flushed=0',
      [
        error,
        expected.sessionId,
        expected.source.name,
        expected.spanId,
        expected.cursorSample,
        expected.settingsRevision,
        expected.modelRevision,
      ],
    );
  });

  AudioAsrJob? job(String id) {
    final row = _rows('SELECT * FROM audio_asr_jobs WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : AudioAsrJob.fromRow(row);
  }

  List<AudioAsrJob> pendingJobs({required int nowMs, int limit = 64}) {
    _page(limit);
    if (!mediaAdmitted) return const [];
    return _rows(
      "SELECT j.* FROM audio_asr_jobs j JOIN recording_sessions s ON s.id=j.session_id JOIN audio_storage_generation g ON g.generation=s.storage_generation AND g.admission='live' WHERE j.state IN ('pending','retry') AND j.retry_after_ms<=? AND s.workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) ORDER BY j.attempts,s.started_wall_ms,j.source,j.owned_start LIMIT ?",
      [nowMs, workspaceEpoch(), limit],
    ).map(AudioAsrJob.fromRow).toList();
  }

  /// One bounded fair turn. A caller remembers the returned session/source
  /// and resumes after that group; when the end is reached selection wraps.
  /// The partial index scans only pending/retry jobs in stable group order.
  AudioAsrJob? nextPendingJob({
    required int nowMs,
    String? afterSessionId,
    AudioSource afterSource = AudioSource.playback,
  }) {
    if (!mediaAdmitted) return null;
    AudioAsrJob? find(String after, AudioSource source) {
      final row = _rows(
        "SELECT j.* FROM audio_asr_jobs j INDEXED BY audio_asr_round_robin JOIN recording_sessions s ON s.id=j.session_id WHERE j.state IN ('pending','retry') AND j.retry_after_ms<=? AND s.storage_generation=? AND s.workspace_epoch=? AND (j.session_id>? OR (j.session_id=? AND j.source>?)) AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) ORDER BY j.session_id,j.source,j.owned_start,j.id LIMIT 1",
        [nowMs, storageGeneration, workspaceEpoch(), after, after, source.name],
      ).firstOrNull;
      return row == null ? null : AudioAsrJob.fromRow(row);
    }

    return find(afterSessionId ?? '', afterSource) ??
        (afterSessionId == null ? null : find('', AudioSource.playback));
  }

  List<AudioChunk> jobChunks(String jobId) => _rows(
    'SELECT c.* FROM audio_chunks c JOIN audio_asr_job_chunks d ON d.chunk_id=c.id WHERE d.job_id=? ORDER BY c.sample_start',
    [jobId],
  ).map(AudioChunk.fromRow).toList();

  AudioAsrLease? claimJob(
    String id, {
    required String ownerGeneration,
    required int nowMs,
  }) => transaction(() {
    _identity(ownerGeneration);
    final value = job(id);
    if (value == null) return null;
    _live(value.sessionId);
    if (![AudioJobState.pending, AudioJobState.retry].contains(value.state)) {
      return null;
    }
    _cover(
      value.sessionId,
      value.spanId,
      value.source,
      value.sampleStart,
      value.sampleEnd,
    );
    db.execute(
      "UPDATE audio_asr_jobs SET state='running',attempts=attempts+1,lease_generation=lease_generation+1,owner_generation=? WHERE id=? AND state IN ('pending','retry') AND retry_after_ms<=?",
      [ownerGeneration, id, nowMs],
    );
    if (db.updatedRows != 1) return null;
    final claimed = job(id)!;
    for (final input in jobChunks(id)) {
      acquireReference(
        '${input.id}.raw',
        ownerGeneration: ownerGeneration,
        purpose: 'asr:$id:${claimed.leaseGeneration}',
      );
    }
    return AudioAsrLease(claimed, ownerGeneration, claimed.leaseGeneration);
  });

  /// The service invokes this only after taking exclusive profile ownership.
  /// Its fresh generation rejects callbacks from a previously running owner.
  void recoverLeases(String ownerGeneration) => transaction(() {
    _identity(ownerGeneration);
    db.execute(
      "UPDATE audio_asr_jobs SET state='retry',attempts=MAX(0,attempts-1),owner_generation=NULL,lease_generation=lease_generation+1,error='worker_interrupted',retry_after_ms=0 WHERE state='running' AND owner_generation!=?",
      [ownerGeneration],
    );
    db.execute(
      "UPDATE audio_transform_jobs SET state='retry',attempts=MAX(0,attempts-1),owner_generation=NULL,lease_generation=lease_generation+1,error='worker_interrupted',retry_after_ms=0 WHERE state='running' AND owner_generation!=?",
      [ownerGeneration],
    );
    db.execute('DELETE FROM audio_media_references WHERE owner_generation!=?', [
      ownerGeneration,
    ]);
    // A player never resumes automatically. The inherited-reader flock already
    // proved previous native readers exited before startup enters this method.
    db.execute(
      "DELETE FROM audio_transform_jobs WHERE kind='playback' AND (owner_generation IS NULL OR owner_generation!=?)",
      [ownerGeneration],
    );
  });

  bool _hasLease(AudioAsrLease lease) {
    final current = job(lease.job.id);
    return current != null &&
        current.state == AudioJobState.running &&
        current.ownerGeneration == lease.ownerGeneration &&
        current.leaseGeneration == lease.leaseGeneration;
  }

  /// Call only after the native operation has actually returned/stopped,
  /// including stale/cancelled callbacks. Invalidating a lease alone does not
  /// release the filesystem reader/deletion fence.
  void releaseAsrLeaseReferences(AudioAsrLease lease) => db.execute(
    'DELETE FROM audio_media_references WHERE owner_generation=? AND purpose=?',
    [lease.ownerGeneration, 'asr:${lease.job.id}:${lease.leaseGeneration}'],
  );

  void releaseTransformLeaseReferences(AudioTransformLease lease) => db.execute(
    'DELETE FROM audio_media_references WHERE owner_generation=? AND purpose=?',
    [
      lease.ownerGeneration,
      'transform:${lease.job.id}:${lease.leaseGeneration}',
    ],
  );

  /// Cancellation/shutdown/model barriers are not recognition failures. Invoke
  /// only after the real worker exits; parent finally still retires stale refs.
  void interruptJob(
    AudioAsrLease lease, {
    required String error,
  }) => transaction(() {
    if (error.length > 1024) throw ArgumentError('Audio error is too long');
    final value = job(lease.job.id);
    if (value == null) return;
    try {
      _live(value.sessionId);
    } on RpcError {
      return;
    }
    if (!_hasLease(lease)) return;
    db.execute(
      "UPDATE audio_asr_jobs SET state='retry',attempts=MAX(0,attempts-1),lease_generation=lease_generation+1,owner_generation=NULL,retry_after_ms=0,error=? WHERE id=?",
      [error, value.id],
    );
    releaseAsrLeaseReferences(lease);
  });

  void failJob(
    AudioAsrLease lease, {
    required String error,
    required int nowMs,
    bool blocked = false,
  }) => transaction(() {
    _live(lease.job.sessionId);
    if (!_hasLease(lease)) return;
    if (error.length > 1024) throw ArgumentError('Audio error is too long');
    final exhausted = lease.job.attempts >= 5;
    db.execute(
      'UPDATE audio_asr_jobs SET state=?,error=?,retry_after_ms=?,owner_generation=NULL WHERE id=?',
      [
        blocked
            ? 'blocked'
            : exhausted
            ? 'failed'
            : 'retry',
        error,
        nowMs + min(300000, 1000 * (1 << min(lease.job.attempts, 8))),
        lease.job.id,
      ],
    );
    releaseAsrLeaseReferences(lease);
  });

  void retryJob(String id) => transaction(() {
    final value = job(id);
    if (value == null) return;
    _live(value.sessionId);
    if (![AudioJobState.blocked, AudioJobState.failed].contains(value.state)) {
      throw StateError('Only blocked or failed jobs can be explicitly retried');
    }
    db.execute(
      "UPDATE audio_asr_jobs SET state='pending',attempts=0,retry_after_ms=0,error='',lease_generation=lease_generation+1,owner_generation=NULL WHERE id=?",
      [id],
    );
  });

  /// Completion contains no callbacks. The transcript, immutable audio links,
  /// meeting revision, existing index journal and job status share one commit.
  /// Re-delivery returns the committed identities without replaying text edits.
  AudioResultCommit commitAsrResult(
    AudioAsrLease lease,
    List<AudioTranscriptResult> results,
  ) => transaction(() {
    final owner = _live(lease.job.sessionId);
    final current = job(lease.job.id);
    if (current?.state == AudioJobState.completed) {
      return AudioResultCommit(
        newlyCommitted: false,
        meetingId: owner.meetingId,
        transcriptIds: _rows(
          'SELECT transcript_id FROM transcript_audio_links WHERE job_id=? ORDER BY ordinal',
          [lease.job.id],
        ).map((r) => r['transcript_id'] as int).toList(),
      );
    }
    if (!_hasLease(lease)) throw StateError('Stale audio result lease');
    if (results.length > 256 ||
        results.fold<int>(0, (total, r) => total + r.text.length) >
            1024 * 1024) {
      throw ArgumentError('ASR result exceeds commit budget');
    }
    final ids = <int>[];
    var previousEnd = current!.ownedStart;
    for (var ordinal = 0; ordinal < results.length; ordinal++) {
      final result = results[ordinal];
      if (result.sampleStart < previousEnd ||
          result.sampleEnd > current.ownedEnd ||
          result.sampleEnd <= result.sampleStart ||
          result.startMs < 0 ||
          result.endMs < result.startMs ||
          result.text.isEmpty ||
          result.text.length > 65536) {
        throw ArgumentError('ASR text is outside its owned audio range');
      }
      previousEnd = result.sampleEnd;
      db.execute(
        'INSERT INTO transcript(meeting_id,text,final,start_ms,end_ms,source) VALUES(?,?,1,?,?,?)',
        [
          owner.meetingId,
          result.text,
          result.startMs,
          result.endMs,
          current.source.name,
        ],
      );
      final transcriptId = db.lastInsertRowId;
      ids.add(transcriptId);
      db.execute('UPDATE meetings SET revision=revision+1 WHERE id=?', [
        owner.meetingId,
      ]);
      final revision = _rows('SELECT revision FROM meetings WHERE id=?', [
        owner.meetingId,
      ]).single['revision'];
      db.execute('INSERT INTO transcript_audio_links VALUES(?,?,?,?,?,?,?)', [
        transcriptId,
        current.id,
        ordinal,
        revision,
        current.source.name,
        result.sampleStart,
        result.sampleEnd,
      ]);
    }
    if (results.isNotEmpty) {
      MeetingIndexJobs(
        db,
        workspaceEpoch: workspaceEpoch,
      ).request(owner.meetingId);
    }
    db.execute(
      "UPDATE audio_asr_jobs SET state='completed',owner_generation=NULL,error='' WHERE id=?",
      [current.id],
    );
    releaseAsrLeaseReferences(lease);
    return AudioResultCommit(
      newlyCommitted: true,
      meetingId: owner.meetingId,
      transcriptIds: List.unmodifiable(ids),
    );
  });

  /// A successful correction retains its verified range. A split/merge owner
  /// must explicitly invalidate links rather than synthesize unsupported seeks.
  void invalidateTranscriptLink(int transcriptId) => db.execute(
    'DELETE FROM transcript_audio_links WHERE transcript_id=?',
    [transcriptId],
  );

  AudioRepresentation publishRepresentation(
    AudioRepresentation value,
  ) => transaction(() {
    final original = chunk(value.chunkId);
    if (original == null) throw StateError('Audio chunk no longer exists');
    _live(original.sessionId);
    _path(value.relativePath);
    _digest(value.sha256);
    _revision(value.settingsRevision);
    if (!value.validated ||
        value.state != AudioRepresentationState.published ||
        value.decodedSamples != original.sampleCount ||
        value.byteLength < 1 ||
        value.preSkip < 0 ||
        value.codec.isEmpty ||
        value.container.isEmpty) {
      throw ArgumentError(
        'Only validated complete representations may be published',
      );
    }
    final existing = _rows('SELECT * FROM audio_representations WHERE id=?', [
      value.id,
    ]).firstOrNull;
    if (existing != null) {
      if (existing['sha256'] != value.sha256 ||
          existing['relative_path'] != value.relativePath ||
          existing['chunk_id'] != value.chunkId ||
          existing['codec'] != value.codec ||
          existing['container'] != value.container ||
          existing['settings_revision'] != value.settingsRevision ||
          existing['byte_length'] != value.byteLength ||
          existing['decoded_samples'] != value.decodedSamples ||
          existing['pre_skip'] != value.preSkip ||
          existing['state'] != 'published') {
        throw StateError('Published representation is immutable');
      }
      return AudioRepresentation.fromRow(existing);
    }
    db.execute(
      "INSERT INTO audio_representations(id,chunk_id,codec,container,settings_revision,relative_path,byte_length,sha256,decoded_samples,pre_skip,state,validated) VALUES(?,?,?,?,?,?,?,?,?,?,'published',1)",
      [
        value.id,
        value.chunkId,
        value.codec,
        value.container,
        value.settingsRevision,
        value.relativePath,
        value.byteLength,
        value.sha256,
        value.decodedSamples,
        value.preSkip,
      ],
    );
    return value;
  });

  String acquireReference(
    String representationId, {
    required String ownerGeneration,
    required String purpose,
  }) => transaction(() {
    _identity(ownerGeneration);
    final row = _rows(
      'SELECT r.*,c.session_id FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id WHERE r.id=?',
      [representationId],
    ).firstOrNull;
    if (row == null || row['state'] != 'published' || row['validated'] != 1) {
      throw StateError('Audio representation is unavailable or being purged');
    }
    _live(row['session_id'] as String);
    if (purpose.isEmpty || purpose.length > 128) {
      throw ArgumentError('Invalid media reference purpose');
    }
    final id = newIdentity();
    db.execute('INSERT INTO audio_media_references VALUES(?,?,?,?)', [
      id,
      representationId,
      ownerGeneration,
      purpose,
    ]);
    return id;
  });
  void releaseReference(String id) =>
      db.execute('DELETE FROM audio_media_references WHERE id=?', [id]);

  /// Phase one fences new readers before an unlink. Segmentation coverage,
  /// retained lookback, span flush, ASR dependencies and readers are checked in
  /// this same transaction. Zero jobs alone is never permission to delete PCM.
  AudioRepresentation? beginRawPurge(String chunkId) => transaction(() {
    final value = chunk(chunkId);
    if (value == null) return null;
    _live(value.sessionId);
    final rows = _rows(
      "SELECT * FROM audio_representations WHERE chunk_id=? AND codec='pcm_s16le'",
      [chunkId],
    );
    if (rows.isEmpty) return null;
    final raw = AudioRepresentation.fromRow(rows.single);
    if (raw.state != AudioRepresentationState.published) return null;
    if (_rows(
      "SELECT 1 FROM audio_representations WHERE chunk_id=? AND codec!='pcm_s16le' AND state='published' AND validated=1 AND decoded_samples=?",
      [chunkId, value.sampleCount],
    ).isEmpty) {
      return null;
    }
    final progress = segmentation(value.sessionId, value.source, value.spanId);
    if (progress == null ||
        progress.cursorSample < value.sampleEnd ||
        progress.retainFromSample < value.sampleEnd) {
      return null;
    }
    final closed =
        _rows('SELECT capture_end_us FROM recording_spans WHERE id=?', [
          value.spanId,
        ]).single['capture_end_us'] !=
        null;
    if (closed && !progress.flushed) return null;
    if (_rows(
          "SELECT 1 FROM audio_asr_jobs j JOIN audio_asr_job_chunks d ON d.job_id=j.id WHERE d.chunk_id=? AND j.state NOT IN ('completed','abandoned')",
          [chunkId],
        ).isNotEmpty ||
        _rows(
          'SELECT 1 FROM audio_media_references WHERE representation_id=?',
          [raw.id],
        ).isNotEmpty) {
      return null;
    }
    if (_rows(
      "SELECT 1 FROM audio_transform_jobs j JOIN audio_transform_inputs i ON i.job_id=j.id WHERE i.representation_id=? AND j.state NOT IN ('completed','abandoned')",
      [raw.id],
    ).isNotEmpty) {
      return null;
    }
    db.execute(
      "UPDATE audio_representations SET state='superseded_pending_purge' WHERE id=?",
      [raw.id],
    );
    return representations(chunkId).singleWhere((r) => r.id == raw.id);
  });

  List<AudioRepresentation> pendingPurges({int limit = 64}) {
    _page(limit);
    if (!mediaAdmitted) return const [];
    return _rows(
      "SELECT r.* FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_sessions s ON s.id=c.session_id WHERE r.state='superseded_pending_purge' AND s.storage_generation=? AND s.workspace_epoch=? ORDER BY r.id LIMIT ?",
      [storageGeneration, workspaceEpoch(), limit],
    ).map(AudioRepresentation.fromRow).toList();
  }

  /// Phase two runs only after successful/idempotent unlink, outside SQLite.
  void completePurge(String representationId) => db.execute(
    "UPDATE audio_representations SET state='purged' WHERE id=? AND state='superseded_pending_purge'",
    [representationId],
  );

  /// The service owns the purge fence and has just validated the exact remaining
  /// raw file. This does not recreate missing bytes or admit a restored path.
  void cancelRawPurge(
    String representationId, {
    required String verifiedSha256,
  }) => transaction(() {
    _digest(verifiedSha256);
    final row = _rows(
      'SELECT r.*,c.session_id FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id WHERE r.id=?',
      [representationId],
    ).single;
    final owner = _live(row['session_id'] as String);
    if (!owner.retainLossless ||
        row['codec'] != 'pcm_s16le' ||
        row['validated'] != 1 ||
        row['sha256'] != verifiedSha256 ||
        row['state'] != 'superseded_pending_purge') {
      throw StateError('Lossless retention proof no longer matches');
    }
    db.execute(
      "UPDATE audio_representations SET state='published' WHERE id=?",
      [representationId],
    );
  });

  void tombstoneSession(String id) => transaction(() {
    final value = session(id);
    if (value == null) return;
    db.execute('DELETE FROM recording_sessions WHERE id=?', [id]);
  });
  void tombstoneMeeting(int meeting) => transaction(() {
    db.execute('DELETE FROM recording_sessions WHERE meeting_id=?', [meeting]);
  });
  List<({String sessionId, String storageGeneration})> pendingErasures({
    int limit = 64,
  }) {
    _page(limit);
    return _rows(
          'SELECT * FROM audio_erasure_intents ORDER BY created,session_id LIMIT ?',
          [limit],
        )
        .map(
          (r) => (
            sessionId: r['session_id'] as String,
            storageGeneration: r['generation'] as String,
          ),
        )
        .toList();
  }

  void completeErasure(String sessionId, String generation) => db.execute(
    'DELETE FROM audio_erasure_intents WHERE session_id=? AND generation=?',
    [sessionId, generation],
  );

  /// Before workspace clear, or before admitting a database-only restored
  /// profile. Old identities are quarantined (restore) or tombstoned (clear), never reassigned to
  /// the new generation. Files can only be removed after worker/read fences.
  String rotateStorageGeneration({
    bool metadataOnly = false,
  }) => transaction(() {
    if (metadataOnly) {
      if (_rows(
            "SELECT 1 FROM audio_asr_jobs WHERE state='running' LIMIT 1",
          ).isNotEmpty ||
          _rows('SELECT 1 FROM audio_media_references LIMIT 1').isNotEmpty ||
          _rows(
            "SELECT 1 FROM audio_transform_jobs WHERE state='running' LIMIT 1",
          ).isNotEmpty) {
        throw StateError(
          'Recover/release media owners before restoring storage',
        );
      }
      // Preserve historical timing and transcript associations while making
      // every old file/job unavailable. Nothing is rebound to the new root.
      db.execute(
        "UPDATE recording_sessions SET capture_state='interrupted',terminal_error='restored_without_audio'",
      );
      db.execute("UPDATE audio_chunks SET state='quarantined'");
      db.execute(
        "UPDATE audio_representations SET state='missing' WHERE state!='purged'",
      );
      db.execute(
        "UPDATE audio_asr_jobs SET state='blocked',error='restored_without_audio',owner_generation=NULL,lease_generation=lease_generation+1 WHERE state NOT IN ('completed','abandoned')",
      );
      db.execute(
        "UPDATE audio_transform_jobs SET state='blocked',error='restored_without_audio',owner_generation=NULL,lease_generation=lease_generation+1 WHERE state NOT IN ('completed','abandoned')",
      );
    } else {
      // The erasure trigger independently refuses live readers/workers.
      for (final row in _rows('SELECT id FROM recording_sessions')) {
        db.execute('DELETE FROM recording_sessions WHERE id=?', [row['id']]);
      }
    }
    final generation = newIdentity();
    db.execute(
      'UPDATE audio_storage_generation SET generation=?,admission=? WHERE singleton=1',
      [generation, metadataOnly ? 'metadata_only' : 'live'],
    );
    return generation;
  });

  /// Explicitly permits NEW recordings after a metadata-only restore; this
  /// does not adopt any old or unmatched media from the original profile.
  void admitNewRecordingStorage() => db.execute(
    "UPDATE audio_storage_generation SET admission='live' WHERE singleton=1",
  );

  TranscriptAudioLink? transcriptAudioLink(int transcriptId) {
    final row = _rows(
      'SELECT l.*,j.session_id,j.span_id FROM transcript_audio_links l JOIN audio_asr_jobs j ON j.id=l.job_id WHERE l.transcript_id=?',
      [transcriptId],
    ).firstOrNull;
    return row == null ? null : TranscriptAudioLink.fromRow(row);
  }

  void abandonJob(String id) => transaction(() {
    final value = job(id);
    if (value == null) return;
    _live(value.sessionId);
    if (value.state == AudioJobState.running) {
      throw StateError(
        'Cancel/release the ASR worker before abandoning its input',
      );
    }
    if (value.state == AudioJobState.completed) {
      throw StateError('Completed transcription cannot be abandoned');
    }
    db.execute(
      "UPDATE audio_asr_jobs SET state='abandoned',owner_generation=NULL,lease_generation=lease_generation+1 WHERE id=?",
      [id],
    );
  });

  static Object? _canonicalSettings(Object? value) {
    if (value is Map<String, Object?>) {
      return {
        for (final key in value.keys.toList()..sort())
          key: _canonicalSettings(value[key]),
      };
    }
    if (value is List<Object?>) return value.map(_canonicalSettings).toList();
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw ArgumentError('Unsupported transform settings value');
  }

  AudioTransformJob? transformJob(String id) {
    final row = _rows('SELECT * FROM audio_transform_jobs WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : AudioTransformJob.fromRow(row);
  }

  /// Frozen representation identities/checksums and codec settings determine
  /// idempotency; a completed output is never replaced by a retry/new worker.
  AudioTransformJob createTransformJob({
    required String sessionId,
    required AudioTransformKind kind,
    required List<String> inputs,
    required String codec,
    required String container,
    required String settingsRevision,
    required Map<String, Object?> settings,
    String? id,
  }) => transaction(() {
    _live(sessionId);
    _revision(settingsRevision);
    if (inputs.isEmpty ||
        inputs.length > 256 ||
        inputs.toSet().length != inputs.length ||
        codec.isEmpty ||
        codec.length > 64 ||
        container.isEmpty ||
        container.length > 64) {
      throw ArgumentError('Invalid transform inputs or target');
    }
    if (kind == AudioTransformKind.compression && inputs.length != 1) {
      throw ArgumentError('Compression owns exactly one chunk');
    }
    final frozen = <Object?>[];
    for (final input in inputs) {
      final row = _rows(
        'SELECT r.*,c.session_id FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id WHERE r.id=?',
        [input],
      ).firstOrNull;
      if (row == null ||
          row['session_id'] != sessionId ||
          row['state'] != 'published' ||
          row['validated'] != 1) {
        throw StateError(
          'Transform input is unavailable or belongs to another recording',
        );
      }
      frozen.add([input, row['sha256'], row['decoded_samples']]);
    }
    final encoded = jsonEncode(_canonicalSettings(settings));
    if (utf8.encode(encoded).length > 16384) {
      throw ArgumentError('Transform settings exceed budget');
    }
    final inputIdentity = crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sessionId,
              kind.name,
              frozen,
              codec,
              container,
              settingsRevision,
              encoded,
            ]),
          ),
        )
        .toString();
    final previous = _rows(
      'SELECT * FROM audio_transform_jobs WHERE input_identity=?',
      [inputIdentity],
    ).firstOrNull;
    if (previous != null) return AudioTransformJob.fromRow(previous);
    final identity = id ?? newIdentity();
    _identity(identity);
    db.execute(
      "INSERT INTO audio_transform_jobs(id,session_id,kind,input_identity,codec,container,settings_revision,settings,state) VALUES(?,?,?,?,?,?,?,?,'pending')",
      [
        identity,
        sessionId,
        kind.name,
        inputIdentity,
        codec,
        container,
        settingsRevision,
        encoded,
      ],
    );
    for (var position = 0; position < inputs.length; position++) {
      db.execute(
        'INSERT INTO audio_transform_inputs(job_id,position,representation_id) VALUES(?,?,?)',
        [identity, position, inputs[position]],
      );
    }
    return transformJob(identity)!;
  });

  /// Freeze a whole stopped recording without constructing an unbounded Dart
  /// input list. SQLite selects one usable representation per chunk; its shared
  /// capture/playback timing and checksums join the immutable snapshot digest.
  /// The caller seals native acquisition/publication before this operation.
  AudioTransformJob createExportJob({
    required String sessionId,
    required String codec,
    required String container,
    required String settingsRevision,
    required Map<String, Object?> settings,
    String preferredInputCodec = 'opus',
    bool allowIncomplete = false,
  }) => _freezeRecordingJob(
    sessionId: sessionId,
    codec: codec,
    container: container,
    settingsRevision: settingsRevision,
    settings: settings,
    preferredInputCodec: preferredInputCodec,
    allowIncomplete: allowIncomplete,
    kind: AudioTransformKind.export,
  );

  /// An ephemeral frozen reader snapshot, claimed synchronously by the player.
  /// It is excluded from background work and discarded after actual exit.
  AudioTransformJob createPlaybackJob(String sessionId) => _freezeRecordingJob(
    sessionId: sessionId,
    codec: 'pcm_s16le',
    container: 'raw',
    settingsRevision: 'shared-playback-v1',
    settings: {'reader': newIdentity()},
    preferredInputCodec: 'opus',
    allowIncomplete: true,
    kind: AudioTransformKind.playback,
  );

  AudioTransformJob _freezeRecordingJob({
    required String sessionId,
    required String codec,
    required String container,
    required String settingsRevision,
    required Map<String, Object?> settings,
    required String preferredInputCodec,
    required bool allowIncomplete,
    required AudioTransformKind kind,
  }) => transaction(() {
    final owner = _live(sessionId);
    _revision(settingsRevision);
    if (!owner.captureState.terminal ||
        _rows(
          'SELECT 1 FROM recording_spans WHERE session_id=? AND capture_end_us IS NULL LIMIT 1',
          [sessionId],
        ).isNotEmpty) {
      throw StateError('Seal the recording before freezing an export');
    }
    if (codec.isEmpty ||
        codec.length > 64 ||
        container.isEmpty ||
        container.length > 64 ||
        preferredInputCodec.length > 64) {
      throw ArgumentError('Invalid export target');
    }
    if (!allowIncomplete &&
        _rows(
          "SELECT 1 FROM audio_chunks WHERE session_id=? AND state!='published' LIMIT 1",
          [sessionId],
        ).isNotEmpty) {
      throw StateError('Export requires explicit incomplete-audio admission');
    }
    if (_rows(
      "SELECT 1 FROM audio_chunks c WHERE c.session_id=? AND c.state='published' AND NOT EXISTS(SELECT 1 FROM audio_representations r WHERE r.chunk_id=c.id AND r.state='published' AND r.validated=1) LIMIT 1",
      [sessionId],
    ).isNotEmpty) {
      throw StateError('Published audio has no usable representation');
    }
    final timeline = playbackTimeline.resolve(
      sessionId,
      authority: playbackTimelineAuthority,
    );
    final encoded = jsonEncode(
      _canonicalSettings({
        ...settings,
        'allow_incomplete': allowIncomplete,
        'timeline_revision': AudioPlaybackTimeline.revision,
        'timeline_frames': timeline.totalFrames,
      }),
    );
    if (utf8.encode(encoded).length > 16384) {
      throw ArgumentError('Export settings exceed budget');
    }
    final id = newIdentity();
    db.execute(
      "INSERT INTO audio_transform_jobs(id,session_id,kind,input_identity,codec,container,settings_revision,settings,state) VALUES(?,?,?,?,?,?,?,?,'pending')",
      [
        id,
        sessionId,
        kind.name,
        crypto.sha256.convert(utf8.encode(id)).toString(),
        codec,
        container,
        settingsRevision,
        encoded,
      ],
    );
    db.execute(
      "WITH candidates AS (SELECT r.id,c.sequence,c.source,s.ordinal,ROW_NUMBER() OVER(PARTITION BY c.id ORDER BY CASE WHEN r.codec=? THEN 0 ELSE 1 END,r.id) AS choice FROM audio_representations r JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_spans s ON s.id=c.span_id WHERE c.session_id=? AND c.state='published' AND r.state='published' AND r.validated=1) INSERT INTO audio_transform_inputs(job_id,position,representation_id) SELECT ?,ROW_NUMBER() OVER(ORDER BY ordinal,sequence,source)-1,id FROM candidates WHERE choice=1",
      [preferredInputCodec, sessionId, id],
    );
    final cursor = timeline.cursor();
    final freeze = db.prepare(
      '''UPDATE audio_transform_inputs
      SET playback_start_frame=?,playback_frame_count=?,playback_geometry_sha256=? WHERE job_id=? AND
      representation_id IN(SELECT id FROM audio_representations WHERE chunk_id=?)''',
    );
    try {
      for (final row in playbackTimeline.acquiredChunks(sessionId)) {
        final geometry = cursor.accept(row);
        freeze.execute([
          geometry.startFrame,
          geometry.frameCount,
          AudioPlaybackTimeline.chunkIdentity(
            row,
            geometry.startFrame,
            geometry.frameCount,
          ),
          id,
          row['id'],
        ]);
      }
    } finally {
      freeze.dispose();
    }
    if (_rows(
      'SELECT 1 FROM audio_transform_inputs WHERE job_id=? AND playback_start_frame IS NULL LIMIT 1',
      [id],
    ).isNotEmpty) {
      throw StateError('Frozen input has no acquired sample geometry');
    }
    final receiver = _AudioDigestSink();
    final digest = crypto.sha256.startChunkedConversion(receiver);
    digest.add(
      utf8.encode(
        jsonEncode([
          sessionId,
          kind.name,
          owner.storageGeneration,
          codec,
          container,
          settingsRevision,
          encoded,
        ]),
      ),
    );
    var after = -1;
    while (true) {
      final page = _rows(
        'SELECT i.position,i.playback_start_frame,i.playback_frame_count,i.playback_geometry_sha256,r.id,r.sha256,r.decoded_samples,c.span_id,c.source,c.sample_start,c.sample_count,c.sample_rate,c.channels,c.capture_start_us,c.capture_end_us,c.gap_before,s.capture_start_us AS span_capture_start,s.playback_start_us,s.capture_end_us AS span_capture_end,s.playback_end_us,(SELECT k.quality FROM audio_source_clocks k WHERE k.span_id=c.span_id AND k.source=c.source AND (k.observed_capture_us IS NULL OR k.observed_capture_us<=c.capture_start_us) ORDER BY k.revision DESC LIMIT 1) AS clock_quality,(SELECT k.uncertainty_us FROM audio_source_clocks k WHERE k.span_id=c.span_id AND k.source=c.source AND (k.observed_capture_us IS NULL OR k.observed_capture_us<=c.capture_start_us) ORDER BY k.revision DESC LIMIT 1) AS clock_uncertainty_us,(SELECT json_group_array(json_array(k.revision,k.quality,k.uncertainty_us,k.observed_capture_us)) FROM audio_source_clocks k WHERE k.span_id=c.span_id AND k.source=c.source AND k.revision>=(SELECT COALESCE(MAX(p.revision),0) FROM audio_source_clocks p WHERE p.span_id=c.span_id AND p.source=c.source AND (p.observed_capture_us IS NULL OR p.observed_capture_us<=c.capture_start_us)) AND (k.observed_capture_us IS NULL OR k.observed_capture_us<=c.capture_end_us)) AS clock_transitions FROM audio_transform_inputs i JOIN audio_representations r ON r.id=i.representation_id JOIN audio_chunks c ON c.id=r.chunk_id JOIN recording_spans s ON s.id=c.span_id WHERE i.job_id=? AND i.position>? ORDER BY i.position LIMIT 256',
        [id, after],
      );
      if (page.isEmpty) break;
      for (final row in page) {
        digest.add(utf8.encode(jsonEncode(row)));
      }
      after = page.last['position'] as int;
    }
    digest.close();
    if (after < 0) {
      throw StateError('The recording contains no exportable audio');
    }
    final identity = receiver.value!.toString();
    final previous = _rows(
      'SELECT * FROM audio_transform_jobs WHERE input_identity=?',
      [identity],
    ).firstOrNull;
    if (previous != null) {
      db.execute('DELETE FROM audio_transform_jobs WHERE id=?', [id]);
      return AudioTransformJob.fromRow(previous);
    }
    db.execute('UPDATE audio_transform_jobs SET input_identity=? WHERE id=?', [
      identity,
      id,
    ]);
    return transformJob(id)!;
  });

  List<AudioRepresentation> transformInputs(
    String jobId, {
    int afterPosition = -1,
    int limit = 256,
  }) {
    _page(limit);
    return _rows(
      'SELECT r.* FROM audio_representations r JOIN audio_transform_inputs i ON i.representation_id=r.id WHERE i.job_id=? AND i.position>? ORDER BY i.position LIMIT ?',
      [jobId, afterPosition, limit],
    ).map(AudioRepresentation.fromRow).toList();
  }

  List<AudioTransformJob> pendingTransformJobs({
    required int nowMs,
    AudioTransformKind? kind,
    int limit = 64,
  }) {
    _page(limit);
    if (!mediaAdmitted) return const [];
    return _rows(
      "SELECT j.* FROM audio_transform_jobs j JOIN recording_sessions s ON s.id=j.session_id WHERE j.kind!='playback' AND j.state IN ('pending','retry') AND j.retry_after_ms<=? AND s.storage_generation=? AND s.workspace_epoch=? AND (? IS NULL OR j.kind=?) AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) ORDER BY j.attempts,s.started_wall_ms,j.id LIMIT ?",
      [
        nowMs,
        storageGeneration,
        workspaceEpoch(),
        kind?.name,
        kind?.name,
        limit,
      ],
    ).map(AudioTransformJob.fromRow).toList();
  }

  /// One eligible job per session/kind turn, with wraparound. A long old
  /// compression queue cannot hide a newer session or an authorized export.
  AudioTransformJob? nextPendingTransformJob({
    required int nowMs,
    String afterSessionId = '',
    AudioTransformKind afterKind = AudioTransformKind.export,
  }) {
    if (!mediaAdmitted) return null;
    List<Map<String, Object?>> next(bool wrap) => _rows(
      "SELECT j.* FROM audio_transform_jobs j JOIN recording_sessions s ON s.id=j.session_id WHERE j.kind!='playback' AND j.state IN ('pending','retry') AND j.retry_after_ms<=? AND s.storage_generation=? AND s.workspace_epoch=? AND NOT EXISTS(SELECT 1 FROM audio_erasure_intents e WHERE e.session_id=s.id) AND (? OR j.session_id>? OR (j.session_id=? AND j.kind>?)) ORDER BY j.session_id,j.kind,j.id LIMIT 1",
      [
        nowMs,
        storageGeneration,
        workspaceEpoch(),
        wrap ? 1 : 0,
        afterSessionId,
        afterSessionId,
        afterKind.name,
      ],
    );
    final row = next(false).firstOrNull ?? next(true).firstOrNull;
    return row == null ? null : AudioTransformJob.fromRow(row);
  }

  /// Call only after actual worker exit/cancellation fencing. Shutdown and
  /// model barriers preserve the bounded failure budget; stale leases are inert.
  void interruptTransformJob(
    AudioTransformLease lease, {
    required String error,
  }) => transaction(() {
    if (error.length > 1024) throw ArgumentError('Audio error is too long');
    final value = transformJob(lease.job.id);
    if (value == null) return;
    try {
      _live(value.sessionId);
    } on RpcError {
      return;
    }
    if (!_hasTransformLease(lease)) return;
    db.execute(
      "UPDATE audio_transform_jobs SET state='retry',attempts=MAX(0,attempts-1),lease_generation=lease_generation+1,owner_generation=NULL,retry_after_ms=0,error=? WHERE id=?",
      [error, value.id],
    );
    releaseTransformLeaseReferences(lease);
  });

  AudioTransformLease? claimTransformJob(
    String id, {
    required String ownerGeneration,
    required int nowMs,
  }) => transaction(() {
    _identity(ownerGeneration);
    final value = transformJob(id);
    if (value == null) return null;
    _live(value.sessionId);
    if (![AudioJobState.pending, AudioJobState.retry].contains(value.state)) {
      return null;
    }
    if (_rows('SELECT 1 FROM audio_transform_inputs WHERE job_id=? LIMIT 1', [
          id,
        ]).isEmpty ||
        _rows(
          "SELECT 1 FROM audio_transform_inputs i JOIN audio_representations r ON r.id=i.representation_id WHERE i.job_id=? AND (r.state!='published' OR r.validated!=1) LIMIT 1",
          [id],
        ).isNotEmpty) {
      throw StateError('Transform input no longer available');
    }
    db.execute(
      "UPDATE audio_transform_jobs SET state='running',attempts=attempts+1,owner_generation=?,lease_generation=lease_generation+1 WHERE id=? AND state IN ('pending','retry') AND retry_after_ms<=?",
      [ownerGeneration, id, nowMs],
    );
    if (db.updatedRows != 1) return null;
    final claimed = transformJob(id)!;
    db.execute(
      "INSERT INTO audio_media_references(id,representation_id,owner_generation,purpose) SELECT ?||':'||position,representation_id,?,? FROM audio_transform_inputs WHERE job_id=?",
      [
        '$id:${claimed.leaseGeneration}',
        ownerGeneration,
        'transform:$id:${claimed.leaseGeneration}',
        id,
      ],
    );
    return AudioTransformLease(
      claimed,
      ownerGeneration,
      claimed.leaseGeneration,
    );
  });

  /// Trusted player only, after every decoder/descriptor owner actually exits.
  /// A stale callback releases its own readers but cannot delete a newer lease.
  void releasePlaybackLease(AudioTransformLease lease) => transaction(() {
    if (lease.job.kind != AudioTransformKind.playback) {
      throw ArgumentError('Only an ephemeral playback lease can be discarded');
    }
    releaseTransformLeaseReferences(lease);
    db.execute(
      "DELETE FROM audio_transform_jobs WHERE id=? AND kind='playback' AND owner_generation=? AND lease_generation=?",
      [lease.job.id, lease.ownerGeneration, lease.leaseGeneration],
    );
  });

  bool _hasTransformLease(AudioTransformLease lease) {
    final value = transformJob(lease.job.id);
    return value != null &&
        value.state == AudioJobState.running &&
        value.ownerGeneration == lease.ownerGeneration &&
        value.leaseGeneration == lease.leaseGeneration;
  }

  void failTransformJob(
    AudioTransformLease lease, {
    required String error,
    required int nowMs,
    bool blocked = false,
  }) => transaction(() {
    _live(lease.job.sessionId);
    if (!_hasTransformLease(lease)) return;
    if (error.length > 1024) throw ArgumentError('Audio error is too long');
    db.execute(
      'UPDATE audio_transform_jobs SET state=?,error=?,retry_after_ms=?,owner_generation=NULL WHERE id=?',
      [
        blocked
            ? 'blocked'
            : lease.job.attempts >= 5
            ? 'failed'
            : 'retry',
        error,
        nowMs + min(300000, 1000 * (1 << min(lease.job.attempts, 8))),
        lease.job.id,
      ],
    );
    releaseTransformLeaseReferences(lease);
  });

  void retryTransformJob(String id) => transaction(() {
    final value = transformJob(id);
    if (value == null) return;
    _live(value.sessionId);
    if (![AudioJobState.blocked, AudioJobState.failed].contains(value.state)) {
      throw StateError('Only failed/blocked transforms can be retried');
    }
    db.execute(
      "UPDATE audio_transform_jobs SET state='pending',attempts=0,retry_after_ms=0,error='',owner_generation=NULL,lease_generation=lease_generation+1 WHERE id=?",
      [id],
    );
  });

  void abandonTransformJob(String id) => transaction(() {
    final value = transformJob(id);
    if (value == null) return;
    _live(value.sessionId);
    if (value.state == AudioJobState.running ||
        value.state == AudioJobState.completed) {
      throw StateError(
        'Release the transform worker before abandoning unfinished output',
      );
    }
    db.execute(
      "UPDATE audio_transform_jobs SET state='abandoned',owner_generation=NULL,lease_generation=lease_generation+1 WHERE id=?",
      [id],
    );
  });

  /// The publisher has validated, synced and renamed the complete output.
  /// Compression requires a matching decoded/sample-mapped representation;
  /// export records its validated immutable artifact identity/metadata. The
  /// service owns authorized destination handling outside this transaction.
  AudioTransformCommit commitTransformResult(
    AudioTransformLease lease, {
    AudioRepresentation? representation,
    Map<String, Object?> outputMetadata = const {},
  }) => transaction(() {
    _live(lease.job.sessionId);
    final current = transformJob(lease.job.id);
    if (current?.state == AudioJobState.completed) {
      return AudioTransformCommit(newlyCommitted: false, job: current!);
    }
    if (!_hasTransformLease(lease)) {
      throw StateError('Stale transform result lease');
    }
    final metadata = jsonEncode(_canonicalSettings(outputMetadata));
    if (utf8.encode(metadata).length > 16384) {
      throw ArgumentError('Transform output metadata exceeds budget');
    }
    if (current!.kind == AudioTransformKind.compression) {
      final input = transformInputs(current.id).single;
      if (representation == null ||
          representation.chunkId != input.chunkId ||
          representation.codec != current.codec ||
          representation.container != current.container ||
          representation.settingsRevision != current.settingsRevision) {
        throw ArgumentError(
          'Compression output does not match frozen input/settings',
        );
      }
      publishRepresentation(representation);
    } else {
      if (representation != null ||
          outputMetadata['validated'] != true ||
          outputMetadata['byte_length'] is! int ||
          (outputMetadata['byte_length'] as int) < 1 ||
          outputMetadata['output_identity'] is! String ||
          (outputMetadata['output_identity'] as String).isEmpty ||
          outputMetadata['sha256'] is! String) {
        throw ArgumentError('Export output has not been validated');
      }
      _digest(outputMetadata['sha256'] as String);
    }
    db.execute(
      "UPDATE audio_transform_jobs SET state='completed',owner_generation=NULL,error='',output_representation_id=?,output_metadata=? WHERE id=?",
      [representation?.id, metadata, current.id],
    );
    releaseTransformLeaseReferences(lease);
    return AudioTransformCommit(
      newlyCommitted: true,
      job: transformJob(current.id)!,
    );
  });
}

final class _AudioDigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) {
    value = data;
  }

  @override
  void close() {}
}
