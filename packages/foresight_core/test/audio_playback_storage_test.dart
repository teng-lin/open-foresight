import 'dart:ffi';
import 'package:foresight_core/src/application_services/audio_playback_source.dart';
import 'package:foresight_core/src/application_services/native_audio_media.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_queries.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Store store;
  late RecordingMedia media;
  late AudioSession session;
  setUp(() {
    final root = createTestTempDirectorySync('playback-snapshot-');
    store = Store('${root.path}/application.db');
    media = RecordingMedia.open(
      store,
      ownerGeneration: AudioStore.newIdentity(),
    );
    session = media.audio.createSession(
      meetingId: store.meeting('Reader'),
      startedWallMs: 0,
    );
    final span = media.audio.startSpan(
      session.id,
      captureStartUs: 0,
      playbackStartUs: 0,
      wallAnchorMs: 0,
    );
    final publication = media
        .preallocate(
          span: span,
          source: AudioSource.microphone,
          firstSequence: 0,
          count: 1,
        )
        .single;
    media.audio.publishPreallocatedChunk(
      publication.id,
      publicationToken: publication.publicationToken,
      sampleStart: 0,
      sampleCount: 4800,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 100000,
      byteLength: 9796,
      sha256: 'a' * 64,
    );
    media.audio.closeSpan(span.id, captureEndUs: 100000, reason: 'stop');
    media.audio.setCaptureState(
      session.id,
      AudioCaptureState.stopped,
      stoppedWallMs: 0,
    );
    addTearDown(() {
      media.close();
      store.close();
    });
  });
  AudioTransformLease claim(AudioTransformJob job) =>
      media.audio.claimTransformJob(
        job.id,
        ownerGeneration: media.ownerGeneration,
        nowMs: 0,
      )!;
  int references() =>
      store.db
              .select('SELECT COUNT(*) AS n FROM audio_media_references')
              .single['n']
          as int;
  test(
    'ephemeral playback is excluded from background work and export status',
    () {
      final playback = media.audio.createPlaybackJob(session.id);
      expect(playback.kind, AudioTransformKind.playback);
      expect(media.audio.pendingTransformJobs(nowMs: 0), isEmpty);
      expect(media.audio.nextPendingTransformJob(nowMs: 0), isNull);
      expect(
        AudioQueries(
          media.audio,
        ).sessions(session.meetingId).single.export.pending,
        0,
      );
      final export = media.audio.createExportJob(
        sessionId: session.id,
        codec: 'opus',
        container: 'ogg',
        settingsRevision: 'export-v1',
        settings: {},
      );
      expect(media.audio.nextPendingTransformJob(nowMs: 0)!.id, export.id);
      expect(
        AudioQueries(
          media.audio,
        ).sessions(session.meetingId).single.export.pending,
        1,
      );
      final lease = claim(playback);
      expect(references(), 1);
      media.audio.releasePlaybackLease(lease);
      expect(references(), 0);
      expect(media.audio.transformJob(playback.id), isNull);
      expect(media.audio.transformJob(export.id), isNotNull);
    },
  );
  test('stale reader release cannot discard a newer lease', () {
    final job = media.audio.createPlaybackJob(session.id), old = claim(job);
    media.audio.interruptTransformJob(old, error: 'controlled interruption');
    final newer = claim(media.audio.transformJob(job.id)!);
    media.audio.releasePlaybackLease(old);
    expect(
      media.audio.transformJob(job.id)!.leaseGeneration,
      newer.leaseGeneration,
    );
    expect(references(), 1);
    media.audio.releasePlaybackLease(newer);
    expect(references(), 0);
  });
  test(
    'exclusive startup discards old playback without automatically resuming it',
    () async {
      final playback = media.audio.createPlaybackJob(session.id);
      claim(playback);
      expect(references(), 1);
      final export = media.audio.createExportJob(
        sessionId: session.id,
        codec: 'opus',
        container: 'ogg',
        settingsRevision: 'export-v1',
        settings: {},
      );
      media.close();
      media = await RecordingMedia.acquire(
        store,
        ownerGeneration: AudioStore.newIdentity(),
      );
      expect(media.audio.transformJob(playback.id), isNull);
      expect(references(), 0);
      expect(media.audio.transformJob(export.id)!.state, AudioJobState.pending);
    },
  );
  test(
    'opening and closing a playback source holds and releases actual DB readers without devices',
    () async {
      final source = NativeAudioPlaybackSource.open(
        media: media,
        bindings: NativeLibrary(DynamicLibrary.process()),
        executable: AudioMediaExecutable(
          path: '/synthetic/not-launched',
          sha256: 'b' * 64,
          buildId: 'c' * 64,
          macosCdHash: '',
        ),
        sessionId: session.id,
      );
      expect(source.totalFrames, 4800);
      expect(references(), 1);
      source.cancel();
      await expectLater(source.decode(0, 1), throwsStateError);
      await source.close();
      expect(references(), 0);
      expect(
        store.db.select(
          "SELECT 1 FROM audio_transform_jobs WHERE kind='playback'",
        ),
        isEmpty,
      );
    },
  );
  test('playback release refuses an export lease', () {
    final job = media.audio.createExportJob(
          sessionId: session.id,
          codec: 'opus',
          container: 'ogg',
          settingsRevision: 'export-v1',
          settings: {},
        ),
        lease = claim(job);
    expect(() => media.audio.releasePlaybackLease(lease), throwsArgumentError);
    expect(references(), 1);
    media.audio.interruptTransformJob(lease, error: 'test cleanup');
  });
}
