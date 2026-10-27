import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late AudioStore audio;
  setUp(() {
    final root = createTestTempDirectorySync('transform-store-');
    store = Store('${root.path}/app.db');
    audio = AudioStore(
      store.db,
      workspaceEpoch: () => store.workspaceEpoch,
      mediaGeneration: () => store.audioStore.storageGeneration,
    );
    addTearDown(store.close);
  });
  AudioRepresentation raw(String sessionId) {
    final session = audio.createSession(
      meetingId: store.meeting('Audio'),
      startedWallMs: 0,
      id: sessionId,
    );
    final span = audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final p = audio.preallocateChunk(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      sequence: 0,
      id: AudioStore.newIdentity(),
      relativePath: '$sessionId.wav',
    );
    audio.publishPreallocatedChunk(
      p.id,
      publicationToken: p.publicationToken,
      sampleStart: 0,
      sampleCount: 48000,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 1000000,
      byteLength: 96196,
      sha256: 'a' * 64,
    );
    return audio.representations(p.id).single;
  }

  AudioTransformJob admit(
    AudioRepresentation input,
    String revision, {
    AudioTransformKind kind = AudioTransformKind.compression,
  }) => audio.createTransformJob(
    sessionId: audio.chunk(input.chunkId)!.sessionId,
    kind: kind,
    inputs: [input.id],
    codec: 'opus',
    container: 'ogg',
    settingsRevision: revision,
    settings: const {'bitrate': 32000},
  );

  test('session/kind fairness wraps beyond a long old compression queue', () {
    final older = raw('00000000-0000-4000-8000-000000000001');
    final newer = raw('00000000-0000-4000-8000-000000000002');
    for (var i = 0; i < 140; i++) {
      admit(older, 'opus-$i');
    }
    admit(older, 'export', kind: AudioTransformKind.export);
    admit(newer, 'new');
    var after = '';
    var kind = AudioTransformKind.export;
    final groups = <String>{};
    for (var i = 0; i < 3; i++) {
      final next = audio.nextPendingTransformJob(
        nowMs: 0,
        afterSessionId: after,
        afterKind: kind,
      )!;
      groups.add('${next.sessionId}:${next.kind.name}');
      after = next.sessionId;
      kind = next.kind;
    }
    expect(groups.length, 3);
    expect(
      audio
          .nextPendingTransformJob(
            nowMs: 0,
            afterSessionId: after,
            afterKind: kind,
          )!
          .sessionId,
      audio.chunk(older.chunkId)!.sessionId,
    );
    expect(store.audioStore.nextPendingTransformJob(nowMs: 0), isNull);
  });

  test(
    'actual-exit interruption refunds budget, releases references, fences stale lease',
    () {
      final input = raw(AudioStore.newIdentity());
      final job = admit(input, 'opus');
      final owner = AudioStore.newIdentity();
      final first = audio.claimTransformJob(
        job.id,
        ownerGeneration: owner,
        nowMs: 0,
      )!;
      expect(
        store.db.select('SELECT * FROM audio_media_references'),
        hasLength(1),
      );
      audio.interruptTransformJob(first, error: 'service_shutdown');
      expect(audio.transformJob(job.id)!.attempts, 0);
      expect(audio.transformJob(job.id)!.state, AudioJobState.retry);
      expect(store.db.select('SELECT * FROM audio_media_references'), isEmpty);
      final second = audio.claimTransformJob(
        job.id,
        ownerGeneration: owner,
        nowMs: 0,
      )!;
      audio.interruptTransformJob(first, error: 'late');
      expect(audio.transformJob(job.id)!.state, AudioJobState.running);
      expect(
        store.db.select('SELECT * FROM audio_media_references'),
        hasLength(1),
      );
      audio.interruptTransformJob(second, error: 'model_barrier');
      expect(audio.transformJob(job.id)!.attempts, 0);
    },
  );
}
