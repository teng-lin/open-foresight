import 'dart:convert';

import 'package:foresight_core/audio_presentation.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_queries.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late AudioStore audio;
  late AudioQueries queries;
  late AudioSession session;
  late AudioSpan span;
  late int meeting;
  setUp(() {
    final root = createTestTempDirectorySync('audio-query-');
    store = Store('${root.path}/app.db');
    audio = AudioStore(
      store.db,
      workspaceEpoch: () => store.workspaceEpoch,
      mediaGeneration: () => store.audioStore.storageGeneration,
    );
    queries = AudioQueries(audio);
    meeting = store.meeting('Silent meeting');
    session = audio.createSession(meetingId: meeting, startedWallMs: 123);
    span = audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 123,
    );
    addTearDown(store.close);
  });
  AudioChunk publish(
    int sequence, {
    AudioSource source = AudioSource.microphone,
    bool gap = false,
  }) {
    final id = AudioStore.newIdentity();
    final p = audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: source,
      sequence: sequence,
      id: id,
      relativePath:
          'recordings/${session.storageGeneration}/${session.id}/$id.wav',
    );
    return audio.publishPreallocatedChunk(
      p.id,
      publicationToken: p.publicationToken,
      sampleStart: sequence * 48000,
      sampleCount: 48000,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: sequence * 1000000,
      captureEndUs: (sequence + 1) * 1000000,
      byteLength: 96196,
      sha256: 'a' * 64,
      gapBefore: gap,
    );
  }

  AudioSegmentationCursor cursor() => audio.initializeSegmentation(
    sessionId: session.id,
    spanId: span.id,
    source: AudioSource.microphone,
    settingsRevision: 'vad',
    modelRevision: 'model',
    initialSample: 0,
  );

  test(
    'retry capabilities require service authority and actual failed frozen jobs',
    () {
      publish(0);
      final job = AudioStore.newIdentity();
      audio.admitSegments(
        cursor(),
        throughSample: 48000,
        retainFromSample: 48000,
        ranges: [
          AudioAsrRange(
            id: job,
            sampleStart: 0,
            sampleEnd: 48000,
            ownedStart: 0,
            ownedEnd: 48000,
          ),
        ],
      );
      store.db.execute(
        "UPDATE audio_asr_jobs SET state='blocked',error='missing_model' WHERE id=?",
        [job],
      );
      store.db.execute(
        "INSERT INTO audio_transform_jobs(id,session_id,kind,input_identity,codec,container,settings_revision,settings,state,error) VALUES(?,?,'compression','unique','opus','ogg','v1','{}','failed','Save failed')",
        [AudioStore.newIdentity(), session.id],
      );
      final ready = queries
          .sessions(
            meeting,
            allowRetryTranscription: true,
            allowRetryCompression: true,
          )
          .single;
      expect(ready.sources.first.failedJobs, 1);
      expect(ready.canRetryTranscription, true);
      expect(ready.canRetryCompression, true);
      final wire = AudioSessionPresentation.fromMap(ready.toMap());
      expect(wire.canRetryTranscription, true);
      expect(wire.canRetryCompression, true);
      final old = AudioSessionPresentation.fromMap(
        {...ready.toMap()}
          ..remove('canRetryTranscription')
          ..remove('canRetryCompression'),
      );
      expect(old.canRetryTranscription, false);
      expect(old.canRetryCompression, false);
      expect(queries.sessions(meeting).single.canRetryTranscription, false);
      final metadata = AudioQueries(store.audioStore)
          .sessions(
            meeting,
            allowRetryTranscription: true,
            allowRetryCompression: true,
          )
          .single;
      expect(metadata.canRetryTranscription, false);
      expect(metadata.canRetryCompression, false);
      audio.retryJob(job);
      final compression =
          store.db.select(
                "SELECT id FROM audio_transform_jobs WHERE session_id=?",
                [session.id],
              ).single['id']
              as String;
      audio.retryTransformJob(compression);
      final retried = queries
          .sessions(
            meeting,
            allowRetryTranscription: true,
            allowRetryCompression: true,
          )
          .single;
      expect(retried.sources.first.failedJobs, 0);
      expect(retried.canRetryTranscription, false);
      expect(retried.canRetryCompression, false);
      expect(audio.job(job)!.modelRevision, 'model');
    },
  );
  test(
    'retention persists per session and controls need independent service authority',
    () {
      publish(0);
      audio.setRetainLossless(session.id, true);
      expect(audio.session(session.id)!.retainLossless, true);
      final other = audio.createSession(meetingId: meeting, startedWallMs: 200);
      expect(audio.retainLossless(other.id), false);
      expect(
        () => store.audioStore.setRetainLossless(session.id, false),
        throwsA(isA<RpcError>()),
      );
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      audio.setCaptureState(
        session.id,
        AudioCaptureState.stopped,
        stoppedWallMs: 1000,
      );
      final ready = queries
          .sessions(
            meeting,
            allowDeleteRecordings: true,
            allowRetentionChanges: true,
          )
          .singleWhere((s) => s.id == session.id);
      expect(ready.retainLossless, true);
      expect(ready.hasLosslessOriginals, true);
      expect(ready.canDeleteRecording, true);
      expect(ready.canChangeRetention, true);
      final wire = AudioSessionPresentation.fromMap(ready.toMap());
      expect(wire.retainLossless, true);
      expect(wire.canDeleteRecording, true);
      final unavailable = AudioQueries(store.audioStore)
          .sessions(
            meeting,
            allowDeleteRecordings: true,
            allowRetentionChanges: true,
          )
          .singleWhere((s) => s.id == session.id);
      expect(unavailable.canDeleteRecording, false);
      expect(unavailable.canChangeRetention, false);
      expect(queries.sessions(meeting + 100).isEmpty, true);
      final active = queries
          .sessions(
            meeting,
            allowDeleteRecordings: true,
            activity: AudioCaptureActivity(
              activeSessionId: session.id,
              state: MeetingAudioPhysicalState.stopping,
            ),
          )
          .singleWhere((s) => s.id == session.id);
      expect(active.canDeleteRecording, false);
    },
  );
  test(
    'quarantined history can be deleted without enabling old media playback',
    () {
      publish(0);
      audio.setRetainLossless(session.id, true);
      audio.rotateStorageGeneration(metadataOnly: true);
      final old = queries
          .sessions(
            meeting,
            allowDeleteRecordings: true,
            allowRetentionChanges: true,
          )
          .single;
      expect(old.canDeleteRecording, true);
      expect(old.canChangeRetention, false);
      expect(old.canPlay, false);
      expect(old.retainLossless, true);
      expect(old.hasLosslessOriginals, false);
    },
  );
  test(
    'audio-only deletion removes seek links and preserves committed transcript text',
    () {
      publish(0);
      final progress = cursor(), jobId = AudioStore.newIdentity();
      audio.admitSegments(
        progress,
        throughSample: 48000,
        retainFromSample: 48000,
        ranges: [
          AudioAsrRange(
            id: jobId,
            sampleStart: 0,
            sampleEnd: 48000,
            ownedStart: 0,
            ownedEnd: 48000,
          ),
        ],
      );
      final lease = audio.claimJob(
        jobId,
        ownerGeneration: AudioStore.newIdentity(),
        nowMs: 0,
      )!;
      final saved = audio.commitAsrResult(lease, [
        const AudioTranscriptResult(
          text: 'Preserved words',
          sampleStart: 0,
          sampleEnd: 48000,
          startMs: 0,
          endMs: 1000,
        ),
      ]);
      final transcript = saved.transcriptIds.single;
      expect(audio.transcriptAudioLink(transcript), isNotNull);
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      audio.setCaptureState(
        session.id,
        AudioCaptureState.stopped,
        stoppedWallMs: 1000,
      );
      audio.tombstoneSession(session.id);
      expect(audio.transcriptAudioLink(transcript), null);
      expect(
        store.db.select('SELECT text FROM transcript WHERE id=?', [
          transcript,
        ]).single['text'],
        'Preserved words',
      );
      expect(audio.pendingErasures().single.sessionId, session.id);
    },
  );
  test(
    'export eligibility requires sealed terminal authority, not idle capture',
    () {
      publish(0);
      expect(queries.sessions(meeting).single.canExport, false);
      audio.closeSpan(span.id, captureEndUs: 1000000, reason: 'stop');
      audio.setCaptureState(
        session.id,
        AudioCaptureState.stopped,
        stoppedWallMs: 5000,
      );
      expect(queries.sessions(meeting).single.canExport, false);
      expect(queries.sessions(meeting).single.exportFormats, isEmpty);
      final ready = queries
          .sessions(
            meeting,
            exportFormats: const [MeetingAudioExportFormat.opus],
            playbackSupported: true,
          )
          .single;
      expect(ready.canExport, true);
      expect(ready.canPlay, true);
      expect(queries.sessions(meeting).single.canPlay, false);
      expect(
        AudioSessionPresentation.fromMap(
          {...ready.toMap()}..remove('playbackSupported'),
        ).playbackSupported,
        false,
      );
      expect(ready.exportFormats, [MeetingAudioExportFormat.opus]);
      expect(AudioSessionPresentation.fromMap(ready.toMap()).exportFormats, [
        MeetingAudioExportFormat.opus,
      ]);
      expect(
        AudioSessionPresentation.fromMap(
          {...ready.toMap()}..remove('exportFormats'),
        ).exportFormats,
        isEmpty,
      );
      expect(
        AudioQueries(store.audioStore).sessions(meeting).single.canExport,
        false,
      );
      expect(
        queries.meeting(meeting + 1000).availability,
        MeetingAudioAvailability.none,
      );
      expect(
        queries
            .meeting(
              meeting + 1000,
              activity: AudioCaptureActivity(
                activeSessionId: session.id,
                state: MeetingAudioPhysicalState.recording,
              ),
            )
            .isRecording,
        false,
      );
    },
  );

  test(
    'preallocation is pending audio rather than a fabricated playable clip',
    () {
      audio.preallocateChunk(
        sessionId: session.id,
        spanId: span.id,
        source: AudioSource.microphone,
        sequence: 0,
        id: AudioStore.newIdentity(),
        relativePath: 'reserved.wav',
      );
      expect(
        queries.meeting(meeting).availability,
        MeetingAudioAvailability.pending,
      );
      expect(queries.meeting(meeting).durationUs, 0);
      expect(queries.clips(session.id), isEmpty);
    },
  );

  test('wire values round trip without persistence paths or authorities', () {
    publish(0);
    final original = queries.meeting(meeting);
    final wire =
        jsonDecode(jsonEncode(original.toMap())) as Map<String, dynamic>;
    expect(AudioMeetingPresentation.fromMap(wire).toMap(), original.toMap());
    final sessionValue = queries.sessions(meeting).single;
    expect(
      AudioSessionPresentation.fromMap(sessionValue.toMap()).toMap(),
      sessionValue.toMap(),
    );
    final clip = queries.clips(session.id).single;
    expect(AudioClipPresentation.fromMap(clip.toMap()).toMap(), clip.toMap());
    const playback = AudioPlaybackPresentation(
      state: MeetingAudioPlaybackState.paused,
      positionUs: 123,
    );
    expect(AudioPlaybackPresentation.fromMap(playback.toMap()).positionUs, 123);
    expect(jsonEncode(wire), isNot(contains('relative_path')));
  });

  test(
    'transcript seeking requires a saved link and current admitted media',
    () {
      publish(0);
      final id = AudioStore.newIdentity();
      audio.admitSegments(
        cursor(),
        throughSample: 48000,
        retainFromSample: 48000,
        ranges: [
          AudioAsrRange(
            id: id,
            sampleStart: 0,
            sampleEnd: 48000,
            ownedStart: 0,
            ownedEnd: 48000,
          ),
        ],
      );
      final lease = audio.claimJob(
        id,
        ownerGeneration: AudioStore.newIdentity(),
        nowMs: 0,
      )!;
      final transcript = audio
          .commitAsrResult(lease, [
            const AudioTranscriptResult(
              text: 'Hello',
              sampleStart: 12000,
              sampleEnd: 48000,
              startMs: 250,
              endMs: 1000,
            ),
          ])
          .transcriptIds
          .single;
      final target = queries.transcriptSeekTarget(transcript)!;
      expect(target.playbackUs, 250000);
      expect(
        AudioTranscriptSeekTarget.fromMap(target.toMap()).sessionId,
        session.id,
      );
      expect(
        AudioQueries(store.audioStore).transcriptSeekTarget(transcript),
        isNull,
      );
      store.db.execute(
        'DELETE FROM transcript_audio_links WHERE transcript_id=?',
        [transcript],
      );
      expect(queries.transcriptSeekTarget(transcript), isNull);
    },
  );

  test(
    'valid silent audio is available with no transcripts; stale rows never imply live',
    () {
      publish(0);
      final result = queries.meeting(meeting);
      expect(result.availability, MeetingAudioAvailability.available);
      expect(result.durationUs, 1000000);
      expect(result.retainedBytes, 96196);
      expect(result.stagingBytes, 0);
      expect(result.isRecording, false);
      expect(store.db.select('SELECT * FROM transcript'), isEmpty);
      final active = queries.meeting(
        meeting,
        activity: AudioCaptureActivity(
          activeSessionId: session.id,
          state: MeetingAudioPhysicalState.recording,
          acquiredThroughUs: 1500000,
        ),
      );
      expect(active.isRecording, true);
      expect(active.durationUs, 1500000);
      expect(queries.sessions(meeting).single.isRecording, false);
      expect(
        queries
            .sessions(
              meeting,
              activity: AudioCaptureActivity(
                activeSessionId: session.id,
                state: MeetingAudioPhysicalState.paused,
              ),
            )
            .single
            .isRecording,
        false,
      );
    },
  );

  test(
    'media binding and workspace identity fail closed but preserve history',
    () {
      publish(0);
      final unbound = AudioQueries(store.audioStore);
      expect(
        unbound.meeting(meeting).availability,
        MeetingAudioAvailability.missing,
      );
      expect(unbound.clips(session.id).single.available, false);
      expect(
        unbound
            .meeting(
              meeting,
              activity: AudioCaptureActivity(
                activeSessionId: session.id,
                state: MeetingAudioPhysicalState.recording,
              ),
            )
            .isRecording,
        false,
      );
      store.db.execute(
        "UPDATE recording_sessions SET workspace_epoch='restored'",
      );
      expect(
        queries.meeting(meeting).availability,
        MeetingAudioAvailability.missing,
      );
      expect(queries.clips(session.id).single.available, false);
    },
  );

  test(
    'owned recognition ranges, context and acquired tail count once per source',
    () {
      publish(0);
      publish(1);
      publish(0, source: AudioSource.playback);
      audio.admitSegments(
        cursor(),
        throughSample: 72000,
        retainFromSample: 48000,
        ranges: [
          AudioAsrRange(
            id: AudioStore.newIdentity(),
            sampleStart: 0,
            sampleEnd: 48000,
            ownedStart: 0,
            ownedEnd: 48000,
          ),
        ],
        context: utf8.encode(jsonEncode({'owned_start': 48000})),
      );
      // Add an overlapping retry range from a second model to prove union counts.
      store.db.execute(
        'INSERT INTO audio_asr_jobs SELECT ?,session_id,span_id,source,0,48000,12000,48000,\'second\',settings_revision,\'retry\',0,0,NULL,0,\'\' FROM audio_asr_jobs LIMIT 1',
        [AudioStore.newIdentity()],
      );
      final result = queries.meeting(meeting);
      expect(result.sources.first.pendingDurationUs, 2000000);
      expect(result.sources.first.pendingJobs, 2);
      expect(result.sources.last.pendingDurationUs, 1000000);
      expect(result.isRecording, false);
      store.db.execute("UPDATE audio_asr_jobs SET state='completed'");
      expect(queries.meeting(meeting).sources.first.pendingDurationUs, 1000000);
    },
  );

  test(
    'silence cursor and completed empty recognition do not leave false lag',
    () {
      publish(0);
      audio.admitSegments(
        cursor(),
        throughSample: 48000,
        retainFromSample: 43200,
        ranges: [],
      );
      expect(queries.meeting(meeting).sources.first.pendingDurationUs, 0);
      expect(
        queries.meeting(meeting).availability,
        MeetingAudioAvailability.available,
      );
    },
  );

  test('partial gaps, capture and compression errors remain independent', () {
    final first = publish(0);
    publish(1, gap: true);
    store.db.execute(
      "UPDATE recording_sessions SET terminal_error='Capture stopped'",
    );
    store.db.execute("UPDATE audio_chunks SET state='missing' WHERE id=?", [
      first.id,
    ]);
    store.db.execute(
      "INSERT INTO audio_transform_jobs(id,session_id,kind,input_identity,codec,container,settings_revision,settings,state,error) VALUES(?,?,'compression','unique','opus','ogg','v1','{}','failed','Save failed')",
      [AudioStore.newIdentity(), session.id],
    );
    final result = queries.sessions(meeting).single;
    expect(result.availability, MeetingAudioAvailability.partial);
    expect(result.hasGaps, true);
    expect(result.captureError, 'Capture stopped');
    expect(result.compression.state, MeetingAudioWorkState.failed);
    expect(result.compression.error, 'Save failed');
    expect(result.export.state, MeetingAudioWorkState.idle);
  });

  test(
    'preferred retention and additional staging bytes do not double count',
    () {
      final c = publish(0);
      store.db.execute(
        "INSERT INTO audio_representations(id,chunk_id,codec,container,settings_revision,relative_path,byte_length,sha256,decoded_samples,state,validated) VALUES(?,?,'opus','ogg','v1','clip.opus',4000,?,48000,'published',1)",
        [AudioStore.newIdentity(), c.id, 'b' * 64],
      );
      final result = queries.meeting(meeting);
      expect(result.retainedBytes, 4000);
      expect(result.stagingBytes, 96196);
    },
  );

  test(
    'chunks and session pages traverse beyond 256 without truncating totals',
    () {
      for (var i = 0; i < 270; i++) {
        publish(i);
      }
      final ids = <String>{};
      var source = '';
      var sequence = -1;
      while (true) {
        final page = queries.clips(
          session.id,
          afterSource: source,
          afterSequence: sequence,
          limit: 31,
        );
        if (page.isEmpty) break;
        ids.addAll(page.map((c) => c.id));
        source = page.last.source.name;
        sequence = page.last.sequence;
      }
      expect(ids.length, 270);
      expect(queries.meeting(meeting).durationUs, 270000000);
      expect(queries.meeting(meeting).retainedBytes, 270 * 96196);
      for (var i = 0; i < 35; i++) {
        audio.createSession(meetingId: meeting, startedWallMs: i);
      }
      final sessions = <String>{};
      var after = '';
      while (true) {
        final page = queries.sessions(meeting, afterId: after, limit: 7);
        if (page.isEmpty) break;
        sessions.addAll(page.map((s) => s.id));
        after = page.last.id;
      }
      expect(sessions.length, 36);
      expect(() => queries.sessions(meeting, limit: 129), throwsRangeError);
      expect(() => queries.clips(session.id, limit: 0), throwsRangeError);
    },
  );

  test('pause removes intentional time but preserves source outages', () {
    publish(0);
    audio.closeSpan(span.id, captureEndUs: 2000000, reason: 'pause');
    span = audio.startSpan(
      session.id,
      captureStartUs: 10000000,
      playbackStartUs: 2000000,
      wallAnchorMs: 9999,
    );
    final p = audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      sequence: 1,
      id: AudioStore.newIdentity(),
      relativePath: 'second.wav',
    );
    audio.publishPreallocatedChunk(
      p.id,
      publicationToken: p.publicationToken,
      sampleStart: 48000,
      sampleCount: 48000,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 10000000,
      captureEndUs: 11000000,
      byteLength: 96196,
      sha256: 'a' * 64,
    );
    expect(queries.meeting(meeting).durationUs, 3000000);
    expect(queries.clips(session.id).last.playbackStartUs, 2000000);
  });
}
