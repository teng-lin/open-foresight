import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/application_services/audio_transform_scheduler.dart';
import 'package:foresight_core/src/application_services/native_audio_media.dart';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_core/src/persistence/audio_store.dart';
import 'package:foresight_core/src/persistence/audio_transform_media.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'sql_support_test_bootstrap.dart';

final _write = DynamicLibrary.process()
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');

class SyntheticExecution implements AudioTransformExecution {
  SyntheticExecution(this.value);
  final AudioEncodedResult value;
  @override
  Future<AudioEncodedResult> get result async => value;
  @override
  Future<void> get closed async {}
  @override
  void cancel() {}
}

void main() {
  bootstrapSqlSupportFixture();
  late Store database;
  late RecordingMedia media;
  late AudioCompressionMedia compression;
  late AudioSession session;
  late AudioSpan span;
  late AudioChunk chunk;
  late AudioTransformScheduler scheduler;
  var starts = 0, now = 0;
  var corruptResult = false;
  final payload = utf8.encode('Synthetic encoded output; not a codec fixture');
  final digest = sha256.convert(payload).toString();
  Future<AudioTransformExecution> synthetic({
    required AudioTransformLease lease,
    required AudioRepresentation input,
    required int inputDescriptor,
    required int outputDescriptor,
    required int ownerLockDescriptor,
    required bool Function() current,
  }) async {
    starts++;
    final memory = calloc<Uint8>(payload.length);
    try {
      memory.asTypedList(payload.length).setAll(0, payload);
      expect(_write(outputDescriptor, memory, payload.length), payload.length);
    } finally {
      calloc.free(memory);
    }
    return SyntheticExecution(
      AudioEncodedResult(
        sha256: corruptResult ? 'f' * 64 : digest,
        byteLength: payload.length,
        frames: 4800,
        preSkip: 312,
        finalGranule: 5112,
        workerBuildId: 'b' * 64,
        workerSha256: 'c' * 64,
      ),
    );
  }

  AudioTransformScheduler owner() => AudioTransformScheduler(
    store: media.audio,
    ownerGeneration: media.ownerGeneration,
    prepare: compression.prepare,
    nowMs: () => now,
    committed: (_) {},
    changed: () {},
  );
  setUp(() async {
    final root = createTestTempDirectorySync('compression-media-');
    database = Store('${root.path}/application.db');
    media = RecordingMedia.open(
      database,
      ownerGeneration: AudioStore.newIdentity(),
    );
    session = media.audio.createSession(
      meetingId: database.meeting('Audio'),
      startedWallMs: 0,
    );
    span = media.audio.startSpan(
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
    final bytes = Uint8List(196 + 4800 * 2), data = ByteData(196 + 4800 * 2);
    void text(int offset, String value) =>
        bytes.setRange(offset, offset + value.length, ascii.encode(value));
    void u16(int offset, int value) =>
        data.setUint16(offset, value, Endian.little);
    void u32(int offset, int value) =>
        data.setUint32(offset, value, Endian.little);
    void u64(int offset, int value) =>
        data.setUint64(offset, value, Endian.little);
    u32(4, bytes.length - 8);
    u32(16, 16);
    u16(20, 1);
    u16(22, 1);
    u32(24, 48000);
    u32(28, 96000);
    u16(32, 2);
    u16(34, 16);
    u32(40, 144);
    u32(152, 0);
    u64(156, 0);
    u64(164, span.ordinal);
    u64(172, 0);
    u64(180, 0);
    u32(192, 4800 * 2);
    bytes.setAll(0, data.buffer.asUint8List());
    text(0, 'RIFF');
    text(8, 'WAVEfmt ');
    text(36, 'fsid');
    text(44, session.id);
    text(80, session.storageGeneration);
    text(116, publication.id);
    text(188, 'data');
    final directory = BackupDirectory(
      media.sessionDirectory(session.id),
      create: false,
    );
    final file = directory.open('${publication.id}.wav', create: true);
    file.write(bytes);
    file.sync();
    file.close();
    directory.sync();
    directory.close();
    chunk = media.audio.publishPreallocatedChunk(
      publication.id,
      publicationToken: publication.publicationToken,
      sampleStart: 0,
      sampleCount: 4800,
      sampleRate: 48000,
      channels: 1,
      captureStartUs: 0,
      captureEndUs: 100000,
      byteLength: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    starts = now = 0;
    corruptResult = false;
    compression = AudioCompressionMedia(media: media, startWorker: synthetic);
    scheduler = owner();
    addTearDown(() async {
      await scheduler.close();
      await compression.fencePurges();
      media.close();
      database.close();
    });
  });
  AudioTransformJob admitted() {
    expect(compression.admitPending(limit: 1), 1);
    expect(compression.admitPending(limit: 1), 0);
    return media.audio.pendingTransformJobs(nowMs: 0).single;
  }

  void silenceFlushed() {
    final cursor = media.audio.initializeSegmentation(
      sessionId: session.id,
      spanId: span.id,
      source: AudioSource.microphone,
      settingsRevision: 'vad-test',
      modelRevision: 'model-test',
      initialSample: 0,
    );
    media.audio.closeSpan(span.id, captureEndUs: 100000, reason: 'stop');
    media.audio.sealSegmentationPublications(span.id);
    media.audio.admitSegments(
      cursor,
      throughSample: 4800,
      retainFromSample: 4800,
      ranges: [],
      flush: true,
    );
  }

  test(
    'managed compression commits immutable representation and retains raw before segmentation',
    () async {
      final job = admitted();
      await scheduler.runOne();
      final actual = media.audio.transformJob(job.id)!;
      expect(actual.state, AudioJobState.completed);
      expect(starts, 1);
      final retained = media.audio
          .representations(chunk.id)
          .singleWhere((r) => r.codec == 'opus');
      expect(retained.sha256, digest);
      expect(retained.preSkip, 312);
      expect(
        File(
          '${database.path.substring(0, database.path.lastIndexOf('/'))}/${retained.relativePath}',
        ).readAsBytesSync(),
        payload,
      );
      expect(
        media.audio
            .representations(chunk.id)
            .singleWhere((r) => r.codec == 'pcm_s16le')
            .state,
        AudioRepresentationState.published,
      );
      expect(await compression.purgeReady(), 0);
    },
  );
  test(
    'later VAD flush and reader exit permit purge; retained media remains available',
    () async {
      admitted();
      await scheduler.runOne();
      silenceFlushed();
      final raw = media.audio
          .representations(chunk.id)
          .singleWhere((r) => r.codec == 'pcm_s16le');
      final reader = media.audio.acquireReference(
        raw.id,
        ownerGeneration: media.ownerGeneration,
        purpose: 'player',
      );
      expect(await compression.purgeReady(), 0);
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
        ).existsSync(),
        true,
      );
      media.audio.releaseReference(reader);
      expect(await compression.purgeReady(), 1);
      expect(
        media.audio
            .representations(chunk.id)
            .singleWhere((r) => r.id == raw.id)
            .state,
        AudioRepresentationState.purged,
      );
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
        ).existsSync(),
        false,
      );
      expect(media.audio.usableRepresentations(chunk.id).single.codec, 'opus');
    },
  );
  test(
    'checksum failure retries without publishing or purging source',
    () async {
      final job = admitted();
      corruptResult = true;
      await scheduler.runOne();
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.retry);
      expect(
        media.audio.usableRepresentations(chunk.id).single.codec,
        'pcm_s16le',
      );
      corruptResult = false;
      now = 100000;
      await scheduler.runOne();
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
      expect(starts, 2);
    },
  );
  test(
    'flushed silence can purge immediately after durable compression commit',
    () async {
      silenceFlushed();
      final job = admitted();
      await scheduler.runOne();
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
      expect(media.audio.usableRepresentations(chunk.id).single.codec, 'opus');
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
        ).existsSync(),
        false,
      );
    },
  );
  test(
    'restart completes phase-one raw purge without relying on a pending job',
    () async {
      admitted();
      await scheduler.runOne();
      silenceFlushed();
      final raw = media.audio.beginRawPurge(chunk.id)!;
      expect(raw.state, AudioRepresentationState.supersededPendingPurge);
      await scheduler.close();
      media.close();
      media = RecordingMedia.open(
        database,
        ownerGeneration: AudioStore.newIdentity(),
      );
      compression = AudioCompressionMedia(media: media, startWorker: synthetic);
      scheduler = owner();
      expect(await compression.purgeReady(), 1);
      expect(
        media.audio
            .representations(chunk.id)
            .singleWhere((r) => r.id == raw.id)
            .state,
        AudioRepresentationState.purged,
      );
    },
  );
  test(
    'lossless policy preserves originals after completed compression and VAD',
    () async {
      await scheduler.close();
      compression = AudioCompressionMedia(
        media: media,
        startWorker: synthetic,
        retainLossless: (_) => true,
      );
      scheduler = owner();
      silenceFlushed();
      admitted();
      await scheduler.runOne();
      expect(await compression.purgeReady(), 0);
      expect(media.audio.usableRepresentations(chunk.id), hasLength(2));
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
        ).existsSync(),
        true,
      );
    },
  );
  test(
    'keep flag and verified purge recovery preserve remaining originals',
    () async {
      admitted();
      await scheduler.runOne();
      silenceFlushed();
      final raw = media.audio.beginRawPurge(chunk.id)!;
      media.audio.setRetainLossless(session.id, true);
      await expectLater(
        compression.restoreRetainedOriginals(
          session.id,
          quiesced: () => false,
          current: () => true,
        ),
        throwsStateError,
      );
      expect(
        () => media.audio.cancelRawPurge(raw.id, verifiedSha256: 'f' * 64),
        throwsStateError,
      );
      final result = await compression.restoreRetainedOriginals(
        session.id,
        quiesced: () => true,
        current: () => true,
      );
      expect(result.restored, 1);
      expect(result.nextAfterId, null);
      expect(media.audio.usableRepresentations(chunk.id), hasLength(2));
      expect(await compression.purgeReady(), 0);
    },
  );
  test(
    'retention recovery cannot recreate originals already physically unlinked',
    () async {
      admitted();
      await scheduler.runOne();
      silenceFlushed();
      final raw = media.audio.beginRawPurge(chunk.id)!;
      final directory = BackupDirectory(
        media.sessionDirectory(session.id),
        create: false,
      );
      directory.remove('${chunk.id}.wav');
      directory.sync();
      directory.close();
      media.audio.setRetainLossless(session.id, true);
      expect(
        (await compression.restoreRetainedOriginals(
          session.id,
          quiesced: () => true,
          current: () => true,
        )).restored,
        0,
      );
      expect(
        media.audio
            .representations(chunk.id)
            .singleWhere((r) => r.id == raw.id)
            .state,
        AudioRepresentationState.purged,
      );
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
        ).existsSync(),
        false,
      );
    },
  );
  test('corrupt remaining original cannot withdraw its purge fence', () async {
    admitted();
    await scheduler.runOne();
    silenceFlushed();
    final raw = media.audio.beginRawPurge(chunk.id)!;
    final directory = BackupDirectory(
      media.sessionDirectory(session.id),
      create: false,
    );
    directory.open('${chunk.id}.wav')
      ..truncateTo(1)
      ..close();
    directory.close();
    media.audio.setRetainLossless(session.id, true);
    await expectLater(
      compression.restoreRetainedOriginals(
        session.id,
        quiesced: () => true,
        current: () => true,
      ),
      throwsFormatException,
    );
    expect(
      media.audio
          .representations(chunk.id)
          .singleWhere((r) => r.id == raw.id)
          .state,
      AudioRepresentationState.supersededPendingPurge,
    );
    expect(database.db.select('SELECT 1 FROM audio_media_references'), isEmpty);
  });
  test(
    'retention read and cancellation remain joined by the real filesystem fence',
    () async {
      admitted();
      await scheduler.runOne();
      silenceFlushed();
      final raw = media.audio.beginRawPurge(chunk.id)!;
      media.audio.setRetainLossless(session.id, true);
      var current = true;
      final work = compression.restoreRetainedOriginals(
        session.id,
        quiesced: () => true,
        current: () => current,
      );
      expect(
        database.db.select('SELECT 1 FROM audio_media_references'),
        hasLength(1),
      );
      final fence = compression.fencePurges();
      fence.ignore();
      current = false;
      await expectLater(work, throwsStateError);
      await expectLater(fence, throwsStateError);
      expect(
        database.db.select('SELECT 1 FROM audio_media_references'),
        isEmpty,
      );
      expect(
        media.audio
            .representations(chunk.id)
            .singleWhere((r) => r.id == raw.id)
            .state,
        AudioRepresentationState.supersededPendingPurge,
      );
    },
  );
  test(
    'retained checksum is revalidated before deleting the lossless source',
    () async {
      admitted();
      await scheduler.runOne();
      silenceFlushed();
      final retained = media.audio
          .usableRepresentations(chunk.id)
          .singleWhere((r) => r.codec == 'opus');
      final directory = BackupDirectory(
        media.sessionDirectory(session.id),
        create: false,
      );
      final file = directory.open(retained.relativePath.split('/').last);
      file.truncateTo(1);
      file.close();
      directory.close();
      await expectLater(compression.purgeReady(), throwsFormatException);
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${chunk.id}.wav',
        ).existsSync(),
        true,
      );
      expect(
        database.db.select('SELECT 1 FROM audio_media_references'),
        isEmpty,
      );
    },
  );
  test(
    'receipt-before-rename restart publishes validated staged bytes once',
    () async {
      await scheduler.close();
      compression = AudioCompressionMedia(
        media: media,
        startWorker: synthetic,
        publicationObserver: (phase) {
          if (phase == 'before_publish') throw StateError('crash');
        },
      );
      scheduler = owner();
      final job = admitted();
      await scheduler.runOne();
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.retry);
      expect(
        File(
          '${media.sessionDirectory(session.id)}/${job.id}.opus',
        ).existsSync(),
        false,
      );
      await scheduler.close();
      media.close();
      media = RecordingMedia.open(
        database,
        ownerGeneration: AudioStore.newIdentity(),
      );
      compression = AudioCompressionMedia(media: media, startWorker: synthetic);
      scheduler = owner();
      now = 100000;
      await scheduler.runOne();
      expect(starts, 1);
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
    },
  );
  test('admission pages all chunks and wraps for later publications', () {
    for (var i = 1; i < 140; i++) {
      final id = AudioStore.newIdentity();
      final publication = media.audio.preallocateChunk(
        sessionId: session.id,
        spanId: span.id,
        source: AudioSource.microphone,
        sequence: i,
        id: id,
        relativePath:
            'recordings/${session.storageGeneration}/${session.id}/$id.wav',
      );
      media.audio.publishPreallocatedChunk(
        publication.id,
        publicationToken: publication.publicationToken,
        sampleStart: i * 4800,
        sampleCount: 4800,
        sampleRate: 48000,
        channels: 1,
        captureStartUs: i * 100000,
        captureEndUs: (i + 1) * 100000,
        byteLength: 9796,
        sha256: 'a' * 64,
      );
    }
    var count = 0;
    while (true) {
      final n = compression.admitPending(limit: 17);
      if (n == 0) break;
      count += n;
    }
    expect(count, 140);
    expect(
      database.db
          .select('SELECT COUNT(*) AS n FROM audio_transform_jobs')
          .single['n'],
      140,
    );
  });
  test(
    'restart adopts exact validated publication instead of rerunning codec',
    () async {
      final job = admitted();
      final lease = media.audio.claimTransformJob(
        job.id,
        ownerGeneration: media.ownerGeneration,
        nowMs: 0,
      )!;
      final operation = await compression.prepare(lease, () => true);
      final execution = await operation.start();
      final result = await execution.result;
      await execution.closed;
      operation.markWorkerClosed();
      final output = await operation.publish(result);
      expect(output.representation!.sha256, digest);
      operation.close();
      await scheduler.close();
      media.close();
      media = RecordingMedia.open(
        database,
        ownerGeneration: AudioStore.newIdentity(),
      );
      compression = AudioCompressionMedia(media: media, startWorker: synthetic);
      scheduler = owner();
      await scheduler.runOne();
      expect(starts, 1);
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
    },
  );
  test(
    'manifest failure preserves validated receipt and retry does not reencode',
    () async {
      final job = admitted();
      database.db.execute(
        "CREATE TEMP TRIGGER refuse_compression_commit BEFORE UPDATE OF state ON audio_transform_jobs WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'simulated commit failure'); END",
      );
      await scheduler.runOne();
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.retry);
      expect(starts, 1);
      database.db.execute('DROP TRIGGER refuse_compression_commit');
      now = 100000;
      await scheduler.runOne();
      expect(media.audio.transformJob(job.id)!.state, AudioJobState.completed);
      expect(starts, 1);
    },
  );
  test('changed source or foreign output cannot be adopted', () async {
    final job = admitted();
    final path = '${media.sessionDirectory(session.id)}/${chunk.id}.wav';
    final file = File(path).openSync(mode: FileMode.writeOnlyAppend);
    file.writeByteSync(1);
    file.closeSync();
    await scheduler.runOne();
    expect(media.audio.transformJob(job.id)!.state, AudioJobState.retry);
    expect(starts, 0);
    expect(media.audio.representations(chunk.id), hasLength(1));
  });
  test(
    'real fixed Opus worker persists validated frames and decoded silence',
    () async {
      final env = Platform.environment;
      final bindings = NativeLibrary(
        DynamicLibrary.open(env['FORESIGHT_NATIVE_LIBRARY']!),
      );
      final worker = NativeAudioCompressionWorker(
        bindings: bindings,
        executable: AudioMediaExecutable(
          path: env['FORESIGHT_TEST_MEDIA_WORKER']!,
          sha256: env['FORESIGHT_TEST_MEDIA_SHA256']!,
          buildId: env['FORESIGHT_TEST_MEDIA_BUILD_ID']!,
          macosCdHash: env['FORESIGHT_TEST_MEDIA_CDHASH'] ?? '',
        ),
      );
      await scheduler.close();
      compression = AudioCompressionMedia(
        media: media,
        startWorker: worker.start,
      );
      scheduler = owner();
      final job = admitted();
      await scheduler.runOne();
      final actual = media.audio.transformJob(job.id)!;
      if (actual.state != AudioJobState.completed) {
        fail(
          'Actual fixed worker failed: ${scheduler.lastError}; job=${actual.error}',
        );
      }
      final retained = media.audio
          .usableRepresentations(chunk.id)
          .singleWhere((r) => r.codec == 'opus');
      expect(retained.decodedSamples, 4800);
      expect(retained.byteLength, lessThan(chunk.byteLength!));
      final directory = BackupDirectory(
        media.sessionDirectory(session.id),
        create: false,
      );
      final input = directory.open('${job.id}.opus', readOnly: true),
          output = directory.open('decoded.raw', create: true);
      final task = await NativeAudioMediaTask.start(
        bindings: bindings,
        executable: worker.executable,
        request: AudioMediaRequest(
          operation: AudioMediaOperation.decodePcm,
          sessionId: session.id,
          jobId: AudioStore.newIdentity(),
          epoch: 1,
          inputSha256: retained.sha256,
          sourceFrames: 4800,
          startFrame: 0,
          frameCount: 4800,
        ),
        inputDescriptor: input.descriptor,
        outputDescriptor: output.descriptor,
        ownerLockDescriptor: media.ownerLockDescriptor,
        current: () => true,
      );
      try {
        final decoded = await task.result;
        await task.closed;
        expect(decoded.frames, 4800);
        expect(output.readSmall(9600), everyElement(0));
      } finally {
        await task.closed;
        input.close();
        output.close();
        directory.close();
      }
    },
    skip:
        Platform.environment['FORESIGHT_TEST_MEDIA_WORKER'] == null ||
            Platform.environment['FORESIGHT_NATIVE_LIBRARY'] == null ||
            Platform.environment['FORESIGHT_TEST_MEDIA_SHA256'] == null
        ? 'Requires verified fixed worker/native pair and exact installation identity'
        : false,
  );
}
