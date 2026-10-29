import 'dart:io';
import 'dart:convert';

import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late String path;
  late Store store;
  late AudioStore audio;
  late AudioSession session;
  late AudioSpan span;
  const digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  AudioStore boundAudio() => AudioStore(
    store.db,
    workspaceEpoch: () => store.workspaceEpoch,
    mediaGeneration: () => store.audioStore.storageGeneration,
  );

  setUp(() {
    root = createTestTempDirectorySync('audio-store-');
    path = '${root.path}/application.db';
    store = Store(path);
    audio = boundAudio();
    final meeting = store.meeting('Meeting');
    session = audio.createSession(meetingId: meeting, startedWallMs: 123);
    span = audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 123,
    );
    addTearDown(() => store.close());
  });

  AudioChunkPublication preallocate({
    AudioSource source = AudioSource.microphone,
    int sequence = 0,
  }) {
    final id = AudioStore.newIdentity();
    return audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: source,
      sequence: sequence,
      id: id,
      relativePath: 'audio/${session.storageGeneration}/${session.id}/$id.wav',
    );
  }

  AudioChunk publish(
    AudioChunkPublication p, {
    int sampleStart = 0,
    int sampleCount = 16000,
    int captureStartUs = 0,
    bool canonical = false,
  }) => audio.publishPreallocatedChunk(
    p.id,
    publicationToken: p.publicationToken,
    sampleStart: sampleStart,
    sampleCount: sampleCount,
    sampleRate: canonical ? 48000 : 16000,
    channels: 1,
    captureStartUs: captureStartUs,
    captureEndUs:
        captureStartUs + sampleCount * 1000000 ~/ (canonical ? 48000 : 16000),
    byteLength: sampleCount * 2 + (canonical ? 196 : 44),
    sha256: digest,
  );
  AudioChunk capture({
    AudioSource source = AudioSource.microphone,
    int sequence = 0,
    int sampleStart = 0,
    int captureStartUs = 0,
    bool canonical = false,
  }) => publish(
    preallocate(source: source, sequence: sequence),
    sampleStart: sampleStart,
    sampleCount: canonical ? 48000 : 16000,
    canonical: canonical,
    captureStartUs: captureStartUs,
  );
  AudioSegmentationCursor cursor({
    AudioSource source = AudioSource.microphone,
  }) => audio.initializeSegmentation(
    sessionId: session.id,
    spanId: span.id,
    source: source,
    settingsRevision: 'vad-v1',
    modelRevision: 'model-sha256',
    initialSample: 0,
  );
  AudioAsrJob admit({AudioSource source = AudioSource.microphone}) {
    final id = AudioStore.newIdentity();
    audio.admitSegments(
      cursor(source: source),
      throughSample: 16000,
      retainFromSample: 16000,
      ranges: [
        AudioAsrRange(
          id: id,
          sampleStart: 0,
          sampleEnd: 16000,
          ownedStart: 0,
          ownedEnd: 16000,
        ),
      ],
    );
    return audio.job(id)!;
  }

  AudioAsrLease claim(AudioAsrJob job, {String? owner}) => audio.claimJob(
    job.id,
    ownerGeneration: owner ?? AudioStore.newIdentity(),
    nowMs: 0,
  )!;
  const result = AudioTranscriptResult(
    text: 'Test words',
    sampleStart: 0,
    sampleEnd: 16000,
    startMs: 0,
    endMs: 1000,
  );
  void compress(AudioChunk chunk) {
    audio.publishRepresentation(
      AudioRepresentation(
        id: '${chunk.id}.opus',
        chunkId: chunk.id,
        codec: 'opus',
        container: 'ogg',
        settingsRevision: 'opus-32k-v1',
        relativePath: '${chunk.relativePath}.ogg',
        byteLength: 1024,
        sha256: digest,
        decodedSamples: 16000,
        preSkip: 312,
        state: AudioRepresentationState.published,
        validated: true,
      ),
    );
  }

  test(
    'unknown-size publication authority survives restart before audio exists',
    () {
      final p = preallocate();
      expect(audio.chunk(p.id), isNull);
      store.close();
      store = Store(path);
      audio = boundAudio();
      expect(audio.pendingPublications().single.id, p.id);
      expect(
        audio.mayAdoptChunk(p.id, p.publicationToken, p.storageGeneration),
        isTrue,
      );
      expect(
        audio.mayAdoptChunk(
          p.id,
          AudioStore.newIdentity(),
          p.storageGeneration,
        ),
        isFalse,
      );
      expect(
        audio.mayAdoptChunk(p.id, p.publicationToken, AudioStore.newIdentity()),
        isFalse,
      );
      final chunk = publish(p, sampleCount: 8000);
      expect(chunk.sampleCount, 8000);
      expect(audio.pendingPublications(), isEmpty);
    },
  );

  test('partial publication after sealed stop uses surviving authority', () {
    final p = preallocate();
    audio.closeSpan(span.id, captureEndUs: 500000, reason: 'stop');
    audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 999,
    );
    final chunk = publish(p, sampleCount: 8000);
    expect(chunk.sampleEnd, 8000);
    expect(() => preallocate(sequence: 1), throwsStateError);
    expect(
      () => audio.startSpan(
        session.id,
        captureStartUs: 500000,
        playbackStartUs: 500000,
        wallAnchorMs: 999,
      ),
      throwsStateError,
    );
  });

  test(
    'immutable publication rejects altered format and duplicate content',
    () {
      final p = preallocate();
      final c = publish(p);
      expect(publish(p).id, c.id);
      expect(audio.representations(c.id), hasLength(1));
      expect(() => publish(p, sampleCount: 8000), throwsStateError);
      expect(
        () => audio.publishChunk(
          c.id,
          publicationToken: p.publicationToken,
          byteLength: 1,
          sha256: digest,
        ),
        throwsStateError,
      );
      expect(
        audio.mayAdoptChunk(c.id, p.publicationToken, p.storageGeneration),
        isFalse,
      );
    },
  );

  test('malformed paths and overlapping source audio cannot be admitted', () {
    for (final path in [
      '/absolute.wav',
      '../outside.wav',
      'audio/../outside.wav',
      'audio//file.wav',
      r'audio\file.wav',
    ]) {
      expect(
        () => audio.preallocateChunk(
          sessionId: session.id,
          spanId: span.id,
          source: AudioSource.microphone,
          sequence: 0,
          relativePath: path,
        ),
        throwsArgumentError,
      );
    }
    capture();
    final p = preallocate(sequence: 1);
    expect(
      () => publish(p, sampleStart: 8000, captureStartUs: 500000),
      throwsStateError,
    );
    expect(audio.chunk(p.id), isNull);
  });

  test('pause removes only intentional interval on compact timeline', () {
    capture();
    audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'pause');
    audio.setCaptureState(session.id, AudioCaptureState.paused);
    final resumed = audio.startSpan(
      session.id,
      captureStartUs: 9000000,
      playbackStartUs: 1000000,
      wallAnchorMs: 55,
    );
    audio.closeSpan(resumed.id, captureEndUs: 10000000, reason: 'stop');
    expect(audio.spans(session.id).last.playbackEndUs, 2000000);
    expect(
      () => audio.closeSpan(span.id, captureEndUs: 2000000, reason: 'pause'),
      throwsStateError,
    );
  });

  test(
    'capture errors survive transient state messages until explicit recovery',
    () {
      audio.setCaptureState(
        session.id,
        AudioCaptureState.recording,
        error: 'disk_full',
      );
      audio.setCaptureState(session.id, AudioCaptureState.pausing);
      expect(audio.session(session.id)!.terminalError, 'disk_full');
      audio.setCaptureState(session.id, AudioCaptureState.recording, error: '');
      expect(audio.session(session.id)!.terminalError, isEmpty);
    },
  );

  test('segmentation cannot advance past an unpublished or missing chunk', () {
    preallocate();
    expect(
      () => audio.admitSegments(
        cursor(),
        throughSample: 16000,
        retainFromSample: 16000,
        ranges: [],
      ),
      throwsStateError,
    );
    expect(
      audio
          .segmentation(session.id, AudioSource.microphone, span.id)!
          .cursorSample,
      0,
    );
    final c = capture(sequence: 1);
    audio.markChunkUnavailable(c.id);
    expect(
      () => audio.admitSegments(
        cursor(),
        throughSample: 16000,
        retainFromSample: 16000,
        ranges: [],
      ),
      throwsStateError,
    );
  });

  test(
    'silence cursor and closed-span flush persist without transcript jobs',
    () {
      capture();
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      audio.admitSegments(
        cursor(),
        throughSample: 16000,
        retainFromSample: 16000,
        ranges: [],
        flush: true,
      );
      store.close();
      store = Store(path);
      audio = boundAudio();
      final progress = audio.segmentation(
        session.id,
        AudioSource.microphone,
        span.id,
      )!;
      expect(progress.cursorSample, 16000);
      expect(progress.flushed, isTrue);
      expect(audio.pendingJobs(nowMs: 0), isEmpty);
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
      expect(
        () => audio.admitSegments(
          progress,
          throughSample: 16000,
          retainFromSample: 16000,
          ranges: [],
          flush: true,
        ),
        throwsStateError,
      );
    },
  );

  test('segmentation settings remain frozen across restart', () {
    capture();
    cursor();
    store.close();
    store = Store(path);
    audio = boundAudio();
    expect(
      () => audio.initializeSegmentation(
        sessionId: session.id,
        spanId: span.id,
        source: AudioSource.microphone,
        settingsRevision: 'different-vad',
        modelRevision: 'model-sha256',
        initialSample: 0,
      ),
      throwsStateError,
    );
  });

  test(
    'cross-chunk open segment retains context and admits owned range once',
    () {
      capture();
      capture(sequence: 1, sampleStart: 16000, captureStartUs: 1000000);
      final original = cursor();
      audio.admitSegments(
        original,
        throughSample: 16000,
        retainFromSample: 0,
        ranges: [],
        context: [1, 2],
      );
      final next = audio.segmentation(
        session.id,
        AudioSource.microphone,
        span.id,
      )!;
      expect(next.context, [1, 2]);
      final id = AudioStore.newIdentity();
      audio.admitSegments(
        next,
        throughSample: 32000,
        retainFromSample: 32000,
        ranges: [
          AudioAsrRange(
            id: id,
            sampleStart: 0,
            sampleEnd: 32000,
            ownedStart: 0,
            ownedEnd: 32000,
          ),
        ],
      );
      expect(audio.jobChunks(id), hasLength(2));
      expect(
        () => audio.admitSegments(
          next,
          throughSample: 32000,
          retainFromSample: 32000,
          ranges: [],
        ),
        throwsStateError,
      );
      expect(audio.pendingJobs(nowMs: 0), hasLength(1));
    },
  );

  test('job admission and cursor rollback together when an insertion fails', () {
    capture();
    store.db.execute(
      "CREATE TRIGGER fail_audio_job BEFORE INSERT ON audio_asr_job_chunks BEGIN SELECT RAISE(ABORT,'fixture admission failure'); END",
    );
    expect(() => admit(), throwsA(isA<SqliteException>()));
    expect(audio.pendingJobs(nowMs: 0), isEmpty);
    expect(
      audio
          .segmentation(session.id, AudioSource.microphone, span.id)!
          .cursorSample,
      0,
    );
    store.db.execute('DROP TRIGGER fail_audio_job');
    expect(admit().state, AudioJobState.pending);
  });

  test('worker reclamation fences late completion and keeps frozen ranges', () {
    capture();
    final j = admit();
    final old = claim(j);
    expect(
      audio.claimJob(j.id, ownerGeneration: AudioStore.newIdentity(), nowMs: 0),
      isNull,
    );
    final owner = AudioStore.newIdentity();
    audio.recoverLeases(owner);
    final fresh = claim(audio.job(j.id)!, owner: owner);
    expect(fresh.leaseGeneration, greaterThan(old.leaseGeneration));
    expect(() => audio.commitAsrResult(old, [result]), throwsStateError);
    expect(audio.commitAsrResult(fresh, [result]).newlyCommitted, isTrue);
  });

  test(
    'result text, links, meeting revision and existing index outbox commit once',
    () {
      capture();
      final lease = claim(admit());
      final committed = audio.commitAsrResult(lease, [result]);
      expect(committed.newlyCommitted, isTrue);
      expect(store.rows('SELECT * FROM transcript'), hasLength(1));
      expect(store.rows('SELECT * FROM transcript_audio_links'), hasLength(1));
      expect(store.rows('SELECT revision FROM meetings').single['revision'], 1);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), hasLength(1));
      final id = committed.transcriptIds.single;
      store.db.execute('UPDATE transcript SET text=? WHERE id=?', [
        'User correction',
        id,
      ]);
      store.close();
      store = Store(path);
      audio = boundAudio();
      expect(audio.commitAsrResult(lease, [result]).newlyCommitted, isFalse);
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'User correction',
      );
      expect(store.rows('SELECT revision FROM meetings').single['revision'], 2);
    },
  );

  test(
    'result transaction failure rolls back text links revision journal and state',
    () {
      capture();
      final lease = claim(admit());
      store.db.execute(
        "CREATE TRIGGER fail_audio_commit BEFORE INSERT ON transcript_audio_links BEGIN SELECT RAISE(ABORT,'fixture result failure'); END",
      );
      expect(
        () => audio.commitAsrResult(lease, [result]),
        throwsA(isA<SqliteException>()),
      );
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
      expect(store.rows('SELECT revision FROM meetings').single['revision'], 0);
      expect(audio.job(lease.job.id)!.state, AudioJobState.running);
      store.db.execute('DROP TRIGGER fail_audio_commit');
      expect(audio.commitAsrResult(lease, [result]).newlyCommitted, isTrue);
    },
  );

  test(
    'ordinary transcript deletion removes audio link and never replays ASR',
    () {
      capture();
      final lease = claim(admit());
      final committed = audio.commitAsrResult(lease, [result]);
      store.db.execute('DELETE FROM transcript WHERE id=?', [
        committed.transcriptIds.single,
      ]);
      expect(store.rows('SELECT * FROM transcript_audio_links'), isEmpty);
      expect(audio.commitAsrResult(lease, [result]).newlyCommitted, isFalse);
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
    },
  );

  test(
    'retry backoff is bounded and blocked errors require explicit retry',
    () {
      capture();
      final lease = claim(admit());
      audio.failJob(lease, error: 'model_missing', nowMs: 10, blocked: true);
      expect(audio.pendingJobs(nowMs: 999999), isEmpty);
      expect(audio.job(lease.job.id)!.error, 'model_missing');
      audio.retryJob(lease.job.id);
      expect(audio.pendingJobs(nowMs: 0).single.id, lease.job.id);
      final retry = claim(audio.job(lease.job.id)!);
      audio.failJob(retry, error: 'runtime_failed', nowMs: 10);
      expect(audio.pendingJobs(nowMs: 10), isEmpty);
      expect(audio.pendingJobs(nowMs: 999999), hasLength(1));
    },
  );

  test(
    'compression cannot purge before segmentation, context, flush and ASR finish',
    () {
      final c = capture();
      compress(c);
      expect(audio.beginRawPurge(c.id), isNull);
      final current = cursor();
      audio.admitSegments(
        current,
        throughSample: 16000,
        retainFromSample: 0,
        ranges: [],
        context: [1],
      );
      expect(audio.beginRawPurge(c.id), isNull);
      final next = audio.segmentation(
        session.id,
        AudioSource.microphone,
        span.id,
      )!;
      final id = AudioStore.newIdentity();
      audio.admitSegments(
        next,
        throughSample: 16000,
        retainFromSample: 16000,
        ranges: [
          AudioAsrRange(
            id: id,
            sampleStart: 0,
            sampleEnd: 16000,
            ownedStart: 0,
            ownedEnd: 16000,
          ),
        ],
      );
      expect(audio.beginRawPurge(c.id), isNull);
      audio.commitAsrResult(claim(audio.job(id)!), [result]);
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      expect(audio.beginRawPurge(c.id), isNull);
      audio.admitSegments(
        audio.segmentation(session.id, AudioSource.microphone, span.id)!,
        throughSample: 16000,
        retainFromSample: 16000,
        ranges: [],
        flush: true,
      );
      expect(
        audio.beginRawPurge(c.id)!.state,
        AudioRepresentationState.supersededPendingPurge,
      );
    },
  );

  test(
    'reader reference and purge fence exclude each other; restart resumes purge',
    () {
      final c = capture();
      compress(c);
      admit();
      final j = audio.pendingJobs(nowMs: 0).single;
      audio.commitAsrResult(claim(j), [result]);
      final owner = AudioStore.newIdentity();
      final reference = audio.acquireReference(
        '${c.id}.raw',
        ownerGeneration: owner,
        purpose: 'playback',
      );
      expect(audio.beginRawPurge(c.id), isNull);
      audio.releaseReference(reference);
      final pending = audio.beginRawPurge(c.id)!;
      expect(
        () => audio.acquireReference(
          pending.id,
          ownerGeneration: owner,
          purpose: 'asr',
        ),
        throwsStateError,
      );
      expect(
        () => audio.admitSegments(
          cursor(),
          throughSample: 16000,
          retainFromSample: 16000,
          ranges: [
            AudioAsrRange(
              id: AudioStore.newIdentity(),
              sampleStart: 0,
              sampleEnd: 16000,
              ownedStart: 0,
              ownedEnd: 16000,
            ),
          ],
        ),
        throwsArgumentError,
      );
      store.close();
      store = Store(path);
      audio = boundAudio();
      expect(audio.pendingPurges().single.id, pending.id);
      audio.completePurge(pending.id);
      audio.completePurge(pending.id);
      expect(audio.pendingPurges(), isEmpty);
      expect(audio.chunk(c.id), isNotNull);
    },
  );

  test(
    'invalid compressed representation retains raw and duplicate publication is immutable',
    () {
      final c = capture();
      expect(
        () => audio.publishRepresentation(
          AudioRepresentation(
            id: 'bad',
            chunkId: c.id,
            codec: 'opus',
            container: 'ogg',
            settingsRevision: 'v1',
            relativePath: 'audio/bad.ogg',
            byteLength: 4,
            sha256: digest,
            decodedSamples: 8000,
            state: AudioRepresentationState.published,
            validated: true,
          ),
        ),
        throwsArgumentError,
      );
      expect(audio.representations(c.id).single.codec, 'pcm_s16le');
      compress(c);
      compress(c);
      expect(audio.representations(c.id), hasLength(2));
    },
  );

  test(
    'deletion requires worker and reader fences then keeps durable erase authority',
    () {
      final c = capture();
      final j = admit();
      final lease = claim(j);
      expect(
        () => audio.tombstoneSession(session.id),
        throwsA(isA<SqliteException>()),
      );
      audio.failJob(
        lease,
        error: 'cancelled_for_delete',
        nowMs: 0,
        blocked: true,
      );
      final reference = audio.acquireReference(
        '${c.id}.raw',
        ownerGeneration: AudioStore.newIdentity(),
        purpose: 'export',
      );
      expect(
        () => audio.tombstoneSession(session.id),
        throwsA(isA<SqliteException>()),
      );
      audio.releaseReference(reference);
      audio.tombstoneSession(session.id);
      store.close();
      store = Store(path);
      audio = boundAudio();
      expect(audio.session(session.id), isNull);
      expect(audio.pendingErasures().single.sessionId, session.id);
      expect(
        audio.mayAdoptChunk(c.id, c.publicationToken, c.storageGeneration),
        isFalse,
      );
      expect(
        () => audio.commitAsrResult(lease, [result]),
        throwsA(isA<Exception>()),
      );
      audio.completeErasure(session.id, session.storageGeneration);
      expect(audio.pendingErasures(), isEmpty);
    },
  );

  test(
    'workspace clear rotates media identity and retains unfinished erasure intent',
    () {
      final p = preallocate();
      final before = audio.storageGeneration;
      WorkspacePersistence(store).clearLocalData([]);
      expect(audio.storageGeneration, isNot(before));
      expect(audio.pendingErasures().single.sessionId, session.id);
      expect(
        audio.mayAdoptChunk(p.id, p.publicationToken, p.storageGeneration),
        isFalse,
      );
      expect(store.rows('SELECT * FROM recording_sessions'), isEmpty);
    },
  );

  test(
    'metadata restore cannot adopt newer media or schedule before independent generation admission',
    () {
      final p = preallocate();
      final observed = audio.storageGeneration;
      final bound = AudioStore(
        store.db,
        workspaceEpoch: () => store.workspaceEpoch,
        mediaGeneration: () => AudioStore.newIdentity(),
      );
      expect(bound.mediaAdmitted, isFalse);
      expect(
        bound.mayAdoptChunk(p.id, p.publicationToken, p.storageGeneration),
        isFalse,
      );
      expect(
        () => bound.validateMediaGeneration('different-generation'),
        throwsStateError,
      );
      final next = audio.rotateStorageGeneration(metadataOnly: true);
      expect(next, isNot(observed));
      expect(audio.mediaAdmitted, isFalse);
      expect(
        () => audio.createSession(
          meetingId: session.meetingId,
          startedWallMs: 456,
        ),
        throwsStateError,
      );
      audio.admitNewRecordingStorage();
      expect(
        audio
            .createSession(meetingId: session.meetingId, startedWallMs: 456)
            .storageGeneration,
        next,
      );
      expect(audio.mayAdoptChunk(p.id, p.publicationToken, observed), isFalse);
    },
  );

  test('known-metadata reservation publishes exactly one raw representation', () {
    final id = AudioStore.newIdentity();
    final reserved = audio.reserveChunk(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      sequence: 0,
      relativePath:
          'recordings/${session.storageGeneration}/${session.id}/$id.wav',
      sampleStart: 0,
      sampleCount: 16000,
      sampleRate: 16000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 1000000,
      id: id,
    );
    expect(reserved.state, AudioChunkState.reserved);
    expect(
      audio.mayAdoptChunk(
        id,
        reserved.publicationToken,
        session.storageGeneration,
      ),
      isTrue,
    );
    final published = audio.publishChunk(
      id,
      publicationToken: reserved.publicationToken,
      byteLength: 32196,
      sha256: digest,
    );
    expect(
      audio.usableRepresentations(id).single.settingsRevision,
      'recording-wav-v1',
    );
    expect(published.sampleEnd, 16000);
    expect(audio.sessionsForMeeting(session.meetingId).single.id, session.id);
    expect(
      () => audio.reserveChunk(
        sessionId: session.id,
        spanId: span.id,
        source: AudioSource.microphone,
        sequence: 1,
        relativePath:
            'recordings/${session.storageGeneration}/${session.id}/oversized.wav',
        sampleStart: 16000,
        sampleCount: 160001,
        sampleRate: 16000,
        channels: 1,
        captureStartUs: 1000000,
        captureEndUs: 11000000,
      ),
      throwsArgumentError,
    );
  });

  test(
    'database-only authority cannot acquire new capture or saved media work',
    () {
      final c = capture();
      admit();
      final unbound = store.audioStore;
      expect(unbound.sessionsForMeeting(session.meetingId), hasLength(1));
      expect(unbound.mediaAdmitted, isFalse);
      expect(
        () => unbound.createSession(
          meetingId: session.meetingId,
          startedWallMs: 10,
        ),
        throwsStateError,
      );
      expect(unbound.usableRepresentations(c.id), isEmpty);
      expect(unbound.pendingJobs(nowMs: 0), isEmpty);
    },
  );

  test('canonical UUIDs interoperate with native fixed identity headers', () {
    final canonical = RegExp(
      r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
    );
    expect(canonical.hasMatch(AudioStore.newIdentity()), isTrue);
    expect(canonical.hasMatch(audio.storageGeneration), isTrue);
  });

  test(
    'metadata-only rotation preserves linked history while denying old media',
    () {
      final c = capture();
      final lease = claim(admit());
      final transcript = audio
          .commitAsrResult(lease, [result])
          .transcriptIds
          .single;
      final link = audio.transcriptAudioLink(transcript)!;
      expect(link.sessionId, session.id);
      expect(link.sampleEnd, 16000);
      audio.rotateStorageGeneration(metadataOnly: true);
      expect(
        audio.session(session.id)!.terminalError,
        'restored_without_audio',
      );
      expect(audio.chunk(c.id)!.state, AudioChunkState.quarantined);
      expect(
        audio.representations(c.id).single.state,
        AudioRepresentationState.missing,
      );
      expect(audio.transcriptAudioLink(transcript)!.jobId, lease.job.id);
      expect(audio.usableRepresentations(c.id), isEmpty);
      expect(audio.pendingJobs(nowMs: 999999), isEmpty);
      audio.admitNewRecordingStorage();
      expect(audio.usableRepresentations(c.id), isEmpty);
    },
  );

  test(
    'independent storage binding denies pending job and usable media admission',
    () {
      final c = capture();
      admit();
      final bound = AudioStore(
        store.db,
        workspaceEpoch: () => store.workspaceEpoch,
        mediaGeneration: () => null,
      );
      expect(bound.pendingJobs(nowMs: 0), isEmpty);
      expect(bound.usableRepresentations(c.id), isEmpty);
      expect(
        () => bound.claimJob(
          audio.pendingJobs(nowMs: 0).single.id,
          ownerGeneration: AudioStore.newIdentity(),
          nowMs: 0,
        ),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'paged two-source chunk cursor does not lose the second same-sequence source',
    () {
      capture();
      capture(source: AudioSource.playback);
      final first = audio.chunks(session.id, limit: 1).single;
      final second = audio
          .chunks(
            session.id,
            afterSequence: first.sequence,
            afterSource: first.source,
            limit: 1,
          )
          .single;
      expect(second.source, isNot(first.source));
    },
  );

  test('initial segmentation cannot skip published audio', () {
    capture();
    expect(
      () => audio.initializeSegmentation(
        sessionId: session.id,
        spanId: span.id,
        source: AudioSource.microphone,
        settingsRevision: 'vad-v1',
        modelRevision: 'model-sha256',
        initialSample: 16000,
      ),
      throwsArgumentError,
    );
    expect(
      audio.segmentation(session.id, AudioSource.microphone, span.id),
      isNull,
    );
  });

  test(
    'ASR exhaustion is bounded and explicit abandonment releases dependencies',
    () {
      final c = capture();
      compress(c);
      final j = admit();
      for (var attempt = 1; attempt <= 5; attempt++) {
        final lease = audio.claimJob(
          j.id,
          ownerGeneration: AudioStore.newIdentity(),
          nowMs: 99999999,
        )!;
        audio.failJob(lease, error: 'fixture_failed', nowMs: 0);
      }
      expect(audio.job(j.id)!.state, AudioJobState.failed);
      expect(audio.beginRawPurge(c.id), isNull);
      audio.abandonJob(j.id);
      expect(audio.beginRawPurge(c.id), isNotNull);
    },
  );

  AudioTransformJob transform(
    AudioChunk c, {
    AudioTransformKind kind = AudioTransformKind.compression,
    Map<String, Object?> settings = const {'bitrate': 32000},
  }) => audio.createTransformJob(
    sessionId: session.id,
    kind: kind,
    inputs: ['${c.id}.raw'],
    codec: kind == AudioTransformKind.compression ? 'opus' : 'mp3',
    container: kind == AudioTransformKind.compression ? 'ogg' : 'mp3',
    settingsRevision: 'codec-v1',
    settings: settings,
  );
  AudioRepresentation compressedOutput(AudioChunk c) => AudioRepresentation(
    id: '${c.id}.encoded',
    chunkId: c.id,
    codec: 'opus',
    container: 'ogg',
    settingsRevision: 'codec-v1',
    relativePath: '${c.relativePath}.opus',
    byteLength: 2048,
    sha256: digest,
    decodedSamples: c.sampleCount,
    preSkip: 312,
    state: AudioRepresentationState.published,
    validated: true,
  );
  AudioTransformLease claimTransform(AudioTransformJob j, {String? owner}) =>
      audio.claimTransformJob(
        j.id,
        ownerGeneration: owner ?? AudioStore.newIdentity(),
        nowMs: 999999,
      )!;

  test(
    'transform input and settings identity is frozen and survives restart',
    () {
      final c = capture();
      final first = transform(c, settings: {'b': 1, 'a': 2});
      expect(transform(c, settings: {'a': 2, 'b': 1}).id, first.id);
      expect(transform(c, settings: {'a': 3, 'b': 1}).id, isNot(first.id));
      store.close();
      store = Store(path);
      audio = boundAudio();
      expect(audio.transformInputs(first.id).single.id, '${c.id}.raw');
      expect(audio.pendingTransformJobs(nowMs: 0), hasLength(2));
    },
  );

  test(
    'transform restart leases fence late publication and completion is idempotent',
    () {
      final c = capture();
      final job = transform(c);
      final old = claimTransform(job);
      final generation = AudioStore.newIdentity();
      audio.recoverLeases(generation);
      final fresh = claimTransform(
        audio.transformJob(job.id)!,
        owner: generation,
      );
      expect(
        () => audio.commitTransformResult(
          old,
          representation: compressedOutput(c),
        ),
        throwsStateError,
      );
      final committed = audio.commitTransformResult(
        fresh,
        representation: compressedOutput(c),
      );
      expect(committed.newlyCommitted, isTrue);
      expect(committed.job.outputRepresentationId, '${c.id}.encoded');
      store.close();
      store = Store(path);
      audio = boundAudio();
      expect(
        audio
            .commitTransformResult(fresh, representation: compressedOutput(c))
            .newlyCommitted,
        isFalse,
      );
      expect(audio.representations(c.id), hasLength(2));
    },
  );

  test('transform output publication and completion roll back together', () {
    final c = capture();
    final lease = claimTransform(transform(c));
    store.db.execute(
      "CREATE TRIGGER fail_transform_commit BEFORE UPDATE OF state ON audio_transform_jobs WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'fixture transform failure'); END",
    );
    expect(
      () => audio.commitTransformResult(
        lease,
        representation: compressedOutput(c),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(audio.representations(c.id), hasLength(1));
    expect(audio.transformJob(lease.job.id)!.state, AudioJobState.running);
    store.db.execute('DROP TRIGGER fail_transform_commit');
    expect(
      audio
          .commitTransformResult(lease, representation: compressedOutput(c))
          .newlyCommitted,
      isTrue,
    );
  });

  test(
    'pending transforms pin raw until completion or explicit abandonment',
    () {
      final c = capture();
      compress(c);
      final j = admit();
      audio.commitAsrResult(claim(j), [result]);
      final job = transform(c);
      expect(audio.beginRawPurge(c.id), isNull);
      final lease = claimTransform(job);
      expect(() => audio.abandonTransformJob(job.id), throwsStateError);
      audio.failTransformJob(
        lease,
        error: 'codec_missing',
        nowMs: 0,
        blocked: true,
      );
      expect(audio.pendingTransformJobs(nowMs: 999999), isEmpty);
      expect(audio.beginRawPurge(c.id), isNull);
      audio.retryTransformJob(job.id);
      audio.abandonTransformJob(job.id);
      expect(audio.beginRawPurge(c.id), isNotNull);
    },
  );

  test('transform workers fence erasure until actual input read ends', () {
    final c = capture();
    final lease = claimTransform(transform(c));
    expect(
      () => audio.tombstoneSession(session.id),
      throwsA(isA<SqliteException>()),
    );
    audio.markChunkUnavailable(c.id);
    expect(audio.transformJob(lease.job.id)!.state, AudioJobState.blocked);
    expect(
      () => audio.tombstoneSession(session.id),
      throwsA(isA<SqliteException>()),
    );
    expect(
      () => audio.commitTransformResult(
        lease,
        representation: compressedOutput(c),
      ),
      throwsStateError,
    );
    audio.releaseTransformLeaseReferences(lease);
    audio.tombstoneSession(session.id);
    expect(audio.session(session.id), isNull);
  });

  test(
    'metadata restore requires stopped transforms and retains their blocked history',
    () {
      final c = capture();
      final lease = claimTransform(transform(c));
      expect(
        () => audio.rotateStorageGeneration(metadataOnly: true),
        throwsStateError,
      );
      audio.recoverLeases(AudioStore.newIdentity());
      audio.rotateStorageGeneration(metadataOnly: true);
      expect(audio.transformJob(lease.job.id)!.state, AudioJobState.blocked);
      expect(
        audio.transformInputs(lease.job.id).single.state,
        AudioRepresentationState.missing,
      );
      expect(audio.pendingTransformJobs(nowMs: 999999), isEmpty);
    },
  );

  test('export output metadata requires validation and commits once', () {
    final c = capture();
    final lease = claimTransform(transform(c, kind: AudioTransformKind.export));
    expect(
      () => audio.commitTransformResult(
        lease,
        outputMetadata: {'validated': false},
      ),
      throwsArgumentError,
    );
    final result = audio.commitTransformResult(
      lease,
      outputMetadata: {
        'validated': true,
        'byte_length': 123,
        'output_identity': 'authorized-export-1',
        'sha256': digest,
      },
    );
    expect(result.newlyCommitted, isTrue);
    expect(result.job.outputMetadata, contains('authorized-export-1'));
    expect(audio.commitTransformResult(lease).newlyCommitted, isFalse);
    expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
  });

  test(
    'long recording export snapshots page canonical inputs across SQL pages',
    () {
      for (var i = 0; i < 257; i++) {
        capture(
          canonical: true,
          sequence: i,
          sampleStart: i * 48000,
          captureStartUs: i * 1000000,
        );
      }
      expect(
        () => audio.createExportJob(
          sessionId: session.id,
          codec: 'mp3',
          container: 'mp3',
          settingsRevision: 'mp3-v1',
          settings: {},
        ),
        throwsStateError,
      );
      audio.closeSpan(span.id, captureEndUs: 257000000, reason: 'stop');
      audio.setCaptureState(session.id, AudioCaptureState.stopped);
      final job = audio.createExportJob(
        sessionId: session.id,
        codec: 'mp3',
        container: 'mp3',
        settingsRevision: 'mp3-v1',
        settings: {'bitrate': 64000},
      );
      expect(jsonDecode(job.settings)['timeline_frames'], 257 * 48000);
      final frozen = store.rows(
        'SELECT playback_start_frame,playback_frame_count,playback_geometry_sha256 FROM audio_transform_inputs WHERE job_id=? ORDER BY position',
        [job.id],
      );
      expect(frozen, hasLength(257));
      for (var i = 0; i < frozen.length; ++i) {
        expect(frozen[i]['playback_start_frame'], i * 48000);
        expect(frozen[i]['playback_frame_count'], 48000);
        expect(frozen[i]['playback_geometry_sha256'], hasLength(64));
      }
      expect(audio.transformInputs(job.id), hasLength(256));
      expect(audio.transformInputs(job.id, afterPosition: 255), hasLength(1));
      expect(
        audio
            .createExportJob(
              sessionId: session.id,
              codec: 'mp3',
              container: 'mp3',
              settingsRevision: 'mp3-v1',
              settings: {'bitrate': 64000},
            )
            .id,
        job.id,
      );
      final lease = claimTransform(job);
      expect(
        store
            .rows('SELECT COUNT(*) AS n FROM audio_media_references')
            .single['n'],
        257,
      );
      expect(
        () => audio.tombstoneSession(session.id),
        throwsA(isA<SqliteException>()),
      );
      audio.commitTransformResult(
        lease,
        outputMetadata: {
          'validated': true,
          'byte_length': 100000,
          'output_identity': 'whole-meeting',
          'sha256': digest,
        },
      );
      expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
    },
  );

  test(
    'missing audio export requires explicit incomplete admission and freezes valid prefix',
    () {
      capture(canonical: true);
      final missing = capture(
        canonical: true,
        sequence: 1,
        sampleStart: 48000,
        captureStartUs: 1000000,
      );
      audio.markChunkUnavailable(missing.id);
      audio.closeSpan(
        span.id,
        captureEndUs: 2000000,
        reason: 'storage_failure',
      );
      audio.setCaptureState(
        session.id,
        AudioCaptureState.interrupted,
        error: 'storage_failure',
      );
      expect(
        () => audio.createExportJob(
          sessionId: session.id,
          codec: 'opus',
          container: 'ogg',
          settingsRevision: 'export-v1',
          settings: {},
        ),
        throwsStateError,
      );
      final job = audio.createExportJob(
        sessionId: session.id,
        codec: 'opus',
        container: 'ogg',
        settingsRevision: 'export-v1',
        settings: {},
        allowIncomplete: true,
      );
      expect(audio.transformInputs(job.id), hasLength(1));
      // The unavailable second chunk remains on the shared timeline as silence.
      expect(jsonDecode(job.settings)['timeline_frames'], 96000);
      final frozen = store.rows(
        'SELECT playback_start_frame,playback_frame_count FROM audio_transform_inputs WHERE job_id=?',
        [job.id],
      ).single;
      expect(frozen['playback_start_frame'], 0);
      expect(frozen['playback_frame_count'], 48000);
      expect(job.settings, contains('"allow_incomplete":true'));
    },
  );

  test(
    'bounded segmentation work rejects a huge committed-media range atomically',
    () {
      for (var i = 0; i < 257; i++) {
        final p = preallocate(sequence: i);
        publish(p, sampleStart: i, sampleCount: 1, captureStartUs: i * 63);
      }
      expect(
        () => audio.admitSegments(
          cursor(),
          throughSample: 257,
          retainFromSample: 257,
          ranges: [],
        ),
        throwsStateError,
      );
      expect(
        audio
            .segmentation(session.id, AudioSource.microphone, span.id)!
            .cursorSample,
        0,
      );
    },
  );

  test(
    'source clocks begin unavailable and keep immutable observed transitions across restart',
    () {
      for (final source in AudioSource.values) {
        final initial = audio.latestSourceClock(span.id, source)!;
        expect(initial.quality, AudioSourceClockQuality.unavailable);
        expect(initial.uncertaintyUs, isNull);
        expect(initial.observedCaptureUs, isNull);
      }
      final observed = audio.recordSourceClock(
        span.id,
        AudioSource.microphone,
        AudioSourceClockQuality.hardwareHostTime,
        observedCaptureUs: 100,
        uncertaintyUs: 50,
      );
      expect(observed.revision, 1);
      expect(
        audio
            .recordSourceClock(
              span.id,
              AudioSource.microphone,
              AudioSourceClockQuality.hardwareHostTime,
              observedCaptureUs: 200,
              uncertaintyUs: 50,
            )
            .revision,
        1,
      );
      audio.recordSourceClock(
        span.id,
        AudioSource.microphone,
        AudioSourceClockQuality.unavailable,
        observedCaptureUs: 300,
      );
      expect(
        () => audio.recordSourceClock(
          span.id,
          AudioSource.microphone,
          AudioSourceClockQuality.pipeDrainEstimate,
          observedCaptureUs: 200,
        ),
        throwsStateError,
      );
      store.close();
      store = Store(path);
      audio = boundAudio();
      final records = audio.sourceClockEvidence(
        span.id,
        AudioSource.microphone,
      );
      expect(records.map((r) => r.revision), [0, 1, 2]);
      expect(records[1].uncertaintyUs, 50);
      expect(records.last.quality, AudioSourceClockQuality.unavailable);
      expect(
        audio.latestSourceClock(span.id, AudioSource.playback)!.quality,
        AudioSourceClockQuality.unavailable,
      );
      expect(
        audio
            .sourceClockEvidence(
              span.id,
              AudioSource.microphone,
              afterRevision: 1,
            )
            .single
            .revision,
        2,
      );
    },
  );

  test(
    'clock unknown uncertainty stays null and export freezes clock history',
    () {
      capture(canonical: true);
      audio.recordSourceClock(
        span.id,
        AudioSource.microphone,
        AudioSourceClockQuality.pipeDrainEstimate,
        observedCaptureUs: 0,
      );
      expect(
        audio.latestSourceClock(span.id, AudioSource.microphone)!.uncertaintyUs,
        isNull,
      );
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      audio.setCaptureState(session.id, AudioCaptureState.stopped);
      final job = audio.createExportJob(
        sessionId: session.id,
        codec: 'opus',
        container: 'ogg',
        settingsRevision: 'export-v1',
        settings: {},
      );
      expect(job.inputIdentity, hasLength(64));
      expect(jsonDecode(job.settings)['timeline_frames'], 48000);
      expect(
        () => audio.recordSourceClock(
          span.id,
          AudioSource.microphone,
          AudioSourceClockQuality.hardwareHostTime,
          observedCaptureUs: 100,
        ),
        throwsStateError,
      );
      expect(
        () => audio.recordSourceClock(
          span.id,
          AudioSource.playback,
          AudioSourceClockQuality.linuxPts,
          observedCaptureUs: 2000000,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'native gap flag is durable and immutable through publication retry',
    () {
      final p = preallocate();
      final chunk = audio.publishPreallocatedChunk(
        p.id,
        publicationToken: p.publicationToken,
        sampleStart: 0,
        sampleCount: 16000,
        sampleRate: 16000,
        channels: 1,
        captureStartUs: 0,
        captureEndUs: 1000000,
        byteLength: 32196,
        sha256: digest,
        gapBefore: true,
      );
      expect(chunk.gapBefore, isTrue);
      store.close();
      store = Store(path);
      audio = boundAudio();
      expect(audio.chunk(chunk.id)!.gapBefore, isTrue);
      expect(() => publish(p), throwsStateError);
    },
  );

  test(
    'pending publication recovery pages past unused preallocation identities',
    () {
      for (var i = 0; i < 70; i++) {
        preallocate(sequence: i);
      }
      final first = audio.pendingPublications();
      expect(first, hasLength(64));
      final rest = audio.pendingPublications(afterId: first.last.id);
      expect(rest, hasLength(6));
      expect({
        ...first.map((p) => p.id),
        ...rest.map((p) => p.id),
      }, hasLength(70));
    },
  );

  test(
    'shutdown/model interruptions preserve failure budget and release actual worker readers',
    () {
      capture();
      final j = admit();
      for (var i = 0; i < 7; i++) {
        final lease = claim(audio.job(j.id)!);
        expect(lease.job.attempts, 1);
        audio.interruptJob(lease, error: 'model_barrier');
        expect(audio.job(j.id)!.attempts, 0);
        expect(audio.job(j.id)!.state, AudioJobState.retry);
        expect(store.rows('SELECT * FROM audio_media_references'), isEmpty);
        audio.interruptJob(lease, error: 'stale_cancel');
      }
      final lease = claim(audio.job(j.id)!);
      audio.recoverLeases(AudioStore.newIdentity());
      expect(audio.job(j.id)!.attempts, 0);
      audio.interruptJob(lease, error: 'old_process');
      expect(audio.job(j.id)!.error, 'worker_interrupted');
    },
  );

  test(
    'fair selection serves every source/session before returning to old microphone backlog',
    () {
      capture();
      capture(sequence: 1, sampleStart: 16000, captureStartUs: 1000000);
      final first = cursor();
      audio.admitSegments(
        first,
        throughSample: 32000,
        retainFromSample: 32000,
        ranges: [
          AudioAsrRange(
            id: AudioStore.newIdentity(),
            sampleStart: 0,
            sampleEnd: 16000,
            ownedStart: 0,
            ownedEnd: 16000,
          ),
          AudioAsrRange(
            id: AudioStore.newIdentity(),
            sampleStart: 16000,
            sampleEnd: 32000,
            ownedStart: 16000,
            ownedEnd: 32000,
          ),
        ],
      );
      capture(source: AudioSource.playback);
      admit(source: AudioSource.playback);
      session = audio.createSession(
        meetingId: store.meeting('New meeting'),
        startedWallMs: 456,
      );
      span = audio.startSpan(
        session.id,
        captureStartUs: 0,
        playbackStartUs: 0,
        wallAnchorMs: 456,
      );
      capture();
      admit();
      String? afterSession;
      var afterSource = AudioSource.playback;
      final groups = <String>{};
      for (var i = 0; i < 3; i++) {
        final selected = audio.nextPendingJob(
          nowMs: 0,
          afterSessionId: afterSession,
          afterSource: afterSource,
        )!;
        groups.add('${selected.sessionId}:${selected.source.name}');
        afterSession = selected.sessionId;
        afterSource = selected.source;
        audio.commitAsrResult(claim(selected), []);
      }
      expect(groups, hasLength(3));
      final remaining = audio.nextPendingJob(
        nowMs: 0,
        afterSessionId: afterSession,
        afterSource: afterSource,
      )!;
      expect(remaining.source, AudioSource.microphone);
      expect(remaining.ownedStart, 16000);
    },
  );

  test('audio reader refuses a future schema in one snapshot', () {
    final older = AudioStore(
      store.db,
      workspaceEpoch: () => store.workspaceEpoch,
      supportedVersion: 23,
    );
    expect(
      () => older.sessionsForMeeting(session.meetingId),
      throwsA(isA<IncompatibleReadSchema>()),
    );
  });

  test(
    'migration24 rollback leaves schema23 and retries complete addition',
    () {
      final oldPath = '${root.path}/old.db';
      final db = sqlite3.open(oldPath);
      for (var version = 1; version <= 23; version++) {
        ApplicationMigrations(db).run(version);
      }
      db.execute('PRAGMA user_version=23');
      db.execute('CREATE TABLE audio_chunks(fixture INTEGER)');
      db.dispose();
      expect(() => Store(oldPath), throwsA(isA<SqliteException>()));
      final failed = sqlite3.open(oldPath);
      expect(failed.select('PRAGMA user_version').single.values.single, 23);
      expect(
        failed.select(
          "SELECT 1 FROM sqlite_master WHERE name='recording_sessions'",
        ),
        isEmpty,
      );
      failed.execute('DROP TABLE audio_chunks');
      failed.dispose();
      final upgraded = Store(oldPath);
      addTearDown(upgraded.close);
      expect(
        upgraded.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      expect(upgraded.audioStore.storageGeneration, isNotEmpty);
      expect(upgraded.audioStore.mediaAdmitted, isFalse);
    },
  );
}
